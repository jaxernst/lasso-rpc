defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc """
  Ranks upstreams with the `BalancedFast` weighted permutation at exponent 8, so the quickest
  measured upstream takes nearly all traffic while one unproven upstream per request, with no
  latency evidence or only stale evidence, still competes at 1/8 of the quickest's weight.

  When no upstream has qualified evidence, the ranking preserves availability and emits an
  explicit degradation event. Live circuit, rate-limit, and other admission state is applied
  after this ranking.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.Strategies.BalancedFast
  alias Lasso.RPC.StrategyContext

  @beta 8.0

  @impl true
  def prepare_context(_profile, chain_id, _method, timeout) do
    StrategyContext.new(chain_id, timeout)
  end

  @impl true
  def rank_channels(channels, _method, ctx, profile, chain_id),
    do: BalancedFast.rank(channels, ctx, profile, chain_id, :fastest, @beta)
end
