# Dashboard Cluster Architecture v2

> **Status**: ✅ Implemented
> **Authors**: Architecture Review Session
> **Date**: 2025-01-24
> **Supersedes**: DASHBOARD_CLUSTERING.md, REALTIME_METRICS_ARCHITECTURE.md, CLUSTERING_SPEC_V1.md
>
> This is the **authoritative architecture document** for dashboard clustering. The implementation is complete:
> - `Lasso.Cluster.Topology` - Single source of truth for cluster membership
> - `LassoWeb.Dashboard.EventStream` - Batched event streaming to LiveViews
> - `LassoWeb.Dashboard.MetricsStore` - RPC-based metrics caching

## Executive Summary

This document specifies a redesigned architecture for cluster-aware dashboard functionality. The redesign consolidates three overlapping systems into a clean separation of concerns with explicit responsibilities, proper OTP patterns, and predictable behavior.

### Key Changes

| Before | After | Rationale |
|--------|-------|-----------|
| 3 modules tracking cluster state independently | 1 authoritative source (`Cluster.Topology`) | Eliminate split-brain, inconsistent coverage metrics |
| Dual PubSub subscription in dashboard | Single path through `EventStream` | 97% message reduction at scale |
| Blocking RPC in GenServer callbacks | Async tasks with supervision | OTP best practices, no mailbox stalls |
| 4 independent timers | Single tick-based state machine | Predictable execution, no timer drift |
| `Node.list()` at query time | Explicit state tracking with reconciliation | Eliminate race conditions |

---

## 1. Problem Statement

### 1.1 Current Architecture Issues

The existing implementation has three modules with overlapping responsibilities:

```
┌─────────────────────────────────────────────────────────────────┐
│                    CURRENT (Fragmented)                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  net_kernel ──┬──> ClusterMonitor ──> telemetry only           │
│               └──> ClusterEventAggregator ──> regions only     │
│                                                                 │
│  PubSub ──┬──> LiveViews (direct, N×M messages)                │
│           ├──> ClusterEventAggregator ──> metrics              │
│           └──> ClusterMetricsCache ──> coverage (via RPC)      │
│                                                                 │
│  Dashboard uses ALL THREE for different "cluster state"        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Identified Issues:**

1. **Dual subscription path**: Dashboard subscribes directly to `routing:decisions:{profile}` AND via aggregator, causing O(N×M) message explosion (60k+ msg/sec at scale)

2. **Inconsistent coverage metrics**:
   - `ClusterMonitor.get_cluster_info()` returns `Node.list()` at call time
   - `ClusterMetricsCache.get_cluster_coverage()` returns `responding == total` (always 100%)
   - `ClusterEventAggregator` tracks regions but not node health

3. **Blocking RPC in callbacks**: `ClusterEventAggregator.handle_info({:nodeup, ...})` blocks for 2.1 seconds (100ms sleep + 2s RPC timeout)

4. **Race conditions**: `Node.list()` called during event handling can diverge from actual state during the callback

5. **Wrong coverage semantics**: `total` equals `responding` in ClusterMetricsCache, hiding node failures

6. **Stuck stale indicators**: No recovery path when RPC times out, spinner persists indefinitely

### 1.2 Design Goals

1. **Single source of truth** for cluster topology and health
2. **Single event path** from PubSub to LiveViews
3. **Non-blocking** GenServer callbacks with async task supervision
4. **Correct semantics** for coverage (connected ≠ responding ≠ expected)
5. **Predictable timing** via consolidated tick-based scheduling
6. **Clean module boundaries** with explicit responsibilities

---

## 2. Architecture Overview

### 2.1 Module Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                    PROPOSED (Unified)                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Lasso.Cluster.Topology                      │   │
│  │  • Authoritative source for cluster membership           │   │
│  │  • ONLY module subscribing to net_kernel node events     │   │
│  │  • Async region discovery via Task.Supervisor            │   │
│  │  • Periodic health checks via RPC multicall              │   │
│  │  • Publishes to PubSub: "cluster:topology"               │   │
│  │  • Provides sync API for health endpoints                │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼ PubSub: cluster:topology         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │        LassoWeb.Dashboard.EventStream                    │   │
│  │  • Subscribes to cluster:topology for node changes       │   │
│  │  • Subscribes to routing:decisions:{profile}             │   │
│  │  • Aggregates metrics from routing events                │   │
│  │  • Batches events (500ms) for LiveView broadcast         │   │
│  │  • Manages LiveView subscriptions                        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼ {:events_batch, [...]}           │
│                              ▼ {:cluster_update, %{...}}        │
│                              ▼ {:metrics_update, %{...}}        │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │           LassoWeb.Dashboard (LiveView)                  │   │
│  │  • Single subscription to EventStream                    │   │
│  │  • Receives batched events and pre-computed metrics      │   │
│  │  • No direct PubSub subscriptions for routing events     │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │       LassoWeb.Dashboard.MetricsStore                    │   │
│  │  • RPC-based historical metrics (leaderboard, etc.)      │   │
│  │  • Caches results with stale-while-revalidate            │   │
│  │  • Uses Topology for node list (no Node.list())          │   │
│  │  • Subscribes to topology for cache invalidation         │   │
│  │  • Aggregates metrics from remote BenchmarkStore         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Module Responsibilities

| Module | Layer | Responsibility | Does NOT Do |
|--------|-------|----------------|-------------|
| `Lasso.Cluster.Topology` | Core | Node membership, regions, health | Event aggregation, metrics |
| `LassoWeb.Dashboard.EventStream` | Web | Live event aggregation, LiveView broadcast | Node tracking, RPC queries |
| `LassoWeb.Dashboard.MetricsStore` | Web | RPC metrics caching, historical data | Real-time events, node tracking |
| `LassoWeb.Dashboard` | Web | UI rendering, user interaction | Event processing, cluster tracking |

### 2.3 Modules to Remove

| Module | Reason | Replacement |
|--------|--------|-------------|
| `Lasso.ClusterMonitor` | Redundant with Topology | `Lasso.Cluster.Topology` |
| `LassoWeb.Dashboard.ClusterEventAggregator` | Renamed and refactored | `LassoWeb.Dashboard.EventStream` |
| `LassoWeb.Dashboard.ClusterMetricsCache` | Renamed and simplified | `LassoWeb.Dashboard.MetricsStore` |
| `LassoWeb.Dashboard.EventBuffer` | Merged into EventStream | `LassoWeb.Dashboard.EventStream` |
| `LassoWeb.Dashboard.EventDedup` | Merged into EventStream | `LassoWeb.Dashboard.EventStream` |

---

## 3. Lasso.Cluster.Topology

### 3.1 Purpose

Single authoritative source for cluster membership, region mapping, and node health. All other modules query or subscribe to Topology rather than tracking cluster state independently.

**Critical**: This is the ONLY module that subscribes to `:net_kernel.monitor_nodes/1`. All other modules receive node events via PubSub from Topology.

### 3.2 Node State Machine

Nodes transition through the following states:

```
                          ┌─────────────────────────────────────────────────────┐
                          │                 NODE STATE MACHINE                   │
                          └─────────────────────────────────────────────────────┘

    ┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
    │  :connected  │ ───> │ :discovering │ ───> │ :responding  │ ───> │   :ready     │
    └──────────────┘      └──────────────┘      └──────────────┘      └──────────────┘
           │                     │                     │                     │
           │                     │                     │                     │
           ▼                     ▼                     ▼                     ▼
    ┌──────────────────────────────────────────────────────────────────────────────┐
    │                           :disconnected                                       │
    └──────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
    ┌──────────────────────────────────────────────────────────────────────────────┐
    │                           :unresponsive                                       │
    │                   (connected but failing health checks)                       │
    └──────────────────────────────────────────────────────────────────────────────┘

    State Transitions:
    ─────────────────
    :connected → :discovering       When: nodeup received, region discovery starts
    :discovering → :responding      When: region discovered AND health check passes
    :discovering → :connected       When: region discovery fails (stays connected, region unknown)
    :responding → :ready            When: Application.started_applications confirms app running
    * → :disconnected               When: nodedown received
    * → :unresponsive               When: 3+ consecutive health check failures
    :unresponsive → :responding     When: health check passes again
