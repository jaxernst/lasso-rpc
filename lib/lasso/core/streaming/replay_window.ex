defmodule Lasso.Core.Streaming.ReplayWindow do
  @moduledoc """
  Resolves a WebSocket replay limit from both block count and wall-clock time.

  `max_backfill_blocks` remains the operator's minimum continuity allowance. Fast
  chains receive enough additional blocks to cover one recovery-deadline horizon.
  The time-derived expansion is capped, while an explicit operator allowance is
  preserved. This avoids giving a 250 ms chain only eight seconds of continuity
  without silently weakening a configured contract.
  """

  @default_blocks 32
  @default_block_time_ms 12_000
  @default_horizon_ms 30_000
  @hard_cap_blocks 2_048

  @spec effective_blocks(integer() | nil, integer() | nil, integer() | nil) :: pos_integer()
  def effective_blocks(configured_blocks, block_time_ms, horizon_ms \\ @default_horizon_ms) do
    configured_blocks = positive_or(configured_blocks, @default_blocks)
    block_time_ms = positive_or(block_time_ms, @default_block_time_ms)
    horizon_ms = positive_or(horizon_ms, @default_horizon_ms)
    time_equivalent_blocks = ceil_div(horizon_ms, block_time_ms)

    max(configured_blocks, min(time_equivalent_blocks, @hard_cap_blocks))
  end

  defp positive_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_or(_value, fallback), do: fallback

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)
end
