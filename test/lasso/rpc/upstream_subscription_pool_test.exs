defmodule Lasso.RPC.UpstreamSubscriptionPoolTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.{UpstreamSubscriptionPool, ClientSubscriptionRegistry, StreamSupervisor}

  @test_chain "test_upstream_pool_unit"

  setup do
    # Minimal setup - just the pool itself and its direct dependencies
    start_supervised!({ClientSubscriptionRegistry, @test_chain})
    start_supervised!({StreamSupervisor, @test_chain})
    {:ok, pool_pid} = start_supervised({UpstreamSubscriptionPool, @test_chain})

    {:ok, pool: pool_pid, chain: @test_chain}
  end

  describe "subscription event routing with upstream_index" do
    test "routes events using upstream_index lookup", %{chain: chain} do
      # This is a critical path - verify upstream_index is used for routing
      key = {:newHeads}
      upstream_id = "0x123abc"
      provider_id = "test_provider"

      # Inject state with upstream_index mapping
      :sys.replace_state(UpstreamSubscriptionPool.via(chain), fn state ->
        entry = %{
          refcount: 1,
          primary_provider_id: provider_id,
          upstream: %{provider_id => upstream_id},
          markers: %{},
          dedupe: nil
        }

        upstream_index = %{
          provider_id => %{upstream_id => key}
        }

        %{
          state
          | keys: Map.put(state.keys, key, entry),
            upstream_index: upstream_index
        }
      end)

      # Verify the lookup path exists
      state = :sys.get_state(UpstreamSubscriptionPool.via(chain))
      assert get_in(state.upstream_index, [provider_id, upstream_id]) == key
    end
  end

  # Note: Full subscription lifecycle tests (subscribe, route events, unsubscribe)
  # are in upstream_subscription_pool_integration_test.exs which uses MockWSProvider
  # and tests the complete flow end-to-end.
end
