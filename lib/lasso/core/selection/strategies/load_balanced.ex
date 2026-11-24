defmodule Lasso.RPC.Strategies.LoadBalanced do
  @moduledoc """
  Load-balanced selection orders physical instances by a weighted random permutation, then
  their transports the same way.

  Routes share load equally unless one's recent failure rate (timeouts and other dispatched
  failures) is clearly worse than its peers': above twice the lower median of the physical
  instances with current evidence, each counted once at its best route, and above 1/32, about
  two failures in the last 64 attempts. Such a route is deferred, not excluded: its weight
  falls with the square of how far its rate exceeds that reference, down to 1/8 of a peer's,
  so it keeps earning samples and returns to an equal share as its rate decays. Because the
  reference is a median over instances, at least half of the measured instances always keep a
  route at full weight, and when every route is failing alike none is deferred.

  Replay-safe reads try distinct physical instances before alternate transports
  within each availability tier. The cursor bounds sibling deferral and preserves
  explicit recovered-head preference. Previously attempted instances are deferred
  when selection resumes across routing phases. Alternate
  transports remain available after that first pass. Other methods keep their
  shuffled order. After shuffling,
  the selection pipeline applies tiered reordering based on circuit breaker
  state and rate limit status:

  - Tier 1: Closed circuit, not rate-limited (preferred)
  - Tier 2: Half-open circuit, not rate-limited
  - Tier 3: Closed circuit, rate-limited
  - Tier 4: Half-open circuit, rate-limited
  """

  alias Lasso.RPC.{AttemptProjection, Channel, ExecutionEnvelope}
  alias Lasso.RPC.ProviderKnowledge.Effects
  alias Lasso.RPC.Strategies.BalancedFast

  @behaviour Lasso.RPC.Strategy

  @failure_rate_floor 1 / 32
  @min_weight 1 / 8

  @impl true
  def prepare_context(_profile, chain_id, _method, timeout) do
    Lasso.RPC.StrategyContext.new(chain_id, timeout)
  end

  @impl true
  def rank_channels([], _method, _ctx, _profile, _chain_id), do: []

  def rank_channels([first | _] = channels, _method, ctx, profile, chain_id) do
    scope = AttemptProjection.scope_state(profile, chain_id, first.route_generation)
    now_us = System.monotonic_time(:microsecond)
    deferral? = deferral?(profile)

    order(channels, &instance_key/1, fn
      %{instance_id: instance_id, transport: transport}
      when deferral? and is_binary(instance_id) ->
        AttemptProjection.recent_failure_rate(
          scope,
          instance_id,
          transport,
          ctx.workload_key,
          now_us
        )

      _unidentified ->
        nil
    end)
  end

  @doc "Whether failure-rate deferral weighs this profile's routes."
  @spec deferral?(String.t()) :: boolean()
  def deferral?(profile), do: Effects.mode(:failure_rate_deferral, profile) == :on

  @doc """
  Orders physical instances by a weighted random permutation, then each instance's routes the
  same way. `failure_rate` returns a route's recent failure rate, or nil without current
  evidence. The peer reference counts each instance once, at its best measured route, so a
  failing instance's sibling transports cannot outvote a healthy peer. Each route is weighed
  against that reference, and an instance weighs the mean of its measured routes' weights.
  """
  @spec order([route], (route -> term()), (route -> float() | nil)) :: [route] when route: term()
  def order(routes, instance_key, failure_rate) do
    groups =
      routes
      |> Enum.map(&{&1, failure_rate.(&1)})
      |> Enum.group_by(fn {route, _rate} -> instance_key.(route) end)
      |> Map.values()

    reference = groups |> Enum.map(&best_rate/1) |> reference()

    groups
    |> Enum.map(fn group ->
      weighted = Enum.map(group, fn {route, rate} -> {route, rate, weight(rate, reference)} end)
      {weighted, instance_weight(weighted)}
    end)
    |> BalancedFast.weighted_permutation()
    |> Enum.flat_map(fn group ->
      group
      |> Enum.map(fn {route, _rate, weight} -> {route, weight} end)
      |> BalancedFast.weighted_permutation()
    end)
  end

  defp best_rate(group) do
    group |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
  end

  # Twice the lower median of the measured instances' rates, never under the floor; nil when no
  # instance has current evidence.
  defp reference(instance_rates) do
    case instance_rates |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> nil
      known -> max(2 * Enum.at(known, div(length(known) - 1, 2)), @failure_rate_floor)
    end
  end

  defp weight(rate, reference) when is_number(rate) and is_number(reference) and rate > reference,
    do: max(:math.pow(reference / rate, 2), @min_weight)

  defp weight(_rate, _reference), do: 1.0

  defp instance_weight(group) do
    case for({_route, rate, weight} <- group, is_number(rate), do: weight) do
      [] -> 1.0
      weights -> Enum.sum(weights) / length(weights)
    end
  end

  defp instance_key(channel),
    do: channel.instance_id || {channel.profile, channel.chain_id, channel.provider_id}

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
        key = instance_key(channel)

        if MapSet.member?(seen, key) do
          {first, [channel | alternates], seen}
        else
          {[channel | first], alternates, MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(first) ++ Enum.reverse(alternates)
  end
end
