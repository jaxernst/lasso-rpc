# Real-Time Cluster Metrics Architecture V2

**Version**: 1.0 (Implemented)
**Status**: ✅ Implemented
**Created**: January 2026
**Related**: [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md)

> **Note**: This design has been implemented as `LassoWeb.Dashboard.EventStream`.
> The V1 document and referenced files have been removed as part of documentation consolidation.

---

## 1. Executive Summary

### Problem Statement

The V1 clustering implementation broke the dashboard's "live" feel by replacing event-driven metrics with cached RPC aggregation. Users experience 15-30s staleness instead of real-time updates.

### Solution

Introduce `LassoWeb.Dashboard.EventStream` - a shared GenServer that:
1. Subscribes to cluster-wide PubSub events (routing decisions, circuit transitions, block sync)
2. Maintains sliding windows of events per `{provider, chain, region}`
3. Pre-computes metrics for both aggregate and per-region views
4. Broadcasts updates to subscribing LiveViews

This restores real-time liveness while keeping `MetricsStore` for detailed metrics that require full ETS reservoir data.

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Aggregator scope | One per profile | Clear ownership, simple lifecycle |
| Event storage key | `{provider_id, chain, source_region}` | Supports both aggregate and per-region queries |
| Broadcast frequency | On significant change + max 1s interval | Avoids unnecessary re-renders |
| Single-node behavior | Same code path, UI adapts | No branching, graceful degradation |
| Event processing | Batched (EventBuffer pattern) | Don't recompute on every event |

---

## 2. What's Real-Time vs Cached

### 2.1 Real-Time (From Aggregator)

These update immediately from PubSub events:

| Data | Source Event | Update Latency |
|------|--------------|----------------|
| **Metrics Strip** (p50, p95, success rate) | `routing:decisions:{profile}` | < 2s |
| **Traffic %** (pick share) | `routing:decisions:{profile}` | < 2s |
| **Circuit Breaker State** | `circuit:events:{profile}:{chain}` | Instant |
| **Block Height** per provider | `block_sync:{profile}:{chain}` | Instant |
| **Consensus Height** | `block_sync:{profile}:{chain}` | Instant |
| **Block Lag** per provider | Derived from height vs consensus | Instant |
| **Regions Reporting** | Derived from event sources | < 2s |

**Note on Percentiles**: The aggregator computes "ephemeral" p50/p95 from the sliding window of routing events. These are approximations from sampled data (~5% sample rate). For accurate per-method percentiles, use MetricsStore (ETS reservoir).

### 2.2 Cached (From MetricsStore)

These require full ETS data and tolerate 5-15s staleness:

| Data | Why Cached | Refresh Interval |
|------|------------|------------------|
| **Per-Method Percentiles** | Needs ETS reservoir (100 samples) | 10-15s |
| **Provider Leaderboard/Scoring** | Complex weighted algorithm | 10-15s |
| **Method List** | Enumeration from BenchmarkStore | 10-15s |

### 2.3 Clarification: Two Types of Percentiles

| Type | Source | Accuracy | Use Case |
|------|--------|----------|----------|
| **Ephemeral p50/p95** | Aggregator (event window) | Approximate (sampled) | Metrics strip, live indicators |
| **Reservoir p50/p95/p99** | MetricsStore (ETS) | Accurate (all traffic) | Per-method breakdown tables |

The metrics strip shows ephemeral percentiles for liveness. Detailed method tables show reservoir percentiles for accuracy.

---

## 3. Data Model

### 3.1 Aggregator State Structure

```elixir
defmodule LassoWeb.Dashboard.EventStream do
  defstruct [
    :profile,

    # === Event Windows ===
    # Key: {provider_id, chain, source_region}
    # Value: list of recent routing events (capped, time-bounded)
    event_windows: %{},

    # === Circuit States ===
    # Key: {provider_id, source_region}
    # Value: %{http: state, ws: state, updated_at: timestamp}
    circuit_states: %{},

    # === Block Sync State ===
    # Key: {provider_id, chain, source_region}
    # Value: %{height: int, timestamp: int, source: :ws | :http}
    block_heights: %{},

    # Key: {chain, source_region}
    # Value: consensus height (max of provider heights)
    consensus_heights: %{},

    # === Pre-computed Metrics ===
    # Key: provider_id
    # Value: see ProviderMetrics type below
    provider_metrics: %{},

    # === Chain Totals (for traffic %) ===
    # Key: {chain, source_region}
    # Value: count of events in window
    chain_totals: %{},

    # === Metadata ===
    known_regions: MapSet.new(),
    subscribers: MapSet.new(),

    # === Batching (EventBuffer pattern) ===
    pending_events: [],
    last_computation: 0,
    metrics_dirty: false
  ]
end
```

