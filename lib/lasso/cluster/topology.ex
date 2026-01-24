defmodule Lasso.Cluster.Topology do
  @moduledoc """
  Authoritative source for cluster membership and node health.

  Tracks node lifecycle through explicit states:
  - **:connected**: Node has established Erlang distribution connection
  - **:discovering**: Region discovery in progress
  - **:responding**: Node responds to RPC health checks, region known
  - **:ready**: Responding AND application is fully started
  - **:unresponsive**: Connected but failing health checks
  - **:disconnected**: Previously connected, now down

  Publishes topology changes to PubSub for interested subscribers.
  Provides synchronous API for health endpoints and metrics queries.

  This is the ONLY module that subscribes to `:net_kernel.monitor_nodes/1`.
  All other modules receive node events via PubSub from Topology.
  """

  use GenServer
  require Logger

  @topology_topic "cluster:topology"

  # Timing configuration
  @tick_interval_ms 500
  @health_check_interval_ms 15_000
  @reconcile_interval_ms 30_000
  @region_discovery_timeout_ms 2_000
  @region_discovery_max_retries 5
  @region_discovery_backoff_base_ms 200
  @region_rediscovery_interval_ms 60_000
  @health_check_timeout_ms 5_000

  @type node_state :: :connected | :discovering | :responding | :ready | :unresponsive | :disconnected

  @type node_info :: %{
          node: node(),
          region: String.t(),
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
            regions: %{},
            self_region: "unknown",
            health_check_task: nil,
            pending_discoveries: %{},
            last_tick: 0,
            last_health_check_start: 0,
            last_health_check_complete: 0,
            last_reconcile: 0,
            last_region_rediscovery: 0

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current cluster topology state.
  """
  @spec get_topology() :: %{
          nodes: [node_info()],
          regions: [String.t()],
          self_node: node(),
          self_region: String.t(),
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
  Returns list of known regions.
  """
  @spec get_regions() :: [String.t()]
  def get_regions do
    GenServer.call(__MODULE__, :get_regions)
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
  Returns the region for the current node.
  """
  @spec get_self_region() :: String.t()
  def get_self_region do
    GenServer.call(__MODULE__, :get_self_region)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    # Subscribe to node events - ONLY module that does this
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Determine self region
    self_region = Application.get_env(:lasso, :cluster_region) || generate_node_id()

    # Initial node discovery
    initial_nodes = build_initial_node_map()

    # Start tick timer
    schedule_tick()

    # Trigger immediate health check
    send(self(), :immediate_health_check)

    state = %__MODULE__{
      self_region: self_region,
      nodes: initial_nodes,
      regions: compute_regions(initial_nodes, self_region),
      last_tick: now(),
      last_health_check_complete: now()
    }

    Logger.info("[Topology] Started with #{map_size(initial_nodes)} nodes, region: #{self_region}")

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
      |> maybe_rediscover_unknown_regions(now)
      |> cleanup_stale_discoveries()

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
      region: "unknown",
      state: :discovering,
      connected_at: now(),
      last_response: nil,
      consecutive_failures: 0
    }

    nodes = Map.put(state.nodes, node, node_info)

    # Start async region discovery
    task = start_region_discovery(node)
    pending = Map.put(state.pending_discoveries, node, task)

    # Broadcast with coverage so dashboard updates immediately
    coverage = compute_coverage(nodes)

    broadcast_topology_event(%{
      event: :node_connected,
      node: node,
      node_info: node_info,
      coverage: coverage
    })

    emit_telemetry(:node_connected, %{node: node})

    {:noreply, %{state | nodes: nodes, pending_discoveries: pending}}
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
        regions = compute_regions(nodes, state.self_region)
        pending = cancel_discovery(state.pending_discoveries, node)

        coverage = compute_coverage(nodes)

        broadcast_topology_event(%{
          event: :node_disconnected,
          node: node,
          node_info: updated_info,
          coverage: coverage
        })

        emit_telemetry(:node_disconnected, %{node: node})

        {:noreply, %{state | nodes: nodes, regions: regions, pending_discoveries: pending}}
    end
  end

  # Region discovery completed successfully
  @impl true
  def handle_info({ref, {:region_discovered, node, region}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state =
      case Map.get(state.nodes, node) do
        nil ->
          state

        node_info ->
          new_state = if node_info.state == :discovering, do: :connected, else: node_info.state
          updated_info = %{node_info | region: region, state: new_state}
          nodes = Map.put(state.nodes, node, updated_info)
          regions = compute_regions(nodes, state.self_region)

          broadcast_topology_event(%{
            event: :region_discovered,
            node: node,
            node_info: updated_info
          })

          emit_telemetry(:region_discovered, %{node: node, region: region})

          Logger.debug("[Topology] Region discovered for #{node}: #{region}")

          %{state | nodes: nodes, regions: regions}
      end

    pending = Map.delete(state.pending_discoveries, node)
    {:noreply, %{state | pending_discoveries: pending}}
  end

  # Region discovery failed
  @impl true
  def handle_info({ref, {:region_discovery_failed, node, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[Topology] Region discovery failed for #{node}: #{inspect(reason)}")

    emit_telemetry(:region_discovery_failed, %{node: node, reason: reason})

    state =
      case Map.get(state.nodes, node) do
        %{state: :discovering} = info ->
          nodes = Map.put(state.nodes, node, %{info | state: :connected})
          %{state | nodes: nodes}

        _ ->
          state
      end

    pending = Map.delete(state.pending_discoveries, node)
    {:noreply, %{state | pending_discoveries: pending}}
  end

  # Health check completed
  @impl true
  def handle_info({ref, {:health_check_complete, results, bad_nodes}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    now = now()
    bad_set = MapSet.new(bad_nodes)

    # Also add badrpc responses to bad set
    badrpc_nodes =
      results
      |> Enum.with_index()
      |> Enum.filter(fn {result, _} -> match?({:badrpc, _}, result) end)
      |> Enum.map(fn {_, idx} ->
        state.nodes |> Map.keys() |> Enum.at(idx)
      end)
      |> Enum.reject(&is_nil/1)

    all_bad = MapSet.union(bad_set, MapSet.new(badrpc_nodes))

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

      Map.values(state.pending_discoveries) |> Enum.any?(&(&1.ref == ref)) ->
        pending =
          state.pending_discoveries
          |> Enum.reject(fn {_, task} -> task.ref == ref end)
          |> Map.new()

        {:noreply, %{state | pending_discoveries: pending}}

      true ->
        {:noreply, state}
    end
  end

  # Call handlers
  @impl true
  def handle_call(:get_topology, _from, state) do
    result = %{
      nodes: Map.values(state.nodes),
      regions: Map.keys(state.regions),
      self_node: node(),
      self_region: state.self_region,
      coverage: compute_coverage(state.nodes)
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_coverage, _from, state) do
    {:reply, compute_coverage(state.nodes), state}
  end

  @impl true
  def handle_call(:get_regions, _from, state) do
    {:reply, Map.keys(state.regions), state}
  end

  @impl true
  def handle_call(:get_connected_nodes, _from, state) do
    connected =
      state.nodes
      |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
      |> Enum.map(fn {node, _} -> node end)

    {:reply, connected, state}
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
  def handle_call(:get_self_region, _from, state) do
    {:reply, state.self_region, state}
  end

  # Private helpers

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp maybe_health_check(state, now) do
    if now - state.last_health_check_complete >= @health_check_interval_ms do
      if is_nil(state.health_check_task) do
        start_health_check(%{state | last_health_check_start: now})
      else
        state
      end
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

  defp maybe_rediscover_unknown_regions(state, now) do
    if now - state.last_region_rediscovery < @region_rediscovery_interval_ms do
      state
    else
      unknown_nodes =
        state.nodes
        |> Enum.filter(fn {node, info} ->
          info.region == "unknown" and
            info.state in [:connected, :responding, :ready] and
            not Map.has_key?(state.pending_discoveries, node)
        end)
        |> Enum.map(fn {node, _} -> node end)

      if unknown_nodes != [] do
        Logger.debug("[Topology] Retrying region discovery for #{length(unknown_nodes)} nodes")

        Enum.reduce(unknown_nodes, %{state | last_region_rediscovery: now}, fn node, acc ->
          task = start_region_discovery(node)
          pending = Map.put(acc.pending_discoveries, node, task)
          nodes = Map.update!(acc.nodes, node, fn info -> %{info | state: :discovering} end)
          %{acc | pending_discoveries: pending, nodes: nodes}
        end)
      else
        %{state | last_region_rediscovery: now}
      end
    end
  end

  defp cleanup_stale_discoveries(state) do
    # Remove discoveries for tasks that have crashed/exited
    pending =
      state.pending_discoveries
      |> Enum.reject(fn {_node, task} ->
        Process.info(task.pid) == nil
      end)
      |> Map.new()

    %{state | pending_discoveries: pending}
  end

  defp start_health_check(state) do
    nodes = get_connected_nodes_internal(state)

    if nodes == [] do
      %{state | last_health_check_complete: now()}
    else
      task =
        Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
          inner_task =
            Task.async(fn ->
              :rpc.multicall(nodes, Node, :self, [], 3_000)
            end)

          case Task.yield(inner_task, @health_check_timeout_ms) || Task.shutdown(inner_task) do
            {:ok, {results, bad_nodes}} ->
              {:health_check_complete, results, bad_nodes}

            nil ->
              {:health_check_timeout}
          end
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

    # Find nodes that appeared without nodeup
    missing_from_tracking = MapSet.difference(actual_nodes, tracked_connected)

    # Find nodes that disappeared without nodedown
    extra_in_tracking = MapSet.difference(tracked_connected, actual_nodes)

    state =
      Enum.reduce(missing_from_tracking, state, fn node, acc ->
        Logger.warning("[Topology] Reconciliation: discovered untracked node #{node}")
        send(self(), {:nodeup, node, []})
        acc
      end)

    state =
      Enum.reduce(extra_in_tracking, state, fn node, acc ->
        Logger.warning("[Topology] Reconciliation: node #{node} no longer in Node.list()")
        send(self(), {:nodedown, node, []})
        acc
      end)

    state
  end

  defp start_region_discovery(node) do
    Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
      discover_region_with_retry(node, @region_discovery_max_retries)
    end)
  end

  defp discover_region_with_retry(node, retries, delay \\ @region_discovery_backoff_base_ms)

  defp discover_region_with_retry(node, 0, _delay) do
    {:region_discovery_failed, node, :max_retries}
  end

  defp discover_region_with_retry(node, retries, delay) do
    # Small delay before first attempt (node may not be fully ready)
    if retries == @region_discovery_max_retries, do: Process.sleep(100)

    case :rpc.call(node, Application, :get_env, [:lasso, :cluster_region], @region_discovery_timeout_ms) do
      region when is_binary(region) ->
        {:region_discovered, node, region}

      {:badrpc, _reason} ->
        Process.sleep(delay)
        discover_region_with_retry(node, retries - 1, min(delay * 2, 2000))

      nil ->
        # No region configured, use node name as fallback
        region = node |> Atom.to_string() |> String.split("@") |> List.first() || "unknown"
        {:region_discovered, node, region}
    end
  end

  defp cancel_discovery(pending_discoveries, node) do
    case Map.get(pending_discoveries, node) do
      nil ->
        pending_discoveries

      task ->
        Task.shutdown(task, :brutal_kill)
        Map.delete(pending_discoveries, node)
    end
  end

  defp build_initial_node_map do
    Node.list()
    |> Enum.map(fn node ->
      {node,
       %{
         node: node,
         region: "unknown",
         state: :connected,
         connected_at: now(),
         last_response: nil,
         consecutive_failures: 0
       }}
    end)
    |> Map.new()
  end

  defp compute_regions(nodes, self_region) do
    nodes
    |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
    |> Enum.group_by(fn {_node, info} -> info.region end, fn {node, _} -> node end)
    |> Map.put_new(self_region, [])
  end

  defp compute_coverage(nodes) do
    node_list = Map.values(nodes)

    connected =
      Enum.count(node_list, fn info -> info.state not in [:disconnected] end)

    responding =
      Enum.count(node_list, fn info -> info.state in [:responding, :ready] end)

    unresponsive =
      node_list
      |> Enum.filter(fn info -> info.state == :unresponsive end)
      |> Enum.map(fn info -> info.node end)

    disconnected =
      node_list
      |> Enum.filter(fn info -> info.state == :disconnected end)
      |> Enum.map(fn info -> info.node end)

    # +1 for self node
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

  defp generate_node_id do
    node()
    |> Atom.to_string()
    |> String.split("@")
    |> List.first()
    |> Kernel.||("local")
  end

  defp now do
    System.monotonic_time(:millisecond)
  end
end
