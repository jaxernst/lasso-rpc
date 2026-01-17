defmodule Lasso.Core.BlockSync.BlockTimeMeasurementTest do
  @moduledoc """
  Tests for dynamic block time measurement using EMA.

  The BlockTimeMeasurement module tracks inter-block intervals using exponential
  moving average (EMA) for fast adaptation to variable block rates.
  """

  use ExUnit.Case, async: true

  alias Lasso.Core.BlockSync.BlockTimeMeasurement

  describe "record/2" do
    test "first observation initializes state without recording interval" do
      state = %BlockTimeMeasurement{}
      state = BlockTimeMeasurement.record(state, 1000)

      assert state.last_height == 1000
      assert state.last_mono_ms != nil
      assert state.ema_ms == nil
      assert state.sample_count == 0
    end

    test "records interval and updates EMA when height increases" do
      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: :erlang.monotonic_time(:millisecond) - 500,
        ema_ms: nil,
        sample_count: 0
      }

      state = BlockTimeMeasurement.record(state, 1002)

      # Should have recorded an interval (2 blocks in ~500ms = ~250ms/block)
      assert state.sample_count == 1
      assert state.ema_ms != nil
      assert state.last_height == 1002
      # First sample sets EMA directly
      assert_in_delta state.ema_ms, 250, 50
    end

    test "EMA adapts to changing block times" do
      # Start with EMA at 2000ms (simulating quiet period)
      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: :erlang.monotonic_time(:millisecond) - 250,
        ema_ms: 2000.0,
        sample_count: 10
      }

      # Record a 250ms interval (activity burst)
      state = BlockTimeMeasurement.record(state, 1001)

      # EMA should move toward 250ms (with alpha=0.15: 2000*0.85 + 250*0.15 = 1737.5)
      assert_in_delta state.ema_ms, 1737.5, 50
    end

    test "ignores out-of-order heights but updates timestamp (reorg handling)" do
      now = :erlang.monotonic_time(:millisecond)

      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: now - 500,
        ema_ms: 250.0,
        sample_count: 5
      }

      # Try to record a lower height (simulating reorg or slower provider)
      state = BlockTimeMeasurement.record(state, 995)

      # EMA and sample_count should not change
      assert state.ema_ms == 250.0
      assert state.sample_count == 5
      # But timestamp should update to avoid stale timing
      assert state.last_mono_ms > now - 500
    end

    test "ignores duplicate heights but updates timestamp" do
      now = :erlang.monotonic_time(:millisecond)

      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: now - 500,
        ema_ms: 250.0,
        sample_count: 5
      }

      # Try to record same height
      state = BlockTimeMeasurement.record(state, 1000)

      # EMA should not change
      assert state.ema_ms == 250.0
      assert state.sample_count == 5
      # Timestamp should update
      assert state.last_mono_ms > now - 500
    end

    test "rejects intervals below 50ms (too fast)" do
      state = %BlockTimeMeasurement{
        last_height: 1000,
        # 30ms ago
        last_mono_ms: :erlang.monotonic_time(:millisecond) - 30,
        ema_ms: 250.0,
        sample_count: 5
      }

      # 1 block in 30ms
      state = BlockTimeMeasurement.record(state, 1001)

      # EMA should not change (interval rejected)
      assert state.ema_ms == 250.0
      assert state.sample_count == 5
      # But height should update for next measurement
      assert state.last_height == 1001
    end

    test "rejects intervals above 60s (chain halt)" do
      state = %BlockTimeMeasurement{
        last_height: 1000,
        # 2 minutes ago
        last_mono_ms: :erlang.monotonic_time(:millisecond) - 120_000,
        ema_ms: 250.0,
        sample_count: 5
      }

      # 1 block in 120s
      state = BlockTimeMeasurement.record(state, 1001)

      # EMA should not change (interval rejected)
      assert state.ema_ms == 250.0
      assert state.sample_count == 5
      # Height should update
      assert state.last_height == 1001
    end

    test "handles multi-block gaps correctly" do
      # 10 blocks in 2500ms = 250ms per block
      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: :erlang.monotonic_time(:millisecond) - 2500,
        ema_ms: nil,
        sample_count: 0
      }

      state = BlockTimeMeasurement.record(state, 1010)

      # Should have recorded ~250ms interval
      assert state.sample_count == 1
      assert_in_delta state.ema_ms, 250, 50
    end

    test "EMA converges toward new block time over multiple samples" do
      # Start at 2000ms, simulate samples of ~250ms
      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: :erlang.monotonic_time(:millisecond),
        ema_ms: 2000.0,
        sample_count: 10
      }

      # Simulate 10 quick block times
      state =
        Enum.reduce(1..10, state, fn i, acc ->
          acc = %{acc | last_mono_ms: :erlang.monotonic_time(:millisecond) - 250}
          BlockTimeMeasurement.record(acc, 1000 + i)
        end)

      # After 10 samples at 250ms, EMA should have moved significantly toward 250ms
      # With alpha=0.15, after 10 samples: roughly halved the distance to 250
      assert state.ema_ms < 900
      assert state.sample_count == 20
    end
  end

  describe "get_block_time_ms/2" do
    test "returns fallback when insufficient samples" do
      state = %BlockTimeMeasurement{ema_ms: 250.0, sample_count: 3}
      assert BlockTimeMeasurement.get_block_time_ms(state, 12_000) == 12_000
    end

    test "returns EMA when warmup complete" do
      state = %BlockTimeMeasurement{ema_ms: 250.0, sample_count: 5}
      assert BlockTimeMeasurement.get_block_time_ms(state, 12_000) == 250
    end

    test "returns nil when no fallback and insufficient samples" do
      state = %BlockTimeMeasurement{ema_ms: 250.0, sample_count: 3}
      assert BlockTimeMeasurement.get_block_time_ms(state, nil) == nil
    end

    test "truncates EMA to integer" do
      state = %BlockTimeMeasurement{ema_ms: 253.7, sample_count: 5}
      assert BlockTimeMeasurement.get_block_time_ms(state, nil) == 253
    end
  end

  describe "helper functions" do
    test "sample_count returns number of recorded intervals" do
      state = %BlockTimeMeasurement{sample_count: 15}
      assert BlockTimeMeasurement.sample_count(state) == 15
    end

    test "warmed_up? returns true when 5+ samples and EMA exists" do
      state = %BlockTimeMeasurement{ema_ms: 250.0, sample_count: 5}
      assert BlockTimeMeasurement.warmed_up?(state) == true
    end

    test "warmed_up? returns false when < 5 samples" do
      state = %BlockTimeMeasurement{ema_ms: 250.0, sample_count: 3}
      assert BlockTimeMeasurement.warmed_up?(state) == false
    end

    test "warmed_up? returns false when EMA is nil" do
      state = %BlockTimeMeasurement{ema_ms: nil, sample_count: 5}
      assert BlockTimeMeasurement.warmed_up?(state) == false
    end

    test "raw_ema returns the raw EMA value" do
      state = %BlockTimeMeasurement{ema_ms: 253.7}
      assert BlockTimeMeasurement.raw_ema(state) == 253.7
    end
  end

  describe "variable block time adaptation (Arbitrum scenario)" do
    test "EMA tracks activity burst correctly" do
      # Simulate Arbitrum: quiet period (2s blocks) -> activity burst (250ms blocks)

      # Start with quiet period measurement
      state = %BlockTimeMeasurement{
        last_height: 1000,
        last_mono_ms: :erlang.monotonic_time(:millisecond),
        ema_ms: 2000.0,
        sample_count: 20
      }

      # Activity burst: 20 blocks at 250ms each
      state =
        Enum.reduce(1..20, state, fn i, acc ->
          acc = %{acc | last_mono_ms: :erlang.monotonic_time(:millisecond) - 250}
          BlockTimeMeasurement.record(acc, 1000 + i)
        end)

      # EMA should have converged close to 250ms
      # After 20 samples with alpha=0.15: moved roughly 95% of distance to 250
      assert state.ema_ms < 400
      assert state.ema_ms > 200
    end
  end
end