### 3.2 Provider Metrics Structure

```elixir
@type provider_metrics :: %{
  provider_id: String.t(),
  chain: String.t(),

  # Aggregate across all regions
  aggregate: %{
    total_calls: non_neg_integer(),
    success_rate: float(),           # 0.0 - 100.0
    error_count: non_neg_integer(),
    p50_latency: non_neg_integer() | nil,
    p95_latency: non_neg_integer() | nil,
    traffic_pct: float(),            # This provider's % of chain traffic
    events_per_second: float(),
    block_height: non_neg_integer() | nil,  # Max across regions
    block_lag: integer() | nil,             # Worst lag across regions
    regions_reporting: [String.t()]
  },

  # Per-region breakdown
  by_region: %{
    (region :: String.t()) => %{
      total_calls: non_neg_integer(),
      success_rate: float(),
      error_count: non_neg_integer(),
      p50_latency: non_neg_integer() | nil,
      p95_latency: non_neg_integer() | nil,
      traffic_pct: float(),          # % of THIS REGION's chain traffic
      events_per_second: float(),
      block_height: non_neg_integer() | nil,
      block_lag: integer() | nil,    # This region's lag
      circuit: %{
        http: :closed | :open | :half_open,
        ws: :closed | :open | :half_open
      }
    }
  },

  updated_at: non_neg_integer()
}
```

### 3.3 Traffic Percentage Calculation

Traffic % answers: "What portion of requests for this chain went to this provider?"

**Formula:**
```
traffic_pct = (provider_calls_in_scope / chain_calls_in_scope) * 100
```

**Guard for zero denominator:**
```elixir
defp traffic_pct(_provider_calls, 0), do: 0.0
defp traffic_pct(provider_calls, chain_calls), do: provider_calls / chain_calls * 100
```

**Scope varies by view:**

| View | provider_calls_in_scope | chain_calls_in_scope |
|------|-------------------------|----------------------|
| Aggregate | Sum across all regions | Sum across all regions |
| Region X | Events from region X only | Events from region X only |

### 3.4 Block Sync Aggregation

Block height data flows through PubSub (`block_sync:{profile}:{chain}`):

```elixir
def handle_info({:block_height_update, data}, state) do
  # data = %{provider_id, chain, height, source: :ws | :http, source_region}
  key = {data.provider_id, data.chain, data.source_region}

  block_heights = Map.put(state.block_heights, key, %{
    height: data.height,
    timestamp: System.system_time(:millisecond),
    source: data.source
  })

  # Recompute consensus for this chain/region
  consensus = compute_consensus(block_heights, data.chain, data.source_region)
  consensus_key = {data.chain, data.source_region}
  consensus_heights = Map.put(state.consensus_heights, consensus_key, consensus)

  # Mark dirty for next metrics computation
  {:noreply, %{state |
    block_heights: block_heights,
    consensus_heights: consensus_heights,
    metrics_dirty: true
  }}
end

defp compute_consensus(block_heights, chain, region) do
  block_heights
  |> Enum.filter(fn {{_pid, c, r}, _} -> c == chain and r == region end)
  |> Enum.map(fn {_, %{height: h}} -> h end)
  |> Enum.max(fn -> nil end)
end
```

**Aggregate block metrics:**
- `block_height`: Max height across all regions
- `block_lag`: Worst (most negative) lag across all regions
- `consensus_height`: Derived per-region, not aggregated

---

## 4. Event Processing (Batched)

### 4.1 Why Batching?

Don't recompute metrics on every event. At 5 events/second:
- Per-event computation = 5 computations/second = CPU waste
- Batched (every 500ms) = 2 computations/second = efficient

### 4.2 EventBuffer Pattern

