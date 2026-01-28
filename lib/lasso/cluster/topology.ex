defmodule Lasso.Cluster.Topology do
  @moduledoc """
  Authoritative source for cluster membership and node health.

  Tracks node lifecycle through explicit states:
  - **:connected**: Node has established Erlang distribution connection
  - **:discovering**: Node ID discovery in progress
  - **:responding**: Node responds to RPC health checks, node ID known
  - **:ready**: Responding AND application is fully started
  - **:unresponsive**: Connected but failing health checks
  - **:disconnected**: Previously connected, now down

  Publishes topology changes to PubSub for interested subscribers.
  Provides synchronous API for health endpoints and metrics queries.

  This is the ONLY module that subscribes to `:net_kernel.monitor_nodes/1`.
  All other modules receive node events via PubSub from Topology.

  ## Node Identity

  Each cluster node has a unique `node_id` (set via `LASSO_NODE_ID` env var) used for
  state partitioning. This is distinct from the Erlang node atom. Convention is to use
  geographic region names when deploying one node per region, but any unique string works.
  """

  use GenServer
  require Logger

  @topology_topic "cluster:topology"

  # Timing configuration
  @tick_interval_ms 500
  @health_check_interval_ms 15_000
  @reconcile_interval_ms 30_000
  @node_id_discovery_timeout_ms 2_000
  @node_id_discovery_max_retries 5
  @node_id_discovery_backoff_base_ms 200
  @node_id_rediscovery_interval_ms 60_000
  @health_check_timeout_ms 5_000
  @disconnected_node_cleanup_ms 24 * 60 * 60 * 1_000

  @type node_state ::
          :connected | :discovering | :responding | :ready | :unresponsive | :disconnected

  @type node_info :: %{
          node: node(),
          node_id: String.t(),
          state: node_state(),
          connected_at: integer() | nil,
          last_response: integer() | nil,
          consecutive_failures: non_neg_integer()
        }

  @type coverage :: %{
          expected: non_neg_integer(),
          connected: non_neg_integer(),
          responding: non_neg_integer(),
          unresponsive: [node()],
          disconnected: [node()]
        }

  defstruct nodes: %{},
            node_ids: %{},
            self_node_id: "unknown",
            health_check_task: nil,
            pending_discoveries: %{},
            discovery_refs: %{},
            last_tick: 0,
            last_health_check_start: 0,
            last_health_check_complete: 0,
            last_reconcile: 0,
            last_node_id_rediscovery: 0

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current cluster topology state.
  """
  @spec get_topology() :: %{
          nodes: [node_info()],
          node_ids: [String.t()],
          self_node: node(),
          self_node_id: String.t(),
          coverage: coverage()
        }
  def get_topology do
    GenServer.call(__MODULE__, :get_topology)
  end

  @doc """
  Returns coverage metrics with correct semantics.
  """
  @spec get_coverage() :: coverage()
  def get_coverage do
    GenServer.call(__MODULE__, :get_coverage)
  end

  @doc """
  Returns list of known node IDs in the cluster.
  """
  @spec get_node_ids() :: [String.t()]
  def get_node_ids do
    GenServer.call(__MODULE__, :get_node_ids)
  end

  @doc """
  Returns connected nodes for RPC operations.
  Consumers should use this instead of Node.list() directly.
  """
  @spec get_connected_nodes() :: [node()]
  def get_connected_nodes do
    GenServer.call(__MODULE__, :get_connected_nodes)
  end

  @doc """
  Returns responding nodes (healthy subset of connected).
  Use this for RPC operations that need high reliability.
  """
  @spec get_responding_nodes() :: [node()]
  def get_responding_nodes do
    GenServer.call(__MODULE__, :get_responding_nodes)
  end

  @doc """
  Returns the node ID for the current node.
  """
  @spec get_self_node_id() :: String.t()
  def get_self_node_id do
    GenServer.call(__MODULE__, :get_self_node_id)
  end

  @doc """
  Returns node info for a specific remote node, or nil if not tracked.
  """
  @spec get_node_info(node()) :: node_info() | nil
  def get_node_info(target_node) do
    GenServer.call(__MODULE__, {:get_node_info, target_node})
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    # Subscribe to node events - ONLY module that does this
    :net_kernel.monitor_nodes(true, node_type: :visible)

    self_node_id = Application.fetch_env!(:lasso, :node_id)

    # Initial node discovery
    initial_nodes = build_initial_node_map()

    # Start tick timer
    schedule_tick()

    # Trigger immediate health check
    send(self(), :immediate_health_check)

    state = %__MODULE__{
      self_node_id: self_node_id,
      nodes: initial_nodes,
      node_ids: compute_node_ids(initial_nodes, self_node_id),
      last_tick: now(),
      last_health_check_complete: now()
    }

    Logger.info(
      "[Topology] Started with #{map_size(initial_nodes)} nodes, node_id: #{self_node_id}"
    )

    {:ok, state}
  end

  # Tick handler - drives all periodic operations
  @impl true
  def handle_info(:tick, state) do
    now = now()

    state =
      state
      |> maybe_health_check(now)
      |> maybe_reconcile(now)
      |> maybe_rediscover_unknown_node_ids(now)
      |> cleanup_stale_disconnected_nodes(now)

    schedule_tick()
    {:noreply, %{state | last_tick: now}}
  end

  # Immediate health check on startup
  @impl true
  def handle_info(:immediate_health_check, state) do
    state = start_health_check(state)
    {:noreply, state}
  end

  # Node connected
  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("[Topology] Node connected: #{node}")

    node_info = %{
      node: node,
      node_id: "unknown",
      state: :discovering,
      connected_at: now(),
      last_response: nil,
      consecutive_failures: 0
    }

    nodes = Map.put(state.nodes, node, node_info)

    # Start async node ID discovery
    task = start_node_id_discovery(node)
    pending = Map.put(state.pending_discoveries, node, task)
    refs = Map.put(state.discovery_refs, task.ref, node)

    # Broadcast with coverage so dashboard updates immediately
    coverage = compute_coverage(nodes)

    broadcast_topology_event(%{
      event: :node_connected,
      node: node,
      node_info: node_info,
      coverage: coverage
    })

    emit_telemetry(:node_connected, %{node: node})

    {:noreply, %{state | nodes: nodes, pending_discoveries: pending, discovery_refs: refs}}
  end

  # Node disconnected
  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("[Topology] Node disconnected: #{node}")

    case Map.get(state.nodes, node) do
      nil ->
        {:noreply, state}

      node_info ->
        updated_info = %{node_info | state: :disconnected}
        nodes = Map.put(state.nodes, node, updated_info)
        node_ids = compute_node_ids(nodes, state.self_node_id)
        {pending, refs} = cancel_discovery(state.pending_discoveries, state.discovery_refs, node)

        coverage = compute_coverage(nodes)

        broadcast_topology_event(%{
          event: :node_disconnected,
          node: node,
          node_info: updated_info,
          coverage: coverage
        })

        emit_telemetry(:node_disconnected, %{node: node})

        {:noreply,
         %{
           state
           | nodes: nodes,
             node_ids: node_ids,
             pending_discoveries: pending,
             discovery_refs: refs
         }}
    end
  end

  # Node ID discovery completed successfully
  @impl true
  def handle_info({ref, {:node_id_discovered, node, node_id}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      case Map.get(state.nodes, node) do
        nil ->
          state

        node_info ->
          new_state = if node_info.state == :discovering, do: :connected, else: node_info.state
          updated_info = %{node_info | node_id: node_id, state: new_state}
          nodes = Map.put(state.nodes, node, updated_info)
          node_ids = compute_node_ids(nodes, state.self_node_id)

          broadcast_topology_event(%{
            event: :node_id_discovered,
            node: node,
            node_info: updated_info
          })

          emit_telemetry(:node_id_discovered, %{node: node, node_id: node_id})

          Logger.debug("[Topology] Node ID discovered for #{node}: #{node_id}")

          %{state | nodes: nodes, node_ids: node_ids}
      end

    pending = Map.delete(state.pending_discoveries, node)
    refs = Map.delete(state.discovery_refs, ref)
    {:noreply, %{state | pending_discoveries: pending, discovery_refs: refs}}
  end

  # Node ID discovery failed
  @impl true
  def handle_info({ref, {:node_id_discovery_failed, node, reason}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[Topology] Node ID discovery failed for #{node}: #{inspect(reason)}")

    emit_telemetry(:node_id_discovery_failed, %{node: node, reason: reason})

    state =
      case Map.get(state.nodes, node) do
        %{state: :discovering} = info ->
          nodes = Map.put(state.nodes, node, %{info | state: :connected})
          %{state | nodes: nodes}

        _ ->
          state
      end

    pending = Map.delete(state.pending_discoveries, node)
    refs = Map.delete(state.discovery_refs, ref)
    {:noreply, %{state | pending_discoveries: pending, discovery_refs: refs}}
  end

  # Health check completed
  @impl true
  def handle_info({ref, {:health_check_complete, node_list, results, bad_nodes}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    now = now()

    # Properly correlate results with nodes by zipping (node_list was captured at RPC call time)
    all_bad =
      Enum.zip(node_list, results)
      |> Enum.flat_map(fn
        {node, {:badrpc, _}} -> [node]
        _ -> []
      end)
      |> Kernel.++(bad_nodes)
      |> MapSet.new()

    old_nodes = state.nodes

    nodes =
      state.nodes
      |> Enum.map(fn {node, info} ->
        cond do
          info.state == :disconnected ->
            {node, info}

          MapSet.member?(all_bad, node) ->
            failures = info.consecutive_failures + 1
            new_state = if failures >= 3, do: :unresponsive, else: info.state
            {node, %{info | consecutive_failures: failures, state: new_state}}

          info.state in [:connected, :discovering, :unresponsive] ->
            {node, %{info | state: :responding, last_response: now, consecutive_failures: 0}}

          true ->
            {node, %{info | last_response: now, consecutive_failures: 0}}
        end
      end)
      |> Map.new()

    broadcast_health_update(old_nodes, nodes)

    emit_telemetry(:health_check_complete, %{
      total: map_size(nodes),
      bad_count: MapSet.size(all_bad)
    })

    {:noreply, %{state | nodes: nodes, health_check_task: nil, last_health_check_complete: now}}
  end

  # Health check timed out
  @impl true
  def handle_info({ref, {:health_check_timeout}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[Topology] Health check timeout")

    emit_telemetry(:health_check_timeout, %{})

    {:noreply, %{state | health_check_task: nil, last_health_check_complete: now()}}
  end

  # Task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      state.health_check_task && state.health_check_task.ref == ref ->
        Logger.warning("[Topology] Health check task crashed: #{inspect(reason)}")
        {:noreply, %{state | health_check_task: nil, last_health_check_complete: now()}}

      Map.has_key?(state.discovery_refs, ref) ->
        node = Map.get(state.discovery_refs, ref)
        Logger.warning("[Topology] Discovery task crashed for #{node}: #{inspect(reason)}")
        pending = Map.delete(state.pending_discoveries, node)
        refs = Map.delete(state.discovery_refs, ref)

        nodes =
          case Map.get(state.nodes, node) do
            %{state: :discovering} = info ->
              Map.put(state.nodes, node, %{info | state: :connected})

            _ ->
              state.nodes
          end

        {:noreply, %{state | pending_discoveries: pending, discovery_refs: refs, nodes: nodes}}

      true ->
        {:noreply, state}
    end
  end

  # Call handlers
  @impl true
  def handle_call(:get_topology, _from, state) do
    result = %{
      nodes: Map.values(state.nodes),
      node_ids: Map.keys(state.node_ids),
      self_node: node(),
      self_node_id: state.self_node_id,
      coverage: compute_coverage(state.nodes)
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_coverage, _from, state) do
    {:reply, compute_coverage(state.nodes), state}
  end

  @impl true
  def handle_call(:get_node_ids, _from, state) do
    {:reply, Map.keys(state.node_ids), state}
  end

  @impl true
  def handle_call(:get_connected_nodes, _from, state) do
    {:reply, get_connected_nodes_internal(state), state}
  end

  @impl true
  def handle_call(:get_responding_nodes, _from, state) do
    responding =
      state.nodes
      |> Enum.filter(fn {_node, info} -> info.state in [:responding, :ready] end)
      |> Enum.map(fn {node, _} -> node end)

    {:reply, responding, state}
  end

  @impl true
  def handle_call(:get_self_node_id, _from, state) do
    {:reply, state.self_node_id, state}
  end

  @impl true
  def handle_call({:get_node_info, target_node}, _from, state) do
    {:reply, Map.get(state.nodes, target_node), state}
  end

  # Private helpers

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp maybe_health_check(state, now) do
    time_elapsed = now - state.last_health_check_complete >= @health_check_interval_ms
    no_task_running = is_nil(state.health_check_task)

    if time_elapsed and no_task_running do
      start_health_check(%{state | last_health_check_start: now})
    else
      state
    end
  end

  defp maybe_reconcile(state, now) do
    if now - state.last_reconcile >= @reconcile_interval_ms do
      reconcile_with_node_list(%{state | last_reconcile: now})
    else
      state
    end
  end

  defp maybe_rediscover_unknown_node_ids(state, now) do
    if now - state.last_node_id_rediscovery < @node_id_rediscovery_interval_ms do
      state
    else
      unknown_nodes =
        state.nodes
        |> Enum.filter(fn {node, info} ->
          info.node_id == "unknown" and
            info.state in [:connected, :responding, :ready] and
            not Map.has_key?(state.pending_discoveries, node)
        end)
        |> Enum.map(fn {node, _} -> node end)

      state = %{state | last_node_id_rediscovery: now}

      if unknown_nodes == [] do
        state
      else
        Logger.debug("[Topology] Retrying node ID discovery for #{length(unknown_nodes)} nodes")

        Enum.reduce(unknown_nodes, state, fn node, acc ->
          task = start_node_id_discovery(node)
          pending = Map.put(acc.pending_discoveries, node, task)
          refs = Map.put(acc.discovery_refs, task.ref, node)
          nodes = Map.update!(acc.nodes, node, fn info -> %{info | state: :discovering} end)
          %{acc | pending_discoveries: pending, discovery_refs: refs, nodes: nodes}
        end)
      end
    end
  end

  defp cleanup_stale_disconnected_nodes(state, now) do
    cutoff = now - @disconnected_node_cleanup_ms

    stale_nodes =
      state.nodes
      |> Enum.filter(fn {_node, info} ->
        info.state == :disconnected and (info.connected_at || 0) < cutoff
      end)
      |> Enum.map(fn {node, _} -> node end)

    if stale_nodes == [] do
      state
    else
      Logger.info("[Topology] Removing #{length(stale_nodes)} stale disconnected nodes")

      nodes = Map.drop(state.nodes, stale_nodes)

      node_ids =
        Enum.reduce(stale_nodes, state.node_ids, fn node, acc ->
          case Map.get(state.nodes, node) do
            %{node_id: nid} when nid != "unknown" ->
              Map.update(acc, nid, [], &List.delete(&1, node))

            _ ->
              acc
          end
        end)
        |> Enum.reject(fn {_node_id, nodes} -> nodes == [] end)
        |> Map.new()

      %{state | nodes: nodes, node_ids: node_ids}
    end
  end

  defp start_health_check(state) do
    node_list = get_connected_nodes_internal(state)

    if node_list == [] do
      %{state | last_health_check_complete: now()}
    else
      task =
        Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
          {results, bad_nodes} =
            :rpc.multicall(node_list, Node, :self, [], @health_check_timeout_ms)

          {:health_check_complete, node_list, results, bad_nodes}
        end)

      %{state | health_check_task: task}
    end
  end

  defp reconcile_with_node_list(state) do
    actual_nodes = MapSet.new(Node.list())

    tracked_connected =
      state.nodes
      |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
      |> Enum.map(fn {node, _} -> node end)
      |> MapSet.new()

    missing_from_tracking = MapSet.difference(actual_nodes, tracked_connected)
    extra_in_tracking = MapSet.difference(tracked_connected, actual_nodes)

    for node <- missing_from_tracking do
      Logger.warning("[Topology] Reconciliation: discovered untracked node #{node}")
      send(self(), {:nodeup, node, []})
    end

    for node <- extra_in_tracking do
      Logger.warning("[Topology] Reconciliation: node #{node} no longer in Node.list()")
      send(self(), {:nodedown, node, []})
    end

    state
  end

  defp start_node_id_discovery(node) do
    Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
      discover_node_id_with_retry(node, @node_id_discovery_max_retries)
    end)
  end

  defp discover_node_id_with_retry(node, retries, delay \\ @node_id_discovery_backoff_base_ms)

  defp discover_node_id_with_retry(node, 0, _delay) do
    {:node_id_discovery_failed, node, :max_retries}
  end

  defp discover_node_id_with_retry(node, retries, delay) do
    # Small delay before first attempt (node may not be fully ready)
    if retries == @node_id_discovery_max_retries, do: Process.sleep(100)

    case :rpc.call(
           node,
           Application,
           :get_env,
           [:lasso, :node_id],
           @node_id_discovery_timeout_ms
         ) do
      node_id when is_binary(node_id) ->
        {:node_id_discovered, node, node_id}

      {:badrpc, _reason} ->
        Process.sleep(delay)
        discover_node_id_with_retry(node, retries - 1, min(delay * 2, 2000))

      nil ->
        # Remote node has no node_id configured; extract hostname as fallback
        node_id =
          node
          |> Atom.to_string()
          |> String.split("@")
          |> List.last()
          |> case do
            nil -> "unknown"
            "" -> "unknown"
            id -> id
          end

        {:node_id_discovered, node, node_id}
    end
  end

  defp cancel_discovery(pending_discoveries, discovery_refs, node) do
    case Map.get(pending_discoveries, node) do
      nil ->
        {pending_discoveries, discovery_refs}

      task ->
        Task.shutdown(task, :brutal_kill)
        {Map.delete(pending_discoveries, node), Map.delete(discovery_refs, task.ref)}
    end
  end

  defp build_initial_node_map do
    Node.list()
    |> Enum.map(fn node ->
      {node,
       %{
         node: node,
         node_id: "unknown",
         state: :connected,
         connected_at: now(),
         last_response: nil,
         consecutive_failures: 0
       }}
    end)
    |> Map.new()
  end

  defp compute_node_ids(nodes, self_node_id) do
    nodes
    |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
    |> Enum.group_by(fn {_node, info} -> info.node_id end, fn {node, _} -> node end)
    |> Map.put_new(self_node_id, [])
  end

  defp compute_coverage(nodes) do
    {connected, responding, unresponsive, disconnected} =
      nodes
      |> Map.values()
      |> Enum.reduce({0, 0, [], []}, fn info, {conn, resp, unr, disc} ->
        case info.state do
          :disconnected -> {conn, resp, unr, [info.node | disc]}
          :unresponsive -> {conn + 1, resp, [info.node | unr], disc}
          state when state in [:responding, :ready] -> {conn + 1, resp + 1, unr, disc}
          _ -> {conn + 1, resp, unr, disc}
        end
      end)

    %{
      expected: connected + 1,
      connected: connected + 1,
      responding: responding + 1,
      unresponsive: unresponsive,
      disconnected: disconnected
    }
  end

  defp get_connected_nodes_internal(state) do
    state.nodes
    |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
    |> Enum.map(fn {node, _} -> node end)
  end

  defp broadcast_topology_event(payload) when is_map(payload) do
    Phoenix.PubSub.broadcast(Lasso.PubSub, @topology_topic, {:topology_event, payload})
  end

  defp broadcast_health_update(old_nodes, new_nodes) do
    changes =
      new_nodes
      |> Enum.filter(fn {node, new_info} ->
        case Map.get(old_nodes, node) do
          nil -> true
          old_info -> old_info.state != new_info.state
        end
      end)
      |> Enum.map(fn {node, info} -> %{node: node, info: info} end)

    unless changes == [] do
      coverage = compute_coverage(new_nodes)

      broadcast_topology_event(%{
        event: :health_update,
        changes: changes,
        coverage: coverage
      })
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:lasso, :cluster, :topology, event],
      %{count: 1},
      metadata
    )
  end

  defp now do
    System.monotonic_time(:millisecond)
  end
end