```

### 3.3 State Definition

```elixir
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
  """

  use GenServer

  @type node_state :: :connected | :discovering | :responding | :ready | :unresponsive | :disconnected

  @type node_info :: %{
    node: node(),
    region: String.t(),
    state: node_state(),
    connected_at: integer() | nil,
    last_response: integer() | nil,
    consecutive_failures: non_neg_integer()
  }

  @type topology_state :: %{
    nodes: %{node() => node_info()},
    regions: %{String.t() => [node()]},
    self_region: String.t(),
    health_check_task: Task.t() | nil,
    pending_discoveries: %{node() => Task.t()},
    last_tick: integer(),
    last_health_check_start: integer(),
    last_health_check_complete: integer(),
    last_reconcile: integer()
  }

  defstruct [
    nodes: %{},
    regions: %{},
    self_region: "unknown",
    health_check_task: nil,
    pending_discoveries: %{},
    last_tick: 0,
    last_health_check_start: 0,
    last_health_check_complete: 0,
    last_reconcile: 0
  ]
end
```

### 3.4 Timing Configuration

```elixir
# Single tick drives all periodic operations
@tick_interval_ms 500

# Health check interval (RPC multicall to verify responsiveness)
# Measured from COMPLETION of last check, not start
@health_check_interval_ms 15_000

# Reconciliation interval (compare tracked state vs Node.list())
@reconcile_interval_ms 30_000

# Region discovery retry configuration
@region_discovery_timeout_ms 2_000
@region_discovery_max_retries 5
@region_discovery_backoff_base_ms 200

# Region rediscovery: retry unknown regions periodically
@region_rediscovery_interval_ms 60_000
```

### 3.5 Initialization

```elixir
def init(_opts) do
  # Subscribe to node events ONCE (NO other module should do this)
  :net_kernel.monitor_nodes(true, node_type: :visible)

  # Determine self region
  self_region = Application.get_env(:lasso, :cluster_region) || generate_node_id()

  # Initial node discovery
  initial_nodes = build_initial_node_map()

  # Start tick timer
  schedule_tick()

  # Trigger immediate health check
  send(self(), :immediate_health_check)

  {:ok, %__MODULE__{
    self_region: self_region,
    nodes: initial_nodes,
    regions: compute_regions(initial_nodes),
    last_tick: now()
  }}
end

defp build_initial_node_map do
  Node.list()
  |> Enum.map(fn node ->
    {node, %{
      node: node,
      region: "unknown",
      state: :connected,  # Will transition to :discovering when discovery starts
      connected_at: now(),
      last_response: nil,
      consecutive_failures: 0
    }}
  end)
  |> Map.new()
end
```

### 3.6 Tick-Based State Machine

All periodic operations run from a single tick handler:

```elixir
def handle_info(:tick, state) do
  now = System.system_time(:millisecond)

  state =
    state
    |> maybe_health_check(now)
    |> maybe_reconcile(now)
    |> maybe_rediscover_unknown_regions(now)
    |> cleanup_stale_discoveries()

  schedule_tick()
  {:noreply, %{state | last_tick: now}}
end

defp schedule_tick do
  Process.send_after(self(), :tick, @tick_interval_ms)
end

defp maybe_health_check(state, now) do
  # Use last_health_check_complete to avoid drift from variable RPC times
  if now - state.last_health_check_complete >= @health_check_interval_ms do
    if is_nil(state.health_check_task) do
      start_health_check(%{state | last_health_check_start: now})
    else
      state  # Skip if check already in progress
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
  # Periodically retry region discovery for nodes stuck at "unknown"
  unknown_nodes =
    state.nodes
    |> Enum.filter(fn {node, info} ->
      info.region == "unknown" and
      info.state in [:connected, :responding, :ready] and
      not Map.has_key?(state.pending_discoveries, node)
    end)
    |> Enum.map(fn {node, _} -> node end)

  if unknown_nodes != [] and now - state.last_tick > @region_rediscovery_interval_ms do
    Enum.reduce(unknown_nodes, state, fn node, acc ->
      task = start_region_discovery(node)
      pending = Map.put(acc.pending_discoveries, node, task)
      nodes = Map.update!(acc.nodes, node, fn info -> %{info | state: :discovering} end)
      %{acc | pending_discoveries: pending, nodes: nodes}
    end)
  else
    state
  end
end
```

### 3.7 Node Event Handling (Non-Blocking)

```elixir
def handle_info({:nodeup, node, _info}, state) do
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

  # CRITICAL: Broadcast with coverage so dashboard updates immediately
  # Don't wait for next health check - connected count changes now
  coverage = compute_coverage(nodes)
  broadcast_topology_event(%{
    event: :node_connected,
    node: node,
    node_info: node_info,
    coverage: coverage
  })

  {:noreply, %{state | nodes: nodes, pending_discoveries: pending}}
end

def handle_info({:nodedown, node, _info}, state) do
  case Map.get(state.nodes, node) do
    nil ->
      {:noreply, state}

    node_info ->
      updated_info = %{node_info | state: :disconnected}
      nodes = Map.put(state.nodes, node, updated_info)
      regions = recompute_regions(nodes)
      pending = cancel_discovery(state.pending_discoveries, node)

      # CRITICAL: Broadcast with coverage so dashboard updates immediately
      coverage = compute_coverage(nodes)
      broadcast_topology_event(%{
        event: :node_disconnected,
        node: node,
        node_info: updated_info,
        coverage: coverage
      })

      {:noreply, %{state |
        nodes: nodes,
        regions: regions,
        pending_discoveries: pending
      }}
  end
end
```

### 3.8 Async Region Discovery

```elixir
defp start_region_discovery(node) do
  parent = self()

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

    {:badrpc, reason} ->
      Process.sleep(delay)
      discover_region_with_retry(node, retries - 1, delay * 2)
  end
end

def handle_info({ref, {:region_discovered, node, region}}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])

  state =
    case Map.get(state.nodes, node) do
      nil ->
        state  # Node disconnected during discovery

      node_info ->
        # Transition from :discovering to :connected (will become :responding after health check)
        new_state = if node_info.state == :discovering, do: :connected, else: node_info.state
        updated_info = %{node_info | region: region, state: new_state}
        nodes = Map.put(state.nodes, node, updated_info)
        regions = recompute_regions(nodes)

        # Broadcast region discovered (map payload)
        broadcast_topology_event(%{
          event: :region_discovered,
          node: node,
          node_info: updated_info
        })

        %{state | nodes: nodes, regions: regions}
    end

  pending = Map.delete(state.pending_discoveries, node)
  {:noreply, %{state | pending_discoveries: pending}}
end

def handle_info({ref, {:region_discovery_failed, node, reason}}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  Logger.warning("[Topology] Region discovery failed for #{node}: #{inspect(reason)}")

  # Transition back to :connected (not :discovering) but keep region as "unknown"
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
```

### 3.9 Health Checks (Async RPC Multicall)

```elixir
defp start_health_check(state) do
  nodes = get_connected_nodes(state)

  if nodes == [] do
    state
  else
    parent = self()

    task = Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
      # Hard timeout wrapper around RPC
      inner_task = Task.async(fn ->
        :rpc.multicall(nodes, Node, :self, [], 3_000)
      end)

      case Task.yield(inner_task, 5_000) || Task.shutdown(inner_task) do
        {:ok, {results, bad_nodes}} ->
          {:health_check_complete, results, bad_nodes}
        nil ->
          {:health_check_timeout}
      end
    end)

    %{state | health_check_task: task}
  end
end

def handle_info({ref, {:health_check_complete, results, bad_nodes}}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])

  now = now()
  bad_set = MapSet.new(bad_nodes)

  # Update node states based on results
  nodes =
    state.nodes
    |> Enum.map(fn {node, info} ->
      cond do
        info.state == :disconnected ->
          {node, info}

        MapSet.member?(bad_set, node) ->
          # Node failed health check
          failures = info.consecutive_failures + 1
          new_state = if failures >= 3, do: :unresponsive, else: info.state
          {node, %{info | consecutive_failures: failures, state: new_state}}

        true ->
          # Node responded - transition to :responding if was :connected or :discovering
          new_state =
            case info.state do
              s when s in [:connected, :discovering, :unresponsive] -> :responding
              other -> other
            end
          {node, %{info |
            state: new_state,
            last_response: now,
            consecutive_failures: 0
          }}
      end
    end)
    |> Map.new()

  # Broadcast health update (map payload)
  broadcast_health_update(state.nodes, nodes)

  # Update last_health_check_complete on COMPLETION, not start
  {:noreply, %{state |
    nodes: nodes,
    health_check_task: nil,
    last_health_check_complete: now
  }}
end

def handle_info({ref, {:health_check_timeout}}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  Logger.warning("[Topology] Health check timeout")
  # Update completion time even on timeout to avoid rapid retries
  {:noreply, %{state |
    health_check_task: nil,
    last_health_check_complete: now()
  }}
end

def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
  cond do
    state.health_check_task && state.health_check_task.ref == ref ->
      Logger.warning("[Topology] Health check task crashed: #{inspect(reason)}")
      {:noreply, %{state | health_check_task: nil, last_health_check_complete: now()}}

    Map.values(state.pending_discoveries) |> Enum.any?(&(&1.ref == ref)) ->
      # Discovery task crashed - clean up
      pending =
        state.pending_discoveries
        |> Enum.reject(fn {_, task} -> task.ref == ref end)
        |> Map.new()
      {:noreply, %{state | pending_discoveries: pending}}

    true ->
      {:noreply, state}
  end
end
```

### 3.10 Public API

```elixir
@doc """
Returns current cluster topology state.
Used by health controller and other synchronous queries.
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
@type coverage :: %{
  expected: non_neg_integer(),      # Nodes we expect (could add libcluster awareness)
  connected: non_neg_integer(),     # Nodes with Erlang distribution connection
  responding: non_neg_integer(),    # Nodes passing health checks
  unresponsive: [node()],           # Connected but failing health checks
  disconnected: [node()]            # Previously connected, now down
}
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
```

### 3.11 PubSub Events

Topology publishes events for interested subscribers. All payloads are maps for consistency:

```elixir
@topology_topic "cluster:topology"

