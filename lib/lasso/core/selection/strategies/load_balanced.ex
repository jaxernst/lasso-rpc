defmodule Lasso.RPC.Strategies.LoadBalanced do
  @moduledoc """
  Load-balanced selection using random shuffle with health-aware tiering.

  Randomly distributes requests across available providers. After shuffling,
  the selection pipeline applies tiered reordering based on circuit breaker
  state and rate limit status:

  - Tier 1: Closed circuit, not rate-limited (preferred)
  - Tier 2: Closed circuit, rate-limited
  - Tier 3: Half-open circuit, not rate-limited
  - Tier 4: Half-open circuit, rate-limited
  """

  @behaviour Lasso.RPC.Strategy

  @impl true
  def prepare_context(_profile, chain, _method, timeout) do
    Lasso.RPC.StrategyContext.new(chain, timeout)
  end

  @impl true
  def rank_channels(channels, _method, _ctx, _profile, _chain) do
    Enum.shuffle(channels)
  end
end
