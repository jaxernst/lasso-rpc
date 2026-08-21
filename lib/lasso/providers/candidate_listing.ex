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
  alias Lasso.RPC.{AttemptProjection, ChainState, RoutingPlan, SelectionFilters}
  alias Lasso.RPC.RoutingEvidence.Workload

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

  @doc false
  @spec list_routing_candidates_from_plan(
          RoutingPlan.t(),
          SelectionFilters.t() | map(),
          non_neg_integer() | :unavailable
        ) :: [map()]
  def list_routing_candidates_from_plan(
        %RoutingPlan{} = plan,
        %SelectionFilters{} = filters,
        consensus_height
      ) do
    list_routing_candidates_from_plan(plan, SelectionFilters.to_map(filters), consensus_height)
  end

  def list_routing_candidates_from_plan(%RoutingPlan{} = plan, filters, consensus_height)
      when is_map(filters) do
    do_list_candidates(plan, filters, :routing, consensus_height)
  end

  @doc false
  @spec list_rankable_candidates_from_plan(
          RoutingPlan.t(),
          SelectionFilters.t() | map(),
          non_neg_integer() | :unavailable
        ) :: [map()]
  def list_rankable_candidates_from_plan(
        %RoutingPlan{} = plan,
        %SelectionFilters{} = filters,
        consensus_height
      ) do
    list_rankable_candidates_from_plan(
      plan,
      SelectionFilters.to_map(filters),
      consensus_height
    )
  end

  def list_rankable_candidates_from_plan(%RoutingPlan{} = plan, filters, consensus_height)
      when is_map(filters) do
    do_list_candidates(plan, filters, :ranked, consensus_height)
  end

  @doc false
  @spec list_fastest_candidates_from_plan(
          RoutingPlan.t(),
          SelectionFilters.t() | map(),
          non_neg_integer() | :unavailable
        ) :: [map()]
  def list_fastest_candidates_from_plan(
        %RoutingPlan{} = plan,
        %SelectionFilters{} = filters,
        consensus_height
      ) do
    list_fastest_candidates_from_plan(
      plan,
      SelectionFilters.to_map(filters),
      consensus_height
    )
  end

  def list_fastest_candidates_from_plan(%RoutingPlan{} = plan, filters, consensus_height)
      when is_map(filters) do
    do_list_candidates(plan, filters, :fastest_ranked, consensus_height)
  end

  @doc false
  @spec list_fastest_candidates_from_plan(
          RoutingPlan.t(),
          SelectionFilters.t() | map(),
          non_neg_integer() | :unavailable,
          AttemptProjection.scope_state()
        ) :: [map()]
  def list_fastest_candidates_from_plan(
        %RoutingPlan{} = plan,
        %SelectionFilters{} = filters,
        consensus_height,
        learned_scope
      ) do
    list_fastest_candidates_from_plan(
      plan,
      SelectionFilters.to_map(filters),
      consensus_height,
      learned_scope
    )
  end

  def list_fastest_candidates_from_plan(
        %RoutingPlan{} = plan,
        filters,
        consensus_height,
        learned_scope
      )
      when is_map(filters) and is_map(learned_scope) do
    do_list_candidates(plan, filters, :fastest_ranked, consensus_height, true, learned_scope)
  end

  @doc false
  @spec routing_candidate_from_plan(
          RoutingPlan.t(),
          RoutingPlan.provider(),
          SelectionFilters.t() | map(),
          non_neg_integer() | :unavailable
        ) :: map() | nil
  def routing_candidate_from_plan(
        %RoutingPlan{} = plan,
        provider,
        %SelectionFilters{} = filters,
        consensus_height
      ) do
    routing_candidate_from_plan(
      plan,
      provider,
      SelectionFilters.to_map(filters),
      consensus_height
    )
  end

  def routing_candidate_from_plan(%RoutingPlan{} = plan, provider, filters, consensus_height)
      when is_map(provider) and is_map(filters) do
    routing_candidate_from_plan(plan, provider, filters, consensus_height, nil)
  end

  @doc false
  @spec routing_candidate_from_plan(
          RoutingPlan.t(),
          RoutingPlan.provider(),
          SelectionFilters.t() | map(),
          non_neg_integer() | :unavailable,
          map() | nil
        ) :: map() | nil
  def routing_candidate_from_plan(
        %RoutingPlan{} = plan,
        provider,
        %SelectionFilters{} = filters,
        consensus_height,
        learned_scope
      ) do
    routing_candidate_from_plan(
      plan,
      provider,
      SelectionFilters.to_map(filters),
      consensus_height,
      learned_scope
    )
  end

  def routing_candidate_from_plan(
        %RoutingPlan{} = plan,
        provider,
        filters,
        consensus_height,
        learned_scope
      )
      when is_map(provider) and is_map(filters) and
             (is_map(learned_scope) or is_nil(learned_scope)) do
    plan
    |> Map.put(:providers, [provider])
    |> do_list_candidates(filters, :routing, consensus_height, false, learned_scope)
    |> List.first()
  end

  defp do_list_candidates(%RoutingPlan{} = plan, filters),
    do: do_list_candidates(plan, filters, :full)

  defp do_list_candidates(%RoutingPlan{} = plan, filters, mode),
    do: do_list_candidates(plan, filters, mode, capture_consensus_height(plan.chain_id))

  defp do_list_candidates(%RoutingPlan{} = plan, filters, mode, consensus_height),
    do: do_list_candidates(plan, filters, mode, consensus_height, true)

  defp do_list_candidates(%RoutingPlan{} = plan, filters, mode, consensus_height, warn_on_lag?),
    do: do_list_candidates(plan, filters, mode, consensus_height, warn_on_lag?, nil)

  defp do_list_candidates(
         %RoutingPlan{} = plan,
         filters,
         mode,
         consensus_height,
         warn_on_lag?,
         learned_scope
       ) do
    protocol = Map.get(filters, :protocol)
    workload_key = filters |> Map.get(:workload_key, :client) |> Workload.normalize()
    include_half_open = Map.get(filters, :include_half_open, false)

    learned_scope =
      learned_scope || AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)

    candidates =
      plan.providers
      |> Enum.map(&build_candidate(&1, learned_scope, plan, protocol, workload_key, mode))
      |> Enum.filter(fn c ->
        transport_available?(c, protocol) and
          candidate_gate_ready?(c, protocol, include_half_open, filters, mode)
      end)
      |> filter_by_lag(
        plan.profile,
        plan.chain_id,
        Map.get(filters, :max_lag_blocks),
        consensus_height,
        warn_on_lag?
      )
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

  defp build_candidate(provider, learned_scope, plan, protocol, workload_key, mode) do
    instance_id = provider.instance_id
    routing_instance_id = provider.routing_instance_id
    transports = live_transports(provider, protocol, plan.profile, plan.chain_id)

    include_learned? = not learned_scope.degraded?

    {http_routing, ws_routing} =
      if mode == :fastest_ranked do
        {nil, nil}
      else
        {
          route_record(learned_scope, routing_instance_id, :http, transports),
          route_record(learned_scope, routing_instance_id, :ws, transports)
        }
      end

    {circuit_state, rate_limited} =
      candidate_gates(
        mode,
        instance_id,
        transports,
        include_learned?,
        http_routing,
        ws_routing
      )

    candidate = %{
      id: provider.id,
      instance_id: instance_id,
      route_generation: plan.generation,
      config: provider.config,
      transports: transports,
      routing_states: %{http: http_routing, ws: ws_routing},
      workload_key: workload_key,
      circuit_state: circuit_state,
      rate_limited: rate_limited,
      learned_feedback_degraded?: learned_scope.degraded?
    }

    candidate
    |> maybe_add_routing_identity(mode, routing_instance_id)
    |> maybe_add_availability(
      mode,
      instance_id,
      http_routing,
      ws_routing,
      include_learned?
    )
  end

  defp maybe_add_routing_identity(candidate, mode, routing_instance_id)
       when mode in [:routing, :ranked, :fastest_ranked],
       do: Map.put(candidate, :routing_instance_id, routing_instance_id)

  defp maybe_add_routing_identity(candidate, :full, _routing_instance_id), do: candidate

  defp maybe_add_availability(candidate, mode, _instance_id, _http, _ws, _include_learned?)
       when mode in [:routing, :ranked, :fastest_ranked],
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

  defp route_record(scope, routing_instance_id, transport, transports) do
    if transport in transports,
      do: AttemptProjection.route_record_bounded(scope, routing_instance_id, transport),
      else: nil
  end

  defp candidate_gate(instance_id, transport, transports, include_learned?, routing) do
    if transport in transports do
      InstanceState.read_candidate_gate(instance_id, transport, routing, include_learned?)
    else
      {:unavailable, false}
    end
  end

  defp candidate_gates(
         mode,
         _instance_id,
         _transports,
         _include_learned?,
         _http_routing,
         _ws_routing
       )
       when mode in [:ranked, :fastest_ranked] do
    {%{http: :deferred, ws: :deferred}, %{http: false, ws: false}}
  end

  defp candidate_gates(
         _mode,
         instance_id,
         transports,
         include_learned?,
         http_routing,
         ws_routing
       ) do
    {http_cb, http_rl} =
      candidate_gate(instance_id, :http, transports, include_learned?, http_routing)

    {ws_cb, ws_rl} =
      candidate_gate(instance_id, :ws, transports, include_learned?, ws_routing)

    {%{http: http_cb, ws: ws_cb}, %{http: http_rl, ws: ws_rl}}
  end

  defp candidate_gate_ready?(_candidate, _protocol, _include_half_open, _filters, mode)
       when mode in [:ranked, :fastest_ranked],
       do: true

  defp candidate_gate_ready?(candidate, protocol, include_half_open, filters, _mode) do
    circuit_breaker_ready?(candidate, protocol, include_half_open) and
      rate_limit_ok?(candidate, protocol, filters)
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

  defp filter_by_lag(candidates, _profile, _chain_id, nil, _consensus_height, _warn_on_lag?),
    do: candidates

  defp filter_by_lag(
         candidates,
         profile,
         chain_id,
         max_lag_blocks,
         consensus_height,
         warn_on_lag?
       )
       when is_integer(max_lag_blocks) do
    case resolve_consensus_height(chain_id, consensus_height) do
      {:ok, consensus_height} ->
        filter_by_lag_with_consensus(
          candidates,
          profile,
          chain_id,
          max_lag_blocks,
          consensus_height,
          warn_on_lag?
        )

      :unavailable ->
        candidates
    end
  end

  defp filter_by_lag_with_consensus(
         candidates,
         profile,
         chain_id,
         max_lag_blocks,
         consensus_height,
         warn_on_lag?
       ) do
    block_time_ms = LagCalculation.get_block_time_ms(chain_id, profile)

    filtered =
      Enum.filter(candidates, fn candidate ->
        case LagCalculation.calculate_optimistic_lag(
               chain_id,
               candidate.instance_id,
               block_time_ms,
               consensus_height
             ) do
          {:ok, optimistic_lag, _raw_lag} -> optimistic_lag >= -max_lag_blocks
          {:error, _} -> true
        end
      end)

    if warn_on_lag? and candidates != [] and filtered == [] do
      Logger.warning(
        "All providers for chain_id #{chain_id} excluded due to lag (threshold: -#{max_lag_blocks} blocks)"
      )
    end

    filtered
  end

  defp resolve_consensus_height(_chain_id, height)
       when is_integer(height) and height >= 0,
       do: {:ok, height}

  defp resolve_consensus_height(_chain_id, :unavailable), do: :unavailable

  defp capture_consensus_height(chain_id) do
    case ChainState.consensus_height(chain_id) do
      {:ok, height} -> height
      {:error, _reason} -> :unavailable
    end
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