```elixir
@batch_interval_ms 500
@max_batch_size 100

def init(profile) do
  # Subscribe to PubSub topics
  Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:decisions:#{profile}")

  for chain <- get_chains(profile) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events:#{profile}:#{chain}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:#{profile}:#{chain}")
  end

  # Start batch processing timer
  Process.send_after(self(), :process_batch, @batch_interval_ms)

  {:ok, %__MODULE__{profile: profile}}
end

# Accumulate events, don't process immediately
def handle_info(%RoutingDecision{} = event, state) do
  pending = [event | state.pending_events]

  # If batch is full, process immediately
  if length(pending) >= @max_batch_size do
    state = process_event_batch(%{state | pending_events: pending})
    {:noreply, state}
  else
    {:noreply, %{state | pending_events: pending}}
  end
end

# Circuit and block events process immediately (low frequency, high priority)
def handle_info({:circuit_breaker_event, data}, state) do
  state = update_circuit_state(state, data)
  broadcast_circuit_update(state, data)
  {:noreply, %{state | metrics_dirty: true}}
end

def handle_info({:block_height_update, data}, state) do
  state = update_block_height(state, data)
  {:noreply, %{state | metrics_dirty: true}}
end

# Periodic batch processing
def handle_info(:process_batch, state) do
  state =
    if state.pending_events != [] or state.metrics_dirty do
      state
      |> process_event_batch()
      |> maybe_broadcast_metrics()
    else
      state
    end

  Process.send_after(self(), :process_batch, @batch_interval_ms)
  {:noreply, state}
end

defp process_event_batch(state) do
  # Deduplicate by request_id
  events = state.pending_events |> Enum.uniq_by(& &1.request_id)

  # Add to windows
  state = Enum.reduce(events, state, &add_event_to_window/2)

  # Recompute all metrics
  state = recompute_all_metrics(state)

  %{state | pending_events: [], metrics_dirty: false, last_computation: now()}
end
```

### 4.3 Deduplication

Events may arrive from multiple nodes during partition recovery. Deduplicate by `request_id`:

```elixir
defp add_event_to_window(event, state) do
  key = {event.provider_id, event.chain, event.source_region}

  window = Map.get(state.event_windows, key, [])

  # Check if already in window
  if Enum.any?(window, & &1.request_id == event.request_id) do
    state
  else
    new_window = [event | window] |> Enum.take(@max_events_per_key)
    %{state | event_windows: Map.put(state.event_windows, key, new_window)}
  end
end
```

---

## 5. Single-Node Behavior

### 5.1 How It Works

The aggregator doesn't know or care about cluster size. It processes whatever events arrive via PubSub.

**In single-node mode:**
- All events have `source_region = System.get_env("CLUSTER_REGION", "local")`
- `event_windows` has keys like `{"alchemy", "ethereum", "local"}`
- `known_regions = MapSet.new(["local"])`
- `by_region` map has single entry
- `aggregate` metrics equal the single region's metrics

### 5.2 UI Adaptation

**Critical fix:** Change condition from `>= 1` to `> 1`:

```elixir
# In provider_details_panel.ex and chain_details_panel.ex
show_region_tabs = length(available_regions) > 1
```

**Single region behavior:**
- Hide the region tab bar entirely
- Display metrics directly (no Aggregate vs region tabs)
- Circuit breaker shows single state

### 5.3 Transition: Single → Multi-Node

When a second node joins:
1. Events from new region start arriving via PubSub
2. Aggregator adds region to `known_regions`
3. Next broadcast includes new region
4. UI receives updated `available_regions`
5. Region tabs appear automatically

**No restart required** - the system adapts dynamically.

### 5.4 Region Disappearance

When a region stops sending events (node down):
1. Events age out of window during cleanup
2. After window duration (60s), region has no events
3. Region removed from `known_regions` on next cleanup
4. Broadcast `{:region_removed, region}`
5. UI auto-switches to aggregate if viewing removed region

---

## 6. Broadcast Strategy

### 6.1 Message Types

| Message | Timing | Payload |
|---------|--------|---------|
| `{:metrics_snapshot, metrics}` | On subscribe | Full current state |
| `{:circuits_snapshot, circuits}` | On subscribe | All circuit states |
| `{:regions_snapshot, regions}` | On subscribe | Known regions list |
| `{:metrics_update, changed}` | Batched (max 1s) | Only changed providers |
| `{:circuit_update, pid, region, state}` | Immediate | Single circuit change |
| `{:block_update, pid, region, height, lag}` | Immediate | Single block update |
| `{:region_added, region}` | Immediate | New region discovered |
| `{:region_removed, region}` | Immediate | Region timed out |

### 6.2 Change Detection Thresholds

Don't broadcast noise. Use per-metric thresholds:

