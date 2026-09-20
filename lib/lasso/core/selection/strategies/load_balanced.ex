defmodule Lasso.RPC.Strategies.LoadBalanced do
  @moduledoc """
  Load-balanced selection using random shuffle with health-aware tiering.

  Replay-safe reads try distinct physical instances before alternate transports
  within each availability tier. The cursor bounds sibling deferral and preserves
  explicit recovered-head preference. Alternate transports remain available
  after that first pass. Other methods keep their shuffled order. After shuffling,
  the selection pipeline applies tiered reordering based on circuit breaker
  state and rate limit status:

  - Tier 1: Closed circuit, not rate-limited (preferred)
  - Tier 2: Half-open circuit, not rate-limited
  - Tier 3: Closed circuit, rate-limited
  - Tier 4: Half-open circuit, rate-limited
  """

  alias Lasso.RPC.{Channel, ExecutionEnvelope}

  @behaviour Lasso.RPC.Strategy

  @impl true
  def prepare_context(_profile, chain_id, _method, timeout) do
    Lasso.RPC.StrategyContext.new(chain_id, timeout)
  end

  @impl true
  def rank_channels(channels, method, _ctx, _profile, _chain) do
    channels |> Enum.shuffle() |> order_fallbacks(method)
  end

  @doc "Orders replay-safe fallbacks by physical instance without changing unsafe-method order."
  @spec order_fallbacks([Channel.t()], String.t(), MapSet.t() | nil) :: [Channel.t()]
  def order_fallbacks(channels, method, seen \\ nil) do
    if ExecutionEnvelope.classify(method) == :replay_safe,
      do: distinct_instances_first(channels, seen),
      else: channels
  end

  @doc "Stably places one route from each unseen physical instance before alternate routes."
  @spec distinct_instances_first([Channel.t()], MapSet.t() | nil) :: [Channel.t()]
  def distinct_instances_first(channels, seen \\ nil) do
    seen = seen || MapSet.new()

    {first, alternates, _seen} =
      Enum.reduce(channels, {[], [], seen}, fn channel, {first, alternates, seen} ->
        key = channel.instance_id || {channel.profile, channel.chain_id, channel.provider_id}

        if MapSet.member?(seen, key) do
          {first, [channel | alternates], seen}
        else
          {[channel | first], alternates, MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(first) ++ Enum.reverse(alternates)
  end
end
