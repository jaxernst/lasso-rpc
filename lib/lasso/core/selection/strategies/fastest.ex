defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc """
  Orders reliability-qualified upstreams by recent successful-attempt latency.

  Reliability qualification is a boundary rather than a score multiplier. When no upstream has
  qualified evidence, the strategy preserves availability and emits an explicit degradation event.
  Live circuit, rate-limit, and other admission state is applied after this ranking.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.{ProviderKnowledge, RoutingEvidence, StrategyContext}
  alias Lasso.RPC.ProviderKnowledge.{Decision, Effects}

  @max_learning_routes 16

  @impl true
  def prepare_context(_profile, chain_id, _method, timeout) do
    StrategyContext.new(chain_id, timeout)
  end

  @impl true
  def rank_channels(channels, method, ctx, profile, chain_id) do
    {ranked, _decision} = rank(channels, method, ctx, profile, chain_id, false, nil)
    ranked
  end

  @doc "Returns the ranking and any qualified local performance intervention."
  @spec rank_with_decision(
          [map()],
          binary(),
          StrategyContext.t(),
          binary(),
          pos_integer(),
          map() | nil
        ) ::
          {[map()], map() | nil}
  def rank_with_decision(channels, method, ctx, profile, chain_id, resource \\ nil) do
    rank(channels, method, ctx, profile, chain_id, true, resource)
  end

  defp rank(channels, method, ctx, profile, chain_id, learning?, resource) do
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

        {Enum.sort_by(channels, &prior_key(&1, summaries)), nil}

      _ ->
        baseline = Enum.sort_by(qualified, &ranking_key(&1, summaries))
        remaining = Enum.sort_by(remaining, &prior_key(&1, summaries))

        {ranked, decision} =
          if learning?,
            do:
              maybe_rank_by_response_latency(baseline, method, ctx, profile, chain_id, resource),
            else: {baseline, nil}

        {ranked ++ remaining, decision}
    end
  end

  defp maybe_rank_by_response_latency(baseline, method, ctx, profile, chain_id, resource) do
    mode = Effects.response_latency_mode(profile)

    if mode == :off or length(baseline) < 2 or length(baseline) > @max_learning_routes do
      {baseline, nil}
    else
      case local_hints(baseline, method, ctx.workload_key, profile, chain_id) do
        {:ok, hints} ->
          proposed =
            baseline
            |> Enum.with_index()
            |> Enum.sort_by(fn {channel, baseline_position} ->
              hint = Map.fetch!(hints, route(channel))
              {hint.value.p95_us, hint.value.p50_us, baseline_position}
            end)
            |> Enum.map(&elem(&1, 0))

          if Enum.map(proposed, &route/1) == Enum.map(baseline, &route/1) do
            {baseline, nil}
          else
            applied = if mode == :on, do: proposed, else: baseline

            changed_at =
              baseline
              |> Enum.zip(proposed)
              |> Enum.find_index(fn {current, candidate} ->
                route(current) != route(candidate)
              end)

            current = baseline |> Enum.at(changed_at) |> route()
            candidate = proposed |> Enum.at(changed_at) |> route()

            decision = %{
              kind: :response_latency,
              mode: mode,
              origin_profile: profile,
              budget_result: :no_extra_dispatch,
              resource: resource,
              partition: ctx.workload_key,
              changed_at: changed_at,
              baseline_at_change: current,
              proposed_at_change: candidate,
              order_scope: :reliability_qualified,
              method: method,
              orders: Decision.orders(baseline, proposed, applied),
              evidence:
                hints
                |> Map.take([current, candidate])
                |> Map.new(fn {route, hint} ->
                  {route,
                   %{
                     source: hint.source,
                     generation: Map.get(hint, :generation),
                     expires_at_ms: hint.expires_at_ms,
                     age_ms: max(System.system_time(:millisecond) - hint.observed_at_ms, 0),
                     accepted_samples: hint.support.accepted_samples,
                     accepted_successes: hint.support.accepted_successes,
                     p50_us: hint.value.p50_us,
                     p95_us: hint.value.p95_us,
                     resolution: hint.resolution
                   }}
                end)
            }

            {applied, Decision.capture(decision)}
          end

        :unknown ->
          {baseline, nil}
      end
    end
  end

  defp local_hints(channels, method, partition, profile, chain_id) do
    Enum.reduce_while(channels, {:ok, %{}}, fn channel, {:ok, hints} ->
      subject =
        case Map.get(channel, :learning_subject) do
          %{id: id} -> id
          _ -> nil
        end

      scope = %{
        subject: subject,
        profile: profile,
        chain_id: chain_id,
        partition: partition,
        instance_id: channel.instance_id,
        method: method
      }

      case ProviderKnowledge.response_latency(scope) do
        {:ok, hint} -> {:cont, {:ok, Map.put(hints, route(channel), hint)}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp route(channel), do: {channel.instance_id, channel.transport}

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
