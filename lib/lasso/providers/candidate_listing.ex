defmodule Lasso.Providers.CandidateListing do
  @moduledoc """
  Pure ETS reads for provider candidate selection.

  Implements a 9-stage filter pipeline using shared ETS state:
  1. Transport availability (provider config has url/ws_url)
  2. WS liveness (channel cache for WS presence)
  3. Circuit breaker state
  4. Rate limit state
  5. Lag filtering (BlockSync.Registry + ChainState)
  6. Min block height filtering (block-height-aware routing)
  7. Archival filtering
  8. `subscribe_new_heads` capability filtering (newHeads-only)
  9. Exclude list

  Return shape: `%{id, config, availability, circuit_state, rate_limited}`.
  """

  require Logger

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, InstanceState, LagCalculation}
  alias Lasso.RPC.{AttemptProjection, RoutingPlan, SelectionFilters}

  @doc """
  Lists provider candidates for a (profile, chain_id) pair, filtered by selection criteria.
  """
  @spec list_candidates(String.t(), pos_integer(), SelectionFilters.t() | map()) :: [map()]
  def list_candidates(profile, chain_id, %SelectionFilters{} = filters) do
    list_candidates(profile, chain_id, SelectionFilters.to_map(filters))
  end

  def list_candidates(profile, chain_id, filters)
      when is_map(filters) and is_integer(chain_id) and chain_id > 0 do
    case Catalog.snapshot() do
      %{generation: generation} = snapshot ->
        if generation == ConfigStore.route_generation(),
          do: list_candidates(profile, chain_id, filters, snapshot),
          else: []

      _unavailable ->
        []
    end
  end

  @doc false
  @spec list_candidates(String.t(), pos_integer(), map(), non_neg_integer() | Catalog.snapshot()) ::
          [map()]
  def list_candidates(profile, chain_id, filters, expected_generation)
      when is_map(filters) and is_integer(chain_id) and chain_id > 0 and
             is_integer(expected_generation) and expected_generation >= 0 do
    case Catalog.snapshot() do
      %{generation: generation} = snapshot ->
        if generation == expected_generation and
             expected_generation == ConfigStore.route_generation(),
           do: list_candidates(profile, chain_id, filters, snapshot),
           else: []

      _unavailable ->
        []
    end
  end

  def list_candidates(
        profile,
        chain_id,
        filters,
        %{table: table, generation: generation} = snapshot
      )
      when is_map(filters) and is_integer(chain_id) and chain_id > 0 and
             not is_nil(table) and is_integer(generation) and generation >= 0 do
    with true <- Catalog.snapshot() == snapshot,
         true <- ConfigStore.route_generation() == generation,
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, profile, chain_id) do
      candidates = do_list_candidates(plan, filters)

      if Catalog.snapshot() == snapshot and ConfigStore.route_generation() == generation,
        do: candidates,
        else: []
    else
      _unavailable -> []
    end
  end

  @doc false
  @spec list_candidates_from_plan(RoutingPlan.t(), SelectionFilters.t() | map()) :: [map()]
  def list_candidates_from_plan(%RoutingPlan{} = plan, %SelectionFilters{} = filters) do
    list_candidates_from_plan(plan, SelectionFilters.to_map(filters))
  end

  def list_candidates_from_plan(%RoutingPlan{} = plan, filters) when is_map(filters) do
    do_list_candidates(plan, filters, :full)
  end

  @doc false
  @spec list_routing_candidates_from_plan(RoutingPlan.t(), SelectionFilters.t() | map()) :: [
          map()
        ]
  def list_routing_candidates_from_plan(%RoutingPlan{} = plan, %SelectionFilters{} = filters) do
    list_routing_candidates_from_plan(plan, SelectionFilters.to_map(filters))
  end

  def list_routing_candidates_from_plan(%RoutingPlan{} = plan, filters) when is_map(filters) do
    do_list_candidates(plan, filters, :routing)
  end

  defp do_list_candidates(%RoutingPlan{} = plan, filters),
    do: do_list_candidates(plan, filters, :full)

  defp do_list_candidates(%RoutingPlan{} = plan, filters, mode) do
    protocol = Map.get(filters, :protocol)
    include_half_open = Map.get(filters, :include_half_open, false)
    learned_scope = AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)

    candidates =
      plan.providers
      |> Enum.map(&build_candidate(&1, learned_scope, plan, protocol, mode))
      |> Enum.filter(fn c ->
        transport_available?(c, protocol) and
          circuit_breaker_ready?(c, protocol, include_half_open) and
          rate_limit_ok?(c, protocol, filters)
      end)
      |> filter_by_lag(plan.profile, plan.chain_id, Map.get(filters, :max_lag_blocks))
      |> filter_by_min_block(plan.profile, plan.chain_id, Map.get(filters, :min_block))
      |> filter_by_archival(Map.get(filters, :requires_archival))
      |> filter_by_subscribe_new_heads(Map.get(filters, :requires_subscribe_new_heads))
      |> filter_excluded(filters)

    candidates
  end

  @doc """
  Returns the minimum recovery time across all open circuits for a (profile, chain_id) pair.
  """
  @spec get_min_recovery_time(String.t(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def get_min_recovery_time(profile, chain_id, opts \\ [])
      when is_integer(chain_id) and chain_id > 0 do
    transport_filter = Keyword.get(opts, :transport, :both)
    profile_providers = Catalog.get_profile_providers(profile, chain_id)
    now_ms = System.monotonic_time(:millisecond)

    times =
      Enum.flat_map(profile_providers, fn pp ->
        transports =
          case transport_filter do
            :http -> [:http]
            :ws -> [:ws]
            _ -> [:http, :ws]
          end

        Enum.flat_map(transports, fn t ->
          cb = InstanceState.read_circuit(pp.instance_id, t)

          if cb.state == :open and is_integer(cb.recovery_deadline_ms) do
            remaining = max(0, cb.recovery_deadline_ms - now_ms)
            if remaining > 0, do: [remaining], else: []
          else
            []
          end
        end)
      end)

    case times do
      [] -> {:ok, nil}
      ts -> {:ok, Enum.min(ts)}
    end
  end

  defp build_candidate(provider, learned_scope, plan, protocol, mode) do
    instance_id = provider.instance_id
    transports = live_transports(provider, protocol, plan.profile, plan.chain_id)

    include_learned? = not learned_scope.degraded?
    http_routing = route_state(learned_scope, instance_id, :http, transports)
    ws_routing = route_state(learned_scope, instance_id, :ws, transports)

    http_cb = circuit_state(instance_id, :http, transports)
    ws_cb = circuit_state(instance_id, :ws, transports)

    http_rl = rate_limit(instance_id, :http, transports, include_learned?, http_routing)
    ws_rl = rate_limit(instance_id, :ws, transports, include_learned?, ws_routing)

    candidate = %{
      id: provider.id,
      instance_id: instance_id,
      route_generation: plan.generation,
      config: provider.config,
      transports: transports,
      routing_states: %{http: http_routing, ws: ws_routing},
      circuit_state: %{http: http_cb.state, ws: ws_cb.state},
      rate_limited: %{http: http_rl.rate_limited, ws: ws_rl.rate_limited},
      learned_feedback_degraded?: learned_scope.degraded?
    }

    maybe_add_availability(
      candidate,
      mode,
      instance_id,
      http_routing,
      ws_routing,
      include_learned?
    )
  end

  defp maybe_add_availability(candidate, :routing, _instance_id, _http, _ws, _include_learned?),
    do: candidate

  defp maybe_add_availability(candidate, :full, instance_id, http, ws, include_learned?) do
    health = InstanceState.read_candidate_health(instance_id, http, ws, include_learned?)

    Map.merge(candidate, %{
      availability: InstanceState.status_to_availability(health.base.status),
      transport_availability: %{
        http: InstanceState.status_to_availability(health.http.status),
        ws: InstanceState.status_to_availability(health.ws.status)
      }
    })
  end

  defp transport_available?(candidate, protocol) do
    case protocol do
      :http -> :http in candidate.transports
      :ws -> :ws in candidate.transports
      :both -> candidate.transports != []
      nil -> candidate.transports != []
    end
  end

  defp live_transports(provider, protocol, profile, chain_id) do
    provider.transports
    |> Enum.filter(fn
      :http -> protocol in [:http, :both, nil]
      :ws -> protocol in [:ws, :both, nil] and ws_channel_live?(profile, chain_id, provider.id)
    end)
  end

  defp route_state(scope, instance_id, transport, transports) do
    if transport in transports,
      do: AttemptProjection.route_state(scope, instance_id, transport),
      else: nil
  end

  defp circuit_state(instance_id, transport, transports) do
    if transport in transports,
      do: InstanceState.read_circuit(instance_id, transport),
      else: %{state: :unavailable}
  end

  defp rate_limit(instance_id, transport, transports, include_learned?, routing) do
    if transport in transports do
      InstanceState.read_rate_limit(instance_id, transport,
        include_learned: include_learned?,
        routing_state: routing
      )
    else
      %{rate_limited: false}
    end
  end

  defp ws_channel_live?(profile, chain_id, provider_id) do
    case :ets.lookup(:transport_channel_cache, {profile, chain_id, provider_id, :ws}) do
      [{_, _channel}] -> true
      [] -> false
    end
  end

  defp circuit_breaker_ready?(candidate, protocol, include_half_open) do
    cs = candidate.circuit_state

    case protocol do
      :http ->
        cb_ready?(cs.http, include_half_open)

      :ws ->
        cb_ready?(cs.ws, include_half_open)

      p when p in [:both, nil] ->
        has_http = :http in candidate.transports
        has_ws = :ws in candidate.transports

        if include_half_open do
          (has_http and cs.http != :open) or (has_ws and cs.ws != :open)
        else
          (has_http and cs.http == :closed) or (has_ws and cs.ws == :closed)
        end
    end
  end

  defp cb_ready?(cb_state, include_half_open) do
    if include_half_open, do: cb_state != :open, else: cb_state == :closed
  end

  defp rate_limit_ok?(candidate, protocol, filters) do
    if Map.get(filters, :exclude_rate_limited, false) do
      rl = candidate.rate_limited

      case protocol do
        :http -> not rl.http
        :ws -> not rl.ws
        :both -> not rl.http and not rl.ws
        nil -> not rl.http or not rl.ws
      end
    else
      true
    end
  end

  defp filter_by_lag(candidates, _profile, _chain_id, nil), do: candidates

  defp filter_by_lag(candidates, profile, chain_id, max_lag_blocks)
       when is_integer(max_lag_blocks) do
    block_time_ms = LagCalculation.get_block_time_ms(chain_id, profile)

    filtered =
      Enum.filter(candidates, fn candidate ->
        case LagCalculation.calculate_optimistic_lag(
               chain_id,
               candidate.instance_id,
               block_time_ms
             ) do
          {:ok, optimistic_lag, _raw_lag} -> optimistic_lag >= -max_lag_blocks
          {:error, _} -> true
        end
      end)

    if candidates != [] and filtered == [] do
      Logger.warning(
        "All providers for chain_id #{chain_id} excluded due to lag (threshold: -#{max_lag_blocks} blocks)"
      )
    end

    filtered
  end

  defp filter_by_min_block(candidates, _profile, _chain_id, nil), do: candidates

  defp filter_by_min_block(candidates, profile, chain_id, min_block) when is_integer(min_block) do
    block_time_ms = LagCalculation.get_block_time_ms(chain_id, profile)

    {capable, rest} =
      Enum.split_with(candidates, fn candidate ->
        case BlockSyncRegistry.get_height(chain_id, candidate.instance_id) do
          {:ok, {height, timestamp, _source, _meta}} ->
            elapsed_ms = System.system_time(:millisecond) - timestamp
            staleness_credit = if block_time_ms > 0, do: div(elapsed_ms, block_time_ms), else: 0
            max_credit = div(30_000, max(block_time_ms, 1))
            optimistic_height = height + min(staleness_credit, max_credit)
            optimistic_height >= min_block

          {:error, _} ->
            true
        end
      end)

    capable ++ rest
  end

  defp filter_by_archival(candidates, true) do
    Enum.filter(candidates, fn c -> c.config.archival != false end)
  end

  defp filter_by_archival(candidates, _), do: candidates

  defp filter_by_subscribe_new_heads(candidates, true) do
    Enum.filter(candidates, fn c -> c.config.subscribe_new_heads == true end)
  end

  defp filter_by_subscribe_new_heads(candidates, _), do: candidates

  defp filter_excluded(candidates, filters) do
    case Map.get(filters, :exclude) do
      exclude_list when is_list(exclude_list) ->
        Enum.filter(candidates, &(&1.id not in exclude_list))

      _ ->
        candidates
    end
  end
end
