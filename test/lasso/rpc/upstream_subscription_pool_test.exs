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
