defmodule Lasso.RPC.Strategies.BalancedFast do
  @moduledoc """
  Produces a weighted random permutation of reliability-qualified upstreams, spreading load
  while favoring the quickest providers.

  Weights are dimensionless latency ratios. Sampling uses exponential-race keys, which produces a
  correct weighted permutation without a weight floor or hidden success-rate multiplier.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.{RoutingEvidence, StrategyContext}

  @default_beta 3.0

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
          :balanced_fast,
          chain_id,
          ctx.workload_key,
          length(channels)
        )

        weighted_available(channels, summaries)

      _ ->
        weighted_available(qualified, summaries) ++ weighted_available(remaining, summaries)
    end
  end

  defp weighted_available([], _summaries), do: []

  defp weighted_available(channels, summaries) do
    {measured, unmeasured} =
      Enum.split_with(channels, &measured?(RoutingEvidence.summary_for_channel(summaries, &1)))

    weighted =
      case measured do
        [] ->
          []

        _ ->
          latencies = Enum.map(measured, &mean_latency(&1, summaries))
          beta = Application.get_env(:lasso, :balanced_fast_beta, @default_beta)

          measured
          |> Enum.zip(relative_weights(latencies, beta))
          |> weighted_permutation()
      end

    weighted ++ Enum.shuffle(unmeasured)
  end

  # As in qualification, a zero mean is not a usable latency measurement.
  defp measured?(%{state: state, successful_mean_latency_ms: mean})
       when state != :stale and is_number(mean),
       do: mean > 0

  defp measured?(_summary), do: false

  defp mean_latency(channel, summaries),
    do: RoutingEvidence.summary_for_channel(summaries, channel).successful_mean_latency_ms

  @doc "Converts latency samples into bounded relative selection weights."
  @spec relative_weights([number()], number()) :: [float()]
  def relative_weights(latencies, beta \\ @default_beta)
      when is_list(latencies) and is_number(beta) and beta > 0 do
    best = Enum.min(latencies)

    Enum.map(latencies, fn latency ->
      :math.pow(best / latency, beta)
    end)
  end

  @doc "Returns a weighted permutation using the supplied uniform sampler."
  @spec weighted_permutation([{term(), number()}], (-> float())) :: [term()]
  def weighted_permutation(weighted_items, uniform_fn \\ &:rand.uniform/0) do
    weighted_items
    |> Enum.map(fn {item, weight} when is_number(weight) and weight > 0 ->
      uniform = uniform_fn.() |> max(:math.pow(2.0, -53)) |> min(1.0)
      {item, -:math.log(uniform) / weight}
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end
end
