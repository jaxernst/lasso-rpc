defmodule Lasso.RPC.ChainStateTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.ChainState
  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry

  setup do
    # Generate unique chain name for each test to avoid conflicts
    chain = "test_chain_#{System.unique_integer([:positive])}"

    # Clear any existing data for this chain
    BlockSyncRegistry.clear_chain(chain)

    on_exit(fn ->
      BlockSyncRegistry.clear_chain(chain)
    end)

    {:ok, chain: chain}
  end

  describe "consensus_height/2" do
    test "calculates consensus from fresh provider data", %{chain: chain} do
      # Insert fresh provider heights via Registry
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})
      BlockSyncRegistry.put_height(chain, "provider_2", 1_000_005, :http, %{})
      BlockSyncRegistry.put_height(chain, "provider_3", 999_995, :http, %{})

      # Consensus should be max height
      assert {:ok, 1_000_005} = ChainState.consensus_height(chain)
    end

    test "returns error when no data available", %{chain: chain} do
      # No data in registry
      assert {:error, :no_data} = ChainState.consensus_height(chain)
    end

    test "returns error when data is stale", %{chain: chain} do
      # Manually insert old timestamp via ETS (for testing staleness)
      old_ts = System.system_time(:millisecond) - 35_000

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "provider_1"}, {1_000_000, old_ts, :http, %{}}}
      )

      # Data older than 30s freshness threshold returns error
      assert {:error, :no_data} = ChainState.consensus_height(chain)
    end
  end

  describe "consensus_height!/1" do
    test "returns height directly when available", %{chain: chain} do
      # Insert fresh data
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})

      assert 1_000_000 = ChainState.consensus_height!(chain)
    end

    test "raises when consensus unavailable", %{chain: chain} do
      # No data
      assert_raise ArgumentError, ~r/Consensus height unavailable/, fn ->
        ChainState.consensus_height!(chain)
      end
    end
  end

  describe "provider_lag/2" do
    test "returns lag for a provider", %{chain: chain} do
      # Insert heights for multiple providers
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})
      BlockSyncRegistry.put_height(chain, "provider_2", 1_000_005, :http, %{})
      BlockSyncRegistry.put_height(chain, "provider_3", 1_000_002, :http, %{})

      # Consensus is 1_000_005 (max)
      # Provider 1 lag: 1_000_000 - 1_000_005 = -5
      # Provider 2 lag: 1_000_005 - 1_000_005 = 0
      # Provider 3 lag: 1_000_002 - 1_000_005 = -3
      assert {:ok, -5} = ChainState.provider_lag(chain, "provider_1")
      assert {:ok, 0} = ChainState.provider_lag(chain, "provider_2")
      assert {:ok, -3} = ChainState.provider_lag(chain, "provider_3")
    end

    test "returns error when provider not found", %{chain: chain} do
      # Add some data so consensus exists
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})

      assert {:error, :no_provider_data} = ChainState.provider_lag(chain, "nonexistent")
    end

    test "returns error when no data for provider and no consensus", %{chain: chain} do
      # No data at all - provider check happens first
      assert {:error, :no_provider_data} = ChainState.provider_lag(chain, "provider")
    end
  end

  describe "consensus_fresh?/1" do
    test "returns true when consensus is fresh", %{chain: chain} do
      # Insert fresh data
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})

      assert ChainState.consensus_fresh?(chain) == true
    end

    test "returns false when consensus is stale", %{chain: chain} do
      # Manually insert stale data
      old_ts = System.system_time(:millisecond) - 35_000

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "provider_1"}, {1_000_000, old_ts, :http, %{}}}
      )

      assert ChainState.consensus_fresh?(chain) == false
    end

    test "returns false when no data available", %{chain: chain} do
      assert ChainState.consensus_fresh?(chain) == false
    end
  end

  describe "data_available?/1" do
    test "returns true when height data exists", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})

      assert ChainState.data_available?(chain) == true
    end

    test "returns false when no height data exists", %{chain: chain} do
      assert ChainState.data_available?(chain) == false
    end
  end

  describe "provider_height/2" do
    test "returns provider height with timestamp", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})

      assert {:ok, 1_000_000, timestamp} = ChainState.provider_height(chain, "provider_1")
      assert is_integer(timestamp)
      # Timestamp should be recent (within last second)
      assert System.system_time(:millisecond) - timestamp < 1000
    end

    test "returns error when provider not found", %{chain: chain} do
      assert {:error, :not_found} = ChainState.provider_height(chain, "nonexistent")
    end
  end

  describe "all_provider_heights/2" do
    test "returns all provider heights", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})
      BlockSyncRegistry.put_height(chain, "provider_2", 1_000_005, :ws, %{})

      heights = ChainState.all_provider_heights(chain)

      assert length(heights) == 2
      assert Enum.any?(heights, fn {id, h, _ts} -> id == "provider_1" and h == 1_000_000 end)
      assert Enum.any?(heights, fn {id, h, _ts} -> id == "provider_2" and h == 1_000_005 end)
    end

    test "returns empty list when no data", %{chain: chain} do
      assert [] = ChainState.all_provider_heights(chain)
    end

    test "filters fresh data when only_fresh: true", %{chain: chain} do
      # Insert fresh data
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})

      # Insert stale data manually
      old_ts = System.system_time(:millisecond) - 35_000

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "provider_2"}, {1_000_005, old_ts, :http, %{}}}
      )

      # Without filter, should get both
      all_heights = ChainState.all_provider_heights(chain)
      assert length(all_heights) == 2

      # With filter, should only get fresh
      fresh_heights = ChainState.all_provider_heights(chain, only_fresh: true)
      assert length(fresh_heights) == 1
      assert Enum.any?(fresh_heights, fn {id, _h, _ts} -> id == "provider_1" end)
    end
  end

  describe "get_chain_status/1" do
    test "returns comprehensive status for all providers", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "provider_1", 1_000_000, :http, %{})
      BlockSyncRegistry.put_height(chain, "provider_2", 1_000_005, :ws, %{hash: "0xabc"})

      status = ChainState.get_chain_status(chain)

      assert Map.has_key?(status, "provider_1")
      assert Map.has_key?(status, "provider_2")

      p1 = status["provider_1"]
      assert p1.height == 1_000_000
      assert p1.source == :http

      p2 = status["provider_2"]
      assert p2.height == 1_000_005
      assert p2.source == :ws
      assert p2.metadata.hash == "0xabc"
    end
  end
end
