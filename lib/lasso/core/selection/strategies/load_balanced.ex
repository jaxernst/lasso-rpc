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

  This ensures healthy providers receive the majority of traffic while
  recovering providers are gradually reintroduced.
  """

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.ProviderPool

  @impl true
  def prepare_context(profile, chain, _method, timeout) do
    base_ctx = Lasso.RPC.StrategyContext.new(chain, timeout)

    total_requests =
      case ProviderPool.get_status(profile, chain) do
        {:ok, %{total_requests: tr}} when is_integer(tr) -> tr
        {:ok, status} when is_map(status) -> Map.get(status, :total_requests, 0)
        _ -> base_ctx.total_requests || 0
      end

    %{base_ctx | total_requests: total_requests}
  end

  @doc """
  Strategy-provided channel ranking: random shuffle per call.
  """
  @impl true
  def rank_channels(channels, _method, ctx, _profile, _chain) do
    _ = ctx
    Enum.shuffle(channels)
  end
end
