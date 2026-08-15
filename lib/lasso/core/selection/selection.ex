defmodule Lasso.RPC.Selection do
  @moduledoc """
  Unified provider selection module that handles all provider picking logic.

  This module provides a single interface for selecting providers across
  different protocols (HTTP vs WS) and fallback strategies. It uses
  CandidateListing for ETS-backed health-aware selection, then falls back to
  ConfigStore-based selection if the catalog is unavailable.

  Selection strategies:
  - Catalog-based (preferred): Uses CandidateListing health and performance data
  - Config-based (fallback): Uses static configuration priority ordering

  This eliminates the need for channels/controllers to load configuration
  or directly manage provider selection logic.
  """

  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{CandidateListing, Catalog}

  alias Lasso.RPC.{
    AttemptProjection,
    ChainState,
    Channel,
    RequestAnalysis,
    RoutingPlan,
    SelectionFilters,
    TransportRegistry
  }

  alias Lasso.RPC.Strategies.Registry, as: StrategyRegistry
  # Selection should be transport-policy agnostic. Transport constraints
  # should be provided by the caller via opts.

  @doc """
  Picks the best provider using simple parameters.

  Options:
  - :params => [term()] (RPC params for request analysis, default [])
  - :strategy => :fastest | :priority | :load_balanced | :latency_weighted (default :load_balanced)
  - :protocol => :http | :ws | :both (default :both)
  - :exclude => [provider_id] (default [])
  - :include_half_open => boolean (default false)
  - :timeout => ms (default 30_000)

  Returns {:ok, provider_id} or {:error, reason}
  """
  @spec select_provider(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def select_provider(profile, chain_id, method, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_binary(method) do
    params = Keyword.get(opts, :params, [])

    selection_opts = %{
      strategy: Keyword.get(opts, :strategy, :load_balanced),
      protocol: Keyword.get(opts, :protocol, :both),
      exclude: Keyword.get(opts, :exclude, []),
      include_half_open: Keyword.get(opts, :include_half_open, false),
      timeout: Keyword.get(opts, :timeout, 30_000),
      requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false)
    }

    select_provider_from_plan(profile, chain_id, method, params, selection_opts)
  end

  # Private implementation

  defp select_provider_from_plan(profile, chain_id, method, params, selection_opts) do
    case capture_selection_snapshot(profile, chain_id) do
      {:ok, snapshot, plan} ->
        do_select_provider(snapshot, plan, method, params, selection_opts)

      :unavailable ->
        {:error, :no_providers_available}
    end
  end

  defp do_select_provider(snapshot, plan, method, params, selection_opts) do
    filters =
      build_selection_filters(
        plan,
        method,
        params,
        selection_opts.exclude,
        selection_opts.protocol,
        include_half_open: selection_opts.include_half_open,
        requires_subscribe_new_heads: selection_opts.requires_subscribe_new_heads
      )

    candidates = CandidateListing.list_candidates_from_plan(plan, filters)

    case candidates do
      [] ->
        {:error, :no_providers_available}

      _ ->
        strategy_mod = StrategyRegistry.resolve(selection_opts.strategy)

        prepared_ctx =
          strategy_mod.prepare_context(
            plan.profile,
            plan.chain_id,
            method,
            selection_opts.timeout
          )
          |> enrich_strategy_context(candidates, plan)

        channels =
          candidates
          |> Enum.flat_map(fn %{
                                id: provider_id,
                                instance_id: instance_id,
                                config: provider_config,
                                route_generation: route_generation,
                                transports: available_transports
                              } ->
            transports =
              Enum.filter(
                available_transports,
                &(&1 in transports_to_check(selection_opts.protocol))
              )

            Enum.flat_map(transports, fn t ->
              case TransportRegistry.get_channel(plan.profile, plan.chain_id, provider_id, t,
                     method: method,
                     provider_config: provider_config,
                     instance_id: instance_id,
                     route_generation: route_generation
                   ) do
                {:ok, ch} -> [ch]
                _ -> []
              end
            end)
          end)

        ordered =
          strategy_mod.rank_channels(
            channels,
            method,
            prepared_ctx,
            plan.profile,
            plan.chain_id
          )

        case {selection_snapshot_current?(snapshot, candidates), List.first(ordered)} do
          {true, %Channel{provider_id: pid}} ->
            {:ok, pid}

          _ ->
            {:error, :no_providers_available}
        end
    end
  end

  # Strategy resolution moved to StrategyRegistry for DRY pluggability.

  @doc """
  Selects the best channels for a method across all available transports.

  onsiders provider capabilities,
  health, and performance metrics to return ordered candidate channels.

  Options:
  - :strategy => :fastest | :priority | :load_balanced | :latency_weighted
  - :transport => :http | :ws | :both (default :both)
  - :exclude => [provider_id]
  - :limit => integer (maximum channels to return)
  - :include_half_open => boolean (default true) - include providers with half-open circuits (deprioritized after closed)

  Returns a list of Channel structs ordered by strategy preference.
  """
  @spec select_channels(String.t(), pos_integer(), String.t(), keyword()) :: [Channel.t()]
  def select_channels(profile, chain_id, method, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_binary(method) do
    case capture_selection_snapshot(profile, chain_id) do
      {:ok, snapshot, plan} -> select_channels_from_plan(snapshot, plan, method, opts)
      :unavailable -> []
    end
  end

  defp select_channels_from_plan(snapshot, plan, method, opts) do
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    transport = Keyword.get(opts, :transport, :both)
    exclude = Keyword.get(opts, :exclude, [])
    limit = Keyword.get(opts, :limit, 1000)
    include_half_open = Keyword.get(opts, :include_half_open, true)
    params = Keyword.get(opts, :params, [])

    pool_protocol =
      case transport do
        :http -> :http
        :ws -> :ws
        _ -> nil
      end

    consensus_height = get_consensus_height(plan.chain_id)

    requirements =
      Lasso.RPC.RequestAnalysis.analyze(
        method,
        params,
        consensus_height: consensus_height,
        archival_threshold: plan.archival_threshold
      )

    pool_filters =
      SelectionFilters.new(
        protocol: pool_protocol,
        exclude: exclude,
        include_half_open: include_half_open,
        max_lag_blocks: plan.max_lag_blocks,
        min_block: requirements.requested_block,
        requires_archival: requirements.requires_archival,
        requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false)
      )

    provider_candidates = CandidateListing.list_candidates_from_plan(plan, pool_filters)

    # Build circuit state lookup map: {provider_id, transport} => :closed | :half_open
    circuit_state_map =
      provider_candidates
      |> Enum.flat_map(fn %{id: provider_id} = candidate ->
        cs = Map.get(candidate, :circuit_state, %{})

        [
          {{provider_id, :http}, Map.get(cs, :http, :closed)},
          {{provider_id, :ws}, Map.get(cs, :ws, :closed)}
        ]
      end)
      |> Map.new()

    # Build rate limit lookup map: provider_id => %{http: bool, ws: bool}
    rate_limit_map =
      provider_candidates
      |> Enum.map(fn %{id: id, rate_limited: rl} -> {id, rl} end)
      |> Map.new()

    # Build channel candidates via TransportRegistry (enforces channel-level health/capabilities)
    # Map provider list into channels, lazily opening as needed
    channels =
      provider_candidates
      |> Enum.flat_map(
        &build_provider_channels(&1, transport, plan.profile, plan.chain_id, method)
      )
      |> Enum.reject(&is_nil/1)

    # Filter channels by method capability (adapter-based filtering)
    capable_channels =
      case Lasso.RPC.Providers.AdapterFilter.filter_channels(channels, method) do
        {:ok, capable, filtered} ->
          if filtered != [] do
            Logger.debug(
              "Filtered #{length(filtered)} channels for #{method}: #{inspect(Enum.map(filtered, & &1.provider_id))}"
            )
          end

          capable
      end

    # Strategy delegation: allow strategy modules to rank channels when available.
    strategy_mod = StrategyRegistry.resolve(strategy)
    timeout = Keyword.get(opts, :timeout, 30_000)

    prepared_ctx =
      strategy_mod.prepare_context(plan.profile, plan.chain_id, method, timeout)
      |> enrich_strategy_context(provider_candidates, plan)

    learned_feedback_degraded? =
      Enum.any?(provider_candidates, & &1.learned_feedback_degraded?)

    ordered_channels =
      if learned_feedback_degraded? and strategy in [:fastest, :latency_weighted] do
        Enum.sort_by(capable_channels, &{&1.provider_id, &1.transport})
      else
        strategy_mod.rank_channels(
          capable_channels,
          method,
          prepared_ctx,
          plan.profile,
          plan.chain_id
        )
      end

    # Health-based tiering: reorder providers by circuit breaker state and rate limit status.
    #
    # The 4-tier system ensures healthy providers receive traffic first while allowing
    # recovering providers to gradually reintegrate:
    #
    # 1. Tier 1: Closed circuit + not rate-limited (preferred)
    # 2. Tier 2: Half-open circuit + not rate-limited
    # 3. Tier 3: Closed circuit + rate-limited
    # 4. Tier 4: Half-open circuit + rate-limited
    #
    # Open-circuit providers are filtered out earlier in the pipeline.
    #
    # Within each tier, the strategy's ranking is preserved. For example, with
    # load-balanced strategy, Tier 1 providers remain shuffled relative to each other,
    # but all Tier 1 providers come before any Tier 2 providers.
    #
    # This tiering explains why traffic may be concentrated on certain providers even
    # with load-balanced: if only one provider is in Tier 1, it receives all traffic
    # that succeeds, with lower tiers acting as fallbacks.

    final_channels = tier_channels(ordered_channels, circuit_state_map, rate_limit_map)

    selected = final_channels |> Enum.take(limit)

    if selection_snapshot_current?(snapshot, provider_candidates),
      do: selected,
      else: []
  end

  @doc """
  Selects the best channel for a specific provider and transport combination.

  Returns {:ok, channel} or {:error, reason}.
  """
  @spec select_provider_channel(String.t(), pos_integer(), String.t(), :http | :ws, keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def select_provider_channel(profile, chain_id, provider_id, transport, opts \\ [])
      when is_integer(chain_id) and chain_id > 0 do
    TransportRegistry.get_channel(profile, chain_id, provider_id, transport, opts)
  end

  ## Private Functions

  @doc false
  @spec tier_channels([Channel.t()], map(), map()) :: [Channel.t()]
  def tier_channels(channels, circuit_state_map, rate_limit_map) do
    channels
    |> Enum.flat_map(fn channel ->
      circuit_state =
        Map.get(circuit_state_map, {channel.provider_id, channel.transport}, :closed)

      rate_limited =
        rate_limit_map
        |> Map.get(channel.provider_id, %{http: false, ws: false})
        |> Map.get(channel.transport, false)

      case {circuit_state, rate_limited} do
        {:closed, false} -> [{1, channel}]
        {:half_open, false} -> [{2, channel}]
        {:closed, true} -> [{3, channel}]
        {:half_open, true} -> [{4, channel}]
        _unavailable -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # Channel building helpers

  defp build_provider_channels(
         %{
           id: provider_id,
           instance_id: instance_id,
           config: config,
           route_generation: route_generation,
           transports: available_transports
         },
         transport,
         profile,
         chain_id,
         method
       ) do
    transport
    |> transports_to_check()
    |> Enum.filter(&(&1 in available_transports))
    |> Enum.flat_map(fn t ->
      fetch_channel(
        profile,
        chain_id,
        provider_id,
        t,
        method,
        config,
        route_generation,
        instance_id
      )
    end)
  end

  defp transports_to_check(:http), do: [:http]
  defp transports_to_check(:ws), do: [:ws]
  defp transports_to_check(_), do: [:http, :ws]

  defp fetch_channel(
         profile,
         chain_id,
         provider_id,
         transport,
         method,
         provider_config,
         route_generation,
         instance_id
       ) do
    case TransportRegistry.get_channel(profile, chain_id, provider_id, transport,
           method: method,
           provider_config: provider_config,
           instance_id: instance_id,
           route_generation: route_generation
         ) do
      {:ok, channel} -> [channel]
      _ -> []
    end
  end

  defp capture_selection_snapshot(profile, chain_id) do
    case Catalog.snapshot() do
      %{generation: generation} = snapshot ->
        with true <- ConfigStore.route_generation() == generation,
             {:ok, plan} <- Catalog.get_routing_plan(snapshot, profile, chain_id) do
          {:ok, snapshot, plan}
        else
          _unavailable -> :unavailable
        end

      _unavailable ->
        :unavailable
    end
  end

  defp selection_snapshot_current?(snapshot),
    do:
      Catalog.snapshot() == snapshot and
        ConfigStore.route_generation() == snapshot.generation

  defp selection_snapshot_current?(snapshot, candidates) do
    Enum.all?(candidates, &(&1.route_generation == snapshot.generation)) and
      selection_snapshot_current?(snapshot)
  end

  defp get_consensus_height(chain_id) do
    case ChainState.consensus_height(chain_id) do
      {:ok, height} -> height
      {:error, _} -> nil
    end
  end

  defp build_selection_filters(plan, method, params, exclude, protocol, opts) do
    consensus_height = get_consensus_height(plan.chain_id)
    include_half_open = Keyword.get(opts, :include_half_open, false)
    requires_subscribe_new_heads = Keyword.get(opts, :requires_subscribe_new_heads, false)

    requirements =
      RequestAnalysis.analyze(
        method,
        params,
        consensus_height: consensus_height,
        archival_threshold: plan.archival_threshold
      )

    SelectionFilters.new(
      exclude: exclude,
      protocol: protocol,
      include_half_open: include_half_open,
      max_lag_blocks: plan.max_lag_blocks,
      min_block: requirements.requested_block,
      requires_archival: requirements.requires_archival,
      requires_subscribe_new_heads: requires_subscribe_new_heads
    )
  end

  defp enrich_strategy_context(ctx, candidates, %RoutingPlan{} = plan) do
    summaries =
      Enum.reduce(candidates, %{}, fn candidate, acc ->
        Enum.reduce(candidate.transports, acc, fn transport, route_acc ->
          row = Map.get(candidate.routing_states, transport)

          summary =
            AttemptProjection.summarize_route(
              row,
              candidate.instance_id,
              transport,
              plan.chain_id,
              ctx.workload_key
            )

          Map.put(route_acc, {candidate.instance_id, transport}, summary)
        end)
      end)

    %{ctx | routing_summaries: summaries, provider_priorities: plan.provider_priorities}
  end
end
