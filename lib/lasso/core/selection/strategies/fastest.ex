defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc """
  Orders reliability-qualified upstreams by recent successful-attempt latency.

  Reliability qualification is a boundary rather than a score multiplier. When no upstream has
  qualified evidence, the strategy preserves availability and emits an explicit degradation event.
  Live circuit, rate-limit, and other admission state is applied after this ranking.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.{RoutingEvidence, StrategyContext}

  @impl true
  def prepare_context(_profile, chain_id, _method, timeout) do
    StrategyContext.new(chain_id, timeout)
  end

  @impl true
  def rank_channels(channels, _method, ctx, profile, chain_id) do
    summaries =
      ctx.routing_summaries ||
        RoutingEvidence.batch_get_summaries(profile, channels, chain_id, ctx.workload_key)

    {qualified, remaining} =
      Enum.split_with(channels, fn channel ->
        summaries |> RoutingEvidence.summary_for_channel(channel) |> RoutingEvidence.qualified?()
      end)

    case qualified do
      [] ->
        RoutingEvidence.emit_availability_degradation(
          profile,
          :fastest,
          chain_id,
          ctx.workload_key,
          length(channels)
        )

        Enum.sort_by(channels, &prior_key(&1, summaries))

      _ ->
        Enum.sort_by(qualified, &ranking_key(&1, summaries)) ++
          Enum.sort_by(remaining, &prior_key(&1, summaries))
    end
  end

  @doc false
  @spec rank_unqualified([map()], map()) :: [map()]
  def rank_unqualified(channels, summaries) when is_list(channels) and is_map(summaries) do
    Enum.sort_by(channels, &prior_key(&1, summaries))
  end

  defp prior_key(channel, summaries) do
    summary = RoutingEvidence.summary_for_channel(summaries, channel)

    {
      prior_latency(summary),
      channel.provider_id,
      channel.transport
    }
  end

  defp prior_latency(%{state: :stale}), do: :infinity
  defp prior_latency(summary), do: (summary && summary.successful_mean_latency_ms) || :infinity

  defp ranking_key(channel, summaries) do
    summary = RoutingEvidence.summary_for_channel(summaries, channel)

    {
      summary.successful_mean_latency_ms,
      summary.successful_p95_latency_ms || summary.successful_mean_latency_ms,
      channel.provider_id,
      channel.transport
    }
  end
end