defp broadcast_topology_event(payload) when is_map(payload) do
  Phoenix.PubSub.broadcast(Lasso.PubSub, @topology_topic, {:topology_event, payload})
end

defp broadcast_health_update(old_nodes, new_nodes) do
  # Find nodes that changed state
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
```

**Event Payloads (all wrapped in `{:topology_event, payload}`):**

| Event | Payload |
|-------|---------|
| Node connected | `%{event: :node_connected, node: node(), node_info: node_info(), coverage: coverage()}` |
| Node disconnected | `%{event: :node_disconnected, node: node(), node_info: node_info(), coverage: coverage()}` |
| Region discovered | `%{event: :region_discovered, node: node(), node_info: node_info()}` |
| Health update | `%{event: :health_update, changes: [%{node: node(), info: node_info()}], coverage: coverage()}` |

**Key design decision**: Coverage is included in `node_connected` and `node_disconnected` events so the dashboard can update immediately. Don't wait for the next health check cycle.

---

## 4. LassoWeb.Dashboard.EventStream

### 4.1 Purpose

Aggregates real-time events from PubSub and broadcasts pre-computed metrics to subscribed LiveViews. Replaces `ClusterEventAggregator` with cleaner responsibilities.

**Key Changes from ClusterEventAggregator:**

1. **No `:net_kernel.monitor_nodes`** - subscribes to `Cluster.Topology` via PubSub instead
2. **No region discovery** - receives region info from Topology events
3. **Proper batch counter** - O(1) instead of O(n) for batch size check
4. **No per-subscriber rate limiting** - handled at LiveView level if needed

### 4.2 State Definition

```elixir
defmodule LassoWeb.Dashboard.EventStream do
  @moduledoc """
  Real-time event aggregation and broadcast for dashboard LiveViews.

  Subscribes to routing decisions, circuit events, and block sync events.
  Pre-computes metrics and broadcasts batched updates to subscribers.
  """

  use GenServer, restart: :transient

  @batch_interval_ms 500
  @max_batch_size 100
  @window_duration_ms 60_000
  @max_events_per_key 100
  @cleanup_interval_ms 30_000

  defstruct [
    :profile,

    # Event processing
    event_windows: %{},           # %{{provider_id, chain, region} => [events]}
    pending_events: [],           # Events awaiting batch processing
    pending_count: 0,             # O(1) count instead of length/1

    # Pre-computed metrics
    provider_metrics: %{},        # %{provider_id => metrics}
    chain_totals: %{},            # %{{chain, region} => count}

    # Circuit and block state
    circuit_states: %{},          # %{{provider_id, region} => circuit_info}
    block_heights: %{},           # %{{provider_id, chain, region} => block_info}
    consensus_heights: %{},       # %{{chain, region} => height}

    # Cluster state (from Topology)
    cluster_state: %{
      connected: 0,
      responding: 0,
      regions: [],
      last_update: 0
    },

    # Subscriber management
    subscribers: MapSet.new(),

    # Timing
    last_tick: 0,
    last_cleanup: 0,

    # Deduplication
    seen_request_ids: %{}         # %{request_id => timestamp} for dedup
  ]
