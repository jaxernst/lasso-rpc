defmodule Lasso.RPC.CircuitBreakerControlRingTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.{Admission, ControlRing, Snapshot, Storage}
  alias Lasso.JSONRPC.Error, as: JError

  test "suspension preserves hard slot and wakeup bounds and degrades only one scope" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {other_id, _other_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())

    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    results = Enum.map(1..12, fn _index -> CircuitBreaker.report_closed(receipt, :ok) end)

    assert Enum.count(results, &(&1 == :ok)) == 4
    assert Enum.count(results, &(&1 == {:error, :saturated})) == 8
    assert %{capacity: 4, occupied: 4, wakeup_pending: 1, dropped: 8} = ControlRing.stats(id)
    assert ordinary_wakeup_count(breaker_pid, id) == 1
    assert {:ok, %Snapshot{control_health: :degraded}} = Snapshot.lookup(id)
    assert {:ok, %Snapshot{control_health: :healthy, state: :closed}} = Snapshot.lookup(other_id)

    :sys.resume(breaker_pid)
    assert %{state: :half_open} = CircuitBreaker.get_state(id)

    assert {:ok, %Snapshot{state: :half_open, control_health: :healthy, generation: 2}} =
             Snapshot.lookup(id)
  end

  test "draining a bounded batch rearms a wakeup while slots remain occupied" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)

    assert [_signal] = ControlRing.drain(id, 1, receipt.generation, receipt.epoch)
    assert %{occupied: 2, wakeup_pending: 1} = ControlRing.stats(id)
    assert ordinary_wakeup_count(breaker_pid, id) <= 2
  end

  test "the compatibility adapter retains no large response or error payload" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 2)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    huge = String.duplicate("sensitive-body", 100_000)

    error =
      JError.new(-32_000, huge,
        category: :server_error,
        retriable?: true,
        breaker_penalty?: true,
        data: %{"body" => huge}
      )

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, error, 1})

    retained =
      Storage.control_table()
      |> :ets.tab2list()
      |> Enum.filter(fn
        {{breaker_id, _index}, {_ring_ref, {_ticket, _generation, _epoch, _signal}}} ->
          breaker_id == id

        _ ->
          false
      end)

    assert byte_size(:erlang.term_to_binary(retained)) < 512
    refute inspect(retained) =~ "sensitive-body"
  end

  test "the ring drains accepted outcomes in linearized producer order" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})

    assert [
             {:failure, :timeout, true},
             :success,
             {:failure, :timeout, true}
           ] = ControlRing.drain(id, 4, receipt.generation, receipt.epoch)
  end

  test "an old ring reference cannot write into replacement slots" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 2)
    {:ok, receipt} = Admission.check(id, deadline_us())

    [{^id, _, _, _, 2, _wakeup, _diagnostics, old_ring_ref}] =
      :ets.lookup(Storage.control_meta_table(), id)

    ControlRing.initialize(id, receipt.generation + 1, receipt.epoch + 1, breaker_pid,
      capacity: 2
    )

    old_sequence = System.unique_integer([:positive, :monotonic])
    key = {id, rem(old_sequence, 2)}

    match_spec = [
      {{key, {old_ring_ref, :empty}}, [],
       [
         {:const,
          {key, {old_ring_ref, {old_sequence, receipt.generation, receipt.epoch, :success}}}}
       ]}
    ]

    assert 0 = :ets.select_replace(Storage.control_table(), match_spec)
    assert [] = ControlRing.drain(id, 2, receipt.generation, receipt.epoch)
  end

  defp start_breaker(config) do
    id = {"control-#{System.unique_integer([:positive])}", :http}
    {:ok, pid} = CircuitBreaker.start_link({id, Map.new(config)})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      :ets.delete(Storage.snapshot_table(), id)
      :ets.delete(Storage.lease_table(), id)
      :ets.delete(Storage.control_meta_table(), id)
    end)

    {id, pid}
  end

  defp ordinary_wakeup_count(pid, id) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.count(messages, fn
      {:breaker_control_ready, ^id, _generation, _epoch} -> true
      _ -> false
    end)
  end

  defp deadline_us, do: System.monotonic_time(:microsecond) + 100_000
end