```elixir
@change_thresholds %{
  success_rate: 1.0,      # 1% absolute change
  traffic_pct: 2.0,       # 2% absolute change
  p50_latency: 5,         # 5ms absolute change
  p95_latency: 10,        # 10ms absolute change
  total_calls: 5,         # 5 call difference
  block_height: 1         # Any height change
}

defp significant_change?(old, new, field) do
  threshold = Map.get(@change_thresholds, field, 0)
  abs(Map.get(new, field, 0) - Map.get(old, field, 0)) >= threshold
end
```

### 6.3 Subscriber Management

```elixir
def handle_call({:subscribe, pid}, _from, state) do
  Process.monitor(pid)
  state = %{state | subscribers: MapSet.put(state.subscribers, pid)}

  # Send current state immediately
  send(pid, {:metrics_snapshot, state.provider_metrics})
  send(pid, {:circuits_snapshot, state.circuit_states})
  send(pid, {:regions_snapshot, MapSet.to_list(state.known_regions)})

  {:reply, :ok, state}
end

# Clean up on subscriber death (no Process.alive? check needed)
def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
  {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
end
```

---

## 7. Memory Management

### 7.1 Corrected Memory Estimates

| Scenario | Calculation | Estimate |
|----------|-------------|----------|
| Conservative (50 providers × 5 regions × 200 events × 200 bytes) | Direct | ~100 MB |
| Typical (20 providers × 3 regions × 100 events × 200 bytes) | Direct | **~1.2 MB** |
| Single-node (20 providers × 1 region × 100 events × 200 bytes) | Direct | ~400 KB |

### 7.2 Cleanup Strategy

Use lazy cleanup on write to amortize cost:

```elixir
@window_duration_ms 60_000
@cleanup_interval_ms 30_000  # Less frequent than v1
@max_events_per_key 200

def handle_info(:cleanup, state) do
  cutoff = System.system_time(:millisecond) - @window_duration_ms

  # Clean event windows
  new_windows =
    state.event_windows
    |> Enum.map(fn {key, events} ->
      {key, Enum.filter(events, & &1.ts > cutoff)}
    end)
    |> Enum.reject(fn {_, events} -> events == [] end)
    |> Map.new()

  # Clean stale block heights (no update in 5 minutes)
  block_cutoff = System.system_time(:millisecond) - 300_000
  new_heights =
    state.block_heights
    |> Enum.reject(fn {_, %{timestamp: ts}} -> ts < block_cutoff end)
    |> Map.new()

  # Update known regions
  active_regions =
    new_windows
    |> Map.keys()
    |> Enum.map(fn {_, _, region} -> region end)
    |> MapSet.new()

  removed_regions = MapSet.difference(state.known_regions, active_regions)
  for region <- removed_regions do
    broadcast_to_subscribers(state, {:region_removed, region})
  end

  Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  {:noreply, %{state |
    event_windows: new_windows,
    block_heights: new_heights,
    known_regions: active_regions
  }}
end
```

---

## 8. RPC Simplification

### 8.1 Functions to Remove from MetricsStore

| Function | Replacement |
|----------|-------------|
| `get_per_region_metrics/3` | `EventStream.get_provider_metrics/2` |
| `get_per_region_chain_metrics/2` | `EventStream.get_chain_metrics/2` |

### 8.2 Functions to Keep

| Function | Why |
|----------|-----|
| `get_provider_leaderboard/2` | Needs full ETS for accurate scoring |
| `get_rpc_method_performance/4` | Needs ETS reservoir for per-method percentiles |

### 8.3 Adjusted TTLs

| Metric | Old TTL | New TTL |
|--------|---------|---------|
| Provider leaderboard | 15s | 10-15s |
| Per-method performance | 15s | 15-30s |

---

## 9. Supervision Tree

### 9.1 Structure

```elixir
# In application.ex
children = [
  # Registry for aggregator lookup
  {Registry, keys: :unique, name: Lasso.Dashboard.AggregatorRegistry},

  # Supervisor for aggregator processes
  {DynamicSupervisor,
    name: Lasso.Dashboard.AggregatorSupervisor,
    strategy: :one_for_one},

  # ... existing children
]
```

### 9.2 Aggregator Lifecycle