end
```

### 4.3 Initialization

```elixir
def init(profile) do
  # Subscribe to topology events (NOT net_kernel directly)
  Phoenix.PubSub.subscribe(Lasso.PubSub, "cluster:topology")

  # Subscribe to routing decisions for this profile
  Phoenix.PubSub.subscribe(Lasso.PubSub, RoutingDecision.topic(profile))

  # Subscribe to circuit and block events for each chain
  chains = ConfigStore.list_chains_for_profile(profile)
  for chain <- chains do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events:#{profile}:#{chain}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:#{profile}:#{chain}")
  end

  # Get initial cluster state from Topology
  cluster_state = fetch_cluster_state()

  # Start tick timer
  schedule_tick()

  {:ok, %__MODULE__{
    profile: profile,
    cluster_state: cluster_state,
    last_tick: now()
  }}
end

defp fetch_cluster_state do
  case Lasso.Cluster.Topology.get_coverage() do
    coverage when is_map(coverage) ->
      %{
        connected: coverage.connected,
        responding: coverage.responding,
        regions: Lasso.Cluster.Topology.get_regions(),
        last_update: now()
      }
    _ ->
      %{connected: 1, responding: 1, regions: [], last_update: now()}
  end
end
```

### 4.4 Event Processing

```elixir
# Routing decisions - batch for efficiency
def handle_info(%RoutingDecision{} = event, state) do
  # Check dedup FIRST
  if Map.has_key?(state.seen_request_ids, event.request_id) do
    {:noreply, state}
  else
    # Track for dedup
    seen = Map.put(state.seen_request_ids, event.request_id, now())

    # Add to pending with O(1) count update
    pending = [event | state.pending_events]
    count = state.pending_count + 1

    # Process immediately if batch is full
    if count >= @max_batch_size do
      state = process_batch(%{state |
        pending_events: pending,
        pending_count: count,
        seen_request_ids: seen
      })
      {:noreply, state}
    else
      {:noreply, %{state |
        pending_events: pending,
        pending_count: count,
        seen_request_ids: seen
      }}
    end
  end
