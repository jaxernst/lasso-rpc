defmodule Lasso.Core.Streaming.StreamCoordinatorTest do
  @moduledoc """
  Unit tests for StreamCoordinator failover orchestration.

  Tests focus on state machine coordination, not backfill implementation:
  - Event routing based on failover status
  - State transitions through failover cycle
  - Circuit breaker behavior
  - Event buffering during failover
  - Provider unhealthy signal handling

  Backfill execution and integration scenarios are tested separately.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Lasso.Core.Streaming.StreamCoordinator

  # Test helpers for event creation
  defp new_heads_event(block_num) do
    %{
      "hash" => "0x#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}",
      "number" => "0x#{Integer.to_string(block_num, 16)}"
    }
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Helper to get coordinator state (encapsulated for stability)
  defp get_coordinator_state(pid) do
    :sys.get_state(pid)
  end

  describe "initialization" do
    test "initializes with correct default state" do
      chain = "test_chain"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1"]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      state = get_coordinator_state(pid)

      assert state.chain == chain
      assert state.key == key
      assert state.primary_provider_id == "provider_1"
      assert state.failover_status == :active
      assert state.failover_context == nil
      assert state.failover_history == []
      assert state.max_failover_attempts == 3
      assert state.failover_cooldown_ms == 5_000

      GenServer.stop(pid)
    end
  end

  describe "event handling - status routing" do
    setup do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1", max_event_buffer: 10]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, coordinator: pid, chain: chain, key: key}
    end

    test "processes events in :active status", %{coordinator: pid} do
      # Verify initial status
      state = get_coordinator_state(pid)
      assert state.failover_status == :active

      # Send event
      event = new_heads_event(100)
      GenServer.cast(pid, {:upstream_event, "provider_1", "upstream_1", event, now()})

      # Give time for cast to process
      Process.sleep(10)

      # Verify event was processed (StreamState updated)
      state = get_coordinator_state(pid)
      assert state.state.markers.last_block_num == 100
    end

    test "buffers events in :backfilling status", %{coordinator: pid} do
      # Force status to :backfilling by setting up failover context
      state = get_coordinator_state(pid)
      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :backfilling, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Send events
      event1 = new_heads_event(100)
      event2 = new_heads_event(101)
      GenServer.cast(pid, {:upstream_event, "provider_1", "upstream_1", event1, now()})
      GenServer.cast(pid, {:upstream_event, "provider_1", "upstream_1", event2, now()})

      Process.sleep(10)

      # Verify events were buffered
      state = get_coordinator_state(pid)
      assert length(state.failover_context.event_buffer) == 2
    end

    test "buffers events in :switching status", %{coordinator: pid} do
      # Force status to :switching
      state = get_coordinator_state(pid)
      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :switching, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Send event
      event = new_heads_event(100)
      GenServer.cast(pid, {:upstream_event, "provider_1", "upstream_1", event, now()})

      Process.sleep(10)

      # Verify event was buffered
      state = get_coordinator_state(pid)
      assert length(state.failover_context.event_buffer) == 1
    end

    test "drops events in :degraded status", %{coordinator: pid} do
      # Force status to :degraded
      state = get_coordinator_state(pid)
      new_state = %{state | failover_status: :degraded, failover_context: nil}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Send event
      event = new_heads_event(100)

      log =
        capture_log(fn ->
          GenServer.cast(pid, {:upstream_event, "provider_1", "upstream_1", event, now()})
          Process.sleep(10)
        end)

      # Verify event was dropped (warning logged)
      assert log =~ "Dropping event in degraded mode"

      # Verify StreamState not updated
      state = get_coordinator_state(pid)
      assert state.state.markers.last_block_num == nil
    end
  end

  describe "provider_unhealthy signal" do
    setup do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1"]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, coordinator: pid, chain: chain, key: key}
    end

    test "initiates failover when status is :active", %{coordinator: pid} do
      # Verify initial status
      state = get_coordinator_state(pid)
      assert state.failover_status == :active

      # Send provider unhealthy signal
      GenServer.cast(pid, {:provider_unhealthy, "provider_1", "provider_2"})

      Process.sleep(10)

      # Verify failover initiated - test outcome, not intermediate state
      # May be :backfilling or :switching (backfill completes fast in tests)
      state = get_coordinator_state(pid)
      assert state.failover_status in [:backfilling, :switching]

      # Test observable outcome: failure recorded in history
      assert length(state.failover_history) == 1
      assert hd(state.failover_history).provider_id == "provider_1"
    end

    test "ignores signal when status is :backfilling", %{coordinator: pid} do
      # Force status to :backfilling
      state = get_coordinator_state(pid)
      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :backfilling, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      old_context = fake_context

      log =
        capture_log(fn ->
          GenServer.cast(pid, {:provider_unhealthy, "p2", "p3"})
          Process.sleep(10)
        end)

      # Verify signal was ignored
      assert log =~ "Ignoring provider_unhealthy signal"

      state = get_coordinator_state(pid)
      assert state.failover_status == :backfilling
      assert state.failover_context == old_context
    end

    test "ignores signal when status is :switching", %{coordinator: pid} do
      # Force status to :switching
      state = get_coordinator_state(pid)
      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :switching, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      log =
        capture_log(fn ->
          GenServer.cast(pid, {:provider_unhealthy, "p2", "p3"})
          Process.sleep(10)
        end)

      # Verify signal was ignored
      assert log =~ "Ignoring provider_unhealthy signal"

      state = get_coordinator_state(pid)
      assert state.failover_status == :switching
    end
  end

  describe "circuit breaker" do
    setup do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1", max_failover_attempts: 2, failover_cooldown_ms: 1_000]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, coordinator: pid, chain: chain, key: key}
    end

    test "enters degraded mode after max_failover_attempts", %{coordinator: pid} do
      # Build failure history that exceeds threshold
      state = get_coordinator_state(pid)
      failure_history = [
        %{provider_id: "p1", failed_at: now()},
        %{provider_id: "p2", failed_at: now()}
      ]
      new_state = %{state | failover_history: failure_history}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Trigger another failover - should enter degraded mode
      log =
        capture_log(fn ->
          GenServer.cast(pid, {:provider_unhealthy, "p3", "p4"})
          Process.sleep(50)
        end)

      assert log =~ "Circuit breaker triggered"
      assert log =~ "Entering degraded mode"

      state = get_coordinator_state(pid)
      assert state.failover_status == :degraded
      assert state.failover_context == nil
    end

    test "continues failover if under threshold", %{coordinator: pid} do
      # Build failure history under threshold
      state = get_coordinator_state(pid)
      failure_history = [
        %{provider_id: "p1", failed_at: now()}
      ]
      new_state = %{state | failover_history: failure_history}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Trigger failover - should proceed (not enter degraded mode)
      GenServer.cast(pid, {:provider_unhealthy, "p2", "p3"})
      Process.sleep(10)

      # Test outcome: did NOT enter degraded mode, failover proceeding
      state = get_coordinator_state(pid)
      refute state.failover_status == :degraded
      assert state.failover_status in [:backfilling, :switching]

      # History should have grown (new failure recorded)
      assert length(state.failover_history) == 2
    end
  end

  describe "state management" do
    test "tracks failover history correctly" do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1"]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      # Initial history empty
      state = get_coordinator_state(pid)
      assert state.failover_history == []

      # Trigger failover
      GenServer.cast(pid, {:provider_unhealthy, "provider_1", "provider_2"})
      Process.sleep(50)

      # History should have one entry
      state = get_coordinator_state(pid)
      assert length(state.failover_history) == 1
      assert hd(state.failover_history).provider_id == "provider_1"

      GenServer.stop(pid)
    end
  end

  describe "event buffer" do
    setup do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1", max_event_buffer: 3]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, coordinator: pid}
    end

    test "buffer grows up to max_event_buffer", %{coordinator: pid} do
      # Force :backfilling status
      state = get_coordinator_state(pid)
      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :backfilling, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Send events up to max
      for i <- 1..3 do
        event = new_heads_event(100 + i)
        GenServer.cast(pid, {:upstream_event, "p1", "up1", event, now()})
      end

      Process.sleep(20)

      state = get_coordinator_state(pid)
      assert length(state.failover_context.event_buffer) == 3
    end

    test "drops oldest events when buffer full", %{coordinator: pid} do
      # Force :backfilling status with full buffer
      state = get_coordinator_state(pid)
      event1 = new_heads_event(100)
      event2 = new_heads_event(101)
      event3 = new_heads_event(102)

      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [event1, event2, event3],  # Buffer is full (max=3)
        attempt_count: 1
      }
      new_state = %{state | failover_status: :backfilling, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Send one more event
      event4 = new_heads_event(103)

      log =
        capture_log(fn ->
          GenServer.cast(pid, {:upstream_event, "p1", "up1", event4, now()})
          Process.sleep(20)
        end)

      assert log =~ "Event buffer full"
      assert log =~ "dropping oldest event"

      # Buffer should still be size 3, with event1 dropped
      state = get_coordinator_state(pid)
      assert length(state.failover_context.event_buffer) == 3
      # event1 dropped, buffer now has [event2, event3, event4]
      refute event1 in state.failover_context.event_buffer
      assert event4 in state.failover_context.event_buffer
    end

    test "buffer preserves event ordering during drain", %{coordinator: pid} do
      # Set up :switching status with buffered events
      state = get_coordinator_state(pid)
      event1 = new_heads_event(100)
      event2 = new_heads_event(101)
      event3 = new_heads_event(102)

      fake_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: make_ref(),
        started_at: now(),
        event_buffer: [event1, event2, event3],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :switching, failover_context: fake_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Complete failover (simulate subscription_confirmed)
      send(pid, {:subscription_confirmed, "p2", "upstream_2"})
      Process.sleep(50)

      # Verify events were processed in order
      state = get_coordinator_state(pid)
      # After drain, buffer should be empty and context cleared
      assert state.failover_context == nil
      assert state.failover_status == :active

      # Verify last block is from event3 (last in buffer)
      assert state.state.markers.last_block_num == 102
    end
  end

  describe "stale backfill handling" do
    setup do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1"]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, coordinator: pid}
    end

    test "ignores backfill complete from old failover attempt", %{coordinator: pid} do
      # Manually set up failover context (avoid real Task.async race)
      state = get_coordinator_state(pid)
      old_ref = make_ref()

      initial_context = %{
        old_provider_id: "p1",
        new_provider_id: "p2",
        backfill_task_ref: old_ref,
        started_at: now(),
        event_buffer: [],
        attempt_count: 1
      }
      new_state = %{state | failover_status: :backfilling, failover_context: initial_context}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Simulate cascaded failover by updating to new ref
      new_ref = make_ref()
      updated_context = %{initial_context | backfill_task_ref: new_ref, new_provider_id: "p3"}
      newer_state = %{new_state | failover_context: updated_context}
      :sys.replace_state(pid, fn _ -> newer_state end)

      # Send completion from OLD backfill (stale message)
      send(pid, {old_ref, :backfill_complete})
      Process.sleep(10)

      # Test outcome: stale message ignored, still tracking NEW ref and NEW provider
      # Don't assert on failover_status (timing-dependent), assert on what matters:
      # - New ref is still tracked
      # - New provider is still tracked
      # - System didn't incorrectly transition on stale message
      state = get_coordinator_state(pid)

      # The key assertion: still working with the NEW failover, not the old one
      assert state.failover_context != nil, "Failover context should not be cleared by stale message"
      assert state.failover_context.backfill_task_ref == new_ref, "Should still track new ref, not old"
      assert state.failover_context.new_provider_id == "p3", "Should still track new provider p3"

      # Status may be :backfilling or :switching depending on timing - both are acceptable
      # as long as we're still tracking the correct failover context
      assert state.failover_status in [:backfilling, :switching],
             "Should be in active failover, not completed or degraded"
    end
  end

  describe "backfill task crash handling" do
    setup do
      chain = "test_chain_#{:rand.uniform(999_999)}"
      key = {:newHeads}
      opts = [primary_provider_id: "provider_1", max_failover_attempts: 2]

      {:ok, pid} = StreamCoordinator.start_link({"default", chain, key, opts})

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, coordinator: pid}
    end

    test "handles backfill task crash via :DOWN message", %{coordinator: pid} do
      # Start failover
      GenServer.cast(pid, {:provider_unhealthy, "p1", "p2"})
      Process.sleep(20)

      state = get_coordinator_state(pid)
      task_ref = state.failover_context.backfill_task_ref

      # Simulate task crash
      log =
        capture_log(fn ->
          send(pid, {:DOWN, task_ref, :process, self(), :simulated_crash})
          Process.sleep(50)
        end)

      assert log =~ "Backfill task crashed"
      assert log =~ "Resubscription failed"

      # Should attempt recovery (enter degraded or retry)
      state = get_coordinator_state(pid)
      # Either degraded or attempting another failover
      assert state.failover_status in [:degraded, :backfilling]
    end
  end
end
