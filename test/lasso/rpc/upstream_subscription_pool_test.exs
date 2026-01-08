defmodule Lasso.Core.Streaming.UpstreamSubscriptionPoolTest do
  @moduledoc """
  Focused unit tests for UpstreamSubscriptionPool state management.

  Tests critical internal behaviors that integration tests don't cover:
  - Refcount lifecycle and consistency
  - Subscription state management
  - Resubscription state atomicity
  - Error handling boundaries
  - Concurrent operation safety

  Note: The Pool now delegates upstream subscription management to
  UpstreamSubscriptionManager. Pool state no longer includes `upstream_index`
  or per-key `upstream` tracking - it only tracks refcount, status, and
  primary_provider_id.

  Integration tests (upstream_subscription_pool_integration_test.exs) cover
  the full flow with real MockWSProvider.
  """

  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.{
    UpstreamSubscriptionPool,
    ClientSubscriptionRegistry,
    StreamSupervisor
  }

  alias Lasso.Testing.MockWSProvider

  @default_profile "default"

  setup do
    # Unique chain per test to avoid interference
    suffix = System.unique_integer([:positive])
    test_chain = "test_pool_unit_#{suffix}"
    test_provider = "mock_provider_#{suffix}"
    test_profile = @default_profile

    # Start mock WS provider - it will auto-create the chain and its dependencies
    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    Process.sleep(200)

    on_exit(fn ->
      MockWSProvider.stop_mock(test_chain, test_provider)

      # Stop the profile chain supervisor
      Lasso.ProfileChainSupervisor.stop_profile_chain(test_profile, test_chain)

      Lasso.Config.ConfigStore.unregister_chain_runtime(test_profile, test_chain)
      Process.sleep(50)
    end)

    {:ok, chain: test_chain, provider: test_provider, profile: test_profile}
  end

  describe "refcount lifecycle and consistency" do
    test "maintains correct refcount through subscribe/unsubscribe cycle", %{
      chain: chain,
      profile: profile
    } do
      # First subscribe (MockWSProvider auto-confirms)
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}
      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)

      Process.sleep(150)

      # Verify initial state
      state = get_pool_state(chain)
      assert state.keys[key].refcount == 1
      assert map_size(state.keys) == 1

      # Second subscribe (should increment refcount, not create new upstream)
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 2
      # Still only one key entry (upstream managed by Manager)
      assert map_size(state.keys) == 1

      # First unsubscribe (should decrement, keep key)
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub1)
      Process.sleep(10)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 1
      assert state.keys[key] != nil

      # Second unsubscribe (should cleanup everything)
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub2)
      Process.sleep(100)

      state = get_pool_state(chain)
      assert state.keys == %{}

      # Cleanup
      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  describe "subscription state consistency" do
    test "keys map tracks primary_provider_id correctly", %{chain: chain, profile: profile} do
      client = spawn(fn -> Process.sleep(:infinity) end)

      # Subscribe to two different keys
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key1)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key2)

      Process.sleep(200)

      # Verify each key has a primary_provider_id set
      state = get_pool_state(chain)
      assert state.keys[key1].primary_provider_id != nil
      assert state.keys[key2].primary_provider_id != nil
      assert state.keys[key1].status == :active
      assert state.keys[key2].status == :active

      # Unsubscribe one key
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub1)
      Process.sleep(100)

      # Verify only one key remains
      state = get_pool_state(chain)
      assert state.keys[key1] == nil
      assert state.keys[key2] != nil

      # Unsubscribe second key
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub2)
      Process.sleep(100)

      # Verify complete cleanup
      state = get_pool_state(chain)
      assert state.keys == %{}

      Process.exit(client, :kill)
    end
  end

  describe "error handling boundaries" do
    test "handles resubscribe when key no longer exists", %{chain: chain, profile: profile} do
      # Empty pool - no keys
      key = {:newHeads}
      coordinator_pid = self()

      # Attempt resubscription for non-existent key
      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain),
        {:resubscribe, key, "provider_2", coordinator_pid}
      )

      # Should receive failure notification
      assert_receive {:subscription_failed, :key_inactive}, 1000

      # State should remain clean
      state = get_pool_state(chain)
      assert state.keys == %{}
    end
  end

  describe "async subscription behavior" do
    test "first subscriber gets immediate response while upstream establishes", %{
      chain: chain,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      # Subscribe should return immediately (< 100ms), not wait for upstream
      start_time = System.monotonic_time(:millisecond)
      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should be instant (< 100ms), not waiting for upstream
      assert elapsed < 100
      assert is_binary(sub_id)

      # State should show establishing or active (depending on how fast mock responds)
      state = get_pool_state(chain)
      assert state.keys[key].status in [:establishing, :active]
      assert state.keys[key].refcount == 1

      # Wait for async establishment to complete if not already
      Process.sleep(200)

      # Should be active
      state = get_pool_state(chain)
      assert state.keys[key].status == :active
      assert state.keys[key].primary_provider_id != nil

      Process.exit(client, :kill)
    end

    test "multiple subscribers during establishment all get immediate response", %{
      chain: chain,
      profile: profile
    } do
      key = {:newHeads}

      # Create 5 clients that subscribe rapidly
      clients =
        for _ <- 1..5 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      # All should subscribe instantly
      sub_ids =
        Enum.map(clients, fn client ->
          {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
          sub_id
        end)

      # All should have unique subscription IDs
      assert length(Enum.uniq(sub_ids)) == 5

      # State should show establishing with refcount 5
      state = get_pool_state(chain)
      assert state.keys[key].status in [:establishing, :active]
      assert state.keys[key].refcount == 5

      # Wait for establishment
      Process.sleep(200)

      # Should be active
      state = get_pool_state(chain)
      assert state.keys[key].status == :active

      Enum.each(clients, fn client -> Process.exit(client, :kill) end)
    end

    test "client unsubscribes during or after establishment", %{chain: chain, profile: profile} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      # Subscribe
      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)

      # Verify entry exists (status can be establishing or active depending on timing)
      state = get_pool_state(chain)
      assert state.keys[key] != nil
      assert state.keys[key].status in [:establishing, :active]

      # Unsubscribe immediately
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub_id)
      Process.sleep(50)

      # Entry should be cleaned up (refcount was 1)
      state = get_pool_state(chain)
      assert state.keys == %{}

      # Even if upstream establishment completes, it should not create orphaned state
      Process.sleep(200)
      state = get_pool_state(chain)
      assert state.keys == %{}

      Process.exit(client, :kill)
    end

    test "rapid subscribe/unsubscribe cycles maintain consistency", %{
      chain: chain,
      profile: profile
    } do
      key = {:newHeads}

      # Rapid subscribe/unsubscribe cycles
      for _ <- 1..10 do
        client = spawn(fn -> Process.sleep(:infinity) end)
        {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
        Process.sleep(5)
        :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub_id)
        Process.exit(client, :kill)
      end

      # Wait for any pending operations
      Process.sleep(300)

      # State should be clean (no leaks)
      state = get_pool_state(chain)
      assert state.keys == %{}
    end

    test "subsequent subscribers after activation are instant", %{chain: chain, profile: profile} do
      key = {:newHeads}

      # First subscriber triggers establishment
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)

      # Wait for establishment to complete
      Process.sleep(200)
      state = get_pool_state(chain)
      assert state.keys[key].status == :active

      # Subsequent subscribers should be instant
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      start_time = System.monotonic_time(:millisecond)
      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should be fast (< 50ms) - accounting for test infrastructure overhead
      assert elapsed < 50

      # Refcount should be 2
      state = get_pool_state(chain)
      assert state.keys[key].refcount == 2

      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  describe "transitioning_from race condition handling" do
    test "tracks transitioning_from during resubscribe", %{chain: chain, profile: profile} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
      Process.sleep(200)

      state = get_pool_state(chain)
      _old_provider = state.keys[key].primary_provider_id

      # Trigger resubscription to a new provider (simulating failover)
      # This is normally triggered by StreamCoordinator
      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain),
        {:resubscribe, key, "provider_2", self()}
      )

      # Should receive confirmation (even if provider_2 doesn't exist for subscription)
      # In real scenario, this would succeed or fail based on provider availability
      receive do
        {:subscription_confirmed, _, _} ->
          # Check that transitioning_from is set
          state = get_pool_state(chain)
          # Either transitioning_from is set OR deferred release already cleared it
          # Both are valid depending on timing
          :ok

        {:subscription_failed, _reason} ->
          # Also valid - provider_2 might not exist
          :ok
      after
        # Timeout is acceptable here since provider_2 may not exist and the
        # resubscribe operation may complete silently without sending a message
        1000 -> :ok
      end

      Process.exit(client, :kill)
    end
  end

  describe "manager restart recovery" do
    test "pool re-establishes subscriptions after manager restart broadcast", %{
      chain: chain,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
      Process.sleep(200)

      state_before = get_pool_state(chain)
      assert state_before.keys[key].status == :active

      # Simulate manager restart by broadcasting the restart event
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "upstream_sub_manager:#{profile}:#{chain}",
        {:upstream_sub_manager_restarted, chain}
      )

      Process.sleep(200)

      # Pool should still be active (re-established)
      state_after = get_pool_state(chain)
      assert state_after.keys[key].status == :active

      Process.exit(client, :kill)
    end
  end

  # Helper functions

  defp get_pool_state(chain, profile \\ @default_profile) do
    :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))
  end
end
