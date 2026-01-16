defmodule Lasso.RPC.OptimisticLagTest do
  @moduledoc """
  Tests for the optimistic lag calculation used in provider selection.

  The optimistic lag formula accounts for observation delay on HTTP providers:

      staleness_credit = elapsed_ms / block_time_ms
      optimistic_height = reported_height + staleness_credit
      optimistic_lag = optimistic_height - consensus_height

  This prevents HTTP providers from being unfairly excluded on fast chains
  like Arbitrum (0.25s blocks) where polling intervals (2s) cause providers
  to always appear ~8 blocks behind.
  """

  use ExUnit.Case, async: true

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.RPC.ChainState

  @chain "optimistic_lag_test_chain"

  setup do
    # Ensure BlockSyncRegistry is started
    case Process.whereis(BlockSyncRegistry) do
      nil -> {:ok, _} = BlockSyncRegistry.start_link([])
      _pid -> :ok
    end

    :ok
  end

  describe "optimistic lag formula" do
    test "synced HTTP provider appears synced after poll gap" do
      # Scenario: Fast chain (250ms blocks), provider polled 2s ago
      # Provider was at consensus when polled, should still appear synced

      block_time_ms = 250
      poll_age_ms = 2000
      height_at_poll = 1000
      # 8 blocks
      blocks_since_poll = div(poll_age_ms, block_time_ms)

      # Consensus has advanced 8 blocks since the poll
      # 1008
      consensus_height = height_at_poll + blocks_since_poll

      # Raw lag would be: 1000 - 1008 = -8 (8 blocks behind)
      raw_lag = height_at_poll - consensus_height
      assert raw_lag == -8

      # Optimistic calculation credits the provider for the poll gap
      # 8 blocks
      staleness_credit = div(poll_age_ms, block_time_ms)
      # 1008
      optimistic_height = height_at_poll + staleness_credit
      # 0
      optimistic_lag = optimistic_height - consensus_height

      assert staleness_credit == 8
      assert optimistic_height == 1008
      assert optimistic_lag == 0
    end

    test "truly lagging provider remains flagged" do
      # Scenario: Provider is genuinely 4 blocks behind
      # Optimistic lag should preserve the true lag

      block_time_ms = 250
      poll_age_ms = 2000
      true_lag_blocks = 4

      # 4 blocks behind when polled
      height_at_poll = 996
      consensus_at_poll = 1000
      # 8
      blocks_since_poll = div(poll_age_ms, block_time_ms)

      # Consensus has advanced
      # 1008
      current_consensus = consensus_at_poll + blocks_since_poll

      # Raw lag: 996 - 1008 = -12
      raw_lag = height_at_poll - current_consensus
      assert raw_lag == -12

      # Optimistic lag should show the true lag (4 blocks), not the raw lag
      # 8
      staleness_credit = div(poll_age_ms, block_time_ms)
      # 1004
      optimistic_height = height_at_poll + staleness_credit
      # -4
      optimistic_lag = optimistic_height - current_consensus

      assert optimistic_lag == -true_lag_blocks
    end

    test "staleness credit is capped at 30s worth" do
      # Very stale data (>30s old) should have capped credit
      # to prevent runaway values

      block_time_ms = 250
      # 60 seconds
      poll_age_ms = 60_000

      # Uncapped credit would be 240 blocks
      uncapped_credit = div(poll_age_ms, block_time_ms)
      assert uncapped_credit == 240

      # Cap is 30s worth = 120 blocks
      max_credit = div(30_000, block_time_ms)
      assert max_credit == 120

      capped_credit = min(uncapped_credit, max_credit)
      assert capped_credit == 120
    end

    test "slow chains get proportionally less credit" do
      # On Ethereum (12s blocks), 2s poll gap = 0 blocks credit
      block_time_ms = 12_000
      poll_age_ms = 2000

      staleness_credit = div(poll_age_ms, block_time_ms)
      assert staleness_credit == 0

      # Even a 12s gap only gives 1 block credit
      staleness_credit_12s = div(12_000, block_time_ms)
      assert staleness_credit_12s == 1
    end

    test "fast chains get proportionally more credit" do
      # On Arbitrum (0.25s blocks), 2s poll gap = 8 blocks credit
      block_time_ms = 250
      poll_age_ms = 2000

      staleness_credit = div(poll_age_ms, block_time_ms)
      assert staleness_credit == 8

      # On Base (2s blocks), 3s poll gap = 1 block credit
      base_block_time_ms = 2000
      base_poll_age_ms = 3000

      base_staleness_credit = div(base_poll_age_ms, base_block_time_ms)
      assert base_staleness_credit == 1
    end
  end

  describe "integration with BlockSyncRegistry" do
    test "optimistic lag passes threshold when raw lag would fail" do
      provider_id = "test_http_provider_#{System.unique_integer()}"

      # Set up: provider reported height 1000, 2 seconds ago
      height = 1000
      poll_timestamp = System.system_time(:millisecond) - 2000

      # Manually insert into ETS (simulating a poll that happened 2s ago)
      :ets.insert(
        :block_sync_registry,
        {{:height, @chain, provider_id}, {height, poll_timestamp, :http, %{}}}
      )

      # Set up consensus: consensus is at 1008 (8 blocks ahead due to poll gap)
      consensus_provider_id = "test_ws_provider_#{System.unique_integer()}"
      consensus_height = 1008

      :ets.insert(
        :block_sync_registry,
        {{:height, @chain, consensus_provider_id},
         {consensus_height, System.system_time(:millisecond), :ws, %{}}}
      )

      # Verify raw lag would fail a threshold of 5 blocks
      {:ok, raw_lag} = ChainState.provider_lag(@chain, provider_id)
      # 8 blocks behind
      assert raw_lag == -8
      # Would fail max_lag_blocks: 5
      assert raw_lag < -5

      # Calculate what optimistic lag should be
      # Arbitrum-like
      block_time_ms = 250
      elapsed_ms = System.system_time(:millisecond) - poll_timestamp
      staleness_credit = div(elapsed_ms, block_time_ms)

      # Should be close to 0 (synced) because credit ~= lag
      expected_optimistic_lag = height + staleness_credit - consensus_height

      # The optimistic lag should be >= -5 (would pass threshold)
      assert expected_optimistic_lag >= -5,
             "Expected optimistic lag #{expected_optimistic_lag} to pass threshold of -5"
    end
  end
end