end

# Circuit events - process immediately (low frequency, high priority)
def handle_info({:circuit_breaker_event, event_data}, state) do
  state = update_circuit_state(state, event_data)
  broadcast_circuit_update(state, event_data)
  {:noreply, state}
end

# Block events - process immediately
def handle_info({:block_height_update, {_profile, provider_id}, height, source, timestamp}, state) do
  region = state.cluster_state.regions |> List.first() || "unknown"
  state = update_block_height(state, provider_id, region, height, source, timestamp)
  {:noreply, state}
end

# Topology events from Cluster.Topology (map payload)
def handle_info({:topology_event, %{event: :health_update} = payload}, state) do
  cluster_state = %{
    connected: payload.coverage.connected,
    responding: payload.coverage.responding,
    regions: Lasso.Cluster.Topology.get_regions(),
    last_update: now()
  }

  # Broadcast to subscribers (map payload)
  broadcast_to_subscribers(state, {:cluster_update, cluster_state})

  {:noreply, %{state | cluster_state: cluster_state}}
end

def handle_info({:topology_event, %{event: :node_connected, coverage: coverage}}, state) do
  # Coverage included - update immediately (don't wait for health_update)
  cluster_state = %{state.cluster_state |
    connected: coverage.connected,
    responding: coverage.responding,
    last_update: now()
  }
  broadcast_to_subscribers(state, {:cluster_update, cluster_state})
  {:noreply, %{state | cluster_state: cluster_state}}
end

def handle_info({:topology_event, %{event: :node_disconnected, coverage: coverage}}, state) do
  # Coverage included - update immediately
  cluster_state = %{state.cluster_state |
    connected: coverage.connected,
    responding: coverage.responding,
    last_update: now()
  }
  broadcast_to_subscribers(state, {:cluster_update, cluster_state})
  {:noreply, %{state | cluster_state: cluster_state}}
end

def handle_info({:topology_event, %{event: :region_discovered, node_info: node_info}}, state) do
  # Add region if new
  regions = [node_info.region | state.cluster_state.regions] |> Enum.uniq()
  cluster_state = %{state.cluster_state | regions: regions}

  broadcast_to_subscribers(state, {:region_added, %{region: node_info.region}})

  {:noreply, %{state | cluster_state: cluster_state}}
end
```

### 4.5 Tick Handler

```elixir
def handle_info(:tick, state) do
  now = now()

  state =
    state
    |> maybe_process_batch(now)
    |> maybe_cleanup(now)
    |> cleanup_seen_request_ids(now)

  schedule_tick()
  {:noreply, %{state | last_tick: now}}
end

defp maybe_process_batch(state, _now) do
  if state.pending_count > 0 do
    process_batch(state)
  else
    state
  end
end

defp process_batch(state) do
  # Deduplicate by request_id (already filtered on arrival, but belt-and-suspenders)
  events =
    state.pending_events
    |> Enum.reverse()  # Restore arrival order
    |> Enum.uniq_by(& &1.request_id)

  # Add events to windows
  state = Enum.reduce(events, state, &add_event_to_window/2)

  # Recompute metrics
  state = recompute_metrics(state)

  # Broadcast updates to subscribers
  broadcast_metrics_update(state)
  broadcast_events_batch(state, events)

  %{state | pending_events: [], pending_count: 0}
end

defp cleanup_seen_request_ids(state, now) do
  # Keep request IDs for 2 minutes for dedup
  cutoff = now - 120_000
  seen =
    state.seen_request_ids
    |> Enum.reject(fn {_id, ts} -> ts < cutoff end)
    |> Map.new()

  %{state | seen_request_ids: seen}
end
```

### 4.6 Subscriber Management

```elixir
def handle_call({:subscribe, pid}, _from, state) do
  Process.monitor(pid)
  subscribers = MapSet.put(state.subscribers, pid)

  # Send current state immediately (map payloads)
  send(pid, {:metrics_snapshot, %{metrics: state.provider_metrics}})
  send(pid, {:circuits_snapshot, %{circuits: state.circuit_states}})
  send(pid, {:cluster_update, state.cluster_state})

  # Send recent events from windows (not a separate buffer)
  recent_events = get_recent_events(state.event_windows, 100)
  send(pid, {:events_snapshot, %{events: recent_events}})

  {:reply, :ok, %{state | subscribers: subscribers}}
end

def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
  subscribers = MapSet.delete(state.subscribers, pid)
  {:noreply, %{state | subscribers: subscribers}}
end

