defmodule Lasso.RPC.Selection.CandidateCursor do
  @moduledoc false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{CandidateListing, Catalog}

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

  @type descriptor :: {RoutingPlan.provider(), :http | :ws}
  @type t :: %__MODULE__{}

  @spec new(Catalog.snapshot(), RoutingPlan.t(), String.t(), keyword()) :: t()
  def new(snapshot, %RoutingPlan{} = plan, method, opts) do
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

    descriptors = build_descriptors(plan, strategy, transport, filters)

    %__MODULE__{
      snapshot: snapshot,
      plan: plan,
      method: method,
      filters: filters,
      consensus_height: consensus_height,
      learned_scope: AttemptProjection.scope_state(plan.profile, plan.chain_id, plan.generation),
      descriptors: descriptors,
      limit: Keyword.get(opts, :limit, 1000)
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
          Enum.reject(cursor.descriptors, fn {provider, _transport} ->
            provider.id == provider_id
          end),
        supported_deferred: reject_queued_provider(cursor.supported_deferred, provider_id),
        unsupported_deferred: reject_queued_provider(cursor.unsupported_deferred, provider_id)
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

  defp channel(cursor, candidate, transport) do
    TransportRegistry.get_channel(
      cursor.plan.profile,
      cursor.plan.chain_id,
      candidate.id,
      transport,
      method: cursor.method,
      provider_config: candidate.config,
      instance_id: candidate.instance_id,
      route_generation: candidate.route_generation
    )
  end

  defp tier(circuit_state, rate_limited, transport) do
    case {Map.fetch!(circuit_state, transport), Map.fetch!(rate_limited, transport)} do
      {:closed, false} -> 1
      {:half_open, false} -> 2
      {:closed, true} -> 3
      {:half_open, true} -> 4
      _unavailable -> nil
    end
  end

  defp defer(cursor, field, tier, channel) do
    queues = Map.fetch!(cursor, field)
    queue = :queue.in(channel, Map.fetch!(queues, tier))
    Map.put(cursor, field, Map.put(queues, tier, queue))
  end

  defp build_descriptors(plan, strategy, transport, filters) do
    exclude = MapSet.new(filters.exclude)

    descriptors =
      plan.providers
      |> Enum.reject(&MapSet.member?(exclude, &1.id))
      |> Enum.filter(fn provider ->
        (not filters.requires_archival or provider.archival) and
          (not filters.requires_subscribe_new_heads or provider.subscribe_new_heads)
      end)
      |> Enum.flat_map(fn provider ->
        transport
        |> transports_to_check()
        |> Enum.filter(&(&1 in provider.transports))
        |> Enum.map(&{provider, &1})
      end)

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