```elixir
defmodule LassoWeb.Dashboard.EventStream do
  use GenServer, restart: :transient

  def start_link(profile) do
    GenServer.start_link(__MODULE__, profile, name: via(profile))
  end

  defp via(profile) do
    {:via, Registry, {Lasso.Dashboard.AggregatorRegistry, {:aggregator, profile}}}
  end

  def ensure_started(profile) do
    case Registry.lookup(Lasso.Dashboard.AggregatorRegistry, {:aggregator, profile}) do
      [{pid, _}] -> {:ok, pid}
      [] ->
        DynamicSupervisor.start_child(
          Lasso.Dashboard.AggregatorSupervisor,
          {__MODULE__, profile}
        )
    end
  end
end
```

---

## 10. Integration Points

### 10.1 Dashboard LiveView

```elixir
# In dashboard.ex mount
def mount(params, session, socket) do
  if connected?(socket) do
    profile = socket.assigns.selected_profile

    # Ensure aggregator is running and subscribe
    {:ok, _pid} = EventStream.ensure_started(profile)
    EventStream.subscribe(profile)
  end

  socket
  |> assign(:live_provider_metrics, %{})
  |> assign(:cluster_circuit_states, %{})
  |> assign(:cluster_block_heights, %{})
  |> assign(:available_regions, [])
end

# Handle messages from aggregator
def handle_info({:metrics_snapshot, metrics}, socket) do
  {:noreply, assign(socket, :live_provider_metrics, metrics)}
end

def handle_info({:metrics_update, changed}, socket) do
  merged = Map.merge(socket.assigns.live_provider_metrics, changed)
  {:noreply, assign(socket, :live_provider_metrics, merged)}
end

def handle_info({:circuit_update, provider_id, region, state}, socket) do
  key = {provider_id, region}
  circuits = Map.put(socket.assigns.cluster_circuit_states, key, state)
  {:noreply, assign(socket, :cluster_circuit_states, circuits)}
end

def handle_info({:block_update, provider_id, region, height, lag}, socket) do
  key = {provider_id, region}
  heights = Map.put(socket.assigns.cluster_block_heights, key, %{height: height, lag: lag})
  {:noreply, assign(socket, :cluster_block_heights, heights)}
end

def handle_info({:regions_snapshot, regions}, socket) do
  {:noreply, assign(socket, :available_regions, regions)}
end

def handle_info({:region_added, region}, socket) do
  regions = Enum.uniq([region | socket.assigns.available_regions])
  {:noreply, assign(socket, :available_regions, regions)}
end

def handle_info({:region_removed, region}, socket) do
  regions = List.delete(socket.assigns.available_regions, region)

  # If viewing this region, switch to aggregate
  socket =
    if socket.assigns[:selected_region] == region do
      socket
      |> assign(:selected_region, "aggregate")
      |> put_flash(:info, "Region #{region} is no longer reporting. Switched to aggregate view.")
    else
      socket
    end

  {:noreply, assign(socket, :available_regions, regions)}
end
```

### 10.2 Provider Details Panel

```elixir
# In provider_details_panel.ex
attr :live_metrics, :map, required: true
attr :cluster_circuits, :map, required: true
attr :cluster_block_heights, :map, required: true
attr :available_regions, :list, required: true

def update(assigns, socket) do
  provider_id = assigns.provider_id

  # Get this provider's live metrics
  provider_metrics = Map.get(assigns.live_metrics, provider_id, default_metrics())

  # Show region tabs only if multiple regions
  show_region_tabs = length(assigns.available_regions) > 1

  # Get display metrics for selected view
  selected = socket.assigns[:selected_region] || "aggregate"
  display_metrics =
    if selected == "aggregate" do
      provider_metrics.aggregate
    else
      Map.get(provider_metrics.by_region, selected, default_metrics())
    end

  socket
  |> assign(:display_metrics, display_metrics)
  |> assign(:show_region_tabs, show_region_tabs)
end
```

---

## 11. Review Findings (Consolidated)

### 11.1 Critical Fixes (Must Do)

| Issue | Source | Fix |
|-------|--------|-----|
| Tab visibility: `>= 1` → `> 1` | Tech Lead, UX | Update provider_details_panel.ex:41, chain_details_panel |
| Division by zero in traffic % | Tech Lead | Add guard clause |
| Batch event processing | Elixir Expert | Follow EventBuffer pattern (implemented in Section 4) |
| Remove `Process.alive?/1` check | Elixir Expert | Use monitor cleanup only (implemented in Section 6.3) |
| Circuit event deduplication | Elixir Expert | Track by `{provider, region, transport, state}` |

### 11.2 Important Improvements (Should Do)

