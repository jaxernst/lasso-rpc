defmodule Lasso.RPC.CircuitBreakerAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.{Admission, AdmissionReceipt, Snapshot, Storage}
  alias Lasso.Core.Transport.AttemptProtocol

  setup do
    id = {"admission-#{System.unique_integer([:positive])}", :http}
    {:ok, breaker_pid} = CircuitBreaker.start_link({id, %{recovery_timeout: 60_000}})

    on_exit(fn ->
      if Process.alive?(breaker_pid), do: GenServer.stop(breaker_pid)
      :ets.delete(Storage.snapshot_table(), id)
    end)

    %{id: id, breaker_pid: breaker_pid}
  end

  test "closed admission does not cross the suspended owner", %{
    id: id,
    breaker_pid: breaker_pid
  } do
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)
    {:message_queue_len, queued_before} = Process.info(breaker_pid, :message_queue_len)

    deadline_us = System.monotonic_time(:microsecond) + 25_000

    assert {:ok, %AdmissionReceipt{kind: :closed}} = Admission.check(id, deadline_us)
    assert {:transport_ran, :ok} = run_after_admission(id, deadline_us, fn -> :ok end)
    assert {:message_queue_len, ^queued_before} = Process.info(breaker_pid, :message_queue_len)
  end

  test "closed call does not wait for the suspended breaker owner", %{
    id: id,
    breaker_pid: breaker_pid
  } do
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)
    started_us = System.monotonic_time(:microsecond)

    assert {:executed, :ok} = CircuitBreaker.call(id, fn -> :ok end, 100)
    assert System.monotonic_time(:microsecond) - started_us < 100_000
  end

  test "a positive one millisecond budget can execute eligible work", %{id: id} do
    results =
      for _attempt <- 1..100 do
        CircuitBreaker.call(id, fn -> :ok end, 1)
      end

    assert Enum.any?(results, &(&1 == {:executed, :ok}))
  end

  test "a successful call leaves no linked-task exit in a trapping caller", %{id: id} do
    parent = self()

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        result = CircuitBreaker.call(id, fn -> :ok end, 100)
        Process.sleep(10)
        send(parent, {:successful_call, result, Process.info(self(), :messages)})
      end)

    caller_monitor = Process.monitor(caller)

    assert_receive {:successful_call, {:executed, :ok}, {:messages, []}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
  end

  test "snapshot admission invokes no telemetry consumer", %{id: id} do
    test_pid = self()
    handler_id = "admission-consumer-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :circuit_breaker, :snapshot_admission],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :unexpected_snapshot_admission_telemetry)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %AdmissionReceipt{kind: :closed}} = Admission.check(id, deadline_us())
    refute_receive :unexpected_snapshot_admission_telemetry, 0
  end

  test "call does not invoke an admission telemetry consumer", %{id: id} do
    test_pid = self()
    handler_id = "call-admission-consumer-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :circuit_breaker, :admit],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, {:admission_handler_entered, self()})
          receive do: (:release_admission_handler -> :ok)
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      receive do
        {:admission_handler_entered, caller} -> send(caller, :release_admission_handler)
      after
        0 -> :ok
      end
    end)

    assert {:executed, :ok} = CircuitBreaker.call(id, fn -> :ok end, 100)
    refute_receive {:admission_handler_entered, _caller}, 0
  end

  test "open admission denies while its owner is suspended", %{
    id: id,
    breaker_pid: breaker_pid
  } do
    CircuitBreaker.open(id)
    assert %{state: :open} = CircuitBreaker.get_state(id)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    deadline_us = System.monotonic_time(:microsecond) + 25_000
    assert {:error, :circuit_open} = Admission.check(id, deadline_us)
  end

  test "missing, unready, and dead-owner snapshots fail closed", %{id: id} do
    :ets.delete(Storage.snapshot_table(), id)
    assert {:error, :admission_unavailable} = Admission.check(id, deadline_us())

    put_snapshot(id, self(), ready?: false)
    assert {:error, :admission_unavailable} = Admission.check(id, deadline_us())

    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    put_snapshot(id, owner)
    assert {:error, :admission_unavailable} = Admission.check(id, deadline_us())
  end

  test "the open recovery boundary is exceptional and equality expires", %{id: id} do
    now_us = System.monotonic_time(:microsecond)
    put_snapshot(id, self(), state: :open, recovery_deadline_us: now_us + 1)

    assert {:error, :circuit_open} = Admission.check(id, now_us + 10, now_us)

    assert {:exceptional, %Snapshot{state: :open}} =
             Admission.check(id, now_us + 10, now_us + 1)

    assert {:error, :admission_timeout} = Admission.check(id, now_us + 1, now_us + 1)
  end

  test "an expired closed snapshot never authorizes transport", %{id: id} do
    now_us = System.monotonic_time(:microsecond)

    assert {:error, :admission_timeout} = Admission.check(id, now_us, now_us)

    assert {:error, :admission_timeout} =
             run_after_admission(id, now_us - 1, fn -> flunk("transport ran after deadline") end)
  end

  test "a closed receipt cannot dispatch after its captured deadline", %{id: id} do
    deadline_us = System.monotonic_time(:microsecond) + 10_000
    assert {:ok, _receipt} = Admission.check(id, deadline_us)
    context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)
    wait_until(deadline_us)

    assert {:error, :deadline_expired} = AttemptProtocol.send_started(context)
    assert AttemptProtocol.close(context).certainty == :not_dispatched
  end

  defp run_after_admission(id, deadline_us, fun) do
    case Admission.check(id, deadline_us) do
      {:ok, _receipt} -> {:transport_ran, fun.()}
      other -> other
    end
  end

  defp wait_until(deadline_us) do
    if System.monotonic_time(:microsecond) < deadline_us do
      Process.sleep(1)
      wait_until(deadline_us)
    end
  end

  defp put_snapshot(id, owner_pid, overrides \\ []) do
    defaults = [
      breaker_id: id,
      state: :closed,
      generation: 1,
      epoch: 1,
      owner_pid: owner_pid,
      ready?: true,
      recovery_deadline_us: nil,
      half_open_capacity: 1,
      half_open_inflight: 0,
      control_health: :healthy
    ]

    defaults
    |> Keyword.merge(overrides)
    |> then(&struct!(Snapshot, &1))
    |> Snapshot.put()
  end

  defp deadline_us, do: System.monotonic_time(:microsecond) + 25_000
end