defp get_recent_events(windows, limit) do
  windows
  |> Enum.flat_map(fn {_key, events} -> events end)
  |> Enum.sort_by(& &1.ts, :desc)
  |> Enum.take(limit)
end
```

### 4.7 Broadcast Messages

All payloads are maps for consistency:

```elixir
# Batched routing events (every 500ms)
{:events_batch, %{events: [%RoutingDecision{}, ...]}}

# Initial event snapshot on subscribe
{:events_snapshot, %{events: [%RoutingDecision{}, ...]}}

# Pre-computed provider metrics
{:metrics_snapshot, %{metrics: %{provider_id => metrics}}}
{:metrics_update, %{metrics: %{provider_id => metrics}}}

# Circuit state
{:circuits_snapshot, %{circuits: %{{provider_id, region} => circuit_info}}}
{:circuit_update, %{provider_id: id, region: region, circuit: circuit_info}}

# Block heights
{:block_update, %{provider_id: id, region: region, height: height, lag: lag}}

# Cluster state (from Topology)
{:cluster_update, %{connected: n, responding: n, regions: [...]}}
{:region_added, %{region: region}}
```

---

## 5. LassoWeb.Dashboard.MetricsStore

### 5.1 Purpose

Handles RPC-based queries for historical metrics (provider leaderboard, method performance, etc.) with caching and aggregation. Renamed from `ClusterMetricsCache` to clarify its role.

**Key Changes:**

1. **Uses `Cluster.Topology.get_responding_nodes()`** instead of `Node.list()`
2. **Simplified coverage tracking** - delegates to Topology
3. **Removed `get_cluster_coverage/0`** - use Topology instead
4. **Subscribes to topology for cache invalidation**
5. **Cleaner cache key structure**

### 5.2 State Definition

```elixir
defmodule LassoWeb.Dashboard.MetricsStore do
  @moduledoc """
  Caches aggregated metrics from cluster-wide RPC queries.

  Uses stale-while-revalidate pattern: returns cached data immediately
  while triggering background refresh when TTL expires.

  Subscribes to topology changes and invalidates cache entries when
  cluster membership changes significantly.
  """

  use GenServer

  @cache_ttl_ms 15_000
  @refresh_timeout_ms 5_000

  defstruct [
    cache: %{},
    refreshing: MapSet.new(),
    last_known_node_count: 0
  ]
end
```

### 5.3 Cache Invalidation on Topology Changes

```elixir
def init(_opts) do
  # Subscribe to topology changes for cache invalidation
  Phoenix.PubSub.subscribe(Lasso.PubSub, "cluster:topology")

  initial_node_count =
    case Lasso.Cluster.Topology.get_coverage() do
      %{connected: n} -> n
      _ -> 1
    end

  {:ok, %__MODULE__{last_known_node_count: initial_node_count}}
end

def handle_info({:topology_event, %{event: event}}, state)
    when event in [:node_connected, :node_disconnected] do
  # Invalidate all cache entries on node changes
  # The next request will fetch fresh data from the new cluster membership
  {:noreply, %{state | cache: %{}}}
end

def handle_info({:topology_event, _}, state) do
  {:noreply, state}
end
```

### 5.4 RPC Integration with Topology

```elixir
@doc false
def fetch_from_cluster(module, function, args) do
  # Use Topology for node list instead of Node.list()
  nodes = Lasso.Cluster.Topology.get_responding_nodes()
  nodes = [node() | nodes] |> Enum.uniq()

  start_time = System.monotonic_time(:millisecond)

  {results, bad_nodes} = :rpc.multicall(nodes, module, function, args, @refresh_timeout_ms)

  duration_ms = System.monotonic_time(:millisecond) - start_time

  # Filter out {:badrpc, reason} tuples
  valid_results = Enum.reject(results, &match?({:badrpc, _}, &1))

  # Get coverage from Topology (authoritative source)
  topology_coverage = Lasso.Cluster.Topology.get_coverage()

  coverage = %{
    responding: length(valid_results),
    total: topology_coverage.connected,
    rpc_bad_nodes: bad_nodes,
    duration_ms: duration_ms
  }

  emit_rpc_telemetry(args, coverage)

  aggregated = aggregate_results(function, valid_results)
  {aggregated, coverage}
end
```

---

## 6. Dashboard LiveView Changes

### 6.1 Subscription Changes

**Remove:**

```elixir
# REMOVE: Direct PubSub subscription (dashboard.ex line 173)
Phoenix.PubSub.subscribe(Lasso.PubSub, RoutingDecision.topic(profile))

# REMOVE: Direct PubSub unsubscribe (dashboard.ex line 192)
Phoenix.PubSub.unsubscribe(Lasso.PubSub, RoutingDecision.topic(profile))

# REMOVE: EventDedup initialization (dashboard.ex line 102)
|> assign(:event_dedup, LassoWeb.Dashboard.EventDedup.new())

# REMOVE: EventDedup handler (dashboard.ex :expire_dedup)
def handle_info(:expire_dedup, socket) do ...
```

**Keep (unchanged):**

```elixir
# Subscribe to EventStream (renamed from ClusterEventAggregator)
EventStream.subscribe(selected_profile)
```

### 6.2 Staleness Detection

The dashboard must detect when it stops receiving updates (e.g., EventStream crash, network partition). On mount, schedule a staleness check timer:

```elixir
@staleness_threshold_ms 30_000
@staleness_check_interval_ms 10_000

def mount(...) do
  # ... existing mount logic
  schedule_staleness_check()
  {:ok, assign(socket, :last_cluster_update, System.system_time(:millisecond))}
end

