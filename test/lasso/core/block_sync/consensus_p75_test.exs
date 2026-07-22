defmodule Lasso.BlockSync.ConsensusP75Test do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry

  setup do
    chain = System.unique_integer([:positive])
    BlockSyncRegistry.clear_chain(chain)
    on_exit(fn -> BlockSyncRegistry.clear_chain(chain) end)
    {:ok, chain: chain}
  end

  describe "P75 consensus calculation" do
    test "1 provider: returns that provider's height", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})
      assert {:ok, 100} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "2 providers: returns MAX", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})
      BlockSyncRegistry.put_height(chain, "p2", 105, :http, %{})
      # sorted desc: [105, 100], idx = floor(2*0.25) = 0
      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "3 providers: returns MAX", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})
      BlockSyncRegistry.put_height(chain, "p2", 105, :http, %{})
      BlockSyncRegistry.put_height(chain, "p3", 103, :http, %{})
      # sorted desc: [105, 103, 100], idx = floor(3*0.25) = 0
      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "4 providers: returns second highest (P75)", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})
      BlockSyncRegistry.put_height(chain, "p2", 108, :ws, %{})
      BlockSyncRegistry.put_height(chain, "p3", 105, :http, %{})
      BlockSyncRegistry.put_height(chain, "p4", 103, :http, %{})
      # sorted desc: [108, 105, 103, 100], idx = floor(4*0.25) = 1
      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "5 providers: returns second highest (P75)", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})
      BlockSyncRegistry.put_height(chain, "p2", 110, :ws, %{})
      BlockSyncRegistry.put_height(chain, "p3", 105, :http, %{})
      BlockSyncRegistry.put_height(chain, "p4", 103, :http, %{})
      BlockSyncRegistry.put_height(chain, "p5", 107, :http, %{})
      # sorted desc: [110, 107, 105, 103, 100], idx = floor(5*0.25) = 1
      assert {:ok, 107} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "10 providers: filters out top 2 outliers", %{chain: chain} do
      heights = [100, 101, 102, 103, 104, 105, 106, 107, 110, 115]

      Enum.with_index(heights, fn height, i ->
        BlockSyncRegistry.put_height(chain, "p#{i}", height, :http, %{})
      end)

      # sorted desc: [115, 110, 107, 106, 105, 104, 103, 102, 101, 100]
      # idx = floor(10*0.25) = 2 → Enum.at(sorted, 2) = 107
      assert {:ok, 107} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "all providers at same height", %{chain: chain} do
      for i <- 1..5 do
        BlockSyncRegistry.put_height(chain, "p#{i}", 200, :http, %{})
      end

      assert {:ok, 200} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "one outlier among many: outlier excluded from consensus", %{chain: chain} do
      for i <- 1..4 do
        BlockSyncRegistry.put_height(chain, "p#{i}", 100, :http, %{})
      end

      # One WS provider way ahead
      BlockSyncRegistry.put_height(chain, "ws_fast", 110, :ws, %{})
      # sorted desc: [110, 100, 100, 100, 100], idx = floor(5*0.25) = 1
      assert {:ok, 100} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "no providers: returns error", %{chain: chain} do
      assert {:error, :no_data} = BlockSyncRegistry.get_consensus_height(chain)
    end
  end
end
