defmodule Lasso.Testing.TelemetrySyncTest do
  use ExUnit.Case, async: true

  alias Lasso.Testing.TelemetrySync

  describe "telemetry collection semantics" do
    test "demonstrates the WRONG pattern - handler attached after event" do
      event_name = [:test, :wrong, :pattern]

      # WRONG: Execute action first
      :telemetry.execute(event_name, %{value: 42}, %{tag: "missed"})

      # Then attach handler (too late!)
      {:ok, collector} = TelemetrySync.attach_collector(event_name)

      # This will timeout because event already fired
      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 100)
    end

    test "demonstrates the CORRECT pattern - handler attached before event" do
      event_name = [:test, :correct, :pattern]

      # CORRECT: Attach handler FIRST
      {:ok, collector} = TelemetrySync.attach_collector(event_name)

      # THEN execute action
      :telemetry.execute(event_name, %{value: 42}, %{tag: "captured"})

      # Event is collected successfully
      assert {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 100)
      assert measurements.value == 42
      assert metadata.tag == "captured"
    end

    test "demonstrates synchronous handler execution in calling process" do
      event_name = [:test, :synchronous, :execution]
      test_pid = self()

      # Attach a handler that records the calling process
      handler_id = :test_handler
      calling_pids = :ets.new(:calling_pids, [:set, :public])

      :telemetry.attach(
        handler_id,
        event_name,
        fn _event, _measurements, _metadata, table ->
          :ets.insert(table, {:caller, self()})
        end,
        calling_pids
      )

      # Execute telemetry from test process
      :telemetry.execute(event_name, %{}, %{})

      # Handler ran in the SAME process (synchronous)
      [{:caller, handler_pid}] = :ets.lookup(calling_pids, :caller)
      assert handler_pid == test_pid

      :telemetry.detach(handler_id)
      :ets.delete(calling_pids)
    end
  end

  describe "attach_collector/2 and await_event/2" do
    test "collects single event with exact match" do
      event_name = [:test, :single, :event]

      {:ok, collector} = TelemetrySync.attach_collector(event_name)

      :telemetry.execute(event_name, %{duration: 100}, %{method: "test_method"})

      assert {:ok, measurements, metadata} = TelemetrySync.await_event(collector)
      assert measurements.duration == 100
      assert metadata.method == "test_method"
    end

    test "collects event with metadata matching" do
      event_name = [:test, :filtered, :event]

      # Only collect events with specific metadata
      {:ok, collector} = TelemetrySync.attach_collector(
        event_name,
        match: [method: "eth_blockNumber"]
      )

      # Emit non-matching event (ignored)
      :telemetry.execute(event_name, %{duration: 50}, %{method: "eth_getBalance"})

      # Emit matching event (collected)
      :telemetry.execute(event_name, %{duration: 100}, %{method: "eth_blockNumber"})

      assert {:ok, measurements, _metadata} = TelemetrySync.await_event(collector, timeout: 100)
      assert measurements.duration == 100
    end

    test "collects event with predicate function" do
      event_name = [:test, :predicate, :event]

      # Custom predicate
      {:ok, collector} = TelemetrySync.attach_collector(
        event_name,
        match: fn measurements, _metadata ->
          measurements.duration > 50
        end
      )

      # Below threshold (ignored)
      :telemetry.execute(event_name, %{duration: 40}, %{})

      # Above threshold (collected)
      :telemetry.execute(event_name, %{duration: 100}, %{})

      assert {:ok, measurements, _metadata} = TelemetrySync.await_event(collector, timeout: 100)
      assert measurements.duration == 100
    end

    test "collects multiple events when count specified" do
      event_name = [:test, :multiple, :events]

      {:ok, collector} = TelemetrySync.attach_collector(event_name, count: 3)

      # Emit 3 events
      :telemetry.execute(event_name, %{attempt: 1}, %{})
      :telemetry.execute(event_name, %{attempt: 2}, %{})
      :telemetry.execute(event_name, %{attempt: 3}, %{})

      assert {:ok, events} = TelemetrySync.await_event(collector, timeout: 100)
      assert length(events) == 3

      attempts = Enum.map(events, fn {measurements, _metadata} -> measurements.attempt end)
      assert attempts == [1, 2, 3]
    end

    test "times out if events don't arrive" do
      event_name = [:test, :timeout, :event]

      {:ok, collector} = TelemetrySync.attach_collector(event_name)

      # Don't emit any events
      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 100)
    end

    test "times out if not enough events arrive" do
      event_name = [:test, :partial, :events]

      {:ok, collector} = TelemetrySync.attach_collector(event_name, count: 3)

      # Only emit 2 events
      :telemetry.execute(event_name, %{attempt: 1}, %{})
      :telemetry.execute(event_name, %{attempt: 2}, %{})

      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 100)
    end

    test "automatically detaches handler after await completes" do
      event_name = [:test, :detach, :event]

      {:ok, collector} = TelemetrySync.attach_collector(event_name)
      :telemetry.execute(event_name, %{}, %{})

      assert {:ok, _measurements, _metadata} = TelemetrySync.await_event(collector)

      # Handler should be detached, subsequent events won't be collected
      {:ok, collector2} = TelemetrySync.attach_collector(event_name)

      # This shouldn't interfere with collector2
      :telemetry.execute(event_name, %{second: true}, %{})

      assert {:ok, measurements, _metadata} = TelemetrySync.await_event(collector2, timeout: 100)
      assert measurements.second == true
    end

    test "automatically detaches handler even on timeout" do
      event_name = [:test, :detach, :timeout]
      handler_id = {TelemetrySync, make_ref(), System.unique_integer([:positive, :monotonic])}

      {:ok, collector} = TelemetrySync.attach_collector(event_name)

      # Verify handler is attached
      handlers_before = :telemetry.list_handlers(event_name)
      assert length(handlers_before) == 1

      # Timeout
      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 50)

      # Handler should be detached
      handlers_after = :telemetry.list_handlers(event_name)
      assert handlers_after == []
    end
  end

  describe "collect_event/3 convenience function" do
    test "collects event from action function" do
      event_name = [:test, :action, :event]

      {:ok, measurements, metadata} =
        TelemetrySync.collect_event(
          event_name,
          fn ->
            :telemetry.execute(event_name, %{value: 123}, %{source: "action"})
            :ok
          end,
          timeout: 100
        )

      assert measurements.value == 123
      assert metadata.source == "action"
    end

    test "works with matching predicates" do
      event_name = [:test, :action, :filtered]

      {:ok, measurements, _metadata} =
        TelemetrySync.collect_event(
          event_name,
          fn ->
            :telemetry.execute(event_name, %{status: :ok}, %{result: "success"})
            :ok
          end,
          match: [result: "success"],
          timeout: 100
        )

      assert measurements.status == :ok
    end
  end

  describe "request-specific helpers" do
    test "attach_request_collector creates collector for request events" do
      # Note: This is a unit test, doesn't actually execute requests
      event_name = [:lasso, :request, :completed]

      {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

      # Simulate request completion telemetry
      :telemetry.execute(
        event_name,
        %{duration: 150, queue_time: 10},
        %{method: "eth_blockNumber", chain: "ethereum", status: :ok}
      )

      assert {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 100)
      assert measurements.duration == 150
      assert metadata.method == "eth_blockNumber"
    end

    test "attach_request_collector can collect multiple retry attempts" do
      event_name = [:lasso, :request, :completed]

      {:ok, collector} = TelemetrySync.attach_request_collector(
        method: "eth_getBalance",
        count: 3
      )

      # Simulate 3 retry attempts
      for attempt <- 1..3 do
        :telemetry.execute(
          event_name,
          %{duration: attempt * 100, attempt: attempt},
          %{method: "eth_getBalance", chain: "ethereum"}
        )
      end

      assert {:ok, events} = TelemetrySync.await_event(collector, timeout: 200)
      assert length(events) == 3

      durations = Enum.map(events, fn {m, _meta} -> m.duration end)
      assert durations == [100, 200, 300]
    end
  end

  describe "process isolation and concurrency" do
    test "multiple collectors can coexist for same event" do
      event_name = [:test, :concurrent, :collectors]

      # Create two collectors with different match criteria
      {:ok, collector1} = TelemetrySync.attach_collector(
        event_name,
        match: [type: :fast]
      )

      {:ok, collector2} = TelemetrySync.attach_collector(
        event_name,
        match: [type: :slow]
      )

      # Emit events
      :telemetry.execute(event_name, %{duration: 10}, %{type: :fast})
      :telemetry.execute(event_name, %{duration: 100}, %{type: :slow})

      # Each collector gets its matched event
      assert {:ok, m1, _meta1} = TelemetrySync.await_event(collector1, timeout: 100)
      assert m1.duration == 10

      assert {:ok, m2, _meta2} = TelemetrySync.await_event(collector2, timeout: 100)
      assert m2.duration == 100
    end

    test "collectors in different processes don't interfere" do
      event_name = [:test, :process, :isolation]

      test_pid = self()

      # Spawn a task that creates its own collector
      task = Task.async(fn ->
        {:ok, collector} = TelemetrySync.attach_collector(event_name)
        send(test_pid, :task_ready)

        # Wait for event
        TelemetrySync.await_event(collector, timeout: 1000)
      end)

      # Wait for task to attach
      assert_receive :task_ready, 100

      # Create our own collector
      {:ok, collector} = TelemetrySync.attach_collector(event_name)

      # Emit event (both collectors should receive it)
      :telemetry.execute(event_name, %{value: 42}, %{})

      # Both collectors get the event
      assert {:ok, m1, _} = TelemetrySync.await_event(collector, timeout: 100)
      assert {:ok, m2, _} = Task.await(task)

      assert m1.value == 42
      assert m2.value == 42
    end
  end

  describe "edge cases and error handling" do
    test "handles rapid event emission" do
      event_name = [:test, :rapid, :events]

      {:ok, collector} = TelemetrySync.attach_collector(event_name, count: 100)

      # Emit 100 events rapidly
      for i <- 1..100 do
        :telemetry.execute(event_name, %{index: i}, %{})
      end

      assert {:ok, events} = TelemetrySync.await_event(collector, timeout: 1000)
      assert length(events) == 100
    end

    test "handles events with missing metadata fields" do
      event_name = [:test, :missing, :fields]

      {:ok, collector} = TelemetrySync.attach_collector(
        event_name,
        match: [optional_field: "value"]
      )

      # Emit event without the field (won't match)
      :telemetry.execute(event_name, %{}, %{})

      # Emit event with the field (matches)
      :telemetry.execute(event_name, %{}, %{optional_field: "value"})

      assert {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 100)
      assert metadata.optional_field == "value"
    end

    test "handles predicate exceptions gracefully" do
      event_name = [:test, :exception, :predicate]

      # Predicate that might raise
      {:ok, collector} = TelemetrySync.attach_collector(
        event_name,
        match: fn _measurements, metadata ->
          # This will raise if :nested is missing
          metadata.nested.value == 42
        end
      )

      # This will cause predicate to raise, but shouldn't crash test
      :telemetry.execute(event_name, %{}, %{})

      # This should match
      :telemetry.execute(event_name, %{}, %{nested: %{value: 42}})

      # Should timeout because exception prevented match
      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 100)
    end
  end
end