def handle_info(:check_staleness, socket) do
  now = System.system_time(:millisecond)
  stale = now - socket.assigns.last_cluster_update > @staleness_threshold_ms
  schedule_staleness_check()
  {:noreply, assign(socket, :metrics_stale, stale)}
end

defp schedule_staleness_check do
  Process.send_after(self(), :check_staleness, @staleness_check_interval_ms)
end
```

### 6.3 New Message Handlers

```elixir
# Cluster state from EventStream (which gets it from Topology)
def handle_info({:cluster_update, cluster_state}, socket) do
  {:noreply,
    socket
    |> assign(:metrics_coverage, %{
        responding: cluster_state.responding,
        total: cluster_state.connected
      })
    |> assign(:cluster_regions, cluster_state.regions)
    |> assign(:last_cluster_update, System.system_time(:millisecond))
    |> assign(:metrics_stale, false)
  }
end

# Batched events from EventStream
def handle_info({:events_batch, %{events: events}}, socket) do
  socket = MessageHandlers.handle_events_batch(events, socket)
  {:noreply, socket}
end

# Initial events on subscribe
def handle_info({:events_snapshot, %{events: events}}, socket) do
  socket = MessageHandlers.handle_events_snapshot(events, socket)
  {:noreply, socket}
end
```

### 6.4 Remove Handlers

```elixir
# REMOVE: Direct RoutingDecision handler (dashboard.ex lines 297-333)
def handle_info(%RoutingDecision{} = evt, socket) do ...

# REMOVE: Legacy map format handler (dashboard.ex lines 337-360)
def handle_info(%{ts: _ts, chain: _chain, ...} = evt, socket) do ...
```

---

## 7. Configuration

### 7.1 Application Config

```elixir
# config/config.exs
config :lasso, :cluster,
  health_check_interval_ms: 15_000,
  reconcile_interval_ms: 30_000,
  region_discovery_timeout_ms: 2_000,
  region_discovery_retries: 5,
  region_rediscovery_interval_ms: 60_000

config :lasso, :dashboard,
  event_stream: [
    batch_interval_ms: 500,
    window_duration_ms: 60_000,
    max_events_per_key: 100
  ],
  metrics_store: [
    cache_ttl_ms: 15_000,
    rpc_timeout_ms: 5_000
  ]
```

### 7.2 Runtime Config

```elixir
# config/runtime.exs

# Cluster region (unchanged)
cluster_region = System.get_env("CLUSTER_REGION") || generate_node_id()
config :lasso, :cluster_region, cluster_region

# Optional overrides
if health_interval = System.get_env("CLUSTER_HEALTH_CHECK_MS") do
  config :lasso, :cluster, health_check_interval_ms: String.to_integer(health_interval)
end
```

---

## 8. Supervision Tree

```elixir
# lib/lasso/application.ex

children = [
  # Core services
  {Phoenix.PubSub, name: Lasso.PubSub},
  {Task.Supervisor, name: Lasso.TaskSupervisor},

  # Cluster topology (single source of truth)
  Lasso.Cluster.Topology,

  # Dashboard registries and supervisors
  {Registry, keys: :unique, name: Lasso.Dashboard.StreamRegistry},
  {DynamicSupervisor, name: Lasso.Dashboard.StreamSupervisor, strategy: :one_for_one},

  # Metrics store (cache)
  LassoWeb.Dashboard.MetricsStore,

  # ... other children
]
```

---

## 9. Migration Plan

### Phase 0: Prerequisites

1. **Add `Lasso.Cluster.Topology` module** with full implementation
2. **Add `EventStream` module** (can coexist with ClusterEventAggregator initially)
3. **Rename `ClusterMetricsCache` to `MetricsStore`** with Topology integration
4. **Update tests** to use new module names

### Phase 1: Parallel Operation

1. **Start Topology as the ONLY net_kernel subscriber**
   - ClusterMonitor continues but does NOT subscribe to net_kernel
   - ClusterMonitor receives events via Topology's PubSub broadcasts
2. **Start EventStream alongside ClusterEventAggregator**
3. **Dashboard subscribes to BOTH** for verification
4. **Compare outputs** via telemetry to ensure consistency

### Phase 2: Cutover

1. **Remove ClusterMonitor from supervision tree**
2. **Switch dashboard to EventStream only**
3. **Remove direct PubSub subscription from dashboard**
4. **Remove ClusterEventAggregator from supervision tree**

### Phase 3: Cleanup

1. **Delete deprecated modules:**
   - `Lasso.ClusterMonitor`
   - `LassoWeb.Dashboard.ClusterEventAggregator`
   - `LassoWeb.Dashboard.ClusterMetricsCache` (if renamed)
   - `LassoWeb.Dashboard.EventBuffer`
   - `LassoWeb.Dashboard.EventDedup`

2. **Update health controller to use Topology**
3. **Update cluster_status.ex component to use Topology**

### Rollback Plan

If issues arise during migration:

**Phase 1 Rollback:**
- Stop Topology
- Re-enable ClusterMonitor's net_kernel subscription
- No user impact (parallel operation)

**Phase 2 Rollback:**
- Switch dashboard back to ClusterEventAggregator subscription
- Re-add direct PubSub subscription to dashboard
- Restart ClusterEventAggregator with net_kernel subscription
- Feature flag: `config :lasso, :use_new_event_stream, false`

**Phase 3 Rollback:**
- Not applicable (modules already deleted)
- Would require code restoration from git

---

## 10. Testing Strategy

### 10.1 Unit Tests

```elixir
# test/lasso/cluster/topology_test.exs
describe "Topology" do
  test "tracks node connections via explicit state, not Node.list()"
  test "handles nodeup/nodedown without blocking"
  test "transitions through :discovering state during region lookup"
  test "retries region discovery with exponential backoff"
  test "rediscovers regions for nodes stuck at 'unknown'"
  test "periodic health check updates responding status"
  test "updates last_health_check_complete on completion, not start"
  test "reconciliation detects state drift"
  test "coverage semantics are correct (connected ≠ responding)"
  test "broadcasts map payloads for all events"
