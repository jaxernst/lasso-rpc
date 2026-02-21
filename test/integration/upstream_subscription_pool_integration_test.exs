defmodule Lasso.Core.Streaming.UpstreamSubscriptionPoolIntegrationTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.UpstreamSubscriptionPool
  alias Lasso.Testing.MockWSProvider

  @default_profile "default"

  setup do
    suffix = System.unique_integer([:positive])
    test_chain = "test_ws_subs_#{suffix}"
    test_provider = "mock_ws_provider_#{suffix}"
    test_profile = @default_profile

    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    Process.sleep(200)

    on_exit(fn ->
      MockWSProvider.stop_mock(test_chain, test_provider)
      Lasso.ProfileChainSupervisor.stop_profile_chain(@default_profile, test_chain)
      Lasso.Config.ConfigStore.unregister_chain_runtime(@default_profile, test_chain)
      Process.sleep(100)
    end)

    {:ok, chain: test_chain, provider: test_provider, profile: test_profile}
  end

  describe "basic subscription lifecycle" do
    test "creates subscription entry and confirms synchronously", %{
      chain: chain,
      profile: profile
    } do
      client_pid = self()
      key = {:newHeads}

      {:ok, _sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)

      Process.sleep(100)

      state = get_pool_state(chain)

      assert map_size(state.keys) == 1
      assert state.keys[key] != nil
    end

    test "increments refcount for duplicate subscriptions", %{chain: chain, profile: profile} do
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)
      Process.sleep(100)

      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 2

      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end

    test "handles multiple different subscription types", %{chain: chain, profile: profile} do
      client_pid = self()
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key1)
      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key2)

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
      profile: profile
    } do
      client_pid = self()
      key = {:newHeads}

      {:ok, _sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)
      Process.sleep(100)

      state = get_pool_state(chain)
      refute Map.has_key?(state, :pending_subscribe)
      assert state.keys[key] != nil
      assert state.keys[key].status == :active
      assert state.keys[key].primary_provider_id != nil
      assert state.keys[key].instance_id != nil
    end
  end

  describe "subscription events" do
    test "receives and routes newHeads events", %{
      chain: chain,
      provider: provider,
      profile: profile
    } do
      client_pid = self()
      key = {:newHeads}

      {:ok, _sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)
      Process.sleep(100)

      block = %{
        "number" => "0x100",
        "hash" => "0xabc123",
        "parentHash" => "0xdef456"
      }

      MockWSProvider.send_block(chain, provider, block)
      Process.sleep(50)

      state = get_pool_state(chain)
      assert state.keys[key] != nil
    end
  end

  describe "unsubscription" do
    test "cleans up state when last client unsubscribes", %{chain: chain, profile: profile} do
      client_pid = self()
      key = {:newHeads}

      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)
      Process.sleep(100)

      state_before = get_pool_state(chain)
      assert state_before.keys[key] != nil

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

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub1)
      Process.sleep(50)

      state = get_pool_state(chain)
      assert state.keys[key] != nil
      assert state.keys[key].refcount == 1

      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  defp get_pool_state(profile \\ @default_profile, chain) do
    :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))
  end
end