| Issue | Source | Status |
|-------|--------|--------|
| Document sampling bias for percentiles | Tech Lead | Added in Section 2.3 |
| Per-metric change thresholds | Tech Lead | Added in Section 6.2 |
| Cleanup interval 10s → 30s | Elixir Expert | Updated in Section 7.2 |
| Memory estimates correction | Tech Lead | Fixed in Section 7.1 |
| Region disappearance handling | UX | Added in Section 5.4 |
| Block sync as real-time | User Feedback | Added throughout |

### 11.3 Sampling Accuracy Limitation

**Documented limitation**: With 5% event sampling:
- p50 from ~100 samples per region: Reasonable accuracy
- p95 from ~100 samples: ~5 tail samples, moderate accuracy
- p99: Unreliable (1-2 samples), **do not display**

Percentiles may **underestimate tail latency** due to uniform random sampling. High-latency outliers have same 5% chance of being sampled as normal requests.

For accurate percentiles, use per-method breakdown from MetricsStore (ETS reservoir).

---

## 12. Implementation Phases

### Phase 1: Aggregator Core

- [ ] Create `EventStream` module with batched processing
- [ ] Implement event window management with deduplication
- [ ] Implement metrics computation (success rate, percentiles, traffic %)
- [ ] Implement circuit state tracking with deduplication
- [ ] Implement block sync tracking
- [ ] Add supervision tree (Registry + DynamicSupervisor)
- [ ] Add telemetry instrumentation

### Phase 2: Dashboard Integration

- [ ] Add aggregator subscription in `dashboard.ex` mount
- [ ] Handle all message types (snapshot, update, circuit, block, region)
- [ ] Add new assigns: `live_provider_metrics`, `cluster_circuit_states`, etc.
- [ ] Handle profile switching (unsubscribe old, subscribe new)

### Phase 3: Panel Updates

- [ ] **Fix bug**: Change `>= 1` to `> 1` in provider_details_panel.ex:41
- [ ] **Fix bug**: Same fix in chain_details_panel.ex if present
- [ ] Update provider_details_panel to use aggregator data
- [ ] Update chain_details_panel to use aggregator data
- [ ] Implement single-node UI (hide tabs when 1 region)
- [ ] Handle region disappearance gracefully

### Phase 4: Cache Cleanup

- [ ] Remove `get_per_region_metrics` from MetricsStore
- [ ] Remove `get_per_region_chain_metrics` from MetricsStore
- [ ] Remove corresponding RPC calls in dashboard
- [ ] Adjust remaining cache TTLs

### Phase 5: Testing

- [ ] Unit tests for aggregator (metrics computation, dedup, cleanup)
- [ ] Integration tests with multiple profiles
- [ ] Single-node behavior tests
- [ ] Region add/remove transition tests
- [ ] Load testing with concurrent subscribers

---

## 13. Success Metrics

| Metric | Current | Target | Measurement |
|--------|---------|--------|-------------|
| Metrics strip latency | 15-30s | < 2s | Event to UI update |
| Circuit state latency | N/A (stale) | < 500ms | Event to UI update |
| Block height latency | Local only | < 1s | All nodes reflected |
| Region tab stability | Flickers | No flicker | Manual testing |
| Memory per aggregator | N/A | < 10MB typical | Process memory |
| Memory per LiveView | ~30MB | < 5MB | Not self-aggregating |

---

## Appendix A: API Reference

```elixir
defmodule LassoWeb.Dashboard.EventStream do
  # Lifecycle
  def start_link(profile)
  def ensure_started(profile) :: {:ok, pid} | {:error, term}

  # Subscription (receive broadcasts)
  def subscribe(profile) :: :ok
  def unsubscribe(profile) :: :ok

  # Direct queries (for non-subscribers)
  def get_provider_metrics(profile, provider_id) :: provider_metrics()
  def get_all_provider_metrics(profile) :: %{provider_id => provider_metrics()}
  def get_chain_metrics(profile, chain) :: chain_metrics()
  def get_circuit_states(profile, provider_id) :: %{region => circuit_state()}
  def get_block_heights(profile, chain) :: %{{provider_id, region} => height_info()}
  def get_known_regions(profile) :: [region]
end
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | Jan 2026 | Initial draft |
| 0.2 | Jan 2026 | Added data model, traffic %, single-node, RPC simplification |
| 0.3 | Jan 2026 | Incorporated review feedback: batching, block sync, dedup, memory fixes, UI fixes |
