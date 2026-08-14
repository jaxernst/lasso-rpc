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
  alias Lasso.RPC.{AttemptProjection, SelectionFilters}

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
    if Catalog.snapshot() == snapshot and ConfigStore.route_generation() == generation,
      do: do_list_candidates(snapshot, profile, chain_id, filters),
      else: []
  end

  defp do_list_candidates(snapshot, profile, chain_id, filters) do
    protocol = Map.get(filters, :protocol)
    include_half_open = Map.get(filters, :include_half_open, false)
    learned_scope = AttemptProjection.scope_state(profile, chain_id, snapshot.generation)

    profile_providers = Catalog.get_profile_providers(snapshot, profile, chain_id)

    candidates =
      profile_providers
      |> Enum.map(&build_candidate(&1, learned_scope, snapshot))
      |> Enum.filter(fn c ->
        transport_available?(c, protocol, profile, chain_id) and
          circuit_breaker_ready?(c, protocol, include_half_open) and
          rate_limit_ok?(c, protocol, filters)
      end)
      |> filter_by_lag(profile, chain_id, Map.get(filters, :max_lag_blocks))
      |> filter_by_min_block(profile, chain_id, Map.get(filters, :min_block))
      |> filter_by_archival(Map.get(filters, :requires_archival))
      |> filter_by_subscribe_new_heads(Map.get(filters, :requires_subscribe_new_heads))
      |> filter_excluded(filters)

    if Catalog.snapshot() == snapshot and ConfigStore.route_generation() == snapshot.generation,
      do: candidates,
      else: []
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

  defp build_candidate(profile_provider, learned_scope, snapshot) do
    instance_id = profile_provider.instance_id

    instance_config =
      case Catalog.get_instance(snapshot, instance_id) do
        {:ok, config} -> config
        _ -> %{}
      end

    include_learned? = not learned_scope.degraded?
    http_routing = AttemptProjection.route_state(learned_scope, instance_id, :http)
    ws_routing = AttemptProjection.route_state(learned_scope, instance_id, :ws)

    base_health = InstanceState.read_health(instance_id, include_learned: false)

    http_health =
      InstanceState.read_health(instance_id,
        include_learned: include_learned?,
        routing_states: [http_routing]
      )

    ws_health =
      InstanceState.read_health(instance_id,
        include_learned: include_learned?,
        routing_states: [ws_routing]
      )

    config =
      Map.merge(instance_config, %{
        id: profile_provider.provider_id,
        priority: profile_provider.priority,
        capabilities: profile_provider.capabilities,
        archival: profile_provider.archival,
        subscribe_new_heads: Map.get(profile_provider, :subscribe_new_heads, false),
        name: profile_provider[:name] || profile_provider.provider_id
      })

    http_cb = InstanceState.read_circuit(instance_id, :http)
    ws_cb = InstanceState.read_circuit(instance_id, :ws)

    http_rl =
      InstanceState.read_rate_limit(instance_id, :http,
        include_learned: include_learned?,
        routing_state: http_routing
      )

    ws_rl =
      InstanceState.read_rate_limit(instance_id, :ws,
        include_learned: include_learned?,
        routing_state: ws_routing
      )

    %{
      id: profile_provider.provider_id,
      instance_id: instance_id,
      route_generation: snapshot.generation,
      config: config,
      availability: InstanceState.status_to_availability(base_health.status),
      transport_availability: %{
        http: InstanceState.status_to_availability(http_health.status),
        ws: InstanceState.status_to_availability(ws_health.status)
      },
      circuit_state: %{http: http_cb.state, ws: ws_cb.state},
      rate_limited: %{http: http_rl.rate_limited, ws: ws_rl.rate_limited},
      learned_feedback_degraded?: learned_scope.degraded?
    }
  end

  defp transport_available?(candidate, protocol, profile, chain_id) do
    config = candidate.config

    case protocol do
      :http ->
        is_binary(config.url)

      :ws ->
        is_binary(config.ws_url) and ws_channel_live?(profile, chain_id, candidate.id)

      :both ->
        is_binary(config.url) or
          (is_binary(config.ws_url) and ws_channel_live?(profile, chain_id, candidate.id))

      nil ->
        is_binary(config.url) or is_binary(config.ws_url)
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
        has_http = is_binary(candidate.config.url)
        has_ws = is_binary(candidate.config.ws_url)

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
