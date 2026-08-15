defmodule Lasso.RPC.CircuitBreakerControlRingTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker

  alias Lasso.Core.Support.CircuitBreaker.{
    Admission,
    AdmissionReceipt,
    ControlRing,
    Snapshot,
    Storage
  }

  alias Lasso.JSONRPC.Error, as: JError

  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal, ExecutionProjector}

  test "failure saturation preserves hard bounds and degrades only one breaker" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {other_id, _other_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    results =
      Enum.map(1..12, fn _index -> CircuitBreaker.report_closed(receipt, {:error, :timeout}) end)

    assert Enum.count(results, &(&1 == :ok)) == 4
    assert Enum.count(results, &(&1 == {:error, :saturated})) == 8

    assert %{capacity: 4, occupied: 4, wakeup_pending: 1, failure_dropped: 8} =
             ControlRing.stats(id)

    assert ordinary_wakeup_count(breaker_pid, id) == 1
    assert {:ok, %Snapshot{control_health: :degraded}} = Snapshot.lookup(id)
    assert {:ok, %Snapshot{control_health: :healthy, state: :closed}} = Snapshot.lookup(other_id)
  end

  test "draining a bounded batch rearms a wakeup while slots remain occupied" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    Enum.each(1..3, fn _index ->
      assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    end)

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
        {{breaker_id, _slot}, {_ring_ref, {_ticket, _generation, _epoch, _signal}}} ->
          breaker_id == id

        _ ->
          false
      end)

    assert byte_size(:erlang.term_to_binary(retained)) < 512
    refute inspect(retained) =~ "sensitive-body"
  end

  test "a success before an undrained failure is conservatively ignored" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})

    assert [{:failure, :timeout, true}, {:failure, :timeout, true}] =
             ControlRing.drain(id, 4, receipt.generation, receipt.epoch)
  end

  test "canonical closed feedback is fenced by the captured route generation" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 2)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    stale = invalid_fact(id, receipt, ConfigStore.route_generation() + 1)
    current = invalid_fact(id, receipt, ConfigStore.route_generation())

    assert :ok =
             CircuitBreaker.report_canonical(receipt, stale, ExecutionProjector.project(stale))

    assert %{occupied: 0} = ControlRing.stats(id)

    assert :ok =
             CircuitBreaker.report_canonical(
               receipt,
               current,
               ExecutionProjector.project(current)
             )

    assert %{occupied: 1} = ControlRing.stats(id)
  end

  test "a needed success shares failure ordering without consuming failure capacity" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 2, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    await_failure_count(id, 1)

    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})

    assert %{occupied: 3, success_marker?: true, failure_dropped: 0} = ControlRing.stats(id)

    assert [:success, {:failure, :timeout, true}] =
             ControlRing.drain(id, 2, receipt.generation, receipt.epoch)

    assert [{:failure, :timeout, true}] =
             ControlRing.drain(id, 2, receipt.generation, receipt.epoch)
  end

  test "concurrent needed successes coalesce into one marker" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 2, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    await_failure_count(id, 1)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    1..100
    |> Task.async_stream(fn _index -> CircuitBreaker.report_closed(receipt, :ok) end,
      max_concurrency: 100,
      ordered: false
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    assert %{occupied: 1, success_marker?: true} = ControlRing.stats(id)
    assert [:success] = ControlRing.drain(id, 2, receipt.generation, receipt.epoch)
  end

  test "a later needed success refreshes the marker behind an intervening failure" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 2, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    await_failure_count(id, 1)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)

    assert [{:failure, :timeout, true}, :success] =
             ControlRing.drain(id, 3, receipt.generation, receipt.epoch)
  end

  test "concurrent success refreshes retain one newest ordered marker" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 4, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    await_failure_count(id, 1)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})

    results =
      1..100
      |> Task.async_stream(fn _index -> CircuitBreaker.report_closed(receipt, :ok) end,
        max_concurrency: 100,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 in [:ok, {:error, :saturated}]))

    stats = ControlRing.stats(id)
    assert stats.success_marker?
    assert stats.occupied == 2
    assert stats.success_dropped == Enum.count(results, &(&1 == {:error, :saturated}))
    assert {:ok, %Snapshot{control_health: :healthy}} = Snapshot.lookup(id)

    assert [{:failure, :timeout, true}, :success] =
             ControlRing.drain(id, 5, receipt.generation, receipt.epoch)
  end

  test "success refresh cannot cross a ring generation replacement" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 2, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    await_failure_count(id, 1)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, :ok)

    ControlRing.initialize(id, receipt.generation + 1, receipt.epoch + 1, breaker_pid,
      capacity: 2
    )

    assert {:error, :stale} = CircuitBreaker.report_closed(receipt, :ok)
    assert %{occupied: 0, success_marker?: false} = ControlRing.stats(id)
  end

  test "one hundred thousand routine closed successes allocate no slots or wakeups" do
    {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
    {:ok, receipt} = Admission.check(id, deadline_us())
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    Enum.each(1..100_000, fn _index ->
      assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    end)

    assert %{occupied: 0, wakeup_pending: 0, dropped: 0, success_marker?: false} =
             ControlRing.stats(id)

    assert ordinary_wakeup_count(breaker_pid, id) == 0
    assert {:ok, %Snapshot{state: :closed, control_health: :healthy}} = Snapshot.lookup(id)
  end

  test "only failure-slot saturation degrades and counters survive replacement" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 1, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    await_failure_count(id, 1)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert {:ok, %Snapshot{control_health: :healthy}} = Snapshot.lookup(id)

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert {:error, :saturated} = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert {:ok, %Snapshot{control_health: :degraded}} = Snapshot.lookup(id)
    assert %{failure_dropped: 1, success_dropped: 0} = ControlRing.stats(id)

    ControlRing.initialize(id, receipt.generation + 1, receipt.epoch + 1, breaker_pid,
      capacity: 1
    )

    assert %{failure_dropped: 1, dropped: 1} = ControlRing.stats(id)
  end

  test "a failure drop cannot be overwritten by an in-flight healthy owner snapshot" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 1, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    test_pid = self()
    release_ref = make_ref()
    block_key = {__MODULE__, release_ref}
    handler_id = "blocked-control-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :circuit_breaker, :failure],
        fn _event, _measurements, metadata, _config ->
          if metadata.instance_id == elem(id, 0) and not Process.get(block_key, false) do
            Process.put(block_key, true)
            send(test_pid, {:control_failure_blocked, self(), release_ref})

            receive do
              {:release_with_snapshot_barrier, ^release_ref, observer, before_ref, after_ref} ->
                Process.put(
                  :lasso_breaker_snapshot_write_barrier,
                  {observer, before_ref, after_ref}
                )
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert_receive {:control_failure_blocked, ^breaker_pid, ^release_ref}, 1_000

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert {:error, :saturated} = CircuitBreaker.report_closed(receipt, {:error, :timeout})

    assert %{failure_dropped: 1, failure_drop_pending?: true} = ControlRing.stats(id)
    assert {:ok, %Snapshot{control_health: :degraded}} = Snapshot.lookup(id)

    before_ref = make_ref()
    after_ref = make_ref()

    send(
      breaker_pid,
      {:release_with_snapshot_barrier, release_ref, self(), before_ref, after_ref}
    )

    assert_receive {:breaker_snapshot_write_ready, ^breaker_pid, :before, ^before_ref},
                   1_000

    send(breaker_pid, before_ref)

    assert_receive {:breaker_snapshot_write_ready, ^breaker_pid, :after, ^after_ref}, 1_000

    assert {:ok, %Snapshot{failure_count: 1, control_health: :degraded}} = Snapshot.lookup(id)
    assert %{failure_drop_pending?: true} = ControlRing.stats(id)

    send(breaker_pid, after_ref)

    await_snapshot(id, fn snapshot ->
      snapshot.generation > receipt.generation and snapshot.state == :half_open and
        snapshot.control_health == :healthy
    end)

    assert %{failure_dropped: 1, failure_drop_pending?: false} = ControlRing.stats(id)
  end

  test "a drop between the owner precheck and snapshot put is fenced after publication" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 1, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    before_ref = make_ref()
    after_ref = make_ref()
    test_pid = self()

    :sys.replace_state(breaker_pid, fn state ->
      Process.put(
        :lasso_breaker_snapshot_write_barrier,
        {test_pid, before_ref, after_ref}
      )

      state
    end)

    GenServer.cast(CircuitBreaker.via_name(id), {:release, make_ref()})

    assert_receive {:breaker_snapshot_write_ready, ^breaker_pid, :before, ^before_ref},
                   1_000

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert {:error, :saturated} = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    send(breaker_pid, before_ref)

    assert_receive {:breaker_snapshot_write_ready, ^breaker_pid, :after, ^after_ref}, 1_000

    assert {:ok, %Snapshot{control_health: :degraded}} = Snapshot.lookup(id)
    assert %{failure_drop_pending?: true} = ControlRing.stats(id)

    send(breaker_pid, after_ref)
  end

  test "failure-drop degradation and cumulative diagnostics survive owner restart" do
    {id, breaker_pid} =
      start_breaker(control_ring_capacity: 1, category_thresholds: %{timeout: 100})

    {:ok, receipt} = Admission.check(id, deadline_us())
    :ok = :sys.suspend(breaker_pid)

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert {:error, :saturated} = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert %{failure_dropped: 1, failure_drop_pending?: true} = ControlRing.stats(id)

    :ok = GenServer.stop(breaker_pid, :normal)

    {:ok, restarted_pid} =
      CircuitBreaker.start_link(
        {id, %{control_ring_capacity: 1, category_thresholds: %{timeout: 100}}}
      )

    on_exit(fn -> if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid) end)

    assert %{failure_dropped: 1, failure_drop_pending?: true} = ControlRing.stats(id)
    assert {:ok, %Snapshot{state: :half_open, control_health: :degraded}} = Snapshot.lookup(id)

    CircuitBreaker.close(id)

    await_snapshot(id, fn snapshot ->
      snapshot.state == :closed and snapshot.control_health == :healthy
    end)

    assert %{failure_dropped: 1, failure_drop_pending?: false} = ControlRing.stats(id)
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

    assert 0 =
             :ets.select_replace(Storage.control_table(), [
               {{key, {old_ring_ref, :empty}}, [],
                [
                  {:const,
                   {key,
                    {old_ring_ref, {old_sequence, receipt.generation, receipt.epoch, :success}}}}
                ]}
             ])

    assert [] = ControlRing.drain(id, 2, receipt.generation, receipt.epoch)
  end

  test "the owner audit repairs a producer death after publication before wakeup" do
    {id, _breaker_pid} =
      start_breaker(
        control_ring_capacity: 2,
        control_audit_interval_ms: 5,
        category_thresholds: %{timeout: 100}
      )

    {:ok, receipt} = Admission.check(id, deadline_us())
    assert :ok = ControlRing.publish_without_notify(receipt, {:failure, :timeout, true})
    assert %{occupied: 1, wakeup_pending: 0} = ControlRing.stats(id)
    await_failure_count(id, 1)
    assert %{occupied: 0} = ControlRing.stats(id)
  end

  test "a success cannot overtake a failure stalled before slot publication" do
    {id, _breaker_pid} =
      start_breaker(
        control_ring_capacity: 2,
        control_audit_interval_ms: 5,
        category_thresholds: %{timeout: 100}
      )

    {:ok, receipt} = Admission.check(id, deadline_us())
    release_ref = make_ref()
    parent = self()

    producer =
      Task.async(fn ->
        ControlRing.publish_after_barrier_without_notify(
          receipt,
          {:failure, :timeout, true},
          parent,
          release_ref
        )
      end)

    assert_receive {:control_publish_reserved, producer_pid, ^release_ref}
    assert producer_pid == producer.pid
    assert :ok = CircuitBreaker.report_closed(receipt, :ok)
    assert %{occupied: 0, success_marker?: false} = ControlRing.stats(id)

    send(producer.pid, release_ref)
    assert :ok = Task.await(producer)
    await_failure_count(id, 1)
    assert {:ok, %Snapshot{failure_count: 1, needs_success?: true}} = Snapshot.lookup(id)
  end

  test "fresh closed breakers admit at high concurrency without owner crossings" do
    for concurrency <- [96, 128] do
      {id, breaker_pid} = start_breaker(control_ring_capacity: 4)
      :sys.suspend(breaker_pid)
      on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

      results =
        1..(concurrency * 4)
        |> Task.async_stream(fn _index -> CircuitBreaker.admit(id, deadline_us()) end,
          max_concurrency: concurrency,
          timeout: 5_000,
          ordered: false
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, %AdmissionReceipt{kind: :closed}}} -> true
               _other -> false
             end)
    end
  end

  test "an open transition commits before optional observers run" do
    {id, _breaker_pid} =
      start_breaker(
        control_ring_capacity: 4,
        category_thresholds: %{timeout: 1},
        recovery_timeout: 60_000
      )

    {:ok, receipt} = Admission.check(id, deadline_us())
    test_pid = self()
    release_ref = make_ref()
    handler_id = "open-transition-consumer-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :circuit_breaker, :open],
        fn _event, _measurements, metadata, _config ->
          if metadata.instance_id == elem(id, 0) do
            send(test_pid, {:open_transition_observer_entered, self()})

            receive do
              ^release_ref -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = CircuitBreaker.report_closed(receipt, {:error, :timeout})
    assert_receive {:open_transition_observer_entered, observer_pid}, 1_000
    assert {:ok, %Snapshot{state: :open}} = Snapshot.lookup(id)
    assert {:error, :circuit_open} = Admission.check(id, deadline_us())

    send(observer_pid, release_ref)
    assert %{state: :open} = CircuitBreaker.get_state(id)
  end

  defp start_breaker(config) do
    id = {"control-#{System.unique_integer([:positive])}", :http}
    {:ok, pid} = CircuitBreaker.start_link({id, Map.new(config)})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      :ets.delete(Storage.snapshot_table(), id)
      :ets.delete(Storage.lease_table(), id)
      ControlRing.delete(id)
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

  defp await_failure_count(id, count, attempts \\ 200)
  defp await_failure_count(_id, _count, 0), do: flunk("failure count was not published")

  defp await_failure_count(id, count, attempts) do
    case Snapshot.lookup(id) do
      {:ok, %Snapshot{failure_count: ^count}} ->
        :ok

      _other ->
        Process.sleep(2)
        await_failure_count(id, count, attempts - 1)
    end
  end

  defp await_snapshot(id, predicate, attempts \\ 200)
  defp await_snapshot(_id, _predicate, 0), do: flunk("snapshot condition was not published")

  defp await_snapshot(id, predicate, attempts) do
    case Snapshot.lookup(id) do
      {:ok, snapshot} ->
        if predicate.(snapshot) do
          snapshot
        else
          Process.sleep(2)
          await_snapshot(id, predicate, attempts - 1)
        end

      :missing ->
        Process.sleep(2)
        await_snapshot(id, predicate, attempts - 1)
    end
  end

  defp invalid_fact(id, receipt, route_generation) do
    identity =
      AttemptIdentity.new(
        request_id: "control-route-request",
        attempt_id: "control-route-attempt-#{route_generation}",
        profile: "public",
        chain_id: 1,
        upstream_instance_id: elem(id, 0),
        transport: :http,
        route_generation: route_generation,
        circuit_scope: :broad,
        circuit_epoch: receipt.epoch,
        execution_safety: :replay_safe,
        routing_intent: "default",
        workload_key: "default",
        request_budget_ms: 100,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    AttemptTerminal.InvalidResponse.new(identity, :invalid_json, 10)
  end

  defp deadline_us, do: System.monotonic_time(:microsecond) + 1_000_000
end
