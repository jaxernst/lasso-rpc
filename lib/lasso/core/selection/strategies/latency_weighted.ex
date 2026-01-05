defmodule Lasso.RPC.Strategies.LatencyWeighted do
  @moduledoc """
  Latency-weighted randomized selection.

  Distributes load across available providers with a probabilistic bias toward
  lower-latency and higher-success providers for the specific RPC method.

  Notes on metrics API inconsistency:
  - Transport-specific metrics are recorded under augmented method keys
    (e.g., "eth_getLogs@http"). To avoid key mismatch, this strategy first
    queries transport-specific metrics for HTTP; if missing, it falls back to
    WS and finally to transport-agnostic metrics if available.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.Core.Benchmarking.Metrics
  alias Lasso.RPC.StrategyContext

  # Default tuning knobs (can be overridden via application config)
  @freshness_cutoff_ms 10 * 60 * 1000
  @default_beta 3.0
  @default_ms_floor 30.0
  @default_min_calls 3
  @default_min_sr 0.85
  @default_explore_floor 0.05

  @impl true
  def prepare_context(selection) do
    base = StrategyContext.new(selection)

    # Calculate fallback latency for providers with no data
    fallback_latency =
      StrategyContext.calculate_fallback_latency(
        selection.profile,
        selection.chain,
        selection.method
      )

    # Return base StrategyContext with populated optional fields
    # Strategy-specific params (beta, ms_floor, explore_floor) are fetched
    # directly in rank_channels to maintain type safety
    %{
      base
      | min_calls:
          base.min_calls || Application.get_env(:lasso, :lw_min_calls, @default_min_calls),
        min_success_rate:
          base.min_success_rate || Application.get_env(:lasso, :lw_min_sr, @default_min_sr),
        freshness_cutoff_ms: base.freshness_cutoff_ms || @freshness_cutoff_ms,
        cold_start_baseline: fallback_latency
    }
  end

  @doc """
  Strategy-provided channel ranking used by Selection.select_channels/3 when present.

  Implements staleness validation and dynamic cold start penalties with
  probabilistic weighting based on latency, success rate, and confidence.
  """
  @impl true
  def rank_channels(channels, method, ctx, profile, chain) do
    current_time = System.system_time(:millisecond)

    # Fetch strategy-specific tuning params from app config
    beta = Application.get_env(:lasso, :lw_beta, @default_beta)
    ms_floor = Application.get_env(:lasso, :lw_ms_floor, @default_ms_floor)
    explore_floor = Application.get_env(:lasso, :lw_explore_floor, @default_explore_floor)

    # Use context fields populated in prepare_context
    min_calls = ctx.min_calls || @default_min_calls
    min_sr = ctx.min_success_rate || @default_min_sr
    freshness_cutoff = ctx.freshness_cutoff_ms || 10 * 60 * 1000

    # Batch fetch all metrics (eliminates N sequential GenServer calls)
    requests = Enum.map(channels, fn ch -> {ch.provider_id, method, ch.transport} end)
    metrics_map = Metrics.batch_get_transport_performance(profile, chain, requests)

    weight_fn = fn ch ->
      key = {ch.provider_id, method, ch.transport}

      case Map.get(metrics_map, key) do
        %{
          latency_ms: ms,
          success_rate: sr,
          total_calls: n,
          confidence_score: conf,
          last_updated_ms: updated
        }
        when is_number(ms) and is_number(sr) and is_number(conf) and is_number(updated) ->
          # Check staleness
          age_ms = current_time - updated

          if age_ms > freshness_cutoff do
            # Stale metrics - treat as cold start with explore floor
            explore_floor
          else
            # Fresh metrics - normal weight calculation
            calls_scale = if n >= min_calls, do: 1.0, else: n / max(min_calls, 1)
            denom = :erlang.max(ms, ms_floor)
            latency_term = 1.0 / :math.pow(denom, beta)
            sr_term = max(sr, min_sr)
            conf_term = conf
            max(explore_floor, latency_term * sr_term * conf_term * calls_scale)
          end

        _ ->
          # Missing data - use fallback latency, transform to weight
          baseline_latency = ctx.cold_start_baseline || 1000.0
          denom = :erlang.max(baseline_latency, ms_floor)
          latency_term = 1.0 / :math.pow(denom, beta)
          # Conservative weight: use 95% success rate, 0.5 confidence
          max(explore_floor, latency_term * 0.95 * 0.5)
      end
    end

    Enum.sort_by(channels, fn ch -> -(:rand.uniform() * weight_fn.(ch)) end)
  end
end
