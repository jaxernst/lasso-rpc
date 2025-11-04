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

  alias Lasso.RPC.{StrategyContext}

  # Default tuning knobs (can be overridden via application config)
  @default_beta 3.0
  @default_ms_floor 30.0
  @default_min_calls 3
  @default_min_sr 0.85
  @default_explore_floor 0.05

  @impl true
  def prepare_context(selection) do
    base = StrategyContext.new(selection)

    # Return base StrategyContext with populated optional fields
    # Strategy-specific params (beta, ms_floor, explore_floor) are fetched
    # directly in rank_channels to maintain type safety
    %{
      base
      | min_calls:
          base.min_calls || Application.get_env(:lasso, :lw_min_calls, @default_min_calls),
        min_success_rate:
          base.min_success_rate || Application.get_env(:lasso, :lw_min_sr, @default_min_sr)
    }
  end

  @doc """
  Strategy-provided channel ranking used by Selection.select_channels/3 when present.
  """
  @impl true
  def rank_channels(channels, method, ctx, chain) do
    # Fetch strategy-specific tuning params from app config
    beta = Application.get_env(:lasso, :lw_beta, @default_beta)
    ms_floor = Application.get_env(:lasso, :lw_ms_floor, @default_ms_floor)
    explore_floor = Application.get_env(:lasso, :lw_explore_floor, @default_explore_floor)

    # Use context fields populated in prepare_context
    min_calls = ctx.min_calls || @default_min_calls
    min_sr = ctx.min_success_rate || @default_min_sr

    weight_fn = fn ch ->
      case Lasso.RPC.Metrics.get_provider_transport_performance(
             chain,
             ch.provider_id,
             method,
             ch.transport
           ) do
        %{latency_ms: ms, success_rate: sr, total_calls: n, confidence_score: conf}
        when is_number(ms) and is_number(sr) and is_number(conf) ->
          calls_scale = if n >= min_calls, do: 1.0, else: n / max(min_calls, 1)
          denom = :erlang.max(ms, ms_floor)
          latency_term = 1.0 / :math.pow(denom, beta)
          sr_term = max(sr, min_sr)
          conf_term = conf
          max(explore_floor, latency_term * sr_term * conf_term * calls_scale)

        _ ->
          # Handle nil values or missing data by using explore_floor
          explore_floor
      end
    end

    Enum.sort_by(channels, fn ch -> -(:rand.uniform() * weight_fn.(ch)) end)
  end
end
