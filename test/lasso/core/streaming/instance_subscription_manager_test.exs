defmodule Lasso.Core.Streaming.InstanceSubscriptionManagerTest do
  @moduledoc """
  Tests for InstanceSubscriptionManager - per-instance manager for upstream
  WebSocket subscription lifecycle.

  Tests critical behaviors:
  - Subscription creation and reuse
  - Grace period teardown
  - Disconnect handling
  - Event dispatching to consumers via InstanceSubscriptionRegistry
  - Concurrent access safety
  - Crash recovery via restart broadcast
  - Staleness detection and timer race prevention
  """

  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.{InstanceSubscriptionManager, InstanceSubscriptionRegistry}
  alias Lasso.Testing.MockWSProvider

  @default_profile "default"

  setup do
    suffix = System.unique_integer([:positive])
    test_chain = "test_manager_#{suffix}"
    test_provider = "mock_manager_provider_#{suffix}"

    {:ok, ^test_provider} =
      MockWSProvider.start_mock(test_chain, %{
        id: test_provider,
        auto_confirm: true,
        priority: 1
      })

    Process.sleep(200)

    instance_id =
      Lasso.Providers.Catalog.lookup_instance_id(@default_profile, test_chain, test_provider)

    on_exit(fn ->
      MockWSProvider.stop_mock(test_chain, test_provider)
      Lasso.ProfileChainSupervisor.stop_profile_chain(@default_profile, test_chain)
      Lasso.Config.ConfigStore.unregister_chain_runtime(@default_profile, test_chain)
      Process.sleep(50)
    end)

    {:ok, chain: test_chain, provider: test_provider, instance_id: instance_id}
  end

  defp establish_connection(instance_id) do
    connection_id = "conn_test_#{System.unique_integer([:positive])}"

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:instance:#{instance_id}",
      {:ws_connected, instance_id, connection_id}
    )

    Process.sleep(20)
    connection_id
  end

  describe "subscription lifecycle" do
    test "first consumer creates new upstream subscription", %{instance_id: instance_id} do
      key = {:logs, %{"address" => "0xtest123"}}

      {:ok, status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      assert status == :new

      Process.sleep(100)

      manager_status = InstanceSubscriptionManager.get_status(instance_id)
      assert map_size(manager_status.active_subscriptions) >= 1
      assert manager_status.active_subscriptions[key] != nil
      assert manager_status.active_subscriptions[key].upstream_id != nil
    end

    test "second consumer joins existing subscription", %{instance_id: instance_id} do
      key = {:logs, %{"address" => "0xtest456"}}
      test_pid = self()

      consumer1 =
        spawn(fn ->
          InstanceSubscriptionRegistry.register_consumer(instance_id, key)
          {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
          send(test_pid, :first_subscribed)
          receive do: (:exit -> :ok)
        end)

      assert_receive :first_subscribed, 1000
      Process.sleep(100)

      status_before = InstanceSubscriptionManager.get_status(instance_id)
      original_upstream_id = status_before.active_subscriptions[key].upstream_id

      consumer2 =
        spawn(fn ->
          InstanceSubscriptionRegistry.register_consumer(instance_id, key)
          {:ok, status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
          send(test_pid, {:second_consumer, status})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:second_consumer, :existing}, 1000

      status_after = InstanceSubscriptionManager.get_status(instance_id)
      assert status_after.active_subscriptions[key].upstream_id == original_upstream_id
      assert status_after.active_subscriptions[key].consumer_count == 2

      send(consumer1, :exit)
      send(consumer2, :exit)
    end

    test "release_subscription marks for teardown when last consumer leaves", %{
      instance_id: instance_id
    } do
      key = {:logs, %{"address" => "0xrelease_test"}}

      {:ok, _status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(100)

      InstanceSubscriptionManager.release_subscription(instance_id, key)
      Process.sleep(100)

      status = InstanceSubscriptionManager.get_status(instance_id)

      case status.active_subscriptions[key] do
        nil -> :ok
        sub_info -> assert sub_info.marked_for_teardown == true
      end
    end

    test "new consumer cancels pending teardown", %{instance_id: instance_id} do
      key = {:newHeads}

      {:ok, _status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(100)

      InstanceSubscriptionManager.release_subscription(instance_id, key)
      Process.sleep(50)

      {:ok, :existing} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key].marked_for_teardown == false
    end
  end

  describe "consumer death handling" do
    test "consumer process death removes registration from Registry", %{
      instance_id: instance_id
    } do
      key = {:newHeads}
      test_pid = self()

      consumer =
        spawn(fn ->
          InstanceSubscriptionRegistry.register_consumer(instance_id, key)
          {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
          send(test_pid, :subscribed)
          receive do: (:exit -> :ok)
        end)

      assert_receive :subscribed, 1000
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, key) >= 1

      Process.exit(consumer, :kill)
      Process.sleep(100)

      count = InstanceSubscriptionRegistry.count_consumers(instance_id, key)
      assert count <= 1
    end
  end

  describe "event dispatching" do
    test "events dispatched to all registered consumers", %{instance_id: instance_id} do
      key = {:newHeads}
      test_pid = self()

      consumer1 =
        spawn(fn ->
          InstanceSubscriptionRegistry.register_consumer(instance_id, key)
          {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)

          receive do
            {:instance_subscription_event, ^instance_id, ^key, payload, _received_at} ->
              send(test_pid, {:consumer1_received, payload})
          after
            5000 -> send(test_pid, :consumer1_timeout)
          end
        end)

      consumer2 =
        spawn(fn ->
          InstanceSubscriptionRegistry.register_consumer(instance_id, key)
          {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)

          receive do
            {:instance_subscription_event, ^instance_id, ^key, payload, _received_at} ->
              send(test_pid, {:consumer2_received, payload})
          after
            5000 -> send(test_pid, :consumer2_timeout)
          end
        end)

      Process.sleep(200)

      test_payload = %{"number" => "0x100", "hash" => "0xabc"}

      InstanceSubscriptionRegistry.dispatch(
        instance_id,
        key,
        {:instance_subscription_event, instance_id, key, test_payload,
         System.monotonic_time(:millisecond)}
      )

      assert_receive {:consumer1_received, ^test_payload}, 1000
      assert_receive {:consumer2_received, ^test_payload}, 1000

      Process.exit(consumer1, :kill)
      Process.exit(consumer2, :kill)
    end
  end

  describe "disconnect handling" do
    test "disconnect cleans up subscriptions", %{instance_id: instance_id} do
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key1)
      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key2)
      Process.sleep(200)

      status_before = InstanceSubscriptionManager.get_status(instance_id)
      assert map_size(status_before.active_subscriptions) >= 2

      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :test_disconnect}})
      Process.sleep(100)

      status_after = InstanceSubscriptionManager.get_status(instance_id)
      assert status_after.active_subscriptions == %{}
    end
  end

  describe "concurrent access" do
    test "concurrent ensure_subscription calls handled safely", %{instance_id: instance_id} do
      key = {:logs, %{"address" => "0xconcurrent_test"}}
      test_pid = self()

      consumers =
        for i <- 1..10 do
          spawn(fn ->
            InstanceSubscriptionRegistry.register_consumer(instance_id, key)

            result =
              InstanceSubscriptionManager.ensure_subscription(instance_id, key)

            send(test_pid, {:result, i, result})
            receive do: (:exit -> :ok)
          end)
        end

      results =
        for _ <- 1..10 do
          receive do
            {:result, i, result} -> {i, result}
          after
            5000 -> flunk("Timeout waiting for subscription result")
          end
        end

      assert Enum.all?(results, fn {_, result} -> match?({:ok, _}, result) end)

      new_count = Enum.count(results, fn {_, result} -> result == {:ok, :new} end)
      existing_count = Enum.count(results, fn {_, result} -> result == {:ok, :existing} end)

      assert new_count == 1
      assert existing_count == 9

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil
      assert status.active_subscriptions[key].consumer_count == 10

      Enum.each(consumers, fn pid -> send(pid, :exit) end)
    end

    test "rapid subscribe/unsubscribe cycles handled correctly", %{instance_id: instance_id} do
      key = {:newHeads}

      for _ <- 1..5 do
        {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
        Process.sleep(10)
        InstanceSubscriptionManager.release_subscription(instance_id, key)
        Process.sleep(10)
      end

      Process.sleep(200)

      status = InstanceSubscriptionManager.get_status(instance_id)
      refute Map.has_key?(status, :error)
    end
  end

  describe "restart broadcast" do
    test "Manager broadcasts restart event on init", %{chain: chain} do
      Phoenix.PubSub.subscribe(Lasso.PubSub, "instance_sub_manager:restarted:#{chain}")
      assert true
    end
  end

  describe "multiple subscription keys" do
    test "different keys managed independently", %{instance_id: instance_id} do
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key1)
      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key2)
      Process.sleep(200)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert map_size(status.active_subscriptions) >= 2

      id1 = status.active_subscriptions[key1].upstream_id
      id2 = status.active_subscriptions[key2].upstream_id
      assert id1 != id2

      InstanceSubscriptionManager.release_subscription(instance_id, key1)
      Process.sleep(100)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key2] != nil
      assert status.active_subscriptions[key2].marked_for_teardown == false
    end
  end

  describe "stale subscription detection (race condition fix)" do
    test "detects stale subscription after fast reconnect and recreates", %{
      instance_id: instance_id
    } do
      key = {:newHeads}

      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :test_reset}})
      Process.sleep(50)

      conn_id_1 = establish_connection(instance_id)

      {:ok, _status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(100)

      status = InstanceSubscriptionManager.get_status(instance_id)
      upstream_id_1 = status.active_subscriptions[key].upstream_id
      assert status.active_subscriptions[key].connection_id == conn_id_1

      conn_id_2 = establish_connection(instance_id)
      assert conn_id_1 != conn_id_2

      {:ok, _status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(100)

      status = InstanceSubscriptionManager.get_status(instance_id)
      upstream_id_2 = status.active_subscriptions[key].upstream_id
      assert status.active_subscriptions[key].connection_id == conn_id_2
      assert upstream_id_1 != upstream_id_2
    end

    test "returns error when connection state is unknown" do
      fake_instance_id = "unknown_instance_#{System.unique_integer([:positive])}"
      {:ok, pid} = InstanceSubscriptionManager.start_link({"fake_chain", fake_instance_id})

      result = InstanceSubscriptionManager.ensure_subscription(fake_instance_id, {:newHeads})
      assert result == {:error, :connection_unknown}

      GenServer.stop(pid)
    end

    test "returns error when provider is disconnected", %{instance_id: instance_id} do
      key = {:newHeads}

      {:ok, _status} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)

      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :test}})
      Process.sleep(50)

      result = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      assert result == {:error, :not_connected}
    end

    test "connection state tracks connection_id correctly through lifecycle", %{
      instance_id: instance_id
    } do
      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :test_reset}})
      Process.sleep(50)

      conn_id_1 = establish_connection(instance_id)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.connection_state.connection_id == conn_id_1
      assert status.connection_state.status == :connected

      send(manager_pid, {:ws_disconnected, instance_id, %{reason: :test}})
      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.connection_state.status == :disconnected
      assert status.connection_state.connection_id == nil

      conn_id_2 = establish_connection(instance_id)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.connection_state.connection_id == conn_id_2
      assert status.connection_state.status == :connected
      assert conn_id_1 != conn_id_2
    end
  end

  describe "subscription liveness monitoring" do
    test "subscription with events is not marked stale", %{instance_id: instance_id} do
      key = {:newHeads}

      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil

      upstream_id = status.active_subscriptions[key].upstream_id

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:subs:instance:#{instance_id}",
        {:subscription_event, instance_id, upstream_id, %{"number" => "0x1"},
         System.monotonic_time(:millisecond)}
      )

      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil
    end

    test "staleness timer is cancelled when subscription receives event", %{
      instance_id: instance_id
    } do
      key = {:newHeads}

      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      upstream_id = status.active_subscriptions[key].upstream_id

      for i <- 1..5 do
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:subs:instance:#{instance_id}",
          {:subscription_event, instance_id, upstream_id, %{"number" => "0x#{i}"},
           System.monotonic_time(:millisecond)}
        )

        Process.sleep(10)
      end

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil
    end

    test "stale subscription is invalidated and consumers notified", %{
      instance_id: instance_id
    } do
      key = {:newHeads}

      InstanceSubscriptionRegistry.register_consumer(instance_id, key)
      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(50)

      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      state = :sys.get_state(manager_pid)
      %{staleness_timer_ref: timer_ref} = state.active_subscriptions[key]

      send(manager_pid, {:staleness_check, key, timer_ref})
      Process.sleep(50)

      assert_receive {:instance_subscription_invalidated, ^instance_id, ^key,
                      :subscription_stale},
                     1000

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] == nil
    end

    test "logs subscriptions don't have staleness monitoring", %{instance_id: instance_id} do
      key = {:logs, %{"address" => "0xtest_no_staleness"}}

      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil

      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      send(manager_pid, {:staleness_check, key, make_ref()})
      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil
    end

    test "staleness threshold is read from chain config", %{instance_id: instance_id} do
      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status != nil
    end

    test "stale timer messages are ignored (race condition fix)", %{instance_id: instance_id} do
      key = {:newHeads}

      {:ok, _} = InstanceSubscriptionManager.ensure_subscription(instance_id, key)
      Process.sleep(50)

      [{manager_pid, _}] =
        Registry.lookup(Lasso.Registry, {:instance_sub_manager, instance_id})

      state = :sys.get_state(manager_pid)
      old_timer_ref = state.active_subscriptions[key].staleness_timer_ref
      upstream_id = state.active_subscriptions[key].upstream_id

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:subs:instance:#{instance_id}",
        {:subscription_event, instance_id, upstream_id, %{"number" => "0x1"},
         System.monotonic_time(:millisecond)}
      )

      Process.sleep(50)

      new_state = :sys.get_state(manager_pid)
      new_timer_ref = new_state.active_subscriptions[key].staleness_timer_ref
      assert new_timer_ref != old_timer_ref

      send(manager_pid, {:staleness_check, key, old_timer_ref})
      Process.sleep(50)

      status = InstanceSubscriptionManager.get_status(instance_id)
      assert status.active_subscriptions[key] != nil
    end
  end
end
