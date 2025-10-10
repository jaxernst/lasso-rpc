defmodule Lasso.RPC.Caching.BlockchainMetadataCacheTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.Caching.BlockchainMetadataCache

  setup do
    # Ensure ETS table exists
    BlockchainMetadataCache.ensure_table()

    # Clean up test data
    BlockchainMetadataCache.clear_chain("test_chain")

    :ok
  end

  describe "get_block_height/1" do
    test "returns error when no data cached" do
      assert {:error, :not_found} = BlockchainMetadataCache.get_block_height("unknown_chain")
    end

    test "returns cached value when fresh" do
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      assert {:ok, 12_345_678} = BlockchainMetadataCache.get_block_height("test_chain")
    end

    test "returns stale error when data is old" do
      # Put a value with old timestamp
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      # Manually set old timestamp (more than 30s ago)
      old_timestamp = System.system_time(:millisecond) - 40_000
      :ets.insert(:blockchain_metadata, {{:chain, "test_chain", :updated_at}, old_timestamp})

      assert {:error, :stale} = BlockchainMetadataCache.get_block_height("test_chain")
    end
  end

  describe "get_block_height!/1" do
    test "returns value directly on success" do
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      assert 12_345_678 = BlockchainMetadataCache.get_block_height!("test_chain")
    end

    test "raises on error" do
      assert_raise ArgumentError, fn ->
        BlockchainMetadataCache.get_block_height!("unknown_chain")
      end
    end
  end


  describe "get_provider_block_height/2" do
    test "returns error when provider not tracked" do
      assert {:error, :not_found} =
               BlockchainMetadataCache.get_provider_block_height("test_chain", "provider1")
    end

    test "returns provider height when cached" do
      BlockchainMetadataCache.put_provider_block_height(
        "test_chain",
        "provider1",
        12_345_678,
        45
      )

      assert {:ok, 12_345_678} =
               BlockchainMetadataCache.get_provider_block_height("test_chain", "provider1")
    end
  end

  describe "get_provider_lag/2" do
    test "returns error when provider not tracked" do
      assert {:error, :not_found} =
               BlockchainMetadataCache.get_provider_lag("test_chain", "provider1")
    end

    test "returns zero lag when provider at best known height" do
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      BlockchainMetadataCache.put_provider_block_height(
        "test_chain",
        "provider1",
        12_345_678,
        45
      )

      assert {:ok, 0} = BlockchainMetadataCache.get_provider_lag("test_chain", "provider1")
    end

    test "returns negative lag when provider behind" do
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      BlockchainMetadataCache.put_provider_block_height(
        "test_chain",
        "provider1",
        12_345_673,
        45
      )

      assert {:ok, -5} = BlockchainMetadataCache.get_provider_lag("test_chain", "provider1")
    end

    test "returns positive lag when provider ahead" do
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      BlockchainMetadataCache.put_provider_block_height(
        "test_chain",
        "provider1",
        12_345_680,
        45
      )

      assert {:ok, 2} = BlockchainMetadataCache.get_provider_lag("test_chain", "provider1")
    end
  end

  describe "get_chain_id/1" do
    test "returns error when not cached" do
      assert {:error, :not_found} = BlockchainMetadataCache.get_chain_id("test_chain")
    end

    test "returns cached chain ID" do
      BlockchainMetadataCache.put_chain_id("test_chain", "0x1")

      assert {:ok, "0x1"} = BlockchainMetadataCache.get_chain_id("test_chain")
    end
  end

  describe "get_network_status/1" do
    test "returns error when no data cached" do
      assert {:error, :not_found} = BlockchainMetadataCache.get_network_status("unknown_chain")
    end

    test "returns network status when cached" do
      BlockchainMetadataCache.put_block_height("test_chain", 12_345_678)

      BlockchainMetadataCache.put_provider_block_height(
        "test_chain",
        "provider1",
        12_345_678,
        45
      )

      assert {:ok, status} = BlockchainMetadataCache.get_network_status("test_chain")
      assert status.status == :healthy
      assert status.best_known_height == 12_345_678
      assert status.providers_tracked == 1
      assert status.cache_age_ms < 1_000
    end
  end
end
