defmodule Lasso.Config.MonitoringDefaults do
  @moduledoc """
  Block-time-aware default derivations for probe and monitoring intervals.

  Single source of truth for the two interval formulas used by:
  - `ConfigBackendDB` (defaults at config-load time)
  - `ConfigGenerator` (defaults at provider-config generation time)
  - `ProbeCoordinator` (Phase 3b — per-instance effective interval)
  - `BlockSync.Worker` (Phase 3b — per-instance effective interval)
  - `EditChainPanel` (Phase 3c — UI input ceiling clamp)

  ## Formulas

  Both formulas share the same structural pattern: `max(block_time * factor, floor)`.

  `default_probe_interval_ms/1`:
    factor = 2 (poll twice per expected block), floor = 5_000ms.
    - Mainnet (12 000ms) → 24 000ms (two polls per 12s block)
    - Base/Optimism (2 000ms) → 5 000ms (floor, not 4 000ms — avoids F1
      recurrence on chains with slight timing jitter)
    - Arbitrum (250ms) → 5 000ms (floor — 40 blocks of allowed staleness)

  `probe_interval_ceiling_ms/1`:
    factor = 10 (10 blocks of allowed staleness), floor = 10_000ms.
    - Mainnet (12 000ms) → 120 000ms (10 × 12s)
    - Arbitrum (250ms) → 10 000ms (floor — 40 blocks; prevents a sub-second
      ceiling from thrashing the probe loop on pathologically fast chains)

  ## Unknown chains

  When `block_time_ms` is `nil` or not a positive integer, both functions
  fall through to wide fallbacks (12 000ms default, 60 000ms ceiling). These
  apply only until the chain's block time is known — either from
  `ChainRegistry` or from the discovery block-time sampling introduced in
  Phase 3a.
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

  Used by Phase 3c's `EditChainPanel` to clamp the user-supplied
  `probe_interval_ms` input: `[3_000, probe_interval_ceiling_ms(block_time_ms)]`.
  """
  @spec probe_interval_ceiling_ms(block_time_ms :: pos_integer() | nil) :: pos_integer()
  def probe_interval_ceiling_ms(block_time_ms)
      when is_integer(block_time_ms) and block_time_ms > 0 do
    max(block_time_ms * 10, 10_000)
  end

  def probe_interval_ceiling_ms(_), do: 60_000
end
