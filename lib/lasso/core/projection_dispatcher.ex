defmodule Lasso.Core.ProjectionDispatcher do
  @moduledoc """
  Registry and lifecycle owner for isolated optional projection lanes.

  Enqueue, cancellation, and recovery use the named ETS registry directly and
  never synchronously call this process. Each configured sink class owns
  separate slots, workers, limits, counters, and failure behavior.
  """

  use GenServer

  alias Lasso.Core.ProjectionLane

  @sink_classes [
    :learned_feedback,
    :diagnostics,
    :analytics,
    :ui,
    :pubsub,
    :telemetry,
    :durable_audit
  ]

  defstruct [:name, :registry, lanes: %{}]

  @type sink_class ::
          :learned_feedback
          | :diagnostics
          | :analytics
          | :ui
          | :pubsub
          | :telemetry
          | :durable_audit

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    unless is_atom(name), do: raise(ArgumentError, "projection dispatcher name must be an atom")

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Enqueues an encoded payload without crossing a process boundary."
  @spec enqueue(atom(), sink_class(), ProjectionLane.scope(), binary()) ::
          ProjectionLane.enqueue_result()
  def enqueue(dispatcher, sink_class, scope, payload) when is_atom(dispatcher) do
    case lookup_lane(dispatcher, sink_class) do
      {:ok, metadata} -> ProjectionLane.enqueue(metadata, scope, payload)
      {:error, reason} -> {:drop, reason, :untracked}
    end
  end

  @doc "Encodes and enqueues a tagged canonical execution fact."
  @spec enqueue_fact(atom(), sink_class(), ProjectionLane.scope(), struct()) ::
          ProjectionLane.enqueue_result()
  def enqueue_fact(dispatcher, sink_class, scope, fact) when is_atom(dispatcher) do
    case lookup_lane(dispatcher, sink_class) do
      {:ok, metadata} -> ProjectionLane.enqueue_fact(metadata, scope, fact)
      {:error, reason} -> {:drop, reason, :untracked}
    end
  end

  @spec cancel(atom(), sink_class(), ProjectionLane.Token.t()) ::
          :cancelled | :delivering | :not_found | :unavailable
  def cancel(dispatcher, sink_class, token) when is_atom(dispatcher) do
    case lookup_lane(dispatcher, sink_class) do
      {:ok, metadata} -> ProjectionLane.cancel(metadata, token)
      _ -> :unavailable
    end
  end

  @spec recover(atom(), sink_class(), ProjectionLane.Degradation.t()) ::
          :recovered | :stale | :unavailable
  def recover(dispatcher, sink_class, degradation) when is_atom(dispatcher) do
    case lookup_lane(dispatcher, sink_class) do
      {:ok, metadata} -> ProjectionLane.recover(metadata, degradation)
      _ -> :unavailable
    end
  end

  @doc false
  @spec lane(GenServer.server(), sink_class()) :: {:ok, pid()} | {:error, :unknown_sink_class}
  def lane(dispatcher, sink_class), do: GenServer.call(dispatcher, {:lane, sink_class})

  @doc false
  @spec stats(GenServer.server(), sink_class()) :: map() | {:error, :unknown_sink_class}
  def stats(dispatcher, sink_class) do
    with {:ok, lane} <- lane(dispatcher, sink_class) do
      ProjectionLane.stats(lane)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)
    lane_configs = Keyword.fetch!(opts, :lanes)
    validate_lane_configs!(lane_configs)

    registry =
      :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])

    :ets.insert(registry, {:registry_state, :initializing})

    lanes =
      Map.new(lane_configs, fn {sink_class, lane_opts} ->
        {:ok, lane} = ProjectionLane.start_link(lane_opts)
        metadata = ProjectionLane.metadata(lane)
        :ets.insert(registry, {sink_class, lane, metadata})
        {sink_class, {lane, lane_opts}}
      end)

    :ets.insert(registry, {:registry_state, :ready})
    {:ok, %__MODULE__{name: name, registry: registry, lanes: lanes}}
  end

  @impl true
  def handle_call({:lane, sink_class}, _from, state) do
    reply =
      case Map.fetch(state.lanes, sink_class) do
        {:ok, {lane, _opts}} -> {:ok, lane}
        :error -> {:error, :unknown_sink_class}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(state.lanes, fn {_class, {lane, _opts}} -> lane == pid end) do
      {sink_class, {^pid, lane_opts}} ->
        {:ok, replacement} = ProjectionLane.start_link(lane_opts)
        metadata = ProjectionLane.metadata(replacement)
        :ets.insert(state.registry, {sink_class, replacement, metadata})
        {:noreply, put_in(state.lanes[sink_class], {replacement, lane_opts})}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.lanes, fn {_class, {lane, _opts}} ->
      if Process.alive?(lane), do: GenServer.stop(lane, :shutdown, 1_000)
    end)

    :ok
  end

  defp lookup_lane(dispatcher, sink_class) do
    case :ets.lookup(dispatcher, sink_class) do
      [{^sink_class, lane, metadata}] ->
        if Process.alive?(lane), do: {:ok, metadata}, else: {:error, :unavailable}

      [] ->
        case :ets.lookup(dispatcher, :registry_state) do
          [{:registry_state, :ready}] -> {:error, :unknown_sink_class}
          _ -> {:error, :unavailable}
        end
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp validate_lane_configs!(lane_configs) when is_list(lane_configs) do
    classes = Keyword.keys(lane_configs)

    if classes != Enum.uniq(classes),
      do: raise(ArgumentError, "projection sink classes must be unique")

    unless Enum.all?(classes, &(&1 in @sink_classes)),
      do: raise(ArgumentError, "unknown or critical projection sink class")

    :ok
  end
end
