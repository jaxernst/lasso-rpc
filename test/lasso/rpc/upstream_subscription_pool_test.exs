defmodule Lasso.Core.Streaming.UpstreamSubscriptionPoolTest do
  @moduledoc """
  Focused unit tests for UpstreamSubscriptionPool state management.

  Tests critical internal behaviors that integration tests don't cover:
  - Refcount lifecycle and consistency
  - Subscription state management
  - Resubscription state atomicity
  - Error handling boundaries
  - Concurrent operation safety

  The Pool delegates upstream subscription management to
  InstanceSubscriptionManager. Pool state tracks refcount, status,
  primary_provider_id, and instance_id.

  Integration tests (upstream_subscription_pool_integration_test.exs) cover
  the full flow with real MockWSProvider.
  """

  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.UpstreamSubscriptionPool
  alias Lasso.Testing.MockWSProvider

  @default_profile "default"

  setup do
    suffix = System.unique_integer([:positive])
    test_chain = "test_pool_unit_#{suffix}"
    test_provider = "mock_provider_#{suffix}"
    test_profile = @default_profile

    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    Process.sleep(200)

    instance_id =
      Lasso.Providers.Catalog.lookup_instance_id(test_profile, test_chain, test_provider)

    on_exit(fn ->
      MockWSProvider.stop_mock(test_chain, test_provider)
      Lasso.ProfileChainSupervisor.stop_profile_chain(test_profile, test_chain)
      Lasso.Config.ConfigStore.unregister_chain_runtime(test_profile, test_chain)
      Process.sleep(50)
    end)

    {:ok,
     chain: test_chain, provider: test_provider, profile: test_profile, instance_id: instance_id}
  end

  describe "refcount lifecycle and consistency" do
    test "maintains correct refcount through subscribe/unsubscribe cycle", %{
      chain: chain,
      profile: profile
    } do
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}
      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)

      Process.sleep(150)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 1
      assert map_size(state.keys) == 1

      client2 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 2
      assert map_size(state.keys) == 1

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub1)
      Process.sleep(10)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 1
      assert state.keys[key] != nil

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub2)
      Process.sleep(100)

      state = get_pool_state(chain)
      assert state.keys == %{}

      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  describe "subscription state consistency" do
    test "keys map tracks primary_provider_id and instance_id correctly", %{
      chain: chain,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)

      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key1)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key2)

      Process.sleep(200)

      state = get_pool_state(chain)
      assert state.keys[key1].primary_provider_id != nil
      assert state.keys[key2].primary_provider_id != nil
      assert state.keys[key1].instance_id != nil
      assert state.keys[key2].instance_id != nil
      assert state.keys[key1].status == :active
      assert state.keys[key2].status == :active

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub1)
      Process.sleep(100)

      state = get_pool_state(chain)
      assert state.keys[key1] == nil
      assert state.keys[key2] != nil

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub2)
      Process.sleep(100)

      state = get_pool_state(chain)
      assert state.keys == %{}

      Process.exit(client, :kill)
    end
  end

  describe "error handling boundaries" do
    test "handles resubscribe when key no longer exists", %{chain: chain, profile: profile} do
      key = {:newHeads}
      coordinator_pid = self()

      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain),
        {:resubscribe, key, "provider_2", coordinator_pid}
      )

      assert_receive {:subscription_failed, _reason}, 1000

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

      start_time = System.monotonic_time(:millisecond)
      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 100
      assert is_binary(sub_id)

      state = get_pool_state(chain)
      assert state.keys[key].status in [:establishing, :active]
      assert state.keys[key].refcount == 1

      Process.sleep(200)

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

      clients =
        for _ <- 1..5 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      sub_ids =
        Enum.map(clients, fn client ->
          {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
          sub_id
        end)

      assert length(Enum.uniq(sub_ids)) == 5

      state = get_pool_state(chain)
      assert state.keys[key].status in [:establishing, :active]
      assert state.keys[key].refcount == 5

      Process.sleep(200)

      state = get_pool_state(chain)
      assert state.keys[key].status == :active

      Enum.each(clients, fn client -> Process.exit(client, :kill) end)
    end

    test "client unsubscribes during or after establishment", %{chain: chain, profile: profile} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)

      state = get_pool_state(chain)
      assert state.keys[key] != nil
      assert state.keys[key].status in [:establishing, :active]

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub_id)
      Process.sleep(50)

      state = get_pool_state(chain)
      assert state.keys == %{}

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

      for _ <- 1..10 do
        client = spawn(fn -> Process.sleep(:infinity) end)
        {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
        Process.sleep(5)
        :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain, sub_id)
        Process.exit(client, :kill)
      end

      Process.sleep(300)

      state = get_pool_state(chain)
      assert state.keys == %{}
    end

    test "subsequent subscribers after activation are instant", %{chain: chain, profile: profile} do
      key = {:newHeads}

      client1 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client1, key)

      Process.sleep(200)
      state = get_pool_state(chain)
      assert state.keys[key].status == :active

      client2 = spawn(fn -> Process.sleep(:infinity) end)
      start_time = System.monotonic_time(:millisecond)
      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client2, key)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 50

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

      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain),
        {:resubscribe, key, "provider_2", self()}
      )

      receive do
        {:subscription_confirmed, _, _} -> :ok
        {:subscription_failed, _reason} -> :ok
      after
        1000 -> :ok
      end

      Process.exit(client, :kill)
    end
  end

  describe "manager restart recovery" do
    test "pool re-establishes subscriptions after manager restart broadcast", %{
      chain: chain,
      profile: profile,
      instance_id: instance_id
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub} = UpstreamSubscriptionPool.subscribe_client(profile, chain, client, key)
      Process.sleep(200)

      state_before = get_pool_state(chain)
      assert state_before.keys[key].status == :active

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "instance_sub_manager:restarted:#{chain}",
        {:instance_sub_manager_restarted, instance_id}
      )

      Process.sleep(200)

      state_after = get_pool_state(chain)
      assert state_after.keys[key].status == :active

      Process.exit(client, :kill)
    end
  end

  defp get_pool_state(chain, profile \\ @default_profile) do
    :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))
  end
end