end

# test/lasso_web/dashboard/event_stream_test.exs
describe "EventStream" do
  test "deduplicates events by request_id"
  test "batches events at 500ms intervals"
  test "processes immediately when batch is full"
  test "broadcasts cluster state from Topology events"
  test "provides recent events snapshot on subscribe"
  test "uses map payloads for all broadcasts"
end

# test/lasso_web/dashboard/metrics_store_test.exs
describe "MetricsStore" do
  test "invalidates cache on topology node changes"
  test "uses Topology.get_responding_nodes() not Node.list()"
  test "stale-while-revalidate returns cached data during refresh"
end
```

### 10.2 Integration Tests

```elixir
describe "Cluster Integration" do
  test "new node appears in coverage within 5 seconds"
  test "node failure shows in coverage after health check"
  test "region discovered and broadcast to LiveViews"
  test "events flow from PubSub through EventStream to LiveView"
  test "no duplicate events received by LiveView"
  test "cache invalidated when node joins/leaves"
end
```

### 10.3 Load Tests

```elixir
describe "Performance" do
  test "handles 10,000 events/sec without mailbox backup"
  test "50 LiveView subscribers receive batched updates"
  test "memory stays bounded under sustained load"
  test "RPC timeout doesn't block other operations"
end
```

---

## 11. Observability

### 11.1 Telemetry Events

```elixir
# Topology events
[:lasso, :cluster, :topology, :node_connected]
[:lasso, :cluster, :topology, :node_disconnected]
[:lasso, :cluster, :topology, :health_check, :complete]
[:lasso, :cluster, :topology, :health_check, :timeout]
[:lasso, :cluster, :topology, :region_discovered]
[:lasso, :cluster, :topology, :region_discovery_failed]

# EventStream events
[:lasso, :dashboard, :event_stream, :batch_processed]
[:lasso, :dashboard, :event_stream, :subscriber_added]
[:lasso, :dashboard, :event_stream, :subscriber_removed]

# MetricsStore events
[:lasso, :dashboard, :metrics_store, :cache_hit]
[:lasso, :dashboard, :metrics_store, :cache_miss]
[:lasso, :dashboard, :metrics_store, :cache_invalidated]
[:lasso, :dashboard, :metrics_store, :rpc_complete]
```

### 11.2 Metrics to Monitor

| Metric | Threshold | Alert |
|--------|-----------|-------|
| Topology health check duration | > 3s | Warning |
| EventStream mailbox size | > 500 | Warning |
| EventStream batch processing time | > 100ms | Warning |
| MetricsStore RPC bad nodes | > 0 | Info |
| Coverage.responding < Coverage.connected | Any | Warning |
| Nodes stuck in :discovering > 30s | Any | Warning |

---

## 12. Appendix: Semantic Definitions

### Coverage Terms

| Term | Definition | Source |
|------|------------|--------|
| **Expected** | Nodes in libcluster topology (future enhancement) | libcluster |
| **Connected** | Nodes with active Erlang distribution | `:net_kernel.monitor_nodes` |
| **Responding** | Connected nodes passing RPC health checks | `:rpc.multicall` |
| **Ready** | Responding nodes with application started | RPC + Application.started_applications |
| **Unresponsive** | Connected but failing health checks | Health check failures >= 3 |

### Node States

| State | Definition |
|-------|------------|
| **:connected** | Erlang distribution established, no region info yet |
| **:discovering** | Region discovery in progress |
| **:responding** | Region known, passing health checks |
| **:ready** | Responding and application confirmed running |
| **:unresponsive** | Connected but 3+ consecutive health check failures |
| **:disconnected** | Previously connected, nodedown received |

### Event Freshness

| State | Definition |
|-------|------------|
| **Fresh** | Data from last 15 seconds |
| **Stale** | Data from 15-60 seconds ago |
| **Expired** | Data older than 60 seconds (discarded) |

---

## 13. Design Decisions & Tradeoffs

### Unresponsive Node Detection Timing

With 15s health check intervals and 3 failures required, unresponsive detection takes 30-45 seconds. This is a deliberate tradeoff:

- **Pros**: Avoids false positives from transient network blips, reduces health check overhead
- **Cons**: Slow to detect genuinely unresponsive nodes

**Future improvement**: Consider adaptive health checks - nodes with `consecutive_failures > 0` could use 5s intervals while healthy nodes stay at 15s.

---

## 14. Open Questions

1. **libcluster integration**: Should Topology query libcluster for "expected" nodes to distinguish "never connected" from "connected then dropped"?

2. **Partition detection**: Should we implement asymmetric partition detection by querying what nodes each node sees?

3. **Rate limiting**: If per-subscriber rate limiting is needed, should it be in EventStream (violates SRP) or in LiveView (complicates LiveView)?

4. **Ready state**: Is the `:ready` state (responding + app started) worth the additional RPC complexity?

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| v2.0 | 2025-01-24 | Complete redesign based on architecture review |
| v2.1 | 2025-01-24 | Added review feedback: :discovering state, migration rollback plan, map payloads, health check timing fix, region rediscovery, cache invalidation, state machine diagram |
| v2.2 | 2025-01-24 | Coverage broadcast on nodeup/nodedown for immediate dashboard updates; staleness detection in LiveView; documented unresponsive timing tradeoff |
