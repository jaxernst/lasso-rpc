defmodule Lasso.Config.MonitoringDefaults do
  @moduledoc """
  Block-time-aware interval defaults for provider probing and block synchronization.

  The default interval is twice the expected block time, with a 5-second floor.
  Unknown block times use a 12-second interval. The ceiling is ten block times,
  with a 10-second floor and a 60-second fallback for unknown block times.
  """

  @doc """
  Derives the default probe interval from the chain's block time.

  Returns `max(block_time_ms * 2, 5_000)` for known block times;
  falls back to `12_000` when block time is unknown.
  """
  @spec default_probe_interval_ms(block_time_ms :: pos_integer() | nil) :: pos_integer()
  def default_probe_interval_ms(block_time_ms)
      when is_integer(block_time_ms) and block_time_ms > 0 do
    max(block_time_ms * 2, 5_000)
  end

  def default_probe_interval_ms(_), do: 12_000

  @doc """
  Derives the maximum allowed probe interval (ceiling) from the chain's block time.

  Returns `max(block_time_ms * 10, 10_000)` for known block times;
  falls back to `60_000` when block time is unknown.

  """
  @spec probe_interval_ceiling_ms(block_time_ms :: pos_integer() | nil) :: pos_integer()
  def probe_interval_ceiling_ms(block_time_ms)
      when is_integer(block_time_ms) and block_time_ms > 0 do
    max(block_time_ms * 10, 10_000)
  end

  def probe_interval_ceiling_ms(_), do: 60_000
end
