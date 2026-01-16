defmodule Lasso.Core.BlockSync.BlockTimeMeasurement do
  @moduledoc """
  Tracks inter-block intervals to dynamically measure block time.

  Uses exponential moving average (EMA) for fast adaptation to changing block rates,
  with monotonic time to avoid clock drift issues.

  ## Why EMA over Median?

  Chains like Arbitrum have demand-driven block production where block times
  vary from 100ms (high activity) to 5+ seconds (quiet periods). EMA adapts
  quickly to these changes, while median requires ~50% of samples to change
  before the measurement shifts.

  ## Multi-Provider Handling

  Heights come from multiple providers (WS and HTTP). The measurement tracks
  the global max height across providers. When multiple providers report:
  - Same height: ignored (height not increasing)
  - Heights close together: the 50ms floor rejects artificially fast intervals
  - Normal operation: interval is recorded normally

  This naturally handles provider convergence without needing per-provider tracking.
  """

  # EMA smoothing factor (higher = more reactive to recent samples)
  # 0.15 provides good balance: adapts in ~10-15 samples while smoothing noise
  @ema_alpha 0.15

  # Bounds for valid intervals
  @min_block_time_ms 50
  @max_block_time_ms 60_000

  # Minimum samples before trusting EMA
  @min_samples 5

  @type t :: %__MODULE__{
          ema_ms: float() | nil,
          sample_count: non_neg_integer(),
          last_height: non_neg_integer() | nil,
          last_mono_ms: integer() | nil
        }

  defstruct ema_ms: nil,
            sample_count: 0,
            last_height: nil,
            last_mono_ms: nil

  @doc """
  Record a new height observation.

  Calculates the inter-block interval and updates the EMA if the interval
  falls within valid bounds (50ms - 60s).
  """
  @spec record(t(), non_neg_integer()) :: t()
  def record(state, height) do
    now = :erlang.monotonic_time(:millisecond)

    case state.last_height do
      nil ->
        # First observation - just record baseline
        %{state | last_height: height, last_mono_ms: now}

      last when height > last ->
        elapsed = now - state.last_mono_ms
        blocks = height - last
        interval = div(elapsed, blocks)

        if interval >= @min_block_time_ms and interval <= @max_block_time_ms do
          # Valid interval - update EMA
          new_ema = update_ema(state.ema_ms, interval)

          %{state |
            ema_ms: new_ema,
            sample_count: state.sample_count + 1,
            last_height: height,
            last_mono_ms: now
          }
        else
          # Invalid interval (too fast or too slow) - skip but update tracking
          %{state | last_height: height, last_mono_ms: now}
        end

      _ ->
        # Height not increasing (reorg, duplicate, or out-of-order from slower provider)
        # Update timestamp to avoid stale timing on next valid observation
        %{state | last_mono_ms: now}
    end
  end

  @doc """
  Get the measured block time in milliseconds.

  Returns the EMA if we have enough samples, otherwise returns the fallback.
  """
  @spec get_block_time_ms(t(), non_neg_integer() | nil) :: non_neg_integer() | nil
  def get_block_time_ms(state, fallback) do
    if state.sample_count >= @min_samples and state.ema_ms != nil do
      trunc(state.ema_ms)
    else
      fallback
    end
  end

  @doc """
  Returns the number of valid samples recorded.
  """
  @spec sample_count(t()) :: non_neg_integer()
  def sample_count(state), do: state.sample_count

  @doc """
  Returns true if we have enough samples for a reliable measurement.
  """
  @spec warmed_up?(t()) :: boolean()
  def warmed_up?(state), do: state.sample_count >= @min_samples and state.ema_ms != nil

  @doc """
  Returns the raw EMA value (for debugging/telemetry).
  """
  @spec raw_ema(t()) :: float() | nil
  def raw_ema(state), do: state.ema_ms

  # Update EMA with new sample
  defp update_ema(nil, interval), do: interval * 1.0
  defp update_ema(current_ema, interval) do
    current_ema * (1 - @ema_alpha) + interval * @ema_alpha
  end
end
