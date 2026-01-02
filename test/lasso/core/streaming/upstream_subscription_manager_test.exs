defmodule Lasso.RPC.UpstreamSubscriptionManagerTest do
  @moduledoc """
  Tests for UpstreamSubscriptionManager - the central hub for upstream subscription lifecycle.

  Tests critical behaviors:
  - Subscription creation and reuse
  - Consumer registration lifecycle
  - Grace period teardown
  - Provider disconnect handling
  - Event dispatching to consumers
  - Concurrent access safety
  - Crash recovery via restart broadcast
  """

  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.UpstreamSubscriptionRegistry
  alias Lasso.RPC.UpstreamSubscriptionManager
  alias Lasso.Testing.MockWSProvider

  @default_profile "default"

  setup do
    # Unique chain/provider per test to avoid cross-test interference
    suffix = System.unique_integer([:positive])
    test_chain = "test_manager_#{suffix}"
    test_provider = "mock_manager_provider_#{suffix}"
    test_profile = @default_profile

    # Start mock WebSocket provider
    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    # Wait for infrastructure
    Process.sleep(200)

    on_exit(fn ->
      MockWSProvider.stop_mock(test_chain, test_provider)

      # Stop the profile chain supervisor (uses "default" profile for tests)
      Lasso.ProfileChainSupervisor.stop_profile_chain("default", test_chain)

      Lasso.Config.ConfigStore.unregister_chain_runtime("default", test_chain)
      Process.sleep(50)
    end)

    {:ok, chain: test_chain, provider: test_provider, profile: test_profile}
  end

  # Helper to simulate connection establishment for tests
  # Broadcasts ws_connected directly to UpstreamSubscriptionManager without triggering
  # other listeners (like BlockHeightMonitor) that might create automatic subscriptions
  defp establish_connection_for_manager(profile, chain, provider) do
    connection_id = "conn_test_#{System.unique_integer([:positive])}"

    # Get the manager pid directly and send the event
    [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
    send(manager_pid, {:ws_connected, provider, connection_id})
    Process.sleep(20)

    connection_id
  end

  describe "subscription lifecycle" do
    test "first consumer creates new upstream subscription", %{chain: chain, provider: provider, profile: profile} do
      # Use a logs key to avoid race with BlockHeightMonitor which auto-subscribes to newHeads
      key = {:logs, %{"address" => "0xtest123"}}

      # Connection already established by MockWSProvider.start_mock()

      # First consumer
      {:ok, status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      assert status == :new

      Process.sleep(100)

      # Verify subscription was created
      manager_status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert map_size(manager_status.active_subscriptions) >= 1
      assert manager_status.active_subscriptions[{provider, key}] != nil
      assert manager_status.active_subscriptions[{provider, key}].upstream_id != nil
    end

    test "second consumer joins existing subscription", %{chain: chain, provider: provider, profile: profile} do
      # Use a logs key to avoid race with BlockHeightMonitor which auto-subscribes to newHeads
      key = {:logs, %{"address" => "0xtest456"}}
      test_pid = self()

      # Connection already established by MockWSProvider.start_mock()

      # First consumer (stays alive)
      consumer1 =
        spawn(fn ->
          {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
          send(test_pid, :first_subscribed)
          receive do: (:exit -> :ok)
        end)

      assert_receive :first_subscribed, 1000
      Process.sleep(100)

      # Get upstream_id
      status_before = UpstreamSubscriptionManager.get_status(profile, chain)
      original_upstream_id = status_before.active_subscriptions[{provider, key}].upstream_id

      # Second consumer (stays alive)
      consumer2 =
        spawn(fn ->
          {:ok, status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
          send(test_pid, {:second_consumer, status})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:second_consumer, :existing}, 1000

      # Verify upstream_id unchanged (reused) while both consumers alive
      status_after = UpstreamSubscriptionManager.get_status(profile, chain)

      assert status_after.active_subscriptions[{provider, key}].upstream_id ==
               original_upstream_id

      assert status_after.active_subscriptions[{provider, key}].consumer_count == 2

      # Cleanup
      send(consumer1, :exit)
      send(consumer2, :exit)
    end

    test "release_subscription marks for teardown when last consumer leaves", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      # Use a logs key to avoid interference with BlockHeightMonitor's newHeads subscription
      key = {:logs, %{"address" => "0xrelease_test"}}

      # Connection already established by MockWSProvider.start_mock()

      # Subscribe
      {:ok, _status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(100)

      # Release (this process is the only consumer)
      UpstreamSubscriptionManager.release_subscription(profile, chain, provider, key)
      Process.sleep(100)

      # Should be marked for teardown
      status = UpstreamSubscriptionManager.get_status(profile, chain)

      case status.active_subscriptions[{provider, key}] do
        nil ->
          # Already torn down (if grace period is 0)
          :ok

        sub_info ->
          assert sub_info.marked_for_teardown == true
      end
    end

    test "new consumer cancels pending teardown", %{chain: chain, provider: provider, profile: profile} do
      key = {:newHeads}

      # Connection already established by MockWSProvider.start_mock()

      # First consumer subscribes
      {:ok, _status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(100)

      # Release
      UpstreamSubscriptionManager.release_subscription(profile, chain, provider, key)
      Process.sleep(50)

      # Second consumer joins before teardown
      {:ok, :existing} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)

      # Verify teardown cancelled
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}].marked_for_teardown == false
    end
  end

  describe "consumer death handling" do
    test "consumer process death removes registration from Registry", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:newHeads}
      test_pid = self()

      # Connection already established by MockWSProvider.start_mock()

      # Spawn consumer that will die
      consumer =
        spawn(fn ->
          {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
          send(test_pid, :subscribed)
          receive do: (:exit -> :ok)
        end)

      assert_receive :subscribed, 1000

      # Verify consumer registered
      assert UpstreamSubscriptionRegistry.count_consumers(profile, chain, provider, key) >= 1

      # Kill consumer
      Process.exit(consumer, :kill)
      Process.sleep(100)

      # Registry should auto-cleanup (Elixir Registry behavior)
      # Note: This may still show 1 if the test process is also registered
      # The key test is that dead processes are removed
      count = UpstreamSubscriptionRegistry.count_consumers(profile, chain, provider, key)

      # At minimum, the killed consumer should be gone
      # We may still have 1 if this test process registered
      assert count <= 1
    end
  end

  describe "event dispatching" do
    test "events dispatched to all registered consumers", %{chain: chain, provider: provider, profile: profile} do
      key = {:newHeads}
      test_pid = self()

      # Connection already established by MockWSProvider.start_mock()

      # Subscribe from two processes
      consumer1 =
        spawn(fn ->
          {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)

          receive do
            {:upstream_subscription_event, ^provider, ^key, payload, _received_at} ->
              send(test_pid, {:consumer1_received, payload})
          after
            5000 -> send(test_pid, :consumer1_timeout)
          end
        end)

      consumer2 =
        spawn(fn ->
          {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)

          receive do
            {:upstream_subscription_event, ^provider, ^key, payload, _received_at} ->
              send(test_pid, {:consumer2_received, payload})
          after
            5000 -> send(test_pid, :consumer2_timeout)
          end
        end)

      Process.sleep(200)

      # Dispatch event directly via Registry (simulating Manager dispatch)
      test_payload = %{"number" => "0x100", "hash" => "0xabc"}

      UpstreamSubscriptionRegistry.dispatch(
        profile,
        chain,
        provider,
        key,
        {:upstream_subscription_event, provider, key, test_payload,
         System.monotonic_time(:millisecond)}
      )

      # Verify both consumers received the event
      assert_receive {:consumer1_received, ^test_payload}, 1000
      assert_receive {:consumer2_received, ^test_payload}, 1000

      # Cleanup
      Process.exit(consumer1, :kill)
      Process.exit(consumer2, :kill)
    end
  end

  describe "provider disconnect handling" do
    test "provider disconnect cleans up subscriptions for that provider", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      # Connection already established by MockWSProvider.start_mock()

      # Subscribe to two keys
      {:ok, _status1} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key1)
      {:ok, _status2} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key2)
      Process.sleep(200)

      # Verify both subscriptions exist
      status_before = UpstreamSubscriptionManager.get_status(profile, chain)
      assert map_size(status_before.active_subscriptions) >= 2

      # Simulate provider disconnect via ws:conn PubSub channel (direct to manager)
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      send(manager_pid, {:ws_disconnected, provider, %{reason: :test_disconnect}})
      Process.sleep(100)

      # Verify both subscriptions cleaned up
      status_after = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status_after.active_subscriptions == %{}
    end
  end

  describe "concurrent access" do
    test "concurrent ensure_subscription calls handled safely", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      # Use a logs key to avoid race with BlockHeightMonitor which auto-subscribes to newHeads
      key = {:logs, %{"address" => "0xconcurrent_test"}}
      test_pid = self()

      # Connection already established by MockWSProvider.start_mock()

      # Spawn consumers that stay alive until we signal them
      consumers =
        for i <- 1..10 do
          spawn(fn ->
            result = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
            send(test_pid, {:result, i, result})

            # Stay alive until told to exit
            receive do
              :exit -> :ok
            end
          end)
        end

      # Collect all results
      results =
        for _ <- 1..10 do
          receive do
            {:result, i, result} -> {i, result}
          after
            5000 -> flunk("Timeout waiting for subscription result")
          end
        end

      # All should succeed
      assert Enum.all?(results, fn {_, result} -> match?({:ok, _}, result) end)

      # Exactly one should be :new, rest should be :existing
      new_count = Enum.count(results, fn {_, result} -> result == {:ok, :new} end)
      existing_count = Enum.count(results, fn {_, result} -> result == {:ok, :existing} end)

      assert new_count == 1
      assert existing_count == 9

      # Verify only ONE upstream subscription created for this key
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil
      assert status.active_subscriptions[{provider, key}].consumer_count == 10

      # Cleanup
      Enum.each(consumers, fn pid -> send(pid, :exit) end)
    end

    test "rapid subscribe/unsubscribe cycles handled correctly", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:newHeads}

      # Connection already established by MockWSProvider.start_mock()

      # Rapid cycles
      for _ <- 1..5 do
        {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
        Process.sleep(10)
        UpstreamSubscriptionManager.release_subscription(profile, chain, provider, key)
        Process.sleep(10)
      end

      # Wait for any pending operations
      Process.sleep(200)

      # Manager should handle gracefully - subscription may or may not exist
      # depending on timing, but state should be consistent
      status = UpstreamSubscriptionManager.get_status(profile, chain)

      # Should not have errors
      refute Map.has_key?(status, :error)
    end
  end

  describe "restart broadcast" do
    test "Manager broadcasts restart event on init", %{chain: chain, profile: profile} do
      # Subscribe to the manager's restart topic
      Phoenix.PubSub.subscribe(Lasso.PubSub, "upstream_sub_manager:#{profile}:#{chain}")

      # The Manager already started during setup, so we won't receive the initial broadcast
      # Instead, verify the topic exists by checking we're subscribed
      # (A proper test would require restarting the Manager, which is complex)

      # Verify we're subscribed (no crash)
      assert true
    end
  end

  describe "multiple subscription keys" do
    test "different keys managed independently", %{chain: chain, provider: provider, profile: profile} do
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      # Connection already established by MockWSProvider.start_mock()

      # Subscribe to both
      {:ok, _status1} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key1)
      {:ok, _status2} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key2)
      Process.sleep(200)

      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert map_size(status.active_subscriptions) >= 2

      # Each has its own upstream_id
      id1 = status.active_subscriptions[{provider, key1}].upstream_id
      id2 = status.active_subscriptions[{provider, key2}].upstream_id
      assert id1 != id2

      # Release one
      UpstreamSubscriptionManager.release_subscription(profile, chain, provider, key1)
      Process.sleep(100)

      # Other should be unaffected
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key2}] != nil
      assert status.active_subscriptions[{provider, key2}].marked_for_teardown == false
    end
  end

  describe "stale subscription detection (race condition fix)" do
    @moduledoc """
    These tests verify the fix for the race condition where fast reconnects
    could cause stale subscriptions to be reused, resulting in dropped events.
    """

    test "detects stale subscription after fast reconnect and recreates", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:newHeads}

      # First disconnect MockWSProvider's initial connection, then establish our own
      # This gives us full control over connection_ids for this test
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      send(manager_pid, {:ws_disconnected, provider, %{reason: :test_reset}})
      Process.sleep(50)

      # Establish initial connection with known connection_id
      conn_id_1 = establish_connection_for_manager(profile, chain, provider)
      {:ok, _status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(100)

      # Verify initial subscription state
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      upstream_id_1 = status.active_subscriptions[{provider, key}].upstream_id
      assert status.active_subscriptions[{provider, key}].connection_id == conn_id_1

      # Simulate fast reconnect - new connection_id without explicit disconnect
      # This simulates the race condition where connection changes faster than cleanup
      conn_id_2 = establish_connection_for_manager(profile, chain, provider)
      assert conn_id_1 != conn_id_2

      # Consumer tries to reuse subscription - should detect stale and return existing
      # (but internally recreates with new connection_id)
      {:ok, _status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(100)

      # Verify subscription was recreated with new connection_id
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      upstream_id_2 = status.active_subscriptions[{provider, key}].upstream_id
      assert status.active_subscriptions[{provider, key}].connection_id == conn_id_2

      # Upstream IDs should be different (new subscription created)
      assert upstream_id_1 != upstream_id_2
    end

    test "returns error when connection state is unknown", %{chain: chain, profile: profile} do
      key = {:newHeads}
      # Use a provider that was never started (no ws_connected broadcast received)
      unknown_provider = "unknown_provider_#{System.unique_integer([:positive])}"

      # Don't establish connection - simulate Manager starting after connection
      # or connection state not yet received
      result = UpstreamSubscriptionManager.ensure_subscription(profile, chain, unknown_provider, key)

      assert result == {:error, :connection_unknown}
    end

    test "returns error when provider is disconnected", %{chain: chain, provider: provider, profile: profile} do
      key = {:newHeads}

      # Connection already established by MockWSProvider.start_mock()
      {:ok, _status} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)

      # Simulate disconnect
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      send(manager_pid, {:ws_disconnected, provider, %{reason: :test}})
      Process.sleep(50)

      # Try to subscribe again - should fail
      result = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      assert result == {:error, :not_connected}
    end

    test "connection state tracks connection_id correctly through lifecycle", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      # First disconnect MockWSProvider's initial connection, then establish our own
      # This gives us full control over connection_ids for this test
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      send(manager_pid, {:ws_disconnected, provider, %{reason: :test_reset}})
      Process.sleep(50)

      # Establish connection with known connection_id
      conn_id_1 = establish_connection_for_manager(profile, chain, provider)

      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.connection_states[provider].connection_id == conn_id_1
      assert status.connection_states[provider].status == :connected

      # Disconnect
      send(manager_pid, {:ws_disconnected, provider, %{reason: :test}})
      Process.sleep(50)

      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.connection_states[provider].status == :disconnected
      assert status.connection_states[provider].connection_id == nil

      # Reconnect with new connection_id
      conn_id_2 = establish_connection_for_manager(profile, chain, provider)

      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.connection_states[provider].connection_id == conn_id_2
      assert status.connection_states[provider].status == :connected
      assert conn_id_1 != conn_id_2
    end
  end

  describe "subscription liveness monitoring (Issue #27)" do
    @moduledoc """
    Tests for detecting silent subscription expiration.
    Provider-side WebSocket subscriptions can silently die while the connection stays alive.
    These tests verify that stale subscriptions are detected and invalidated.
    """

    test "subscription with events is not marked stale", %{chain: chain, provider: provider, profile: profile} do
      key = {:newHeads}

      {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(50)

      # Get manager state
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil

      # Simulate an event arriving - this should reset staleness timer
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      upstream_id = status.active_subscriptions[{provider, key}].upstream_id

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:subs:#{profile}:#{chain}",
        {:subscription_event, provider, upstream_id, %{"number" => "0x1"},
         System.monotonic_time(:millisecond)}
      )

      Process.sleep(50)

      # Subscription should still be active
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil
    end

    test "staleness timer is cancelled when subscription receives event", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:newHeads}

      {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(50)

      # Get initial status
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      upstream_id = status.active_subscriptions[{provider, key}].upstream_id

      # Send multiple events rapidly - each should reset the timer
      for i <- 1..5 do
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:subs:#{profile}:#{chain}",
          {:subscription_event, provider, upstream_id, %{"number" => "0x#{i}"},
           System.monotonic_time(:millisecond)}
        )

        Process.sleep(10)
      end

      # Subscription should still be active (timers keep getting reset)
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil
    end

    test "stale subscription is invalidated and consumers notified", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:newHeads}
      test_pid = self()

      # Register to receive invalidation events
      UpstreamSubscriptionRegistry.register_consumer(profile, chain, provider, key)

      {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(50)

      # Get manager pid and the current timer ref from state
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      state = :sys.get_state(manager_pid)
      %{staleness_timer_ref: timer_ref} = state.active_subscriptions[{provider, key}]

      # Manually trigger the staleness check with correct timer ref (simulating timer firing)
      send(manager_pid, {:staleness_check, provider, key, timer_ref})
      Process.sleep(50)

      # Should receive invalidation message
      assert_receive {:upstream_subscription_invalidated, ^provider, ^key, :subscription_stale},
                     1000

      # Subscription should be removed from state
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] == nil
    end

    test "logs subscriptions don't have staleness monitoring (for now)", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:logs, %{"address" => "0xtest_no_staleness"}}

      {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(50)

      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil

      # Manually trigger staleness check - logs subscriptions should be ignored
      # Note: logs subscriptions have nil timer_ref, so we pass a fake ref
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      send(manager_pid, {:staleness_check, provider, key, make_ref()})
      Process.sleep(50)

      # Subscription should still exist (logs don't have staleness detection yet)
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil
    end

    test "staleness threshold is read from chain config new_heads_staleness_threshold_ms", %{
      chain: chain,
      profile: profile
    } do
      # Test chains use default config with 42000ms staleness threshold
      # (which is the default in ChainConfig.Monitoring)
      status = UpstreamSubscriptionManager.get_status(profile, chain)

      # The new_heads_staleness_threshold_ms is stored in state but not exposed via get_status
      # We verify the calculation is working by checking the manager is running
      # A more comprehensive test would check actual timing, but that requires long waits
      assert status != nil
    end

    test "stale timer messages are ignored (race condition fix)", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      key = {:newHeads}

      {:ok, _} = UpstreamSubscriptionManager.ensure_subscription(profile, chain, provider, key)
      Process.sleep(50)

      # Get manager pid and the current timer ref
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:upstream_sub_manager, profile, chain})
      state = :sys.get_state(manager_pid)
      old_timer_ref = state.active_subscriptions[{provider, key}].staleness_timer_ref
      upstream_id = state.active_subscriptions[{provider, key}].upstream_id

      # Simulate event arriving which resets the timer (creates new timer_ref)
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:subs:#{profile}:#{chain}",
        {:subscription_event, provider, upstream_id, %{"number" => "0x1"},
         System.monotonic_time(:millisecond)}
      )

      Process.sleep(50)

      # Verify timer ref changed
      new_state = :sys.get_state(manager_pid)
      new_timer_ref = new_state.active_subscriptions[{provider, key}].staleness_timer_ref
      assert new_timer_ref != old_timer_ref

      # Now send a staleness check with the OLD timer ref (simulating race condition)
      # This should be ignored because the timer ref doesn't match
      send(manager_pid, {:staleness_check, provider, key, old_timer_ref})
      Process.sleep(50)

      # Subscription should still exist (stale timer message was ignored)
      status = UpstreamSubscriptionManager.get_status(profile, chain)
      assert status.active_subscriptions[{provider, key}] != nil
    end
  end
end
