defmodule Lasso.RPC.CircuitBreakerHalfOpenAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.{AttemptLifecycle, CircuitBreaker}
  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, ControlRing, Snapshot, Storage}

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
    CircuitBreaker.release_half_open(old_receipt)
    assert %{state: :half_open, inflight_count: 1} = :sys.get_state(restarted_pid)
    assert [{^id, %{token: old_token}}] = :ets.lookup(Storage.lease_table(), id)
    assert old_token == old_receipt.token
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

  test "the caller retains half-open lease ownership when the lifecycle dies" do
    {id, breaker_pid} = start_half_open_breaker()
    parent = self()

    caller =
      spawn(fn ->
        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _attempt_ref} = AttemptLifecycle.dispatch_context()
              send(parent, {:attempt_started, lifecycle_pid})
              Process.sleep(:infinity)
            end,
            5_000
          )

        send(parent, {:call_result, result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:attempt_started, lifecycle_pid}, 1_000
    assert [{^id, %{owner_pid: ^caller, claimed?: true}}] = :ets.lookup(Storage.lease_table(), id)
    assert Process.alive?(caller)
    Process.exit(lifecycle_pid, :kill)

    assert_receive {:call_result, {:executed, {:exception, {:exit, :killed, []}}}}, 1_000
    assert Process.alive?(caller)
    assert %{inflight_count: 0, inflight_attempts: %{}} = :sys.get_state(breaker_pid)
    assert [] = :ets.lookup(Storage.lease_table(), id)
    send(caller, :stop)
  end

  test "restart preserves an unexpired open recovery deadline" do
    id = {"open-restart-#{System.unique_integer([:positive])}", :http}
    {:ok, pid} = CircuitBreaker.start_link({id, %{recovery_timeout: 60_000}})
    CircuitBreaker.open(id)
    await_snapshot_state(id, :open)

    assert {:ok, %Snapshot{state: :open, recovery_deadline_us: old_deadline}} =
             Snapshot.lookup(id)

    :ok = GenServer.stop(pid)

    {:ok, restarted_pid} = CircuitBreaker.start_link({id, %{recovery_timeout: 60_000}})

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid)
      :ets.delete(Storage.snapshot_table(), id)
      :ets.delete(Storage.lease_table(), id)
      ControlRing.delete(id)
    end)

    assert {:ok, %Snapshot{state: :open, recovery_deadline_us: new_deadline}} =
             Snapshot.lookup(id)

    assert new_deadline >= old_deadline
    assert {:error, :circuit_open} = CircuitBreaker.admit(id, deadline_us())
  end

  test "restart schedules proactive recovery at the preserved open deadline" do
    id = {"open-timer-#{System.unique_integer([:positive])}", :http}
    {:ok, pid} = CircuitBreaker.start_link({id, %{recovery_timeout: 20}})
    CircuitBreaker.open(id)
    await_snapshot_state(id, :open)
    :ok = GenServer.stop(pid)
    {:ok, restarted_pid} = CircuitBreaker.start_link({id, %{recovery_timeout: 20}})

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid)
      :ets.delete(Storage.snapshot_table(), id)
      :ets.delete(Storage.lease_table(), id)
      ControlRing.delete(id)
    end)

    await_snapshot_state(id, :half_open)
  end

  test "exceptional claim is bounded by the receipt deadline and cleanup is ordered" do
    {id, breaker_pid} = start_half_open_breaker()
    assert {:ok, receipt} = CircuitBreaker.admit(id, System.monotonic_time(:microsecond) + 25_000)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)
    started_us = System.monotonic_time(:microsecond)

    assert {:__attempt_lifecycle_rejected__, :timeout} =
             Lasso.Core.Support.AttemptLifecycle.run(
               self(),
               receipt,
               fn -> flunk("transport ran without claim") end,
               1_000,
               nil,
               nil,
               :immediate,
               receipt.deadline_us
             )

    assert System.monotonic_time(:microsecond) - started_us < 100_000
    :sys.resume(breaker_pid)
    await_no_lease(id)
  end

  test "an unclaimed lease abandoned during restart is not recovered" do
    {id, breaker_pid} = start_half_open_breaker()
    assert {:ok, receipt} = CircuitBreaker.admit(id, deadline_us())
    :ok = GenServer.stop(breaker_pid)
    CircuitBreaker.abandon_unclaimed(receipt, self())
    assert [] = :ets.lookup(Storage.lease_table(), id)

    {:ok, restarted_pid} = CircuitBreaker.start_link({id, %{success_threshold: 1}})
    on_exit(fn -> if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid) end)
    assert %{inflight_count: 0} = :sys.get_state(restarted_pid)
  end

  defp await_snapshot_state(id, state, attempts \\ 100)
  defp await_snapshot_state(_id, _state, 0), do: flunk("snapshot did not transition")

  defp await_snapshot_state(id, state, attempts) do
    case Snapshot.lookup(id) do
      {:ok, %Snapshot{state: ^state}} ->
        :ok

      _ ->
        Process.sleep(5)
        await_snapshot_state(id, state, attempts - 1)
    end
  end

  defp await_no_lease(id, attempts \\ 100)
  defp await_no_lease(_id, 0), do: flunk("lease was not released")

  defp await_no_lease(id, attempts) do
    case :ets.lookup(Storage.lease_table(), id) do
      [] ->
        :ok

      _ ->
        Process.sleep(5)
        await_no_lease(id, attempts - 1)
    end
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
