defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc """
  Orders reliability-qualified upstreams by recent successful-attempt latency.

  Reliability qualification is a boundary rather than a score multiplier. When no upstream has
  qualified evidence, the strategy preserves availability and emits an explicit degradation event.
  Live circuit, rate-limit, and other admission state is applied after this ranking.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.{RoutingEvidence, StrategyContext}
  alias Lasso.RPC.RoutingEvidence.Summary

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
        summaries
        |> RoutingEvidence.summary_for_channel(channel)
        |> qualified?()
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

        deterministic_order(channels)

      _ ->
        Enum.sort_by(qualified, &ranking_key(&1, summaries)) ++ deterministic_order(remaining)
    end
  end

  defp qualified?(%Summary{
         state: :qualified,
         successful_mean_latency_ms: mean
       })
       when is_number(mean) and mean > 0,
       do: true

  defp qualified?(_summary), do: false

  defp ranking_key(channel, summaries) do
    summary = RoutingEvidence.summary_for_channel(summaries, channel)

    {
      summary.successful_mean_latency_ms,
      summary.successful_p95_latency_ms || summary.successful_mean_latency_ms,
      channel.provider_id,
      channel.transport
    }
  end

  defp deterministic_order(channels) do
    Enum.sort_by(channels, &{&1.provider_id, &1.transport})
  end
end
