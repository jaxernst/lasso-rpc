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
    RoutingEvidence,
    RoutingPlan,
    Selection.CandidateCursor,
    SelectionFilters,
    TransportRegistry
  }

  alias Lasso.RPC.Selection.CandidateCursor.DeferredRanking
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

      :unavailable ->
        {:error, :no_providers_available}
    end
  end

  defp do_select_provider(snapshot, plan, method, params, selection_opts) do
    {filters, consensus_height} =
      build_selection_filters(
        plan,
        method,
        params,
        selection_opts.exclude,
        selection_opts.protocol,
        include_half_open: selection_opts.include_half_open,
        requires_subscribe_new_heads: selection_opts.requires_subscribe_new_heads,
        workload_key: workload_for_origin(selection_opts.request_origin)
      )

    candidates =
      CandidateListing.list_routing_candidates_from_plan(plan, filters, consensus_height)

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
          |> Map.put(:workload_key, workload_for_origin(selection_opts.request_origin))
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

  @doc false
  @spec select_channel_candidates(String.t(), pos_integer(), String.t(), keyword()) ::
          [Channel.t()] | CandidateCursor.t()
  def select_channel_candidates(profile, chain_id, method, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_binary(method) do
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    strategy_mod = StrategyRegistry.resolve(strategy)

    case {strategy, strategy_mod} do
      {strategy, _module} when strategy in [:priority, :load_balanced] ->
        case capture_selection_snapshot(profile, chain_id) do
          {:ok, snapshot, plan} -> CandidateCursor.new(snapshot, plan, method, opts)
          :unavailable -> []
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

      {:latency_weighted, Lasso.RPC.Strategies.LatencyWeighted} ->
        select_ranked_channel_candidates(profile, chain_id, method, opts, strategy_mod, :full)

      _custom_or_unknown ->
        select_channels(profile, chain_id, method, opts)
    end
  end

  defp select_channels_from_plan(snapshot, plan, method, opts) do
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    limit = Keyword.get(opts, :limit, 1000)

    {provider_candidates, transport, workload_key, _filters, _consensus_height} =
      routing_candidates(plan, method, opts)

    # Build channel candidates via TransportRegistry (enforces channel-level health/capabilities)
    # Map provider list into channels, lazily opening as needed
    channels =
      provider_candidates
      |> Enum.flat_map(&build_provider_channels(&1, transport, plan, method))
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
        workload_key
      )

    selected = final_channels |> Enum.take(limit)

    if selection_snapshot_current?(snapshot, provider_candidates),
      do: selected,
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
        fastest_winner = fastest_winner(ranking_mode, plan)
        inputs = routing_inputs(plan, method, opts)

        case build_hinted_fastest_cursor(
               snapshot,
               plan,
               method,
               opts,
               strategy_mod,
               fastest_winner,
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

      :unavailable ->
        []
    end
  end

  defp routing_candidates(plan, method, opts, gate_mode \\ :captured_gates) do
    {transport, workload_key, pool_filters, consensus_height} =
      routing_inputs(plan, method, opts)

    candidates =
      candidates_from_inputs(plan, pool_filters, consensus_height, gate_mode)

    {candidates, transport, workload_key, pool_filters, consensus_height}
  end

  defp routing_inputs(plan, method, opts) do
    transport = Keyword.get(opts, :transport, :both)
    workload_key = workload_for_origin(Keyword.get(opts, :request_origin, :client))

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
        Keyword.get(opts, :params, []),
        consensus_height: consensus_height,
        archival_threshold: plan.archival_threshold
      )

    pool_filters =
      SelectionFilters.new(
        protocol: pool_protocol,
        exclude: Keyword.get(opts, :exclude, []),
        include_half_open: Keyword.get(opts, :include_half_open, true),
        max_lag_blocks: plan.max_lag_blocks,
        min_block: requirements.requested_block,
        requires_archival: requirements.requires_archival,
        requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
        workload_key: workload_key
      )

    {transport, workload_key, pool_filters, consensus_height}
  end

  defp candidates_from_inputs(plan, filters, consensus_height, gate_mode) do
    case gate_mode do
      :deferred_fastest ->
        CandidateListing.list_fastest_candidates_from_plan(
          plan,
          filters,
          consensus_height || :unavailable
        )

      :deferred_gates ->
        CandidateListing.list_rankable_candidates_from_plan(
          plan,
          filters,
          consensus_height || :unavailable
        )

      :captured_gates ->
        CandidateListing.list_routing_candidates_from_plan(
          plan,
          filters,
          consensus_height || :unavailable
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
         {_, workload_key, filters, consensus_height}
       ) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    {ranked_candidates, deferred_ranking, candidates} =
      ranked_candidate_state(
        plan,
        method,
        timeout,
        strategy_mod,
        strategy,
        workload_key,
        filters,
        consensus_height
      )

    if selection_snapshot_current?(snapshot, candidates) do
      CandidateCursor.new_ranked(
        snapshot,
        plan,
        method,
        opts,
        ranked_candidates,
        filters,
        consensus_height || :unavailable,
        deferred_ranking
      )
    else
      []
    end
  end

  defp ranked_candidate_state(
         plan,
         method,
         timeout,
         strategy_mod,
         strategy,
         workload_key,
         filters,
         consensus_height
       ) do
    candidates = candidates_from_inputs(plan, filters, consensus_height, :deferred_gates)

    entries =
      for candidate <- candidates,
          transport <- candidate.transports do
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

    {ranked_candidates, deferred_ranking} =
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
          strategy_mod: strategy_mod
        }
      )

    {ranked_candidates, deferred_ranking, candidates}
  end

  defp build_hinted_fastest_cursor(
         snapshot,
         plan,
         method,
         opts,
         strategy_mod,
         %{route: {routing_instance_id, winner_transport}},
         {requested_transport, workload_key, filters, consensus_height}
       ) do
    matching_providers =
      Enum.filter(plan.providers, fn provider ->
        provider.routing_instance_id == routing_instance_id and
          winner_transport in transports_to_check(requested_transport) and
          winner_transport in provider.transports
      end)

    candidate_entries =
      case matching_providers do
        [provider] ->
          candidate_plan = %{plan | providers: [provider]}

          for candidate <-
                candidates_from_inputs(
                  candidate_plan,
                  filters,
                  consensus_height,
                  :deferred_fastest
                ),
              winner_transport in candidate.transports do
            {ranking_channel(plan, candidate, winner_transport), candidate, winner_transport}
          end

        _ambiguous_or_missing ->
          []
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
          {ranked, deferred, _candidates} =
            ranked_candidate_state(
              plan,
              method,
              timeout,
              strategy_mod,
              :fastest,
              workload_key,
              filters,
              consensus_height
            )

          {ranked, deferred}
        end

        deferred = %DeferredRanking{
          entries: [],
          scope: AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation),
          chain_id: plan.chain_id,
          workload_key: workload_key,
          resolver: resolver,
          excluded_routes: MapSet.new([{candidate.instance_id, transport}]),
          candidate_labels: if(limit > 0, do: ["#{candidate.id}:#{transport}"], else: [])
        }

        if selection_snapshot_current?(snapshot, [candidate]) do
          {:ok,
           CandidateCursor.new_ranked(
             snapshot,
             plan,
             method,
             opts,
             [{candidate, transport}],
             filters,
             consensus_height || :unavailable,
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

  defp fastest_winner(:fastest_winner, plan) do
    plan.profile
    |> AttemptProjection.scope_state(plan.chain_id, plan.generation)
    |> AttemptProjection.fastest_winner()
  end

  defp fastest_winner(:full, _plan), do: nil

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
         workload_key
       )
       when strategy in [:fastest, :priority, :load_balanced, :latency_weighted] do
    maybe_record_single_channel_degradation(channel, candidates, strategy, plan, workload_key)
    [channel]
  end

  defp order_capable_channels(channels, candidates, strategy, method, plan, timeout, workload_key) do
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

    tier_channels(ordered_channels, circuit_state_map, rate_limit_map)
  end

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
       when strategy in [:fastest, :priority, :load_balanced, :latency_weighted] do
    maybe_record_single_channel_degradation(channel, candidates, strategy, plan, workload_key)
    [channel]
  end

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
         strategy in [:fastest, :latency_weighted] do
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
           workload_key: :client,
           strategy_mod: Lasso.RPC.Strategies.Fastest = strategy_mod
         } = ranking
       ) do
    if Enum.any?(candidates, & &1.learned_feedback_degraded?) do
      {rank_channels_eager(channels, entries_by_key, ranking), nil}
    else
      scope = AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)
      now_us = System.monotonic_time(:microsecond)

      {qualified, remaining} =
        split_client_qualified(channels, entries_by_key, plan.chain_id, now_us)

      case qualified do
        [] ->
          {rank_cold_fastest_channels(
             remaining,
             entries_by_key,
             method,
             plan,
             timeout,
             strategy_mod,
             scope,
             now_us
           ), nil}

        _qualified ->
          summaries =
            Map.new(qualified, fn {channel, summary} ->
              {{channel.instance_id, channel.transport}, summary}
            end)

          prepared_ctx =
            strategy_mod.prepare_context(plan.profile, plan.chain_id, method, timeout)
            |> Map.put(:workload_key, :client)
            |> Map.put(:routing_summaries, summaries)
            |> Map.put(:provider_priorities, plan.provider_priorities)

          ranked =
            qualified
            |> Enum.map(&elem(&1, 0))
            |> strategy_mod.rank_channels(
              method,
              prepared_ctx,
              plan.profile,
              plan.chain_id
            )
            |> Enum.map(&Map.fetch!(entries_by_key, {&1.instance_id, &1.transport}))

          deferred = %DeferredRanking{
            entries:
              Enum.map(remaining, fn {channel, _summary} ->
                {candidate, transport} =
                  Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

                {channel, candidate, transport}
              end),
            scope: scope,
            chain_id: plan.chain_id,
            workload_key: :client
          }

          {ranked, deferred}
      end
    end
  end

  defp rank_candidate_channels(
         channels,
         entries_by_key,
         ranking
       ) do
    {rank_channels_eager(channels, entries_by_key, ranking), nil}
  end

  defp split_client_qualified(channels, entries_by_key, chain_id, now_us) do
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
          now_us
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
         scope,
         now_us
       ) do
    summaries =
      Map.new(channels_with_summaries, fn {channel, primary} ->
        {candidate, transport} =
          Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

        summary =
          AttemptProjection.complete_client_summary_bounded(
            scope,
            candidate_route_record(scope, candidate, transport),
            candidate.instance_id,
            candidate.routing_instance_id,
            transport,
            plan.chain_id,
            primary,
            now_us
          )

        {{channel.instance_id, transport}, summary}
      end)

    prepared_ctx =
      strategy_mod.prepare_context(plan.profile, plan.chain_id, method, timeout)
      |> Map.put(:workload_key, :client)
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
         %{transports: available_transports} = candidate,
         transport,
         plan,
         method
       ) do
    transport
    |> transports_to_check()
    |> Enum.filter(&(&1 in available_transports))
    |> Enum.flat_map(fn t ->
      fetch_channel(plan, candidate, t, method)
    end)
  end

  defp transports_to_check(:http), do: [:http]
  defp transports_to_check(:ws), do: [:ws]
  defp transports_to_check(_), do: [:http, :ws]

  defp fetch_channel(plan, candidate, transport, method) do
    case TransportRegistry.get_channel_from_plan(plan, candidate, transport, method) do
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
    workload_key = Keyword.get(opts, :workload_key, :client)

    requirements =
      RequestAnalysis.analyze(
        method,
        params,
        consensus_height: consensus_height,
        archival_threshold: plan.archival_threshold
      )

    filters =
      SelectionFilters.new(
        exclude: exclude,
        protocol: protocol,
        include_half_open: include_half_open,
        max_lag_blocks: plan.max_lag_blocks,
        min_block: requirements.requested_block,
        requires_archival: requirements.requires_archival,
        requires_subscribe_new_heads: requires_subscribe_new_heads,
        workload_key: workload_key
      )

    {filters, consensus_height || :unavailable}
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

  defp workload_for_origin(:system), do: :system
  defp workload_for_origin(_origin), do: :client
end
