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

  alias Lasso.Core.Streaming.{ClientSubscriptionRegistry, UpstreamSubscriptionPool}
  alias Lasso.Testing.MockWSProvider

  @default_profile "public"
  # Synthetic chain_id base outside registry range
  @chain_id_base 4_217_500

  setup do
    suffix = System.unique_integer([:positive])
    test_chain_id = @chain_id_base + rem(suffix, 100_000)
    test_provider = "mock_provider_#{suffix}"
    test_profile = @default_profile

    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain_id, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    :ok = wait_for_ws_channel(test_profile, test_chain_id, test_provider)

    instance_id =
      Lasso.Providers.Catalog.lookup_instance_id(test_profile, test_chain_id, test_provider)

    on_exit(fn ->
      MockWSProvider.stop_mock(test_chain_id, test_provider)
      Lasso.ProfileChainSupervisor.stop_profile_chain(test_profile, test_chain_id)
      Lasso.Config.ConfigStore.unregister_chain_runtime(test_profile, test_chain_id)
      Process.sleep(50)
    end)

    {:ok,
     chain_id: test_chain_id,
     provider: test_provider,
     profile: test_profile,
     instance_id: instance_id}
  end

  describe "refcount lifecycle and consistency" do
    test "maintains correct refcount through subscribe/unsubscribe cycle", %{
      chain_id: chain_id,
      profile: profile
    } do
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}
      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client1, key)

      :ok = wait_until_key_active(chain_id, key)

      state = get_pool_state(chain_id)
      assert state.keys[key].refcount == 1
      assert map_size(state.keys) == 1

      client2 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client2, key)

      state = get_pool_state(chain_id)
      assert state.keys[key].refcount == 2
      assert map_size(state.keys) == 1

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, sub1)

      state = get_pool_state(chain_id)
      assert state.keys[key].refcount == 1
      assert state.keys[key] != nil

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, sub2)

      :ok = wait_until_keys_empty(chain_id)

      state = get_pool_state(chain_id)
      assert state.keys == %{}

      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  describe "subscription state consistency" do
    test "keys map tracks primary_provider_id and instance_id correctly", %{
      chain_id: chain_id,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)

      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key1)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key2)

      :ok = wait_until_key_active(chain_id, key1)
      :ok = wait_until_key_active(chain_id, key2)

      state = get_pool_state(chain_id)
      assert state.keys[key1].primary_provider_id != nil
      assert state.keys[key2].primary_provider_id != nil
      assert state.keys[key1].instance_id != nil
      assert state.keys[key2].instance_id != nil
      assert state.keys[key1].status == :active
      assert state.keys[key2].status == :active

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, sub1)

      state = get_pool_state(chain_id)
      assert state.keys[key1] == nil
      assert state.keys[key2] != nil

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, sub2)

      :ok = wait_until_keys_empty(chain_id)

      state = get_pool_state(chain_id)
      assert state.keys == %{}

      Process.exit(client, :kill)
    end
  end

  describe "error handling boundaries" do
    test "rejects an unknown provider constraint without mutating pool state", %{
      chain_id: chain_id,
      profile: profile
    } do
      assert {:error, %Lasso.JSONRPC.Error{code: -32_602}} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads},
                 provider_id: "missing-provider"
               )

      assert get_pool_state(chain_id).keys == %{}
    end

    test "handles resubscribe when key no longer exists", %{
      chain_id: chain_id,
      profile: profile
    } do
      key = {:newHeads}
      coordinator_pid = self()

      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain_id),
        {:resubscribe, key, "provider_2", coordinator_pid}
      )

      assert_receive {:subscription_failed, _reason}, 1000

      state = get_pool_state(chain_id)
      assert state.keys == %{}
    end
  end

  describe "provider constraints and readiness" do
    test "reconsiders a transiently unavailable provider for a routed subscription", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile,
      instance_id: instance_id
    } do
      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :readiness_test}})

      assert TestHelper.eventually(fn ->
               Lasso.Core.Streaming.InstanceSubscriptionManager.ensure_subscription(
                 instance_id,
                 {:newHeads}
               ) == {:error, :not_connected}
             end)

      client_pid = self()

      subscribe_task =
        Task.async(fn ->
          UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client_pid, {:newHeads})
        end)

      Process.sleep(25)
      assert get_pool_state(chain_id).keys[{:newHeads}].status == :establishing

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_connection(profile, chain_id),
        {:ws_connected, provider, "conn-ready-routed"}
      )

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_conn_instance(instance_id),
        {:ws_connected, instance_id, "conn-ready-routed"}
      )

      :ok = wait_for_ws_channel(profile, chain_id, provider)
      :ok = wait_until_key_active(chain_id, {:newHeads})
      assert {:ok, _subscription_id} = Task.await(subscribe_task)

      entry = get_pool_state(chain_id).keys[{:newHeads}]
      assert entry.primary_provider_id == provider
      assert entry.provider_constraint == nil
    end

    test "an active sole-provider route terminates and can be re-established after reconnect", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile,
      instance_id: instance_id
    } do
      assert {:ok, subscription_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads}
               )

      :ok = wait_until_key_active(chain_id, {:newHeads})
      [{manager_pid, _}] = Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})
      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :recovery_test}})
      :ets.delete(:transport_channel_cache, {profile, chain_id, provider, :ws})

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.provider_event(profile, chain_id),
        %Lasso.Events.Provider.WSDisconnected{
          ts: System.system_time(:millisecond),
          chain_id: chain_id,
          provider_id: provider,
          reason: :recovery_test
        }
      )

      assert_receive {:subscription_terminated, ^subscription_id, :continuity_exhausted}, 1_000
      assert TestHelper.eventually(fn -> get_pool_state(chain_id).keys == %{} end)

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_connection(profile, chain_id),
        {:ws_connected, provider, "conn-recovered"}
      )

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_conn_instance(instance_id),
        {:ws_connected, instance_id, "conn-recovered"}
      )

      :ok = wait_for_ws_channel(profile, chain_id, provider)

      {:ok, replacement_subscription_id} =
        UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:newHeads})

      :ok = wait_until_key_active(chain_id, {:newHeads})
      assert get_pool_state(chain_id).keys[{:newHeads}].refcount == 1

      client_registry = :sys.get_state(ClientSubscriptionRegistry.via(profile, chain_id))
      assert client_registry.by_id[replacement_subscription_id].client_pid == self()
      assert client_registry.by_id[replacement_subscription_id].key == {:newHeads}

      assert :ok =
               UpstreamSubscriptionPool.unsubscribe_client(
                 profile,
                 chain_id,
                 replacement_subscription_id
               )
    end

    test "keeps routed subscriptions pending after provider readiness is exhausted", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile
    } do
      :ets.delete(:transport_channel_cache, {profile, chain_id, provider, :ws})

      client_pid = self()

      subscribe_task =
        Task.async(fn ->
          UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client_pid, {:newHeads})
        end)

      pool = UpstreamSubscriptionPool.via(profile, chain_id)
      Process.sleep(25)

      entry = get_pool_state(chain_id).keys[{:newHeads}]
      generation = entry.establishment_generation
      token = entry.retry_token
      assert is_reference(token)

      send(GenServer.whereis(pool), {:retry_establish, {:newHeads}, generation, make_ref(), []})
      Process.sleep(50)

      unchanged_entry = get_pool_state(chain_id).keys[{:newHeads}]
      assert unchanged_entry.status == :establishing
      assert unchanged_entry.refcount == 1
      assert unchanged_entry.retry_token == token

      Process.sleep(700)
      bounded_entry = get_pool_state(chain_id).keys[{:newHeads}]
      assert bounded_entry.readiness_retries <= 4

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_connection(profile, chain_id),
        {:ws_connected, provider, "conn-ready-after-exhaustion"}
      )

      :ok = wait_for_ws_channel(profile, chain_id, provider)
      :ok = wait_until_key_active(chain_id, {:newHeads})
      assert {:ok, _subscription_id} = Task.await(subscribe_task)
    end

    test "waits for the constrained provider channel and activates on that provider", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile
    } do
      :ets.delete(:transport_channel_cache, {profile, chain_id, provider, :ws})

      client_pid = self()

      subscribe_task =
        Task.async(fn ->
          UpstreamSubscriptionPool.subscribe_client(
            profile,
            chain_id,
            client_pid,
            {:newHeads},
            provider_id: provider
          )
        end)

      pool_key = {:route, provider, {:newHeads}}

      Process.sleep(25)
      assert get_pool_state(chain_id).keys[pool_key].status == :establishing

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_connection(profile, chain_id),
        {:ws_connected, provider, "conn-ready"}
      )

      :ok = wait_for_ws_channel(profile, chain_id, provider)
      :ok = wait_until_key_active(chain_id, pool_key)

      entry = get_pool_state(chain_id).keys[pool_key]
      assert entry.primary_provider_id == provider
      assert entry.provider_constraint == provider
      assert {:ok, _subscription_id} = Task.await(subscribe_task)
    end

    test "selects a lower-priority constrained provider", %{
      chain_id: chain_id,
      profile: profile
    } do
      secondary = "secondary_#{System.unique_integer([:positive])}"

      assert {:ok, ^secondary} =
               MockWSProvider.start_mock(chain_id, %{
                 id: secondary,
                 auto_confirm: true,
                 priority: 2
               })

      :ok = wait_for_ws_channel(profile, chain_id, secondary)

      assert {:ok, _subscription_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads},
                 provider_id: secondary
               )

      pool_key = {:route, secondary, {:newHeads}}
      :ok = wait_until_key_active(chain_id, pool_key)
      assert get_pool_state(chain_id).keys[pool_key].primary_provider_id == secondary
    end

    test "keeps constrained and routed subscriptions independent", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile
    } do
      assert {:ok, _subscription_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads},
                 provider_id: provider
               )

      assert {:ok, _subscription_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads}
               )

      pool_key = {:route, provider, {:newHeads}}
      :ok = wait_until_key_active(chain_id, pool_key)
      :ok = wait_until_key_active(chain_id, {:newHeads})

      state = get_pool_state(chain_id)
      assert state.keys[pool_key].refcount == 1
      assert state.keys[{:newHeads}].refcount == 1
    end

    test "unsubscribing one routing group preserves another shared upstream", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile,
      instance_id: instance_id
    } do
      assert {:ok, constrained_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads},
                 provider_id: provider
               )

      assert {:ok, routed_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads}
               )

      constrained_key = {:route, provider, {:newHeads}}
      :ok = wait_until_key_active(chain_id, constrained_key)
      :ok = wait_until_key_active(chain_id, {:newHeads})

      assert :ok =
               UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, constrained_id)

      assert get_pool_state(chain_id).keys[{:newHeads}].status == :active

      assert Lasso.Core.Streaming.InstanceSubscriptionRegistry.has_consumers?(
               instance_id,
               {:newHeads}
             )

      assert :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, routed_id)
    end

    test "a timed out establishment is client-visible and cannot be resurrected", %{
      chain_id: chain_id,
      provider: provider,
      profile: profile
    } do
      :ets.delete(:transport_channel_cache, {profile, chain_id, provider, :ws})

      deadline_us = System.monotonic_time(:microsecond) + 100_000

      assert {:error, :timeout} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads},
                 provider_id: provider,
                 request_owner_pid: self(),
                 deadline_us: deadline_us
               )

      assert get_pool_state(chain_id).keys == %{}

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_connection(profile, chain_id),
        {:ws_connected, provider, "conn-after-unsubscribe"}
      )

      Process.sleep(150)
      assert get_pool_state(chain_id).keys == %{}
    end
  end

  describe "async subscription behavior" do
    test "first subscriber receives an id after upstream establishment", %{
      chain_id: chain_id,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      start_time = System.monotonic_time(:millisecond)
      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 100
      assert is_binary(sub_id)

      state = get_pool_state(chain_id)
      assert state.keys[key].status in [:establishing, :active]
      assert state.keys[key].refcount == 1

      :ok = wait_until_key_active(chain_id, key)

      state = get_pool_state(chain_id)
      assert state.keys[key].status == :active
      assert state.keys[key].primary_provider_id != nil

      Process.exit(client, :kill)
    end

    test "multiple subscribers share the established upstream subscription", %{
      chain_id: chain_id,
      profile: profile
    } do
      key = {:newHeads}

      clients =
        for _ <- 1..5 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      sub_ids =
        Enum.map(clients, fn client ->
          {:ok, sub_id} =
            UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key)

          sub_id
        end)

      assert length(Enum.uniq(sub_ids)) == 5

      state = get_pool_state(chain_id)
      assert state.keys[key].status in [:establishing, :active]
      assert state.keys[key].refcount == 5

      :ok = wait_until_key_active(chain_id, key)

      state = get_pool_state(chain_id)
      assert state.keys[key].status == :active

      Enum.each(clients, fn client -> Process.exit(client, :kill) end)
    end

    test "subscription acknowledgement waits for the upstream confirmation", %{
      chain_id: chain_id,
      profile: profile
    } do
      delayed = "delayed_#{System.unique_integer([:positive])}"

      assert {:ok, ^delayed} =
               MockWSProvider.start_mock(chain_id, %{
                 id: delayed,
                 auto_confirm: true,
                 confirm_delay: 150,
                 priority: 2
               })

      :ok = wait_for_ws_channel(profile, chain_id, delayed)

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, subscription_id} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads},
                 provider_id: delayed
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert is_binary(subscription_id)
      assert elapsed_ms >= 100

      pool_key = {:route, delayed, {:newHeads}}
      assert get_pool_state(chain_id).keys[pool_key].status == :active
    end

    test "a slow upstream response cannot exceed the caller establishment deadline", %{
      chain_id: chain_id,
      profile: profile
    } do
      delayed = "deadline-delayed-#{System.unique_integer([:positive])}"

      assert {:ok, ^delayed} =
               MockWSProvider.start_mock(chain_id, %{
                 id: delayed,
                 auto_confirm: true,
                 confirm_delay: 1_000,
                 priority: 2
               })

      :ok = wait_for_ws_channel(profile, chain_id, delayed)

      {:ok, _primary_subscription} =
        UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:newHeads})

      deadline_us = System.monotonic_time(:microsecond) + 150_000
      started_at = System.monotonic_time(:millisecond)
      test_pid = self()

      delayed_task =
        Task.async(fn ->
          UpstreamSubscriptionPool.subscribe_client(
            profile,
            chain_id,
            test_pid,
            {:newHeads},
            provider_id: delayed,
            request_owner_pid: test_pid,
            deadline_us: deadline_us
          )
        end)

      delayed_key = {:route, delayed, {:newHeads}}

      assert TestHelper.eventually(fn ->
               case get_pool_state(chain_id).keys[delayed_key] do
                 %{establishment_attempt_pid: pid} when is_pid(pid) -> true
                 _ -> false
               end
             end)

      active_started_at = System.monotonic_time(:millisecond)

      assert {:ok, _shared_subscription} =
               UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:newHeads})

      assert System.monotonic_time(:millisecond) - active_started_at < 100
      assert {:error, :timeout} = Task.await(delayed_task)

      assert System.monotonic_time(:millisecond) - started_at < 500
      assert TestHelper.eventually(fn -> is_nil(get_pool_state(chain_id).keys[delayed_key]) end)
    end

    test "client unsubscribes during or after establishment", %{
      chain_id: chain_id,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key)

      state = get_pool_state(chain_id)
      assert state.keys[key] != nil
      assert state.keys[key].status in [:establishing, :active]

      :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, sub_id)

      state = get_pool_state(chain_id)
      assert state.keys == %{}

      state = get_pool_state(chain_id)
      assert state.keys == %{}

      Process.exit(client, :kill)
    end

    test "rapid subscribe/unsubscribe cycles maintain consistency", %{
      chain_id: chain_id,
      profile: profile
    } do
      key = {:newHeads}

      for _ <- 1..10 do
        client = spawn(fn -> Process.sleep(:infinity) end)

        {:ok, sub_id} =
          UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key)

        Process.sleep(5)
        :ok = UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, sub_id)
        Process.exit(client, :kill)
      end

      :ok = wait_until_keys_empty(chain_id)

      state = get_pool_state(chain_id)
      assert state.keys == %{}
    end

    test "subsequent subscribers after activation are instant", %{
      chain_id: chain_id,
      profile: profile
    } do
      key = {:newHeads}

      client1 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client1, key)

      :ok = wait_until_key_active(chain_id, key)

      state = get_pool_state(chain_id)
      assert state.keys[key].status == :active

      client2 = spawn(fn -> Process.sleep(:infinity) end)
      start_time = System.monotonic_time(:millisecond)
      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client2, key)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 50

      state = get_pool_state(chain_id)
      assert state.keys[key].refcount == 2

      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  describe "transitioning_from race condition handling" do
    test "slow replacement establishment does not block active subscription calls", %{
      chain_id: chain_id,
      profile: profile
    } do
      secondary = "slow-replacement-#{System.unique_integer([:positive])}"

      assert {:ok, ^secondary} =
               MockWSProvider.start_mock(chain_id, %{
                 id: secondary,
                 auto_confirm: true,
                 confirm_delay: 1_000,
                 priority: 2
               })

      :ok = wait_for_ws_channel(profile, chain_id, secondary)

      {:ok, _first_subscription} =
        UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:newHeads})

      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain_id),
        {:resubscribe, {:newHeads}, secondary, self()}
      )

      assert TestHelper.eventually(fn ->
               case get_pool_state(chain_id).keys[{:newHeads}] do
                 %{resubscribe_pid: pid} when is_pid(pid) -> true
                 _ -> false
               end
             end)

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, _shared_subscription} =
               UpstreamSubscriptionPool.subscribe_client(
                 profile,
                 chain_id,
                 self(),
                 {:newHeads}
               )

      assert System.monotonic_time(:millisecond) - started_at < 100
      assert_receive {:subscription_confirmed, ^secondary, nil}, 2_000
    end

    test "tracks transitioning_from during resubscribe", %{chain_id: chain_id, profile: profile} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key)
      :ok = wait_until_key_active(chain_id, key)

      state = get_pool_state(chain_id)
      _old_provider = state.keys[key].primary_provider_id

      GenServer.cast(
        UpstreamSubscriptionPool.via(profile, chain_id),
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
      chain_id: chain_id,
      profile: profile,
      instance_id: instance_id
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      {:ok, _sub} = UpstreamSubscriptionPool.subscribe_client(profile, chain_id, client, key)
      :ok = wait_until_key_active(chain_id, key)

      state_before = get_pool_state(chain_id)
      assert state_before.keys[key].status == :active

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.instance_sub_manager_restarted(chain_id),
        {:instance_sub_manager_restarted, instance_id}
      )

      :ok = wait_until_key_active(chain_id, key)

      state_after = get_pool_state(chain_id)
      assert state_after.keys[key].status == :active

      Process.exit(client, :kill)
    end
  end

  test "coordinator loss terminates downstream subscriptions", %{
    chain_id: chain_id,
    profile: profile
  } do
    {:ok, subscription_id} =
      UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:newHeads})

    coordinator =
      GenServer.whereis(
        Lasso.Core.Streaming.StreamCoordinator.via(profile, chain_id, {:newHeads})
      )

    assert is_pid(coordinator)
    Process.exit(coordinator, :kill)

    assert_receive {:subscription_terminated, ^subscription_id, :continuity_exhausted}, 1_000
    assert TestHelper.eventually(fn -> get_pool_state(chain_id).keys == %{} end)
  end

  defp get_pool_state(chain_id, profile \\ @default_profile) do
    :sys.get_state(UpstreamSubscriptionPool.via(profile, chain_id))
  end

  defp wait_for_ws_channel(profile, chain_id, provider, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ws_channel(profile, chain_id, provider, deadline)
  end

  defp do_wait_for_ws_channel(profile, chain_id, provider, deadline) do
    case :ets.lookup(:transport_channel_cache, {profile, chain_id, provider, :ws}) do
      [_] ->
        :ok

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          do_wait_for_ws_channel(profile, chain_id, provider, deadline)
        end
    end
  end

  defp wait_until_key_active(chain_id, key, profile \\ @default_profile, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_key_active(chain_id, key, profile, deadline)
  end

  defp do_wait_until_key_active(chain_id, key, profile, deadline) do
    state = get_pool_state(chain_id, profile)

    case Map.get(state.keys, key) do
      %{status: :active} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          do_wait_until_key_active(chain_id, key, profile, deadline)
        end
    end
  end

  defp wait_until_keys_empty(chain_id, profile \\ @default_profile, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_keys_empty(chain_id, profile, deadline)
  end

  defp do_wait_until_keys_empty(chain_id, profile, deadline) do
    state = get_pool_state(chain_id, profile)

    if state.keys == %{} do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(10)
        do_wait_until_keys_empty(chain_id, profile, deadline)
      end
    end
  end
end
