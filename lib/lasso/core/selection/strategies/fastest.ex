defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc "Choose fastest provider using method-specific latency scores with quality filters."

  @behaviour Lasso.RPC.Strategy

  alias Lasso.Core.Benchmarking.Metrics
  alias Lasso.RPC.StrategyContext

  # Metrics older than 10 minutes are considered stale
  @freshness_cutoff_ms 10 * 60 * 1000
  @min_calls 3
  @min_success_rate 0.9

  @impl true
  def prepare_context(profile, chain, method, timeout) do
    base_ctx = StrategyContext.new(chain, timeout)

    min_calls = Application.get_env(:lasso, :fastest_min_calls, @min_calls)
    min_success_rate = Application.get_env(:lasso, :fastest_min_success_rate, @min_success_rate)

    # Calculate fallback latency for providers with no data
    fallback_latency =
      StrategyContext.calculate_fallback_latency(
        profile,
        chain,
        method
      )

    %{
      base_ctx
      | freshness_cutoff_ms: base_ctx.freshness_cutoff_ms || @freshness_cutoff_ms,
        min_calls: base_ctx.min_calls || min_calls,
        min_success_rate: base_ctx.min_success_rate || min_success_rate,
        cold_start_baseline: fallback_latency
    }
  end

  @doc """
  Strategy-provided channel ranking: order channels by measured latency (ascending).

  Implements staleness validation and dynamic cold start penalties:
  - Fresh metrics (< 10min old): Use actual latency
  - Stale metrics (> 10min old): Treat as cold start
  - Missing metrics: Use P75 of known providers as dynamic baseline
  """
  @impl true
  def rank_channels(channels, method, ctx, profile, chain) do
    current_time = System.system_time(:millisecond)

    # Batch fetch all metrics (eliminates N sequential GenServer calls)
    requests =
      Enum.map(channels, fn ch ->
        {ch.provider_id, method, ch.transport}
      end)

    metrics_map = Metrics.batch_get_transport_performance(profile, chain, requests)

    # Sort using pre-fetched metrics with staleness and cold start checks
    Enum.sort_by(channels, fn channel ->
      key = {channel.provider_id, method, channel.transport}

      case Map.get(metrics_map, key) do
        %{latency_ms: ms, last_updated_ms: updated}
        when is_number(ms) and is_number(updated) and ms > 0 ->
          # Check staleness
          age_ms = current_time - updated

          if age_ms > ctx.freshness_cutoff_ms do
            # Stale metrics - treat as cold start
            ctx.cold_start_baseline || 10_000
          else
            # Fresh metrics - use actual latency
            ms
          end

        _ ->
          # Missing metrics - use fallback latency
          ctx.cold_start_baseline || 10_000
      end
    end)
  end
end
