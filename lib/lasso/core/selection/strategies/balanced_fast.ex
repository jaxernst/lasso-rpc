defmodule Lasso.RPC.Strategies.BalancedFast do
  @moduledoc """
  Produces one weighted random permutation of reliable upstreams, spreading load while favoring
  the quickest providers. Upstreams with recent failure evidence follow in their own permutation.

  Weights are dimensionless latency ratios over the best evidence each upstream has: client
  samples, else the same family's system prior. One upstream with no latency evidence joins each
  permutation at the weight of the quickest, so it earns a sample instead of being starved; any
  others follow the measured upstreams. Sampling uses exponential-race keys, which produces a
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

    if not Enum.any?(channels, &RoutingEvidence.qualified?(summary(summaries, &1))) do
      RoutingEvidence.emit_availability_degradation(
        profile,
        :balanced_fast,
        chain_id,
        ctx.workload_key,
        length(channels)
      )
    end

    {unreliable, reliable} =
      Enum.split_with(channels, &match?(%{state: :unreliable}, summary(summaries, &1)))

    weighted_available(reliable, summaries) ++ weighted_available(unreliable, summaries)
  end

  defp weighted_available(channels, summaries) do
    {stale, current} =
      Enum.split_with(channels, &match?(%{state: :stale}, summary(summaries, &1)))

    {measured, unmeasured} = Enum.split_with(current, &measured?(summary(summaries, &1)))
    # One unmeasured upstream per request competes with the measured ones, so this ranking never
    # puts two unproven upstreams ahead of a proven one in the same group.
    {sampled, deferred} = unmeasured |> Enum.shuffle() |> Enum.split(1)
    beta = Application.get_env(:lasso, :balanced_fast_beta, @default_beta)
    latencies = Enum.map(measured, &summary(summaries, &1).successful_mean_latency_ms)

    measured
    |> Enum.zip(relative_weights(latencies, beta))
    |> Enum.concat(Enum.map(sampled, &{&1, 1.0}))
    |> weighted_permutation()
    |> Enum.concat(deferred)
    |> Enum.concat(Enum.shuffle(stale))
  end

  # As in qualification, a zero mean is not a usable latency measurement.
  defp measured?(%{successful_mean_latency_ms: mean}) when is_number(mean), do: mean > 0
  defp measured?(_summary), do: false

  defp summary(summaries, channel), do: RoutingEvidence.summary_for_channel(summaries, channel)

  @doc "Converts latency samples into bounded relative selection weights."
  @spec relative_weights([number()], number()) :: [float()]
  def relative_weights(latencies, beta \\ @default_beta)

  def relative_weights([], _beta), do: []

  def relative_weights(latencies, beta)
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
