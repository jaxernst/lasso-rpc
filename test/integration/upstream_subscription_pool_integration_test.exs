defmodule Lasso.RPC.UpstreamSubscriptionPoolIntegrationTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.UpstreamSubscriptionPool
  alias Lasso.Testing.MockWSProvider

  @default_profile "default"

  setup do
    # Unique chain/provider per test to avoid cross-test interference
    suffix = System.unique_integer([:positive])
    test_chain = "test_ws_subs_#{suffix}"
    test_provider = "mock_ws_provider_#{suffix}"
    test_profile = @default_profile

    # Start mock WebSocket provider for non-existent chain
    # Chain will be auto-created by Providers module (called internally by MockWSProvider)
    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    # Wait briefly for infrastructure to start
    Process.sleep(200)

    on_exit(fn ->
      # Clean up provider
      MockWSProvider.stop_mock(test_chain, test_provider)

      # Stop the profile chain supervisor (uses "default" profile for tests)
      Lasso.ProfileChainSupervisor.stop_profile_chain("default", test_chain)

      # Unregister chain from ConfigStore
      Lasso.Config.ConfigStore.unregister_chain_runtime("default", test_chain)

      # Give some time for cleanup
      Process.sleep(100)
    end)

    {:ok, chain: test_chain, provider: test_provider, profile: test_profile}
  end

  describe "basic subscription lifecycle" do
    test "creates subscription entry and confirms synchronously", %{chain: chain, profile: profile} do
      client_pid = self()
      key = {:newHeads}

      {:ok, _sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)

      # Give time for subscription to be confirmed
      Process.sleep(100)

      state = get_pool_state(chain)

      # Should have confirmed subscription
      assert map_size(state.keys) == 1
      assert state.keys[key] != nil
    end

    test "increments refcount for duplicate subscriptions", %{chain: chain, profile: profile} do
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)

      # Wait for confirmation
      Process.sleep(100)

      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 2

      # Cleanup
      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end

    test "handles multiple different subscription types", %{chain: chain, profile: profile} do
      client_pid = self()
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key1)
      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key2)

      # Wait for confirmations
      Process.sleep(100)

      state = get_pool_state(chain)
      assert map_size(state.keys) == 2
      assert state.keys[key1] != nil
      assert state.keys[key2] != nil
    end
  end

  describe "subscription confirmation" do
    test "processes successful confirmation and updates state", %{
      chain: chain,
      provider: _provider, profile: profile
    } do
      client_pid = self()
      key = {:newHeads}

      {:ok, _sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)

      # Wait for auto-confirmation from MockWSProvider
      Process.sleep(100)

      # Verify state updates - Pool now tracks keys with primary_provider_id
      # (upstream tracking is delegated to UpstreamSubscriptionManager)
      state = get_pool_state(chain)
      refute Map.has_key?(state, :pending_subscribe)
      assert state.keys[key] != nil
      assert state.keys[key].status == :active
      assert state.keys[key].primary_provider_id != nil
    end
  end

  describe "subscription events" do
    test "receives and routes newHeads events", %{chain: chain, provider: provider, profile: profile} do
      client_pid = self()
      key = {:newHeads}

      {:ok, _sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)

      # Wait for confirmation
      Process.sleep(100)

      # Send a mock block
      block = %{
        "number" => "0x100",
        "hash" => "0xabc123",
        "parentHash" => "0xdef456"
      }

      MockWSProvider.send_block(chain, provider, block)

      # The event should be routed through StreamCoordinator
      # In a full integration test, we'd verify the client receives it
      Process.sleep(50)

      # Verify subscription is still active
      state = get_pool_state(chain)
      assert state.keys[key] != nil
    end
  end

  describe "unsubscription" do
    test "cleans up state when last client unsubscribes", %{chain: chain, profile: profile} do
      client_pid = self()
      key = {:newHeads}

      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)

      # Wait for confirmation
      Process.sleep(100)

      # Verify subscription exists
      state_before = get_pool_state(chain)
      assert state_before.keys[key] != nil

      # Unsubscribe
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub_id)
      Process.sleep(50)

      state_after = get_pool_state(chain)
      assert state_after.keys == %{}
    end

    test "maintains subscription when refcount > 1", %{chain: chain, profile: profile} do
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)
      Process.sleep(100)

      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)
      Process.sleep(50)

      # Unsubscribe first client
      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub1)
      Process.sleep(50)

      # Subscription should remain (refcount = 1)
      state = get_pool_state(chain)
      assert state.keys[key] != nil
      assert state.keys[key].refcount == 1

      # Cleanup
      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  # Helper functions

  defp get_pool_state(profile \\ @default_profile, chain) do
    :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))
  end
end
