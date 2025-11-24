defmodule Lasso.RPC.UpstreamSubscriptionPoolTest do
  @moduledoc """
  Focused unit tests for UpstreamSubscriptionPool state management.

  Tests critical internal behaviors that integration tests don't cover:
  - Refcount lifecycle and consistency
  - Upstream index consistency invariants
  - Resubscription state atomicity
  - Error handling boundaries
  - Concurrent operation safety

  Integration tests (upstream_subscription_pool_integration_test.exs) cover
  the full flow with real MockWSProvider.
  """

  use ExUnit.Case, async: false

  alias Lasso.RPC.{UpstreamSubscriptionPool, ClientSubscriptionRegistry, StreamSupervisor}
  alias Lasso.Testing.MockWSProvider

  setup do
    # Unique chain per test to avoid interference
    suffix = System.unique_integer([:positive])
    test_chain = "test_pool_unit_#{suffix}"
    test_provider = "mock_provider_#{suffix}"

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

      case Registry.lookup(Lasso.Registry, {:chain_supervisor, test_chain}) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Lasso.RPC.Supervisor, pid)
        [] -> :ok
      end

      Lasso.Config.ConfigStore.unregister_chain_runtime(test_chain)
      Process.sleep(50)
    end)

    {:ok, chain: test_chain, provider: test_provider}
  end

  describe "refcount lifecycle and consistency" do
    test "maintains correct refcount through subscribe/unsubscribe cycle", %{chain: chain} do
      # First subscribe (MockWSProvider auto-confirms)
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}
      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(chain, client1, key)

      Process.sleep(150)

      # Verify initial state
      state = get_pool_state(chain)
      assert state.keys[key].refcount == 1
      assert map_size(state.keys) == 1

      # Second subscribe (should increment refcount, not create new upstream)
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(chain, client2, key)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 2
      # Still only one upstream subscription
      assert map_size(state.keys[key].upstream) == 1

      # First unsubscribe (should decrement, keep key)
      :ok = UpstreamSubscriptionPool.unsubscribe_client(chain, sub1)
      Process.sleep(10)

      state = get_pool_state(chain)
      assert state.keys[key].refcount == 1
      assert state.keys[key] != nil
      # Upstream still exists
      assert map_size(state.upstream_index) == 1

      # Second unsubscribe (should cleanup everything)
      :ok = UpstreamSubscriptionPool.unsubscribe_client(chain, sub2)
      Process.sleep(100)

      state = get_pool_state(chain)
      assert state.keys == %{}
      assert state.upstream_index == %{}

      # Cleanup
      Process.exit(client1, :kill)
      Process.exit(client2, :kill)
    end
  end

  describe "upstream_index consistency invariants" do
    test "upstream_index always matches keys map structure", %{chain: chain} do
      client = spawn(fn -> Process.sleep(:infinity) end)

      # Subscribe to two different keys
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      {:ok, sub1} = UpstreamSubscriptionPool.subscribe_client(chain, client, key1)
      {:ok, sub2} = UpstreamSubscriptionPool.subscribe_client(chain, client, key2)

      Process.sleep(200)

      # Verify consistency: every key has corresponding upstream_index entry
      assert_index_consistency(chain)

      # Unsubscribe one key
      :ok = UpstreamSubscriptionPool.unsubscribe_client(chain, sub1)
      Process.sleep(100)

      # Verify consistency maintained
      assert_index_consistency(chain)

      # Unsubscribe second key
      :ok = UpstreamSubscriptionPool.unsubscribe_client(chain, sub2)
      Process.sleep(100)

      # Verify complete cleanup
      state = get_pool_state(chain)
      assert state.keys == %{}
      assert state.upstream_index == %{}

      Process.exit(client, :kill)
    end
  end

  describe "error handling boundaries" do
    test "handles resubscribe when key no longer exists", %{chain: chain} do
      # Empty pool - no keys
      key = {:newHeads}
      coordinator_pid = self()

      # Attempt resubscription for non-existent key
      GenServer.cast(
        UpstreamSubscriptionPool.via(chain),
        {:resubscribe, key, "provider_2", coordinator_pid}
      )

      # Should receive failure notification
      assert_receive {:subscription_failed, :key_inactive}, 1000

      # State should remain clean
      state = get_pool_state(chain)
      assert state.keys == %{}
      assert state.upstream_index == %{}
    end
  end

  describe "async subscription behavior" do
    test "first subscriber gets immediate response while upstream establishes", %{chain: chain} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      # Subscribe should return immediately (< 100ms), not wait for upstream
      start_time = System.monotonic_time(:millisecond)
      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(chain, client, key)
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

    test "multiple subscribers during establishment all get immediate response", %{chain: chain} do
      key = {:newHeads}

      # Create 5 clients that subscribe rapidly
      clients =
        for _ <- 1..5 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      # All should subscribe instantly
      sub_ids =
        Enum.map(clients, fn client ->
          {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(chain, client, key)
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

    test "client unsubscribes during or after establishment", %{chain: chain} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      key = {:newHeads}

      # Subscribe
      {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(chain, client, key)

      # Verify entry exists (status can be establishing or active depending on timing)
      state = get_pool_state(chain)
      assert state.keys[key] != nil
      assert state.keys[key].status in [:establishing, :active]

      # Unsubscribe immediately
      :ok = UpstreamSubscriptionPool.unsubscribe_client(chain, sub_id)
      Process.sleep(50)

      # Entry should be cleaned up (refcount was 1)
      state = get_pool_state(chain)
      assert state.keys == %{}

      # Even if upstream establishment completes, it should not create orphaned state
      Process.sleep(200)
      state = get_pool_state(chain)
      assert state.keys == %{}
      assert state.upstream_index == %{}

      Process.exit(client, :kill)
    end

    test "rapid subscribe/unsubscribe cycles maintain consistency", %{chain: chain} do
      key = {:newHeads}

      # Rapid subscribe/unsubscribe cycles
      for _ <- 1..10 do
        client = spawn(fn -> Process.sleep(:infinity) end)
        {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(chain, client, key)
        Process.sleep(5)
        :ok = UpstreamSubscriptionPool.unsubscribe_client(chain, sub_id)
        Process.exit(client, :kill)
      end

      # Wait for any pending operations
      Process.sleep(300)

      # State should be clean (no leaks)
      state = get_pool_state(chain)
      assert state.keys == %{}
      assert state.upstream_index == %{}
    end

    test "subsequent subscribers after activation are instant", %{chain: chain} do
      key = {:newHeads}

      # First subscriber triggers establishment
      client1 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _sub1} = UpstreamSubscriptionPool.subscribe_client(chain, client1, key)

      # Wait for establishment to complete
      Process.sleep(200)
      state = get_pool_state(chain)
      assert state.keys[key].status == :active

      # Subsequent subscribers should be instant
      client2 = spawn(fn -> Process.sleep(:infinity) end)
      start_time = System.monotonic_time(:millisecond)
      {:ok, _sub2} = UpstreamSubscriptionPool.subscribe_client(chain, client2, key)
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

  # Helper functions

  defp get_pool_state(chain) do
    :sys.get_state(UpstreamSubscriptionPool.via(chain))
  end

  defp assert_index_consistency(chain) do
    state = get_pool_state(chain)

    # For every key in keys map, there should be a corresponding upstream_index entry
    Enum.each(state.keys, fn {key, entry} ->
      provider_id = entry.primary_provider_id
      upstream_id = Map.get(entry.upstream, provider_id)

      if upstream_id do
        # Verify reverse lookup exists
        assert get_in(state.upstream_index, [provider_id, upstream_id]) == key,
               "upstream_index missing entry for key=#{inspect(key)}, provider=#{provider_id}, upstream=#{upstream_id}"
      end
    end)

    # For every upstream_index entry, there should be a corresponding key
    Enum.each(state.upstream_index, fn {provider_id, upstream_map} ->
      Enum.each(upstream_map, fn {upstream_id, key} ->
        assert state.keys[key] != nil,
               "upstream_index has orphaned entry: provider=#{provider_id}, upstream=#{upstream_id}, key=#{inspect(key)}"
      end)
    end)
  end
end
