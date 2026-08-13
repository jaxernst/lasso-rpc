defmodule Lasso.RPC.CircuitBreakerHalfOpenAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, Snapshot, Storage}

  test "concurrent recovery candidates produce one bounded lease" do
    {id, breaker_pid} = start_half_open_breaker()
    parent = self()

    first =
      Task.async(fn ->
        result = CircuitBreaker.admit(id, deadline_us())
        send(parent, {:first_admission, self(), result})
        receive do: (:release_owner -> result)
      end)

    assert_receive {:first_admission, first_owner,
                    {:ok, %AdmissionReceipt{kind: :half_open} = receipt}}

    assert {:error, :half_open_busy} = CircuitBreaker.admit(id, deadline_us())
    assert :sys.get_state(breaker_pid).inflight_count == 1
    assert [{^id, %{token: token}}] = :ets.lookup(Storage.lease_table(), id)
    assert token == receipt.token

    CircuitBreaker.release_half_open(receipt)
    send(first_owner, :release_owner)
    assert {:ok, ^receipt} = Task.await(first)
    assert %{inflight_count: 0} = :sys.get_state(breaker_pid)
    assert [] = :ets.lookup(Storage.lease_table(), id)
  end

  test "owner death releases a live lease exactly once" do
    {id, breaker_pid} = start_half_open_breaker()
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:receipt, CircuitBreaker.admit(id, deadline_us())})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:receipt, {:ok, %AdmissionReceipt{kind: :half_open}}}
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert %{inflight_count: 0, inflight_attempts: %{}} = :sys.get_state(breaker_pid)
    assert [] = :ets.lookup(Storage.lease_table(), id)
  end

  test "restart publishes a fresh conservative epoch and recovers a live lease" do
    {id, breaker_pid} = start_half_open_breaker()

    assert {:ok, %AdmissionReceipt{kind: :half_open} = old_receipt} =
             CircuitBreaker.admit(id, deadline_us())

    {:ok, old_snapshot} = Snapshot.lookup(id)
    :ok = GenServer.stop(breaker_pid)
    {:ok, restarted_pid} = CircuitBreaker.start_link({id, %{success_threshold: 1}})

    on_exit(fn -> if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid) end)

    assert {:ok,
            %Snapshot{
              state: :half_open,
              control_health: :degraded,
              half_open_inflight: 1
            } = restarted_snapshot} = Snapshot.lookup(id)

    assert restarted_snapshot.epoch != old_snapshot.epoch
    assert restarted_snapshot.generation > old_snapshot.generation
    assert :sys.get_state(restarted_pid).inflight_count == 1

    CircuitBreaker.report_half_open(old_receipt, :ok)
    assert %{state: :half_open, inflight_count: 0} = :sys.get_state(restarted_pid)
    assert [] = :ets.lookup(Storage.lease_table(), id)
  end

  test "a live registered owner is not reclaimed by elapsed wall time" do
    {id, breaker_pid} = start_half_open_breaker()

    assert {:ok, %AdmissionReceipt{kind: :half_open} = receipt} =
             CircuitBreaker.admit(id, deadline_us())

    send(breaker_pid, {:attempt_proactive_recovery, 999_999})
    assert %{inflight_count: 1} = :sys.get_state(breaker_pid)
    assert [{^id, %{token: token}}] = :ets.lookup(Storage.lease_table(), id)
    assert token == receipt.token
  end

  defp start_half_open_breaker do
    id = {"half-open-#{System.unique_integer([:positive])}", :http}
    {:ok, pid} = CircuitBreaker.start_link({id, %{success_threshold: 1}})
    state = :sys.replace_state(pid, &%{&1 | state: :half_open})

    Snapshot.put(%Snapshot{
      breaker_id: id,
      state: :half_open,
      generation: state.transition_generation,
      epoch: state.process_epoch,
      owner_pid: pid,
      ready?: true,
      recovery_deadline_us: nil,
      half_open_capacity: 1,
      half_open_inflight: 0,
      control_health: :healthy
    })

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      :ets.delete(Storage.snapshot_table(), id)
      :ets.delete(Storage.lease_table(), id)
      :ets.delete(Storage.control_meta_table(), id)
    end)

    {id, pid}
  end

  defp deadline_us, do: System.monotonic_time(:microsecond) + 100_000
end
