defmodule Lasso.RPC.CircuitBreakerHalfOpenAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, ControlRing, Snapshot, Storage}

  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal, ExecutionProjector}

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

  test "request owner activates its half-open lease with one exact local CAS" do
    {id, breaker_pid} = start_half_open_breaker()

    assert {:ok, %AdmissionReceipt{kind: :half_open} = receipt} =
             CircuitBreaker.admit(id, deadline_us())

    assert [{^id, %{claimed?: false, owner_pid: owner}}] = :ets.lookup(Storage.lease_table(), id)
    assert owner == self()

    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.activate_attempt(receipt, self())
    assert [{^id, %{claimed?: true, owner_pid: owner}}] = :ets.lookup(Storage.lease_table(), id)
    assert owner == self()
    assert {:error, :stale} = CircuitBreaker.activate_attempt(receipt, self())

    :sys.resume(breaker_pid)
    CircuitBreaker.release_half_open(receipt)
    await_no_lease(id)
  end

  test "stale route feedback consumes its lease without changing half-open control state" do
    {id, breaker_pid} = start_half_open_breaker()
    assert {:ok, receipt} = CircuitBreaker.admit(id, deadline_us())
    assert :ok = CircuitBreaker.activate_attempt(receipt, self())

    identity =
      AttemptIdentity.new(
        request_id: "half-open-route-request",
        attempt_id: "half-open-route-attempt",
        profile: "public",
        chain_id: 1,
        upstream_instance_id: elem(id, 0),
        transport: :http,
        route_generation: ConfigStore.route_generation() + 1,
        circuit_scope: :broad,
        circuit_epoch: receipt.epoch,
        execution_safety: :replay_safe,
        routing_intent: "default",
        workload_key: "default",
        request_budget_ms: 100,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    fact = AttemptTerminal.Response.new(identity, :success, 10)
    assert :ok = CircuitBreaker.report_canonical(receipt, fact, ExecutionProjector.project(fact))
    await_no_lease(id)

    assert %{state: :half_open, inflight_count: 0, success_count: 0, failure_count: 0} =
             :sys.get_state(breaker_pid)
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

  test "the caller directly owns its half-open lease until the call reports" do
    {id, breaker_pid} = start_half_open_breaker()
    parent = self()

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          CircuitBreaker.call(
            id,
            fn ->
              send(parent, {:attempt_started, self()})
              receive do: (:finish_attempt -> :ok)
            end,
            5_000
          )

        send(parent, {:call_result, result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:attempt_started, worker}, 1_000
    assert worker != caller
    assert [{^id, %{owner_pid: ^caller, claimed?: true}}] = :ets.lookup(Storage.lease_table(), id)
    assert Process.alive?(caller)
    send(worker, :finish_attempt)

    assert_receive {:call_result, {:executed, :ok}}, 1_000
    assert Process.alive?(caller)
    await_no_lease(id)
    assert %{inflight_count: 0, inflight_attempts: %{}} = :sys.get_state(breaker_pid)
    assert [] = :ets.lookup(Storage.lease_table(), id)
    send(caller, :stop)
  end

  test "call timeout terminates admitted work and releases half-open capacity" do
    {id, breaker_pid} = start_half_open_breaker()
    parent = self()

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          CircuitBreaker.call(
            id,
            fn ->
              send(parent, {:blocked_worker, self()})
              receive do: (:never -> :ok)
            end,
            25
          )

        Process.sleep(10)
        send(parent, {:blocked_call_result, result, Process.info(self(), :messages)})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:blocked_worker, worker}, 1_000

    assert_receive {
                     :blocked_call_result,
                     {:rejected, :admission_timeout},
                     {:messages, []}
                   },
                   1_000

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    refute Process.alive?(worker)
    await_no_lease(id)

    assert %{state: :half_open, inflight_count: 0, inflight_attempts: %{}} =
             :sys.get_state(breaker_pid)

    assert [] = :ets.lookup(Storage.lease_table(), id)
    assert {:executed, :ok} = CircuitBreaker.call(id, fn -> :ok end, 100)
  end

  test "call worker and half-open lease are released when the caller dies" do
    {id, breaker_pid} = start_half_open_breaker()
    parent = self()

    caller =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            send(parent, {:caller_owned_worker, self()})
            receive do: (:never -> :ok)
          end,
          5_000
        )
      end)

    assert_receive {:caller_owned_worker, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    await_no_lease(id)
    assert %{inflight_count: 0, inflight_attempts: %{}} = :sys.get_state(breaker_pid)
  end

  test "an admitted worker exit is reported truthfully without caller mailbox residue" do
    {id, _breaker_pid} = start_half_open_breaker()
    parent = self()

    caller =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          CircuitBreaker.call(
            id,
            fn ->
              send(parent, {:kill_worker, self()})
              receive do: (:never -> :ok)
            end,
            1_000
          )

        send(parent, {:worker_exit_result, result, Process.info(self(), :messages)})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:kill_worker, worker}, 1_000
    Process.exit(worker, :kill)

    assert_receive {
                     :worker_exit_result,
                     {:executed, {:exception, {:exit, :killed, []}}},
                     {:messages, []}
                   },
                   1_000

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    await_no_lease(id)
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

  test "exceptional activation is local while the breaker owner is suspended" do
    {id, breaker_pid} = start_half_open_breaker()
    assert {:ok, receipt} = CircuitBreaker.admit(id, System.monotonic_time(:microsecond) + 25_000)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)
    started_us = System.monotonic_time(:microsecond)

    assert :ok = CircuitBreaker.activate_attempt(receipt, self())

    assert System.monotonic_time(:microsecond) - started_us < 100_000
    assert [{^id, %{claimed?: true}}] = :ets.lookup(Storage.lease_table(), id)
    :sys.resume(breaker_pid)
    CircuitBreaker.release_half_open(receipt)
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
