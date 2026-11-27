defmodule Lasso.RPC.Selection.CandidateCursor do
  @moduledoc false

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Config.MethodConstraints
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.{CandidateListing, Catalog, InstanceState}

  alias Lasso.RPC.{
    AttemptProjection,
    Channel,
    ExecutionEnvelope,
    RequestAnalysis,
    RequestFacts,
    RoutingPlan,
    SelectionFilters,
    TransportRegistry
  }

  alias Lasso.RPC.ProviderKnowledge.{Decision, Effects, Evidence}
  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RoutingEvidence.Workload
  alias Lasso.RPC.Selection.{HeadSuitability, SiblingLast}
  alias Lasso.RPC.Strategies.LoadBalanced

  # Each availability tier scans its ordinary routes before the routes deferred
  # by head suitability or a learned effect.
  @queue_keys for tier <- 1..4, bucket <- [:ordinary, :deferred], do: {tier, bucket}
  @empty_queues Map.new(@queue_keys, &{&1, :queue.new()})

  @enforce_keys [
    :plan,
    :method,
    :filters,
    :head_snapshot,
    :learned_scope,
    :descriptors,
    :limit
  ]
  defstruct @enforce_keys ++
              [
                snapshot: nil,
                candidate_labels: [],
                channel_lookup: :open,
                deadline_us: nil,
                effect_context: %{},
                learning_decision: nil,
                request_facts: nil,
                shadow_proposals: [],
                deferred_routes: MapSet.new(),
                excluded_provider_ids: MapSet.new(),
                returned: 0,
                excluded_fallback: nil,
                diversity_seen: nil,
                diversity_ordered_tiers: MapSet.new(),
                supported?: false,
                supported_deferred: @empty_queues,
                unsupported_deferred: @empty_queues
              ]

  @type descriptor ::
          {RoutingPlan.provider(), :http | :ws}
          | {:ranked, map(), :http | :ws}
  @type t :: %__MODULE__{}

  @doc "Drains decisions once, including policy applications during lazy materialization."
  @spec take_learning_decisions(t()) :: {map() | list() | nil, t()}
  def take_learning_decisions(%__MODULE__{} = cursor),
    do: {cursor.learning_decision, %{cursor | learning_decision: nil}}

  @doc "Drains bounded shadow candidates from each materialized batch once."
  @spec take_shadow_proposals(t()) :: {list(), t()}
  def take_shadow_proposals(%__MODULE__{} = cursor),
    do: {cursor.shadow_proposals, %{cursor | shadow_proposals: []}}

  @doc "The head-suitability capture this cursor's selection phase used."
  @spec head_suitability(t()) :: HeadSuitability.t() | nil
  def head_suitability(%__MODULE__{effect_context: context}),
    do: Map.get(context, :head_suitability)

  @doc "Block facts and the head reference this cursor's selection phase used."
  @spec request_facts(t()) :: RequestFacts.t() | nil
  def request_facts(%__MODULE__{request_facts: facts}), do: facts

  @spec new(Catalog.snapshot(), RoutingPlan.t(), String.t(), keyword()) :: t()
  def new(snapshot, %RoutingPlan{} = plan, method, opts) do
    build(
      plan,
      method,
      opts,
      AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation)
    )
    |> Map.put(:snapshot, snapshot)
  end

  @doc "Builds a cursor over ranked candidates."
  @spec new_ranked(
          Catalog.snapshot(),
          RoutingPlan.t(),
          String.t(),
          keyword(),
          [
            {map(), :http | :ws}
          ],
          SelectionFilters.t(),
          HeadSnapshot.t() | :unavailable
        ) :: t()
  def new_ranked(
        snapshot,
        %RoutingPlan{} = plan,
        method,
        opts,
        ranked_candidates,
        %SelectionFilters{} = filters,
        head_snapshot
      )
      when is_list(ranked_candidates) and
             (is_struct(head_snapshot, HeadSnapshot) or head_snapshot == :unavailable) do
    descriptors =
      Enum.map(ranked_candidates, fn {candidate, transport} ->
        {:ranked, candidate, transport}
      end)

    limit = Keyword.get(opts, :limit, 1000)

    candidate_labels =
      descriptors
      |> Enum.take(max(limit, 0))
      |> Enum.map(&descriptor_label(plan.profile, &1))

    effect_context = effect_context(opts, method, plan, filters)

    {ordered, deferred_routes, decisions} =
      Effects.order_with_decision(descriptors, plan, method, effect_context)

    %__MODULE__{
      snapshot: snapshot,
      plan: plan,
      method: method,
      filters: filters,
      head_snapshot: head_snapshot,
      learned_scope: nil,
      effect_context: effect_context,
      learning_decision: decisions,
      request_facts: filters.request_facts,
      shadow_proposals:
        Effects.shadow_proposals(
          descriptors,
          plan,
          method,
          effect_context
        ),
      descriptors: ordered,
      deferred_routes: deferred_routes,
      limit: limit,
      deadline_us: Keyword.get(opts, :deadline_us),
      candidate_labels: candidate_labels,
      diversity_seen: diversity_seen(Keyword.get(opts, :strategy), method, opts)
    }
  end

  defp build(plan, method, opts, learned_scope) do
    transport = Keyword.get(opts, :transport, :both)
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    head_snapshot = head_snapshot(plan)

    filters =
      SelectionFilters.for_phase(plan, method, head_snapshot, opts,
        protocol: transport,
        exclude: Keyword.get(opts, :exclude, []),
        include_half_open: Keyword.get(opts, :include_half_open, true),
        requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
        workload_key: Workload.for_request(Keyword.get(opts, :request_origin, :client), method)
      )

    descriptors =
      if MethodConstraints.disallowed?(method) do
        []
      else
        build_descriptors(plan, strategy, transport, filters, learned_scope)
      end

    request_facts = filters.request_facts

    limit = Keyword.get(opts, :limit, 1000)
    effect_context = effect_context(opts, method, plan, filters)

    {ordered, deferred_routes, decisions} =
      Effects.order_with_decision(descriptors, plan, method, effect_context)

    %__MODULE__{
      plan: plan,
      method: method,
      filters: filters,
      head_snapshot: head_snapshot,
      learned_scope: learned_scope,
      request_facts: request_facts,
      effect_context: effect_context,
      learning_decision: decisions,
      shadow_proposals: Effects.shadow_proposals(descriptors, plan, method, effect_context),
      descriptors: ordered,
      deferred_routes: deferred_routes,
      limit: limit,
      deadline_us: Keyword.get(opts, :deadline_us),
      candidate_labels: [],
      diversity_seen: diversity_seen(strategy, method, opts)
    }
  end

  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{returned: returned, limit: limit}) when returned >= limit, do: false

  def pending?(%__MODULE__{} = cursor) do
    cursor.descriptors != [] or
      deferred_pending?(cursor.supported_deferred) or
      deferred_pending?(cursor.unsupported_deferred)
  end

  @doc "Explains static exclusions from the captured selection plan without probing providers."
  @spec exhaustion_reason(t()) :: atom()
  def exhaustion_reason(%__MODULE__{} = cursor) do
    providers =
      Enum.reject(cursor.plan.providers, &(&1.id in cursor.filters.exclude))

    transport_providers =
      Enum.filter(providers, fn provider ->
        Enum.any?(provider.transports, &(&1 in transports_to_check(cursor.filters.protocol)))
      end)

    cond do
      cursor.plan.providers == [] ->
        :no_providers_configured

      providers == [] ->
        :providers_excluded

      transport_providers == [] ->
        :transport_unavailable

      cursor.filters.requires_archival and
          Enum.all?(transport_providers, &(&1.archival == false)) ->
        :archive_required

      true ->
        :no_eligible_providers
    end
  end

  defp deferred_pending?(tiers),
    do: Enum.any?(tiers, fn {_tier, queue} -> not :queue.is_empty(queue) end)

  @doc "Returns the next channel or a terminal status for the captured catalog."
  @spec next(t()) :: {:ok, Channel.t(), t()} | :done | :stale
  def next(cursor) do
    case next_with_evidence(cursor) do
      {terminal, _remaining} when terminal in [:done, :stale] -> terminal
      selected -> selected
    end
  end

  @doc "Retains bounded rejection and learning evidence on terminal cursors."
  @spec next_with_evidence(t()) :: {:ok, Channel.t(), t()} | {:done | :stale, t()}
  def next_with_evidence(%__MODULE__{returned: returned, limit: limit} = cursor)
      when returned >= limit,
      do: {:done, cursor}

  def next_with_evidence(%__MODULE__{} = cursor) do
    if current?(cursor), do: scan(cursor), else: {:stale, cursor}
  end

  @doc "Assesses remaining cached channels without opening uncached routes."
  @spec next_cached(t()) :: {:ok, Channel.t(), t()} | {:done | :stale, t()}
  def next_cached(%__MODULE__{} = cursor),
    do: next_with_evidence(%{cursor | channel_lookup: :cached})

  defp current?(cursor), do: Catalog.snapshot() == cursor.snapshot

  @spec exclude_provider(t(), String.t()) :: t()
  def exclude_provider(%__MODULE__{} = cursor, provider_id) when is_binary(provider_id) do
    %{
      cursor
      | excluded_fallback:
          if(cursor.excluded_fallback && cursor.excluded_fallback.provider_id != provider_id,
            do: cursor.excluded_fallback
          ),
        descriptors:
          Enum.reject(cursor.descriptors, &(descriptor_provider_id(&1) == provider_id)),
        supported_deferred: reject_queued_provider(cursor.supported_deferred, provider_id),
        unsupported_deferred: reject_queued_provider(cursor.unsupported_deferred, provider_id),
        excluded_provider_ids: MapSet.put(cursor.excluded_provider_ids, provider_id)
    }
  end

  defp scan(%__MODULE__{descriptors: [descriptor | rest]} = cursor) do
    cursor = %{cursor | descriptors: rest}

    case materialize(cursor, descriptor) do
      {:ok, channel, tier, true} ->
        cursor = %{cursor | supported?: true, unsupported_deferred: @empty_queues}

        case {tier, bucket(cursor, descriptor)} do
          {1, :ordinary} = key ->
            if defer_alternate?(cursor, channel),
              do: cursor |> defer(:supported_deferred, key, channel) |> scan(),
              else: return(channel, cursor)

          key ->
            cursor |> defer(:supported_deferred, key, channel) |> scan()
        end

      {:ok, _channel, _tier, false} when cursor.supported? ->
        scan(cursor)

      {:ok, channel, tier, false} ->
        cursor
        |> defer(:unsupported_deferred, {tier, bucket(cursor, descriptor)}, channel)
        |> scan()

      {:skip, reason} ->
        case scan(cursor) do
          {:done, remaining} ->
            rejection = %{
              provider_id: descriptor_provider_id(descriptor),
              transport: descriptor_transport(descriptor),
              reason: reason
            }

            effect_context = remaining.effect_context

            rejections =
              Enum.take([rejection | Map.get(effect_context, :selection_rejections, [])], 32)

            effect_context =
              effect_context
              |> Map.put(:selection_rejections, rejections)
              |> Map.update(:selection_rejection_count, 1, &(&1 + 1))

            {:done, %{remaining | effect_context: effect_context}}

          selected ->
            selected
        end
    end
  end

  defp scan(%__MODULE__{supported?: true} = cursor),
    do: pop_deferred(cursor, :supported_deferred, @queue_keys)

  defp scan(%__MODULE__{} = cursor),
    do: pop_deferred(cursor, :unsupported_deferred, @queue_keys)

  defp diversity_seen(:load_balanced, method, opts) do
    if is_nil(Keyword.get(opts, :preferred_head_height)) and
         ExecutionEnvelope.classify(method) == :replay_safe,
       do: MapSet.new(Keyword.get(opts, :attempted_instances, []))
  end

  defp diversity_seen(_strategy, _method, _opts), do: nil

  # The historical age uses the same reference height that set the phase's
  # archival permission, so the two never disagree about an expiring head.
  defp effect_context(opts, method, plan, filters) do
    span =
      if method == "eth_getLogs" and Effects.mode(:span_limit, plan.profile) != :off,
        do: RequestAnalysis.analyze(method, Keyword.get(opts, :params, [])).block_range

    historical? = Effects.mode(:historical_depth, plan.profile) != :off
    facts = filters.request_facts && filters.request_facts.block_facts
    height = Lasso.RPC.RequestFacts.numeric_interval(facts)

    age =
      if historical? and is_integer(filters.reference_height) and
           not is_nil(height),
         do: filters.reference_height - elem(height, 0)

    %{
      partition: Workload.for_request(Keyword.get(opts, :request_origin, :client), method),
      span: span,
      historical_resource:
        if(historical?, do: (facts && facts.resource) || filters.historical_resource),
      historical_height: height,
      historical_age: age,
      request_shape:
        if(Effects.mode(:disproved_error, plan.profile) != :off,
          do:
            Evidence.request_shape(
              method,
              Keyword.get(opts, :params, []),
              filters.reference_height
            )
        ),
      head_suitability: Keyword.get(opts, :head_suitability, filters.head_suitability)
    }
  end

  defp bucket(cursor, descriptor) do
    if MapSet.member?(cursor.deferred_routes, Decision.route(descriptor)),
      do: :deferred,
      else: :ordinary
  end

  defp defer_alternate?(%{diversity_seen: nil}, _channel), do: false

  defp defer_alternate?(cursor, channel) do
    MapSet.member?(cursor.diversity_seen, channel.instance_id) and
      :queue.len(cursor.supported_deferred[{1, :ordinary}]) < cursor.limit - cursor.returned
  end

  defp order_deferred(%{diversity_seen: nil} = cursor, _field, _tier), do: cursor

  defp order_deferred(cursor, field, key) do
    ordered = {field, key}

    if MapSet.member?(cursor.diversity_ordered_tiers, ordered) do
      cursor
    else
      queues = Map.fetch!(cursor, field)

      channels =
        LoadBalanced.distinct_instances_first(:queue.to_list(queues[key]), cursor.diversity_seen)

      cursor
      |> Map.put(field, Map.put(queues, key, :queue.from_list(channels)))
      |> Map.put(:diversity_ordered_tiers, MapSet.put(cursor.diversity_ordered_tiers, ordered))
    end
  end

  # A route a learned refusal held back is the last resort: tried only once no
  # other candidate remains, while the request still has dispatch budget.
  defp pop_deferred(%{excluded_fallback: channel} = cursor, _field, [])
       when not is_nil(channel),
       do: {:ok, channel, %{cursor | returned: cursor.returned + 1, excluded_fallback: nil}}

  defp pop_deferred(cursor, _field, []), do: {:done, cursor}

  defp pop_deferred(cursor, field, [key | rest]) do
    cursor = order_deferred(cursor, field, key)
    cursor = order_refusal_queue(cursor, field, key)
    queues = Map.fetch!(cursor, field)

    case :queue.out(Map.fetch!(queues, key)) do
      {{:value, channel}, queue} ->
        return(channel, Map.put(cursor, field, Map.put(queues, key, queue)))

      {:empty, _queue} ->
        pop_deferred(cursor, field, rest)
    end
  end

  defp order_refusal_queue(%{effect_context: %{sibling_last: groups}} = cursor, field, key) do
    queues = Map.fetch!(cursor, field)

    queue =
      queues[key] |> :queue.to_list() |> order_siblings(groups, cursor) |> :queue.from_list()

    Map.put(cursor, field, Map.put(queues, key, queue))
  end

  defp order_refusal_queue(cursor, _field, _key), do: cursor

  defp return(channel, cursor) do
    provider = Enum.find(cursor.plan.providers, &(&1.instance_id == channel.instance_id))

    refused? =
      provider &&
        Effects.method_refused?(
          {provider, channel.transport},
          cursor.plan,
          cursor.method,
          cursor.effect_context
        )

    if refused? do
      scan(%{
        cursor
        | excluded_fallback: cursor.excluded_fallback || channel
      })
    else
      return_allowed(channel, cursor)
    end
  end

  @doc "Defers known-company siblings within each existing availability and knowledge band."
  @spec sibling_last(t(), [atom()]) :: t()
  def sibling_last(cursor, groups) do
    cursor = %{cursor | effect_context: Map.put(cursor.effect_context, :sibling_last, groups)}
    # An unresolved route is a barrier: only selection may open its channel.
    {entries, _unresolved?} =
      Enum.map_reduce(cursor.descriptors, false, fn descriptor, unresolved? ->
        band = if not unresolved?, do: cached_band(cursor, descriptor)
        {{descriptor, band}, unresolved? or is_nil(band)}
      end)

    # Other bands finish materialising into queues before the same rule is applied.
    band = {1, :ordinary, true}

    ordered =
      entries
      |> Enum.filter(&(elem(&1, 1) == band))
      |> Enum.map(&elem(&1, 0))
      |> order_descriptors(groups, cursor)

    {descriptors, []} =
      Enum.map_reduce(entries, ordered, fn
        {_descriptor, ^band}, [next | rest] -> {next, rest}
        {descriptor, _other}, remaining -> {descriptor, remaining}
      end)

    %{cursor | descriptors: descriptors}
  end

  defp cached_band(cursor, descriptor) do
    case materialize(%{cursor | channel_lookup: :cached}, descriptor) do
      {:ok, _channel, tier, supported?} -> {tier, bucket(cursor, descriptor), supported?}
      {:skip, _reason} -> nil
    end
  end

  defp order_descriptors(descriptors, groups, cursor) do
    SiblingLast.order(
      descriptors,
      groups,
      fn descriptor ->
        {provider, transport} =
          case descriptor do
            {provider, transport} -> {provider, transport}
            {:ranked, candidate, transport} -> {candidate, transport}
          end

        %{template_provider_config: provider.config, transport: transport}
      end,
      &head_class(cursor, &1)
    )
  end

  defp order_siblings(channels, groups, cursor),
    do: SiblingLast.order(channels, groups, & &1, &head_class(cursor, &1))

  defp head_class(cursor, route),
    do:
      elem(
        HeadSuitability.classify(cursor.effect_context.head_suitability, Decision.route(route)),
        0
      )

  defp return_allowed(channel, cursor) do
    if current?(cursor) do
      cursor = %{cursor | effect_context: Map.delete(cursor.effect_context, :sibling_last)}
      seen = cursor.diversity_seen && MapSet.put(cursor.diversity_seen, channel.instance_id)
      {:ok, channel, %{cursor | returned: cursor.returned + 1, diversity_seen: seen}}
    else
      {:stale, cursor}
    end
  end

  defp materialize(cursor, {provider, transport}) do
    filters = %{SelectionFilters.to_map(cursor.filters) | protocol: transport}

    case CandidateListing.routing_candidate_result_from_plan(
           cursor.plan,
           provider,
           filters,
           cursor.learned_scope
         ) do
      %{circuit_state: circuit_state, rate_limited: rate_limited} = candidate ->
        with {:ok, channel} <- channel(cursor, candidate, transport),
             tier when tier in 1..4 <-
               candidate_tier(
                 candidate.instance_id,
                 transport,
                 Map.fetch!(circuit_state, transport),
                 Map.fetch!(rate_limited, transport)
               ) do
          {:ok, channel, tier, AdapterFilter.method_supported?(channel, cursor.method)}
        else
          {:error, error} ->
            {:skip, channel_failure(error)}

          _unavailable ->
            {:skip,
             gate_failure(
               cursor.filters,
               Map.fetch!(circuit_state, transport),
               Map.fetch!(rate_limited, transport)
             )}
        end

      {:error, candidate} ->
        state = Map.get(candidate.circuit_state, transport)

        reason =
          cond do
            transport not in provider.transports ->
              :transport_not_configured

            transport == :ws and transport not in candidate.transports ->
              :ws_disconnected

            true ->
              gate_failure(cursor.filters, state, Map.get(candidate.rate_limited, transport))
          end

        {:skip, reason}
    end
  end

  defp materialize(cursor, {:ranked, candidate, transport}) do
    routing_state = ranked_routing_state(cursor, candidate, transport)

    {circuit_state, rate_limited?} =
      InstanceState.read_candidate_gate(
        candidate.instance_id,
        transport,
        routing_state,
        not candidate.learned_feedback_degraded?
      )

    with true <- gate_allowed?(cursor.filters, circuit_state, rate_limited?),
         tier when tier in 1..4 <-
           candidate_tier(candidate.instance_id, transport, circuit_state, rate_limited?),
         {:ok, channel} <- channel(cursor, candidate, transport) do
      {:ok, channel, tier, AdapterFilter.method_supported?(channel, cursor.method)}
    else
      false -> {:skip, gate_failure(cursor.filters, circuit_state, rate_limited?)}
      {:error, error} -> {:skip, channel_failure(error)}
      _unavailable -> {:skip, :circuit_unavailable}
    end
  end

  defp ranked_routing_state(cursor, candidate, transport) do
    case Map.fetch!(candidate.routing_states, transport) do
      nil ->
        scope =
          cursor.learned_scope ||
            AttemptProjection.scope_state(
              cursor.plan.profile,
              cursor.plan.chain_id,
              cursor.plan.generation
            )

        AttemptProjection.route_record_bounded(
          scope,
          candidate.routing_instance_id,
          transport
        )

      row ->
        row
    end
  end

  defp descriptor_transport({:ranked, _candidate, transport}), do: transport
  defp descriptor_transport({_provider, transport}), do: transport

  defp gate_failure(_filters, :unavailable, _), do: :circuit_unavailable
  defp gate_failure(_filters, :open, _), do: :circuit_open
  defp gate_failure(%{include_half_open: false}, :half_open, _), do: :half_open_excluded
  defp gate_failure(_filters, _state, true), do: :rate_limited
  defp gate_failure(_filters, _state, _), do: :candidate_filtered

  defp channel_failure(reason)
       when reason in [:registry_unavailable, :registry_timeout, :provider_not_found],
       do: reason

  defp channel_failure(_), do: :channel_lookup_failed

  defp channel(%{channel_lookup: :cached} = cursor, candidate, transport) do
    TransportRegistry.get_cached_channel_from_plan(
      cursor.plan,
      candidate,
      transport,
      cursor.method
    )
  end

  defp channel(cursor, candidate, transport) do
    TransportRegistry.get_channel_from_plan(
      cursor.plan,
      candidate,
      transport,
      cursor.method,
      cursor.deadline_us
    )
  end

  defp candidate_tier(instance_id, :http, :half_open, false) do
    case Snapshot.lookup({instance_id, :http}) do
      {:ok,
       %{opened_by_category: :connect_failure, control_health: :healthy, half_open_inflight: 0}} ->
        1

      _ ->
        2
    end
  end

  defp candidate_tier(_instance_id, _transport, state, limited?), do: tier(state, limited?)

  defp tier(:closed, false), do: 1
  defp tier(:half_open, false), do: 2
  defp tier(:closed, true), do: 3
  defp tier(:half_open, true), do: 4
  defp tier(_state, _limited?), do: nil

  defp gate_allowed?(filters, circuit_state, rate_limited?) do
    circuit_allowed? =
      circuit_state == :closed or
        (circuit_state == :half_open and filters.include_half_open)

    rate_limit_allowed? = not filters.exclude_rate_limited or not rate_limited?

    circuit_allowed? and rate_limit_allowed?
  end

  defp defer(cursor, field, key, channel) do
    queues = Map.fetch!(cursor, field)
    queue = :queue.in(channel, Map.fetch!(queues, key))
    Map.put(cursor, field, Map.put(queues, key, queue))
  end

  defp build_descriptors(plan, strategy, transport, filters, learned_scope) do
    exclude = MapSet.new(filters.exclude)
    transports = transports_to_check(transport)

    descriptors =
      for provider <- plan.providers,
          not MapSet.member?(exclude, provider.id),
          not filters.requires_archival or provider.archival != false,
          not filters.requires_subscribe_new_heads or
            if(Map.get(provider.config, :subscribe_new_heads, false),
              do: :ok,
              else: {:error, :subscription_unsupported}
            ) == :ok,
          protocol <- transports,
          protocol in provider.transports,
          do: {provider, protocol}

    case strategy do
      :priority ->
        Enum.sort_by(descriptors, fn {provider, protocol} ->
          {provider.priority, if(protocol == :http, do: 0, else: 1)}
        end)

      :load_balanced ->
        now_us = System.monotonic_time(:microsecond)
        deferral? = LoadBalanced.deferral?(plan.profile)

        LoadBalanced.order(
          descriptors,
          fn {provider, _transport} ->
            provider.instance_id || {plan.profile, plan.chain_id, provider.id}
          end,
          fn
            {provider, transport} when deferral? ->
              LoadBalanced.route_failure_rate(
                learned_scope,
                provider.instance_id,
                transport,
                filters.workload_key,
                now_us
              )

            _route ->
              nil
          end
        )
    end
  end

  defp head_snapshot(%RoutingPlan{} = plan) do
    case BlockSyncRegistry.get_head_snapshot(
           plan.head_scope,
           plan.generation,
           System.system_time(:millisecond)
         ) do
      {:ok, %HeadSnapshot{} = snapshot} -> snapshot
      {:error, _reason} -> :unavailable
    end
  end

  defp transports_to_check(:http), do: [:http]
  defp transports_to_check(:ws), do: [:ws]
  defp transports_to_check(_both), do: [:http, :ws]

  defp descriptor_provider_id({provider, _transport}), do: provider.id
  defp descriptor_provider_id({:ranked, candidate, _transport}), do: candidate.id

  defp descriptor_label(_profile, descriptor) do
    transport = elem(descriptor, tuple_size(descriptor) - 1)
    "#{descriptor_provider_id(descriptor)}:#{transport}"
  end

  defp reject_queued_provider(queues, provider_id) do
    Map.new(queues, fn {tier, queue} ->
      filtered = queue |> :queue.to_list() |> Enum.reject(&(&1.provider_id == provider_id))
      {tier, :queue.from_list(filtered)}
    end)
  end
end
