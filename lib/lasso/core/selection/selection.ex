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

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.{CandidateListing, Catalog}

  alias Lasso.RPC.{
    AttemptProjection,
    Channel,
    RequestAnalysis,
    RoutingEvidence,
    RoutingPlan,
    Selection.CandidateCursor,
    SelectionFilters,
    TransportRegistry
  }

  alias Lasso.RPC.ProviderKnowledge.Effects
  alias Lasso.RPC.RoutingEvidence.Workload
  @client_workloads Workload.client_partitions()
  alias Lasso.RPC.Selection.CandidateCursor.DeferredRanking
  alias Lasso.RPC.Selection.HeadSuitability
  alias Lasso.RPC.Strategies.LoadBalanced
  alias Lasso.RPC.Strategies.Registry, as: StrategyRegistry
  # Selection should be transport-policy agnostic. Transport constraints
  # should be provided by the caller via opts.

  @doc """
  Picks the best provider using simple parameters.

  Options:
  - :params => [term()] (RPC params for request analysis, default [])
  - :strategy => :fastest | :priority | :load_balanced | :balanced_fast (default :load_balanced)
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
      requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
      request_origin: Keyword.get(opts, :request_origin, :client)
    }

    select_provider_from_plan(profile, chain_id, method, params, selection_opts)
  end

  # Private implementation

  defp select_provider_from_plan(profile, chain_id, method, params, selection_opts) do
    case capture_selection_snapshot(profile, chain_id) do
      {:ok, snapshot, plan} ->
        do_select_provider(snapshot, plan, method, params, selection_opts)

      {:unavailable, _} ->
        {:error, :no_providers_available}
    end
  end

  defp do_select_provider(snapshot, plan, method, params, selection_opts) do
    {filters, head_snapshot} =
      build_selection_filters(
        plan,
        method,
        params,
        selection_opts.exclude,
        selection_opts.protocol,
        include_half_open: selection_opts.include_half_open,
        requires_subscribe_new_heads: selection_opts.requires_subscribe_new_heads,
        workload_key: Workload.for_request(selection_opts.request_origin, method)
      )

    candidates =
      CandidateListing.list_routing_candidates_from_plan(plan, filters, head_snapshot)

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
          |> Map.put(:workload_key, Workload.for_request(selection_opts.request_origin, method))
          |> enrich_strategy_context(candidates, plan, strategy_mod)

        channels =
          candidates
          |> Enum.flat_map(fn %{transports: available_transports} = candidate ->
            transports =
              Enum.filter(
                available_transports,
                &(&1 in transports_to_check(selection_opts.protocol))
              )

            Enum.flat_map(transports, fn t ->
              case TransportRegistry.get_channel_from_plan(plan, candidate, t, method) do
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

  Considers provider capabilities,
  health, and performance metrics to return ordered candidate channels.

  Options:
  - :strategy => :fastest | :priority | :load_balanced | :balanced_fast
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
      {:unavailable, _} -> []
    end
  end

  @doc "Returns an incremental cursor for static strategies and an eager list otherwise."
  @spec select_channel_candidates(String.t(), pos_integer(), String.t(), keyword()) ::
          [Channel.t()] | CandidateCursor.t() | {:unavailable, map()}
  def select_channel_candidates(profile, chain_id, method, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_binary(method) do
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    strategy_mod = StrategyRegistry.resolve(strategy)

    case {strategy, strategy_mod} do
      {strategy, _module} when strategy in [:priority, :load_balanced] ->
        case capture_selection_snapshot(profile, chain_id) do
          {:ok, snapshot, plan} -> CandidateCursor.new(snapshot, plan, method, opts)
          {:unavailable, _} = failure -> failure
        end

      {:fastest, Lasso.RPC.Strategies.Fastest} ->
        select_ranked_channel_candidates(
          profile,
          chain_id,
          method,
          opts,
          strategy_mod,
          :fastest_winner
        )

      {:balanced_fast, Lasso.RPC.Strategies.BalancedFast} ->
        select_ranked_channel_candidates(profile, chain_id, method, opts, strategy_mod, :full)

      _custom_or_unknown ->
        select_channels(profile, chain_id, method, opts)
    end
  end

  @doc "Selects eligible channels from one captured publication plan."
  @spec select_channels_from_plan(RoutingPlan.t(), String.t(), keyword()) :: [Channel.t()]
  def select_channels_from_plan(%RoutingPlan{} = plan, method, opts),
    do: select_channels_from_plan(Catalog.snapshot(), plan, method, opts)

  defp select_channels_from_plan(snapshot, %RoutingPlan{} = plan, method, opts) do
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    limit = Keyword.get(opts, :limit, 1000)

    {provider_candidates, transport, workload_key, filters, _head_snapshot} =
      routing_candidates(plan, method, opts)

    head = filters.head_suitability

    # Build channel candidates via TransportRegistry (enforces channel-level health/capabilities)
    # Map provider list into channels, lazily opening as needed
    channels =
      provider_candidates
      |> Enum.flat_map(
        &build_provider_channels(&1, transport, plan, method, Keyword.get(opts, :deadline_us))
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

    final_channels =
      order_capable_channels(
        capable_channels,
        provider_candidates,
        strategy,
        method,
        plan,
        Keyword.get(opts, :timeout, 30_000),
        workload_key,
        Keyword.put(opts, :head_suitability, head)
      )

    if selection_snapshot_current?(snapshot, provider_candidates),
      do: Enum.take(final_channels, limit),
      else: []
  end

  defp select_ranked_channel_candidates(
         profile,
         chain_id,
         method,
         opts,
         strategy_mod,
         ranking_mode
       ) do
    case capture_selection_snapshot(profile, chain_id) do
      {:ok, snapshot, plan} ->
        strategy = Keyword.fetch!(opts, :strategy)

        fastest_hint =
          fastest_hint(
            ranking_mode,
            plan,
            Workload.for_request(Keyword.get(opts, :request_origin, :client), method)
          )

        {_transport, _workload_key, filters, _head_snapshot} =
          inputs = routing_inputs(plan, method, opts)

        opts =
          Keyword.put(
            opts,
            :head_suitability,
            filters.head_suitability
          )

        case build_hinted_fastest_cursor(
               snapshot,
               plan,
               method,
               opts,
               strategy_mod,
               fastest_hint,
               inputs
             ) do
          {:ok, cursor} ->
            cursor

          :miss ->
            build_ranked_cursor(
              snapshot,
              plan,
              method,
              opts,
              strategy_mod,
              strategy,
              inputs
            )
        end

      {:unavailable, _} = failure ->
        failure
    end
  end

  defp routing_candidates(plan, method, opts, gate_mode \\ :captured_gates) do
    {transport, workload_key, pool_filters, head_snapshot} =
      routing_inputs(plan, method, opts)

    candidates =
      candidates_from_inputs(plan, pool_filters, head_snapshot, gate_mode)

    {candidates, transport, workload_key, pool_filters, head_snapshot}
  end

  defp routing_inputs(plan, method, opts) do
    transport = Keyword.get(opts, :transport, :both)
    workload_key = Workload.for_request(Keyword.get(opts, :request_origin, :client), method)

    pool_protocol =
      case transport do
        :http -> :http
        :ws -> :ws
        _ -> nil
      end

    head_snapshot = get_head_snapshot(plan)

    pool_filters =
      SelectionFilters.for_phase(plan, method, head_snapshot, opts,
        protocol: pool_protocol,
        exclude: Keyword.get(opts, :exclude, []),
        include_half_open: Keyword.get(opts, :include_half_open, true),
        requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
        workload_key: workload_key
      )

    {transport, workload_key, pool_filters, head_snapshot}
  end

  defp candidates_from_inputs(plan, filters, head_snapshot, gate_mode, learned_scope \\ nil) do
    case gate_mode do
      :deferred_fastest ->
        if learned_scope do
          CandidateListing.list_fastest_candidates_from_plan(
            plan,
            filters,
            head_snapshot,
            learned_scope
          )
        else
          CandidateListing.list_fastest_candidates_from_plan(
            plan,
            filters,
            head_snapshot
          )
        end

      :deferred_gates ->
        CandidateListing.list_rankable_candidates_from_plan(
          plan,
          filters,
          head_snapshot
        )

      :captured_gates ->
        CandidateListing.list_routing_candidates_from_plan(
          plan,
          filters,
          head_snapshot
        )
    end
  end

  defp build_ranked_cursor(
         snapshot,
         plan,
         method,
         opts,
         strategy_mod,
         strategy,
         {_, workload_key, filters, head_snapshot}
       ) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    {ranked_candidates, deferred_ranking, _candidates, learning_decision} =
      ranked_candidate_state(
        plan,
        method,
        timeout,
        strategy_mod,
        strategy,
        workload_key,
        %{filters: filters, head_snapshot: head_snapshot}
      )

    CandidateCursor.new_ranked(
      snapshot,
      plan,
      method,
      Keyword.put(opts, :learning_decision, learning_decision),
      ranked_candidates,
      filters,
      head_snapshot,
      deferred_ranking
    )
  end

  defp ranked_candidate_state(
         plan,
         method,
         timeout,
         strategy_mod,
         strategy,
         workload_key,
         %{filters: filters, head_snapshot: head_snapshot} = selection
       ) do
    candidates = candidates_from_inputs(plan, filters, head_snapshot, :deferred_gates)

    entries =
      for candidate <- candidates,
          transport <- candidate.transports,
          {candidate.instance_id, transport} not in Map.get(selection, :excluded_routes, []) do
        {ranking_channel(plan, candidate, transport), candidate, transport}
      end

    capable_channels =
      entries
      |> Enum.map(&elem(&1, 0))
      |> filter_capable_channels(method)

    entries_by_key =
      Map.new(entries, fn {channel, candidate, transport} ->
        {{channel.instance_id, transport}, {candidate, transport}}
      end)

    {ranked_candidates, deferred_ranking, learning_decision} =
      rank_candidate_channels(
        capable_channels,
        entries_by_key,
        %{
          candidates: candidates,
          strategy: strategy,
          method: method,
          plan: plan,
          timeout: timeout,
          workload_key: workload_key,
          resource: %{
            historical_resource: filters.historical_resource,
            historical_height: filters.historical_height
          },
          strategy_mod: strategy_mod
        }
      )

    {ranked_candidates, deferred_ranking, candidates, learning_decision}
  end

  defp build_hinted_fastest_cursor(
         snapshot,
         plan,
         method,
         opts,
         strategy_mod,
         {%{route: {routing_instance_id, winner_transport}}, learned_scope},
         {requested_transport, workload_key, filters, head_snapshot}
       ) do
    matching_providers =
      Enum.filter(plan.providers, fn provider ->
        provider.routing_instance_id == routing_instance_id and
          winner_transport in transports_to_check(requested_transport) and
          winner_transport in provider.transports
      end)

    {eligible, candidate_entries} =
      case matching_providers do
        [provider] ->
          eligible =
            candidates_from_inputs(
              plan,
              filters,
              head_snapshot,
              :deferred_fastest,
              learned_scope
            )

          {eligible,
           for candidate <- eligible,
               candidate.id == provider.id,
               winner_transport in candidate.transports do
             {ranking_channel(plan, candidate, winner_transport), candidate, winner_transport}
           end}

        _ambiguous_or_missing ->
          {[], []}
      end

    capable_entries =
      candidate_entries
      |> Enum.filter(fn {channel, _candidate, _transport} ->
        filter_capable_channels([channel], method) == [channel]
      end)

    case capable_entries do
      [{_channel, candidate, transport}] ->
        timeout = Keyword.get(opts, :timeout, 30_000)
        limit = Keyword.get(opts, :limit, 1000)

        resolver = fn ->
          {ranked, deferred, _candidates, decision} =
            ranked_candidate_state(
              plan,
              method,
              timeout,
              strategy_mod,
              :fastest,
              workload_key,
              %{
                filters: filters,
                head_snapshot: head_snapshot,
                excluded_routes: [{candidate.instance_id, transport}]
              }
            )

          {ranked, deferred, decision}
        end

        deferred = %DeferredRanking{
          entries: [],
          scope: learned_scope,
          chain_id: plan.chain_id,
          workload_key: workload_key,
          resolver: resolver,
          excluded_routes: MapSet.new([{candidate.instance_id, transport}]),
          candidate_labels:
            if(limit > 0,
              do: ["#{candidate.id}:#{transport}"],
              else: []
            )
        }

        if HeadSuitability.leads?(
             Keyword.get(opts, :head_suitability),
             {candidate.instance_id, transport},
             capable_routes(eligible, plan, requested_transport, method)
           ) and
             cached_winner_effect_eligible?(
               candidate,
               transport,
               plan,
               method,
               opts,
               workload_key,
               filters
             ) do
          {:ok,
           CandidateCursor.new_ranked(
             snapshot,
             plan,
             method,
             opts,
             [{candidate, transport}],
             filters,
             head_snapshot,
             deferred
           )}
        else
          :miss
        end

      _missing_or_unsupported ->
        :miss
    end
  end

  defp build_hinted_fastest_cursor(
         _snapshot,
         _plan,
         _method,
         _opts,
         _strategy_mod,
         _winner,
         _inputs
       ),
       do: :miss

  defp cached_winner_effect_eligible?(
         candidate,
         transport,
         plan,
         method,
         opts,
         workload_key,
         filters
       ) do
    facts = filters.request_facts && filters.request_facts.block_facts
    height = Lasso.RPC.RequestFacts.numeric_interval(facts)

    age =
      if is_integer(filters.reference_height) and not is_nil(height),
        do: filters.reference_height - elem(height, 0)

    span =
      if method == "eth_getLogs" and Effects.mode(:span_limit, plan.profile) == :on,
        do: RequestAnalysis.analyze(method, Keyword.get(opts, :params, [])).block_range

    Effects.cached_winner_eligible?({candidate, transport}, plan, method, %{
      partition: workload_key,
      span: span,
      historical_resource: (facts && facts.resource) || filters.historical_resource,
      historical_height: height,
      historical_age: age
    })
  end

  defp fastest_hint(:fastest_winner, plan, workload) do
    if Effects.response_latency_mode(plan.profile) == :off do
      scope = AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)

      case AttemptProjection.fastest_winner(scope, workload) do
        nil -> nil
        winner -> {winner, scope}
      end
    else
      nil
    end
  end

  defp fastest_hint(:full, _plan, _workload), do: nil

  # The eligible, method-capable routes a cached winner is compared with. Lazy:
  # a winner in the first suitability class never enumerates them.
  defp capable_routes(candidates, plan, transport, method) do
    Stream.flat_map(candidates, fn candidate ->
      transport
      |> transports_to_check()
      |> Enum.filter(&(&1 in candidate.transports))
      |> Enum.map(&ranking_channel(plan, candidate, &1))
      |> filter_capable_channels(method)
      |> Enum.map(&{&1.instance_id, &1.transport})
    end)
  end

  defp ranking_channel(plan, candidate, transport) do
    %Channel{
      profile: plan.profile,
      chain_id: plan.chain_id,
      provider_id: candidate.id,
      instance_id: candidate.instance_id,
      route_generation: plan.generation,
      transport: transport,
      raw_channel: nil,
      transport_module: nil,
      capabilities: nil,
      learning_subject: nil,
      provider_capabilities: Map.get(candidate.config, :capabilities)
    }
  end

  defp filter_capable_channels(channels, method) do
    case Lasso.RPC.Providers.AdapterFilter.filter_channels(channels, method) do
      {:ok, capable, filtered} ->
        if filtered != [] do
          Logger.debug(
            "Filtered #{length(filtered)} channels for #{method}: #{inspect(Enum.map(filtered, & &1.provider_id))}"
          )
        end

        capable
    end
  end

  defp order_capable_channels(
         [channel],
         candidates,
         strategy,
         _method,
         plan,
         _timeout,
         workload_key,
         _opts
       )
       when strategy in [:fastest, :priority, :load_balanced, :balanced_fast] do
    maybe_record_single_channel_degradation(channel, candidates, strategy, plan, workload_key)
    [channel]
  end

  defp order_capable_channels(
         channels,
         candidates,
         strategy,
         method,
         plan,
         timeout,
         workload_key,
         opts
       ) do
    circuit_state_map =
      candidates
      |> Enum.flat_map(fn %{id: provider_id} = candidate ->
        circuit_state = Map.get(candidate, :circuit_state, %{})

        [
          {{provider_id, :http}, Map.get(circuit_state, :http, :closed)},
          {{provider_id, :ws}, Map.get(circuit_state, :ws, :closed)}
        ]
      end)
      |> Map.new()

    rate_limit_map =
      Map.new(candidates, fn %{id: id, rate_limited: rate_limited} ->
        {id, rate_limited}
      end)

    ordered_channels =
      rank_capable_channels(
        channels,
        candidates,
        strategy,
        method,
        plan,
        timeout,
        workload_key,
        StrategyRegistry.resolve(strategy)
      )

    head = Keyword.get(opts, :head_suitability)
    attempted = MapSet.new(Keyword.get(opts, :attempted_instances, []))

    # Load-balanced diversity orders within each suitability class, as the
    # cursor does within each tier bucket, so it never lifts a deferred route.
    tier_channels(ordered_channels, circuit_state_map, rate_limit_map, fn tier, seen ->
      seen = if strategy == :load_balanced, do: MapSet.union(seen, attempted), else: seen

      tier
      |> Enum.group_by(&HeadSuitability.class(head, {&1.instance_id, &1.transport}))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map_reduce(seen, fn {_class, group}, seen ->
        order_class_group(group, strategy, method, seen)
      end)
    end)
  end

  defp order_class_group(group, :load_balanced, method, seen) do
    ordered = LoadBalanced.order_fallbacks(group, method, seen)
    {ordered, Enum.reduce(ordered, seen, &MapSet.put(&2, &1.instance_id))}
  end

  defp order_class_group(group, _strategy, _method, seen), do: {group, seen}

  defp rank_capable_channels(
         [channel],
         candidates,
         strategy,
         _method,
         plan,
         _timeout,
         workload_key,
         _strategy_mod
       )
       when strategy in [:fastest, :priority, :load_balanced, :balanced_fast] do
    maybe_record_single_channel_degradation(channel, candidates, strategy, plan, workload_key)
    [channel]
  end

  defp rank_capable_channels(
         channels,
         _candidates,
         :load_balanced,
         _method,
         _plan,
         _timeout,
         _workload_key,
         LoadBalanced
       ),
       do: LoadBalanced.shuffle_channels(channels)

  defp rank_capable_channels(
         channels,
         candidates,
         strategy,
         method,
         plan,
         timeout,
         workload_key,
         strategy_mod
       ) do
    prepared_ctx =
      strategy_mod.prepare_context(plan.profile, plan.chain_id, method, timeout)
      |> Map.put(:workload_key, workload_key)
      |> enrich_strategy_context(candidates, plan, strategy_mod)

    if Enum.any?(candidates, & &1.learned_feedback_degraded?) and
         strategy in [:fastest, :balanced_fast] do
      Enum.sort_by(channels, &{&1.provider_id, &1.transport})
    else
      strategy_mod.rank_channels(
        channels,
        method,
        prepared_ctx,
        plan.profile,
        plan.chain_id
      )
    end
  end

  defp rank_candidate_channels(
         channels,
         entries_by_key,
         %{
           candidates: candidates,
           strategy: :fastest,
           method: method,
           plan: plan,
           timeout: timeout,
           workload_key: workload_key,
           resource: resource,
           strategy_mod: Lasso.RPC.Strategies.Fastest = strategy_mod
         } = ranking
       )
       when workload_key in @client_workloads do
    if Enum.any?(candidates, & &1.learned_feedback_degraded?) do
      {rank_channels_eager(channels, entries_by_key, ranking), nil, nil}
    else
      scope = AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)
      now_us = System.monotonic_time(:microsecond)

      {qualified, remaining} =
        split_client_qualified(channels, entries_by_key, plan.chain_id, now_us, workload_key)

      case qualified do
        [] ->
          {rank_cold_fastest_channels(
             remaining,
             entries_by_key,
             method,
             plan,
             timeout,
             strategy_mod,
             {scope, now_us, workload_key}
           ), nil, nil}

        _qualified ->
          summaries =
            Map.new(qualified, fn {channel, summary} ->
              {{channel.instance_id, channel.transport}, summary}
            end)

          prepared_ctx =
            strategy_mod.prepare_context(plan.profile, plan.chain_id, method, timeout)
            |> Map.put(:workload_key, workload_key)
            |> Map.put(:routing_summaries, summaries)
            |> Map.put(:provider_priorities, plan.provider_priorities)

          learn_response_latency? = Effects.response_latency_mode(plan.profile) != :off

          qualified_channels =
            Enum.map(qualified, fn {channel, _summary} ->
              if learn_response_latency? do
                {candidate, transport} =
                  Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

                %{
                  channel
                  | learning_subject:
                      TransportRegistry.learning_subject_for(
                        plan.profile,
                        plan.chain_id,
                        transport,
                        candidate.config
                      )
                }
              else
                channel
              end
            end)

          {ranked_channels, learning_decision} =
            qualified_channels
            |> strategy_mod.rank_with_decision(
              method,
              prepared_ctx,
              plan.profile,
              plan.chain_id,
              resource
            )

          ranked =
            Enum.map(ranked_channels, &Map.fetch!(entries_by_key, {&1.instance_id, &1.transport}))

          AttemptProjection.cache_ranked_winner(scope, plan.providers, workload_key)

          deferred = %DeferredRanking{
            entries:
              Enum.map(remaining, fn {channel, _summary} ->
                {candidate, transport} =
                  Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

                {channel, candidate, transport}
              end),
            scope: scope,
            chain_id: plan.chain_id,
            workload_key: workload_key
          }

          {ranked, deferred, learning_decision}
      end
    end
  end

  defp rank_candidate_channels(
         channels,
         entries_by_key,
         ranking
       ) do
    {rank_channels_eager(channels, entries_by_key, ranking), nil, nil}
  end

  defp split_client_qualified(channels, entries_by_key, chain_id, now_us, workload_key) do
    channels
    |> Enum.map(fn channel ->
      {candidate, transport} =
        Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

      summary =
        candidate.routing_states
        |> Map.get(transport)
        |> AttemptProjection.summarize_client_partition(
          candidate.instance_id,
          transport,
          chain_id,
          now_us,
          workload_key
        )

      {channel, summary}
    end)
    |> Enum.split_with(fn {_channel, summary} -> RoutingEvidence.qualified?(summary) end)
  end

  defp rank_cold_fastest_channels(
         channels_with_summaries,
         entries_by_key,
         method,
         plan,
         timeout,
         strategy_mod,
         {scope, _now_us, workload_key}
       ) do
    summaries =
      Map.new(channels_with_summaries, fn {channel, _primary} ->
        {candidate, transport} =
          Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

        summary =
          AttemptProjection.summarize_route_bounded(
            scope,
            candidate_route_record(scope, candidate, transport),
            candidate.instance_id,
            candidate.routing_instance_id,
            transport,
            plan.chain_id,
            workload_key
          )

        {{channel.instance_id, transport}, summary}
      end)

    prepared_ctx =
      strategy_mod.prepare_context(plan.profile, plan.chain_id, method, timeout)
      |> Map.put(:workload_key, workload_key)
      |> Map.put(:routing_summaries, summaries)
      |> Map.put(:provider_priorities, plan.provider_priorities)

    channels_with_summaries
    |> Enum.map(&elem(&1, 0))
    |> strategy_mod.rank_channels(method, prepared_ctx, plan.profile, plan.chain_id)
    |> Enum.map(&Map.fetch!(entries_by_key, {&1.instance_id, &1.transport}))
  end

  defp candidate_route_record(scope, candidate, transport) do
    case Map.get(candidate.routing_states, transport) do
      nil ->
        AttemptProjection.route_record_bounded(
          scope,
          candidate.routing_instance_id,
          transport
        )

      row ->
        row
    end
  end

  defp rank_channels_eager(
         channels,
         entries_by_key,
         %{
           candidates: candidates,
           strategy: strategy,
           method: method,
           plan: plan,
           timeout: timeout,
           workload_key: workload_key,
           strategy_mod: strategy_mod
         }
       ) do
    channels
    |> rank_capable_channels(
      candidates,
      strategy,
      method,
      plan,
      timeout,
      workload_key,
      strategy_mod
    )
    |> Enum.map(&Map.fetch!(entries_by_key, {&1.instance_id, &1.transport}))
  end

  defp maybe_record_single_channel_degradation(
         _channel,
         _candidates,
         strategy,
         _plan,
         _workload_key
       )
       when strategy in [:priority, :load_balanced],
       do: :ok

  defp maybe_record_single_channel_degradation(
         channel,
         candidates,
         strategy,
         plan,
         workload_key
       ) do
    if Enum.any?(candidates, & &1.learned_feedback_degraded?) do
      :ok
    else
      summary =
        candidates
        |> Enum.find(&(&1.instance_id == channel.instance_id))
        |> single_channel_summary(channel, plan, workload_key)

      if RoutingEvidence.qualified?(summary) do
        :ok
      else
        RoutingEvidence.emit_availability_degradation(
          plan.profile,
          strategy,
          plan.chain_id,
          workload_key,
          1
        )
      end
    end
  end

  defp single_channel_summary(nil, _channel, _plan, _workload_key), do: nil

  defp single_channel_summary(candidate, channel, plan, workload_key) do
    scope = AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)

    AttemptProjection.summarize_route_bounded(
      scope,
      Map.get(candidate.routing_states, channel.transport),
      candidate.instance_id,
      candidate.routing_instance_id,
      channel.transport,
      plan.chain_id,
      workload_key
    )
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

  @doc "Orders channels into circuit and rate-limit availability tiers."
  @spec tier_channels([Channel.t()], map(), map()) :: [Channel.t()]
  def tier_channels(channels, circuit_state_map, rate_limit_map) do
    tier_channels(channels, circuit_state_map, rate_limit_map, fn tier, seen -> {tier, seen} end)
  end

  defp tier_channels(channels, circuit_state_map, rate_limit_map, order_tier) do
    {tiers, _seen} =
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
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map_reduce(MapSet.new(), fn tier, seen ->
        order_tier.(Enum.map(tier, &elem(&1, 1)), seen)
      end)

    List.flatten(tiers)
  end

  # Channel building helpers

  defp build_provider_channels(
         %{transports: available_transports} = candidate,
         transport,
         plan,
         method,
         deadline_us
       ) do
    transport
    |> transports_to_check()
    |> Enum.filter(&(&1 in available_transports))
    |> Enum.flat_map(fn t ->
      fetch_channel(plan, candidate, t, method, deadline_us)
    end)
  end

  defp transports_to_check(:http), do: [:http]
  defp transports_to_check(:ws), do: [:ws]
  defp transports_to_check(_), do: [:http, :ws]

  defp fetch_channel(plan, candidate, transport, method, deadline_us) do
    case TransportRegistry.get_channel_from_plan(plan, candidate, transport, method, deadline_us) do
      {:ok, channel} -> [channel]
      _ -> []
    end
  end

  defp capture_selection_snapshot(profile, chain_id) do
    snapshot = Catalog.snapshot()

    case snapshot do
      %{generation: generation} ->
        case Catalog.get_routing_plan(snapshot, profile, chain_id) do
          {:ok, %RoutingPlan{generation: ^generation} = plan} -> {:ok, snapshot, plan}
          {:ok, _} -> selection_unavailable(snapshot, :plan_generation_mismatch)
          _ -> selection_unavailable(snapshot, :plan_unavailable)
        end

      _ ->
        selection_unavailable(snapshot, :unavailable)
    end
  end

  defp selection_unavailable(snapshot, reason) do
    {:unavailable,
     %{
       catalog_generation: snapshot && snapshot.generation,
       config_generation: Lasso.Config.ConfigStore.route_generation(),
       catalog_status: reason
     }}
  end

  defp selection_snapshot_current?(snapshot, candidates) do
    Catalog.snapshot() == snapshot and
      Enum.all?(candidates, &(&1.route_generation == snapshot.generation))
  end

  defp get_head_snapshot(%RoutingPlan{} = plan) do
    case BlockSyncRegistry.get_head_snapshot(
           plan.head_scope,
           plan.generation,
           System.system_time(:millisecond)
         ) do
      {:ok, %HeadSnapshot{} = snapshot} -> snapshot
      {:error, _reason} -> :unavailable
    end
  end

  defp build_selection_filters(plan, method, params, exclude, protocol, opts) do
    head_snapshot = get_head_snapshot(plan)

    filters =
      SelectionFilters.for_phase(plan, method, head_snapshot, Keyword.put(opts, :params, params),
        exclude: exclude,
        protocol: protocol,
        include_half_open: Keyword.get(opts, :include_half_open, false),
        requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
        workload_key: Keyword.get(opts, :workload_key, :client)
      )

    {filters, head_snapshot}
  end

  defp enrich_strategy_context(
         ctx,
         _candidates,
         %RoutingPlan{} = plan,
         Lasso.RPC.Strategies.Priority
       ) do
    %{ctx | provider_priorities: plan.provider_priorities}
  end

  defp enrich_strategy_context(
         ctx,
         _candidates,
         %RoutingPlan{},
         Lasso.RPC.Strategies.LoadBalanced
       ),
       do: ctx

  defp enrich_strategy_context(ctx, candidates, %RoutingPlan{} = plan, _strategy_mod) do
    scope = AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)

    summaries =
      Enum.reduce(candidates, %{}, fn candidate, acc ->
        Enum.reduce(candidate.transports, acc, fn transport, route_acc ->
          row = Map.get(candidate.routing_states, transport)

          summary =
            AttemptProjection.summarize_route_bounded(
              scope,
              row,
              candidate.instance_id,
              candidate.routing_instance_id,
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
