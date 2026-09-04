defmodule Lasso.BlockSync.ConsensusP75Test do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Core.BlockSync.BlockTimeMeasurement

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

    test "time-aligns fresh sampled providers before rejecting a live head as an outlier", %{
      chain: chain
    } do
      now_ms = System.system_time(:millisecond)

      :ets.insert(
        :block_sync_registry,
        {{:block_time, chain},
         %BlockTimeMeasurement{ema_ms: 100.0, sample_count: 5, last_height: 1_200}}
      )

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "live"}, {1_200, now_ms, :ws, %{stale_after_ms: 30_000}}}
      )

      for provider <- ~w(sampled-1 sampled-2 sampled-3 sampled-4) do
        :ets.insert(
          :block_sync_registry,
          {{:height, chain, provider},
           {1_000, now_ms - 20_000, :http,
            %{stale_after_ms: 180_000, optimistic_credit_ms: 60_000}}}
        )
      end

      assert {:ok, 1_200} = BlockSyncRegistry.get_consensus_height_filtered(chain, [])
    end

    test "bounded alignment does not let one implausible head dictate consensus", %{
      chain: chain
    } do
      now_ms = System.system_time(:millisecond)

      :ets.insert(
        :block_sync_registry,
        {{:block_time, chain},
         %BlockTimeMeasurement{ema_ms: 100.0, sample_count: 5, last_height: 1_500}}
      )

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "outlier"}, {1_500, now_ms, :ws, %{stale_after_ms: 30_000}}}
      )

      for provider <- ~w(sampled-1 sampled-2 sampled-3 sampled-4) do
        :ets.insert(
          :block_sync_registry,
          {{:height, chain, provider},
           {1_000, now_ms - 1_000, :http,
            %{stale_after_ms: 180_000, optimistic_credit_ms: 60_000}}}
        )
      end

      assert {:ok, consensus} = BlockSyncRegistry.get_consensus_height_filtered(chain, [])
      assert consensus in 1_009..1_011
    end

    test "no providers: returns error", %{chain: chain} do
      assert {:error, :no_data} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "ignores stale heights without changing stored metadata", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "fresh", 105, :http, %{payload: "fresh"})
      BlockSyncRegistry.put_height(chain, "stale", 999, :ws, %{payload: "stale"})

      stale_timestamp = System.system_time(:millisecond) - 31_000

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "stale"}, {999, stale_timestamp, :ws, %{payload: "stale"}}}
      )

      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain, 30_000)

      assert {999, ^stale_timestamp, :ws, %{payload: "stale"}} =
               BlockSyncRegistry.get_all_heights(chain)["stale"]
    end

    test "default consensus and lag honor the observation's configured freshness", %{
      chain: chain
    } do
      observed_at_ms = System.system_time(:millisecond) - 45_000

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "slow-poll-provider"},
         {500, observed_at_ms, :http, %{stale_after_ms: 90_000}}}
      )

      assert {:ok, 500} = BlockSyncRegistry.get_consensus_height(chain)
      assert {:ok, 500} = BlockSyncRegistry.get_consensus_height_filtered(chain, [])
      assert {:ok, 0} = BlockSyncRegistry.get_provider_lag(chain, "slow-poll-provider")

      assert {:error, :no_data} = BlockSyncRegistry.get_consensus_height(chain, 30_000)

      assert {:error, :stale_data} =
               BlockSyncRegistry.get_provider_lag(chain, "slow-poll-provider", 30_000)
    end

    test "filtered consensus preserves provider and empty-list semantics", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{payload: "one"})
      BlockSyncRegistry.put_height(chain, "p2", 105, :http, %{payload: "two"})
      BlockSyncRegistry.put_height(chain, "p3", 110, :ws, %{payload: "three"})

      assert {:ok, 105} =
               BlockSyncRegistry.get_consensus_height_filtered(chain, ["p1", "p2"])

      assert {:ok, 110} =
               BlockSyncRegistry.get_consensus_height_filtered(chain, ["p3", "p3"])

      assert {:error, :no_data} =
               BlockSyncRegistry.get_consensus_height_filtered(chain, ["missing"])

      assert {:ok, 110} = BlockSyncRegistry.get_consensus_height_filtered(chain, [])
    end

    test "default consensus uses the published snapshot and refreshes on height writes", %{
      chain: chain
    } do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})

      assert [{{:consensus, ^chain}, first_revision, first_revision, 100, first_valid_through}] =
               :ets.lookup(:block_sync_registry, {:consensus, chain})

      assert is_integer(first_revision)
      assert is_integer(first_valid_through)
      assert {:ok, 100} = BlockSyncRegistry.get_consensus_height(chain)

      BlockSyncRegistry.put_height(chain, "p2", 105, :http, %{})

      assert [
               {{:consensus, ^chain}, second_revision, second_revision, 105, second_valid_through}
             ] =
               :ets.lookup(:block_sync_registry, {:consensus, chain})

      assert second_revision > first_revision
      assert second_valid_through >= first_valid_through
      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain)
    end

    test "expired snapshot falls back to an exact fresh calculation", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})

      [{{:consensus, ^chain}, revision, revision, 100, _valid_through}] =
        :ets.lookup(:block_sync_registry, {:consensus, chain})

      now_ms = System.system_time(:millisecond)

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "p1"}, {999, now_ms - 31_000, :http, %{}}}
      )

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "p2"}, {105, now_ms, :http, %{}}}
      )

      :ets.insert(
        :block_sync_registry,
        {{:consensus, chain}, revision, revision, 100, now_ms - 1}
      )

      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain)

      assert [{{:consensus, ^chain}, ^revision, ^revision, 105, valid_through}] =
               :ets.lookup(:block_sync_registry, {:consensus, chain})

      assert valid_through >= now_ms
    end

    test "an interrupted publication is never served and is repaired by the reader", %{
      chain: chain
    } do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})

      now_ms = System.system_time(:millisecond)

      :ets.insert(
        :block_sync_registry,
        {{:height, chain, "p2"}, {105, now_ms, :http, %{}}}
      )

      allocated_revision =
        :ets.update_counter(:block_sync_registry, {:consensus, chain}, {2, 1})

      assert [
               {{:consensus, ^chain}, ^allocated_revision, published_revision, 100,
                _valid_through}
             ] = :ets.lookup(:block_sync_registry, {:consensus, chain})

      assert published_revision < allocated_revision
      assert {:ok, 105} = BlockSyncRegistry.get_consensus_height(chain)

      assert [
               {{:consensus, ^chain}, ^allocated_revision, ^allocated_revision, 105,
                repaired_valid_through}
             ] = :ets.lookup(:block_sync_registry, {:consensus, chain})

      assert repaired_valid_through >= now_ms
    end

    test "concurrent writers cannot leave an older consensus snapshot", %{chain: chain} do
      1..32
      |> Task.async_stream(
        fn height ->
          BlockSyncRegistry.put_height(chain, "p#{height}", height, :http, %{})
        end,
        max_concurrency: 16,
        ordered: false
      )
      |> Stream.run()

      assert BlockSyncRegistry.get_consensus_height(chain) ==
               BlockSyncRegistry.get_consensus_height(chain, 30_000)

      assert [{{:consensus, ^chain}, revision, revision, _height, _valid_through}] =
               :ets.lookup(:block_sync_registry, {:consensus, chain})
    end

    test "clearing a chain removes its fixed consensus state", %{chain: chain} do
      BlockSyncRegistry.put_height(chain, "p1", 100, :http, %{})
      BlockSyncRegistry.clear_chain(chain)

      assert [] = :ets.lookup(:block_sync_registry, {:consensus, chain})
      assert {:error, :no_data} = BlockSyncRegistry.get_consensus_height(chain)
      assert [] = :ets.lookup(:block_sync_registry, {:consensus, chain})
    end
  end
end
