defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc "Choose fastest provider using method-specific latency scores with quality filters."

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.Metrics

  @impl true
  def prepare_context(selection) do
    base_ctx = Lasso.RPC.StrategyContext.new(selection)
    # Allow gates to be configured via env, with base_ctx defaults
    freshness_cutoff_ms =
      Application.get_env(:lasso, :fastest_freshness_cutoff_ms, 10 * 60 * 1000)

    min_calls = Application.get_env(:lasso, :fastest_min_calls, 3)
    min_success_rate = Application.get_env(:lasso, :fastest_min_success_rate, 0.9)

    %{
      base_ctx
      | freshness_cutoff_ms: base_ctx.freshness_cutoff_ms || freshness_cutoff_ms,
        min_calls: base_ctx.min_calls || min_calls,
        min_success_rate: base_ctx.min_success_rate || min_success_rate,
        chain: selection.chain
    }
  end

  @doc """
  Strategy-provided channel ranking: order channels by measured latency (ascending).
  Falls back to a large latency when unknown to de-prioritize.
  """
  @impl true
  def rank_channels(channels, method, _ctx, chain) do
    Enum.sort_by(channels, fn channel ->
      perf =
        Metrics.get_provider_transport_performance(
          chain,
          channel.provider_id,
          method,
          channel.transport
        )

      case perf do
        %{latency_ms: ms} when is_number(ms) and ms > 0 -> ms
        _ -> 10_000
      end
    end)
  end
end
