defmodule Lasso.RPC.Strategies.LatencyWeighted do
  @moduledoc """
  Produces a weighted random permutation of reliability-qualified upstreams.

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
        summaries
        |> RoutingEvidence.summary_for_channel(channel)
        |> RoutingEvidence.qualified?()
      end)

    case qualified do
      [] ->
        RoutingEvidence.emit_availability_degradation(
          profile,
          :latency_weighted,
          chain_id,
          ctx.workload_key,
          length(channels)
        )

        Enum.shuffle(channels)

      _ ->
        latencies =
          Enum.map(qualified, fn channel ->
            RoutingEvidence.summary_for_channel(summaries, channel).successful_mean_latency_ms
          end)

        beta = Application.get_env(:lasso, :lw_beta, @default_beta)

        qualified
        |> Enum.zip(relative_weights(latencies, beta))
        |> weighted_permutation()
        |> Kernel.++(Enum.shuffle(remaining))
    end
  end

  @doc false
  @spec relative_weights([number()], number()) :: [float()]
  def relative_weights(latencies, beta \\ @default_beta)
      when is_list(latencies) and is_number(beta) and beta > 0 do
    best = Enum.min(latencies)

    Enum.map(latencies, fn latency ->
      :math.pow(best / latency, beta)
    end)
  end

  @doc false
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
