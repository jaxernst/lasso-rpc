defmodule Lasso.Core.Streaming.UpstreamSubscriptionPoolIntegrationTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.ClientSubscriptionRegistry
  alias Lasso.Core.Streaming.SubscriptionRouter
  alias Lasso.Core.Streaming.UpstreamSubscriptionPool
  alias Lasso.Testing.MockWSProvider
  alias LassoWeb.RPCSocket.ItemOwner

  @default_profile "public"

  setup do
    suffix = System.unique_integer([:positive])
    test_chain = suffix
    test_provider = "mock_ws_provider_#{suffix}"
    test_profile = @default_profile

    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    assert wait_for_pool(test_profile, test_chain)

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

    test "router binds subscriptions to the downstream client and releases its monitor", %{
      chain: chain,
      profile: profile
    } do
      client = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, subscription_id} =
        SubscriptionRouter.subscribe(profile, chain, {:newHeads}, client_pid: client)

      registry = ClientSubscriptionRegistry.via(profile, chain)
      registry_state = :sys.get_state(registry)
      assert registry_state.by_id[subscription_id].client_pid == client
      assert map_size(registry_state.client_monitors) == 1

      assert :ok = SubscriptionRouter.unsubscribe(profile, chain, subscription_id)
      registry_state = :sys.get_state(registry)
      assert registry_state.client_monitors == %{}
      assert {:monitors, []} = Process.info(GenServer.whereis(registry), :monitors)

      Process.exit(client, :kill)
    end

    test "repeated subscribe and unsubscribe keeps one bounded client monitor", %{
      chain: chain,
      profile: profile
    } do
      registry = ClientSubscriptionRegistry.via(profile, chain)

      Enum.each(1..20, fn _iteration ->
        {:ok, subscription_id} =
          SubscriptionRouter.subscribe(profile, chain, {:newHeads}, client_pid: self())

        assert map_size(:sys.get_state(registry).client_monitors) == 1
        assert :ok = SubscriptionRouter.unsubscribe(profile, chain, subscription_id)
      end)

      assert :sys.get_state(registry).client_monitors == %{}
      assert {:monitors, []} = Process.info(GenServer.whereis(registry), :monitors)
    end

    test "concurrent checked unsubscriptions return one true result", %{
      chain: chain,
      profile: profile
    } do
      {:ok, subscription_id} =
        SubscriptionRouter.subscribe(profile, chain, {:newHeads}, client_pid: self())

      results =
        1..2
        |> Enum.map(fn _iteration ->
          Task.async(fn ->
            SubscriptionRouter.unsubscribe_checked(profile, chain, subscription_id)
          end)
        end)
        |> Task.await_many()
        |> Enum.sort()

      assert results == [{:ok, false}, {:ok, true}]
    end

    test "subscription control does not execute arbitrary telemetry handlers", %{
      chain: chain,
      profile: profile
    } do
      handler_id = "subscription-status-isolation-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:lasso, :subs, :status],
            [:lasso, :subs, :client_subscribe],
            [:lasso, :subs, :client_unsubscribe],
            [:lasso, :subs, :upstream, :subscribe],
            [:lasso, :subs, :upstream, :unsubscribe],
            [:lasso, :subs, :resubscribe, :success],
            [:lasso, :subs, :resubscribe, :failed]
          ],
          fn _event, _measurements, _metadata, owner ->
            send(owner, :subscription_telemetry_handler_invoked)
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, subscription_id} =
               SubscriptionRouter.subscribe(profile, chain, {:newHeads}, client_pid: self())

      assert :ok = SubscriptionRouter.unsubscribe(profile, chain, subscription_id)
      refute_receive :subscription_telemetry_handler_invoked
    end

    test "a suspended pool cannot retain a subscription owner after socket death", %{
      chain: chain,
      profile: profile
    } do
      pool = GenServer.whereis(UpstreamSubscriptionPool.via(profile, chain))
      :ok = :sys.suspend(pool)

      on_exit(fn ->
        if Process.alive?(pool) do
          try do
            :sys.resume(pool)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      socket = spawn(fn -> Process.sleep(:infinity) end)
      item_ref = make_ref()
      now_us = System.monotonic_time(:microsecond)

      work = %ItemOwner.Work{
        chain_id: chain,
        method: "eth_subscribe",
        params: ["newHeads"],
        profile: profile,
        strategy: :priority,
        provider_id: nil,
        jsonrpc_id: 1,
        jsonrpc_id_present?: true,
        started_at_us: now_us,
        deadline_us: now_us + 5_000_000,
        timeout_ms: 5_000
      }

      assert {:ok, owner} = ItemOwner.start(socket, item_ref, work)
      owner_monitor = Process.monitor(owner)
      assert wait_for_mailbox(pool)

      Process.exit(socket, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :caller_down}, 250

      :ok = :sys.resume(pool)
      Process.sleep(20)
      registry = ClientSubscriptionRegistry.via(profile, chain)
      assert :sys.get_state(registry).by_id == %{}
    end

    test "registry delay past the deadline cannot publish a subscription", %{
      chain: chain,
      profile: profile
    } do
      pool = GenServer.whereis(UpstreamSubscriptionPool.via(profile, chain))
      registry = ClientSubscriptionRegistry.via(profile, chain)
      registry_pid = GenServer.whereis(registry)
      :ok = :sys.suspend(registry_pid)

      on_exit(fn ->
        if Process.alive?(registry_pid) do
          try do
            :sys.resume(registry_pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      socket = spawn(fn -> Process.sleep(:infinity) end)
      item_ref = make_ref()
      now_us = System.monotonic_time(:microsecond)

      work = %ItemOwner.Work{
        chain_id: chain,
        method: "eth_subscribe",
        params: ["newHeads"],
        profile: profile,
        strategy: :priority,
        provider_id: nil,
        jsonrpc_id: 1,
        jsonrpc_id_present?: true,
        started_at_us: now_us,
        deadline_us: now_us + 100_000,
        timeout_ms: 100
      }

      assert {:ok, owner} = ItemOwner.start(socket, item_ref, work)
      owner_monitor = Process.monitor(owner)
      assert wait_for_mailbox(registry_pid)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :deadline_expired}, 300

      :ok = :sys.resume(registry_pid)
      Process.sleep(20)
      assert :sys.get_state(registry).by_id == %{}
      assert :sys.get_state(pool).keys == %{}

      Process.exit(socket, :kill)
    end

    test "registry delay past the deadline cannot remove a subscription", %{
      chain: chain,
      profile: profile
    } do
      socket = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, subscription_id} =
        SubscriptionRouter.subscribe(profile, chain, {:newHeads}, client_pid: socket)

      pool = GenServer.whereis(UpstreamSubscriptionPool.via(profile, chain))
      registry = ClientSubscriptionRegistry.via(profile, chain)
      registry_pid = GenServer.whereis(registry)
      :ok = :sys.suspend(registry_pid)

      on_exit(fn ->
        if Process.alive?(registry_pid) do
          try do
            :sys.resume(registry_pid)
          catch
            :exit, _reason -> :ok
          end
        end

        Process.exit(socket, :kill)
      end)

      item_ref = make_ref()
      now_us = System.monotonic_time(:microsecond)

      work = %ItemOwner.Work{
        chain_id: chain,
        method: "eth_unsubscribe",
        params: [subscription_id],
        profile: profile,
        strategy: :priority,
        provider_id: nil,
        jsonrpc_id: 1,
        jsonrpc_id_present?: true,
        subscription_known?: true,
        started_at_us: now_us,
        deadline_us: now_us + 100_000,
        timeout_ms: 100
      }

      assert {:ok, owner} = ItemOwner.start(socket, item_ref, work)
      owner_monitor = Process.monitor(owner)
      assert wait_for_mailbox(registry_pid)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :deadline_expired}, 300

      :ok = :sys.resume(registry_pid)
      Process.sleep(20)
      assert Map.has_key?(:sys.get_state(registry).by_id, subscription_id)
      assert map_size(:sys.get_state(pool).keys) == 1

      assert {:ok, true} =
               SubscriptionRouter.unsubscribe_checked(profile, chain, subscription_id)
    end

    test "production item owner completes subscribe and checked unsubscribe asynchronously", %{
      chain: chain,
      profile: profile
    } do
      now_us = System.monotonic_time(:microsecond)
      subscribe_ref = make_ref()

      subscribe_work = %ItemOwner.Work{
        chain_id: chain,
        method: "eth_subscribe",
        params: ["newHeads"],
        profile: profile,
        strategy: :priority,
        provider_id: nil,
        jsonrpc_id: 1,
        jsonrpc_id_present?: true,
        started_at_us: now_us,
        deadline_us: now_us + 5_000_000,
        timeout_ms: 5_000
      }

      assert {:ok, subscribe_owner} = ItemOwner.start(self(), subscribe_ref, subscribe_work)

      assert_receive {:rpc_item_result, ^subscribe_ref, ^subscribe_owner,
                      {:ok, {:subscription_added, subscription_id}, _context}}

      unsubscribe_ref = make_ref()

      unsubscribe_work = %{
        subscribe_work
        | method: "eth_unsubscribe",
          params: [subscription_id],
          subscription_known?: true,
          started_at_us: System.monotonic_time(:microsecond),
          deadline_us: System.monotonic_time(:microsecond) + 5_000_000
      }

      assert {:ok, unsubscribe_owner} =
               ItemOwner.start(self(), unsubscribe_ref, unsubscribe_work)

      assert_receive {:rpc_item_result, ^unsubscribe_ref, ^unsubscribe_owner,
                      {:ok, {:subscription_removed, ^subscription_id, true}, _context}}
    end
  end

  defp get_pool_state(profile \\ @default_profile, chain) do
    :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))
  end

  defp wait_for_pool(profile, chain, attempts \\ 50)

  defp wait_for_pool(_profile, _chain, 0), do: false

  defp wait_for_pool(profile, chain, attempts) do
    case GenServer.whereis(UpstreamSubscriptionPool.via(profile, chain)) do
      pid when is_pid(pid) ->
        true

      nil ->
        Process.sleep(20)
        wait_for_pool(profile, chain, attempts - 1)
    end
  end

  defp wait_for_mailbox(pid, attempts \\ 100)

  defp wait_for_mailbox(_pid, 0), do: false

  defp wait_for_mailbox(pid, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} when length > 0 ->
        true

      _other ->
        Process.sleep(2)
        wait_for_mailbox(pid, attempts - 1)
    end
  end
end
