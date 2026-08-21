defmodule Lasso.RPC.Selection.CandidateCursor do
  @moduledoc false

  defmodule DeferredRanking do
    @moduledoc false

    @enforce_keys [:entries, :scope, :chain_id, :workload_key]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            entries: [{Lasso.RPC.Channel.t(), map(), :http | :ws}],
            scope: map(),
            chain_id: pos_integer(),
            workload_key: atom()
          }
  end

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{CandidateListing, Catalog, InstanceState}

  alias Lasso.RPC.{
    AttemptProjection,
    Channel,
    RequestAnalysis,
    RoutingPlan,
    SelectionFilters,
    TransportRegistry
  }

  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RoutingEvidence.Workload
  alias Lasso.RPC.Strategies.Fastest

  @enforce_keys [
    :snapshot,
    :plan,
    :method,
    :filters,
    :consensus_height,
    :learned_scope,
    :descriptors,
    :limit
  ]
  defstruct @enforce_keys ++
              [
                candidate_labels: [],
                deferred_ranking: nil,
                returned: 0,
                supported?: false,
                supported_deferred: %{2 => :queue.new(), 3 => :queue.new(), 4 => :queue.new()},
                unsupported_deferred: %{
                  1 => :queue.new(),
                  2 => :queue.new(),
                  3 => :queue.new(),
                  4 => :queue.new()
                }
              ]

  @type descriptor ::
          {RoutingPlan.provider(), :http | :ws}
          | {:ranked, map(), :http | :ws}
  @type t :: %__MODULE__{}

  @spec new(Catalog.snapshot(), RoutingPlan.t(), String.t(), keyword()) :: t()
  def new(snapshot, %RoutingPlan{} = plan, method, opts) do
    build(
      snapshot,
      plan,
      method,
      opts,
      &build_descriptors/4,
      fn -> AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation) end
    )
  end

  @doc false
  @spec new_ranked(
          Catalog.snapshot(),
          RoutingPlan.t(),
          String.t(),
          keyword(),
          [
            {map(), :http | :ws}
          ],
          SelectionFilters.t(),
          non_neg_integer() | :unavailable,
          DeferredRanking.t() | nil
        ) :: t()
  def new_ranked(
        snapshot,
        %RoutingPlan{} = plan,
        method,
        opts,
        ranked_candidates,
        %SelectionFilters{} = filters,
        consensus_height,
        deferred_ranking \\ nil
      )
      when is_list(ranked_candidates) and
             (is_integer(consensus_height) or consensus_height == :unavailable) do
    descriptors =
      Enum.map(ranked_candidates, fn {candidate, transport} ->
        {:ranked, candidate, transport}
      end)

    limit = Keyword.get(opts, :limit, 1000)

    candidate_labels =
      descriptors
      |> Kernel.++(deferred_descriptors(deferred_ranking))
      |> Enum.take(max(limit, 0))
      |> Enum.map(&descriptor_label/1)

    %__MODULE__{
      snapshot: snapshot,
      plan: plan,
      method: method,
      filters: filters,
      consensus_height: consensus_height,
      learned_scope: nil,
      descriptors: descriptors,
      deferred_ranking: deferred_ranking,
      limit: limit,
      candidate_labels: candidate_labels
    }
  end

  defp build(
         snapshot,
         plan,
         method,
         opts,
         descriptors_fun,
         learned_scope_fun
       ) do
    transport = Keyword.get(opts, :transport, :both)
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    consensus_height = consensus_height(plan.chain_id)

    requirements =
      RequestAnalysis.analyze(
        method,
        Keyword.get(opts, :params, []),
        consensus_height: unavailable_to_nil(consensus_height),
        archival_threshold: plan.archival_threshold
      )

    filters =
      SelectionFilters.new(
        protocol: nil,
        exclude: Keyword.get(opts, :exclude, []),
        include_half_open: Keyword.get(opts, :include_half_open, true),
        max_lag_blocks: plan.max_lag_blocks,
        min_block: requirements.requested_block,
        requires_archival: requirements.requires_archival,
        requires_subscribe_new_heads: Keyword.get(opts, :requires_subscribe_new_heads, false),
        workload_key: workload_for_origin(Keyword.get(opts, :request_origin, :client))
      )

    descriptors = descriptors_fun.(plan, strategy, transport, filters)
    limit = Keyword.get(opts, :limit, 1000)

    %__MODULE__{
      snapshot: snapshot,
      plan: plan,
      method: method,
      filters: filters,
      consensus_height: consensus_height,
      learned_scope: learned_scope_fun.(),
      descriptors: descriptors,
      limit: limit,
      candidate_labels: []
    }
  end

  @spec next(t()) :: {:ok, Channel.t(), t()} | :done | :stale
  def next(%__MODULE__{returned: returned, limit: limit}) when returned >= limit, do: :done

  def next(%__MODULE__{} = cursor) do
    if current?(cursor) do
      scan(cursor)
    else
      :stale
    end
  end

  @spec exclude_provider(t(), String.t()) :: t()
  def exclude_provider(%__MODULE__{} = cursor, provider_id) when is_binary(provider_id) do
    %{
      cursor
      | descriptors:
          Enum.reject(cursor.descriptors, &(descriptor_provider_id(&1) == provider_id)),
        supported_deferred: reject_queued_provider(cursor.supported_deferred, provider_id),
        unsupported_deferred: reject_queued_provider(cursor.unsupported_deferred, provider_id),
        deferred_ranking: reject_deferred_provider(cursor.deferred_ranking, provider_id)
    }
  end

  defp scan(%__MODULE__{descriptors: [descriptor | rest]} = cursor) do
    cursor = %{cursor | descriptors: rest}

    case materialize(cursor, descriptor) do
      {:ok, channel, tier, true} when tier == 1 ->
        return(channel, %{cursor | supported?: true, unsupported_deferred: empty_unsupported()})

      {:ok, channel, tier, true} ->
        cursor
        |> defer(:supported_deferred, tier, channel)
        |> Map.put(:supported?, true)
        |> Map.put(:unsupported_deferred, empty_unsupported())
        |> scan()

      {:ok, _channel, _tier, false} when cursor.supported? ->
        scan(cursor)

      {:ok, channel, tier, false} ->
        cursor |> defer(:unsupported_deferred, tier, channel) |> scan()

      :skip ->
        scan(cursor)
    end
  end

  defp scan(
         %__MODULE__{descriptors: [], deferred_ranking: %DeferredRanking{} = deferred} = cursor
       ) do
    if current?(cursor) do
      descriptors = rank_deferred(deferred)
      scan(%{cursor | descriptors: descriptors, deferred_ranking: nil})
    else
      :stale
    end
  end

  defp scan(%__MODULE__{supported?: true} = cursor),
    do: pop_deferred(cursor, :supported_deferred, [2, 3, 4])

  defp scan(%__MODULE__{} = cursor),
    do: pop_deferred(cursor, :unsupported_deferred, [1, 2, 3, 4])

  defp pop_deferred(cursor, _field, []), do: if(current?(cursor), do: :done, else: :stale)

  defp pop_deferred(cursor, field, [tier | rest]) do
    queues = Map.fetch!(cursor, field)

    case :queue.out(Map.fetch!(queues, tier)) do
      {{:value, channel}, queue} ->
        return(channel, Map.put(cursor, field, Map.put(queues, tier, queue)))

      {:empty, _queue} ->
        pop_deferred(cursor, field, rest)
    end
  end

  defp return(channel, cursor) do
    if current?(cursor) do
      {:ok, channel, %{cursor | returned: cursor.returned + 1}}
    else
      :stale
    end
  end

  defp materialize(cursor, {provider, transport}) do
    filters = %{SelectionFilters.to_map(cursor.filters) | protocol: transport}

    case CandidateListing.routing_candidate_from_plan(
           cursor.plan,
           provider,
           filters,
           cursor.consensus_height,
           cursor.learned_scope
         ) do
      %{circuit_state: circuit_state, rate_limited: rate_limited} = candidate ->
        with {:ok, channel} <- channel(cursor, candidate, transport),
             tier when tier in 1..4 <- tier(circuit_state, rate_limited, transport) do
          {:ok, channel, tier, AdapterFilter.method_supported?(channel, cursor.method)}
        else
          _unavailable -> :skip
        end

      nil ->
        :skip
    end
  end

  defp materialize(cursor, {:ranked, candidate, transport}) do
    routing_state = Map.fetch!(candidate.routing_states, transport)

    {circuit_state, rate_limited?} =
      InstanceState.read_candidate_gate(
        candidate.instance_id,
        transport,
        routing_state,
        not candidate.learned_feedback_degraded?
      )

    with true <- gate_allowed?(cursor.filters, circuit_state, rate_limited?),
         tier when tier in 1..4 <- tier(circuit_state, rate_limited?),
         {:ok, channel} <- channel(cursor, candidate, transport) do
      {:ok, channel, tier, AdapterFilter.method_supported?(channel, cursor.method)}
    else
      _unavailable -> :skip
    end
  end

  defp channel(cursor, candidate, transport) do
    TransportRegistry.get_channel_from_plan(cursor.plan, candidate, transport, cursor.method)
  end

  defp tier(circuit_state, rate_limited, transport) do
    case {Map.fetch!(circuit_state, transport), Map.fetch!(rate_limited, transport)} do
      {state, limited?} -> tier(state, limited?)
    end
  end

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

  defp defer(cursor, field, tier, channel) do
    queues = Map.fetch!(cursor, field)
    queue = :queue.in(channel, Map.fetch!(queues, tier))
    Map.put(cursor, field, Map.put(queues, tier, queue))
  end

  defp build_descriptors(plan, strategy, transport, filters) do
    exclude = MapSet.new(filters.exclude)
    transports = transports_to_check(transport)

    descriptors =
      for provider <- plan.providers,
          not MapSet.member?(exclude, provider.id),
          not filters.requires_archival or provider.archival,
          not filters.requires_subscribe_new_heads or provider.subscribe_new_heads,
          protocol <- transports,
          protocol in provider.transports,
          do: {provider, protocol}

    case strategy do
      :priority ->
        Enum.sort_by(descriptors, fn {provider, protocol} ->
          {provider.priority, if(protocol == :http, do: 0, else: 1)}
        end)

      :load_balanced ->
        Enum.shuffle(descriptors)
    end
  end

  defp current?(cursor) do
    Catalog.snapshot() == cursor.snapshot and
      ConfigStore.route_generation() == cursor.snapshot.generation
  end

  defp consensus_height(chain_id) do
    case Lasso.RPC.ChainState.consensus_height(chain_id) do
      {:ok, height} -> height
      {:error, _reason} -> :unavailable
    end
  end

  defp unavailable_to_nil(:unavailable), do: nil
  defp unavailable_to_nil(height), do: height

  defp transports_to_check(:http), do: [:http]
  defp transports_to_check(:ws), do: [:ws]
  defp transports_to_check(_both), do: [:http, :ws]

  defp workload_for_origin(:system), do: Workload.normalize(:system)
  defp workload_for_origin(_origin), do: Workload.normalize(:client)

  defp descriptor_provider_id({provider, _transport}), do: provider.id
  defp descriptor_provider_id({:ranked, candidate, _transport}), do: candidate.id

  defp descriptor_label(descriptor) do
    transport = elem(descriptor, tuple_size(descriptor) - 1)
    "#{descriptor_provider_id(descriptor)}:#{transport}"
  end

  defp deferred_descriptors(%DeferredRanking{entries: entries}) do
    Enum.map(entries, fn {_channel, candidate, transport} ->
      {:ranked, candidate, transport}
    end)
  end

  defp deferred_descriptors(_deferred), do: []

  defp reject_deferred_provider(%DeferredRanking{entries: entries} = deferred, provider_id) do
    filtered =
      Enum.reject(entries, fn {_channel, candidate, _transport} -> candidate.id == provider_id end)

    %{deferred | entries: filtered}
  end

  defp reject_deferred_provider(_deferred, _provider_id), do: nil

  defp rank_deferred(%DeferredRanking{
         entries: entries,
         scope: scope,
         chain_id: chain_id,
         workload_key: workload_key
       }) do
    summaries =
      Map.new(entries, fn {channel, candidate, transport} ->
        row = Map.get(candidate.routing_states, transport)

        summary =
          AttemptProjection.summarize_route_bounded(
            scope,
            row,
            candidate.instance_id,
            candidate.routing_instance_id,
            transport,
            chain_id,
            workload_key
          )

        {{channel.instance_id, transport}, summary}
      end)

    entries_by_key =
      Map.new(entries, fn {channel, candidate, transport} ->
        {{channel.instance_id, transport}, {candidate, transport}}
      end)

    entries
    |> Enum.map(&elem(&1, 0))
    |> Fastest.rank_unqualified(summaries)
    |> Enum.map(fn channel ->
      {candidate, transport} =
        Map.fetch!(entries_by_key, {channel.instance_id, channel.transport})

      {:ranked, candidate, transport}
    end)
  end

  defp empty_unsupported do
    %{1 => :queue.new(), 2 => :queue.new(), 3 => :queue.new(), 4 => :queue.new()}
  end

  defp reject_queued_provider(queues, provider_id) do
    Map.new(queues, fn {tier, queue} ->
      filtered = queue |> :queue.to_list() |> Enum.reject(&(&1.provider_id == provider_id))
      {tier, :queue.from_list(filtered)}
    end)
  end
end
