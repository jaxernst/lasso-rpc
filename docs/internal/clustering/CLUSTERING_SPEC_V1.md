# Lasso RPC Clustering Specification V1

> ⚠️ **SUPERSEDED**: This document has been superseded by [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md).
>
> This V1 spec is preserved for historical reference. The V2 architecture consolidates and simplifies
> the clustering design with a unified `Cluster.Topology` module, `EventStream` for batched event
> delivery, and `MetricsStore` for RPC-based caching.

**Version**: 1.0
**Last Updated**: January 2026
**Status**: Historical - Superseded by V2
**Authors**: Engineering Team

---

## 1. Executive Summary

This specification defines the architecture for multi-node clustered deployments of Lasso RPC with a unified dashboard experience. It incorporates findings from comprehensive technical reviews including Product/UX, Multi-Tenant Privacy, BEAM/OTP Operations, Event Schema, Dashboard Performance, Metrics Aggregation, Core Architecture, and Billing/CU Metering perspectives.

### 1.1 Problem Statement

When Lasso is deployed as a geo-distributed proxy (e.g., US-East, EU-West, Asia-Pacific), a user viewing the dashboard sees only data from the single node they're connected to:

1. **Incomplete Activity Feed**: Shows ~33% of actual traffic (one node's view)
2. **Partial Metrics**: RPS, success rates, and provider rankings reflect only one node
3. **Misleading Provider Status**: Circuit breaker state may differ across nodes
4. **SaaS Data Leak**: Global `routing:decisions` topic exposes cross-tenant traffic

### 1.2 Solution Overview

- Automatic node discovery via libcluster with DNS polling
- Profile-scoped and account-scoped event streaming via Phoenix.PubSub
- Cached cluster-wide metrics aggregation with async RPC patterns
- Coverage indicators showing data completeness (e.g., "2/3 nodes")
- OSS vs Cloud scoping for appropriate tenant isolation
- **Single-node friendly**: Zero config required for single-node deployments

### 1.3 Critical Constraint: RPC Hot Path Unchanged

**All clustering changes are dashboard-only.** The RPC request hot path (routing, failover, circuit breakers, provider selection) MUST NOT be affected:

- No cross-node RPC calls during request handling
- No distributed state lookups in the routing path
- Circuit breakers remain node-local for latency isolation
- Provider selection uses local ETS data only

### 1.4 V1 Scope

#### Blocking (P0)

| Item | Rationale |
|------|-----------|
| Profile-scoped routing events | SaaS data leak - users can see other accounts' traffic |
| libcluster installation + configuration | Nodes cannot discover each other without it |
| Erlang cookie configuration | Nodes refuse to connect without shared cookie |
| ClusterMetricsCache implementation | LiveView blocking causes UI freezes under cluster RPC |
| Async RPC pattern in LiveView | Prevents process blocking on cluster operations |
| Coverage indicators | Users must understand data completeness |

#### Explicitly Deferred from V1

| Item | Rationale | Revisit When |
|------|-----------|--------------|
| CU Accumulator node-aware flush | 10s loss on crash is acceptable | User feedback indicates billing accuracy issues |
| Distributed rate limiting (Redis) | Accept 3x burst capacity limitation | Scale requires stricter enforcement |
| Region filter toggle in UI | Validate user need before adding complexity | User feedback requests it |
| Advisory circuit breaker signals | Over-engineering; regional isolation is correct | Users report confusion about regional state |
| Adaptive event sampling | Fixed 5% rate sufficient for V1 | Event rate exceeds 1000/s sustained |
| Per-profile sample rates | Global rate is simpler to tune | Different profiles need different rates |

#### Circuit Breaker State in Topology (V1 Resolution)

The topology visualization needs aggregate badges ("2/3 regions healthy") but we're deferring ClusterCircuitState RPC queries. **Resolution**: Use existing PubSub circuit events.

Circuit events are already broadcast at `circuit:events:{profile}:{chain}` with low frequency (state transitions only). The dashboard can:
1. Subscribe to circuit events for the selected profile
2. Maintain local cache of last-known state per provider/region
3. Display aggregate badges from cached state
4. Show "stale" indicator if no event received in >60s

This avoids RPC queries while providing aggregate visibility. Full ClusterCircuitState module deferred to V2.

#### Accepted Limitations

1. **Rate limiting**: 3 nodes = 3x effective burst capacity (Hammer ETS is node-local)
2. **CU metering**: Up to 10 seconds of CU lost on node crash (at-most-once semantics)
3. **Config consistency**: Eventual consistency during rolling deploys
4. **Block sync polling**: 3x upstream provider load (each node polls independently)

#### Implementation Warnings

The following are critical correctness and performance considerations identified during technical review:

| Area | Warning | Mitigation |
|------|---------|------------|
| **RPS Aggregation** | `SUM(node_rps)` is incorrect if nodes use varying time windows | BenchmarkStore must return raw `calls_in_window` and time window; aggregate as `sum(calls) / window_seconds` |
| **PubSub at Scale** | >10K req/s can bottleneck PubSub even with fire-and-forget | Event sampling (1-5%) is mandatory, not optional |
| **Rolling Deploys** | Event struct schema changes can crash old nodes | Use optional fields for new additions; prefer immediate deploy strategy |
| **Cache Contention** | First cache miss with 100+ dashboard viewers creates O(100) waiters | Single producer pattern handles this correctly; monitor cache miss rate |
| **Clock Skew** | Up to ~5% RPS aggregation error due to clock differences | Document as expected; wall-clock alignment is overkill for dashboard |
| **Scaling Beyond 10 Nodes** | `:rpc.multicall` latency grows with node count | Consider increasing cache TTL from 15s to 30s; per-region aggregators for V2 |

### 1.5 Repository Architecture: OSS/Cloud Boundary

**Critical Constraint**: lasso-rpc (OSS) must be completely independent of lasso-cloud. The OSS version is a fully-functional clustered RPC proxy. Cloud is a fork that adds multi-tenancy.

#### Repository Relationship

```
lasso-rpc (OSS)                    lasso-cloud (Proprietary)
─────────────────                  ─────────────────────────
Standalone RPC proxy         ───►  Fork of lasso-rpc
Profile-scoped clustering          + Account/billing system
No account concepts                + Multi-tenant isolation
Self-hosted operators              + SaaS-specific UX
```

**Dependency Direction**: One-way only. Cloud depends on OSS. OSS has zero knowledge of Cloud.

#### Boundary Rules

| Rule | Rationale |
|------|-----------|
| No `account_id` in OSS code | Account is a Cloud concept |
| No `api_key_id` in OSS code | API key billing is Cloud concept |
| No conditional `if cloud_mode?()` branches | Creates hidden coupling |
| OSS event structs have no Cloud fields | Clean extension point |
| OSS dashboard is profile-scoped only | No "My App" concept without accounts |

#### What Lives Where

| Component | OSS (lasso-rpc) | Cloud (lasso-cloud) |
|-----------|-----------------|---------------------|
| libcluster + infrastructure | ✓ | inherits |
| ClusterMonitor | ✓ | inherits |
| Profile-scoped events | ✓ | inherits |
| ClusterMetricsCache | ✓ | inherits |
| Coverage indicators | ✓ | inherits |
| Event sampling (global) | ✓ | extends with per-profile |
| Base event structs | ✓ | extends with account fields |
| EventSubscription (profile) | ✓ | replaces with account-aware |
| `account_id` in events | ✗ | ✓ |
| Account-scoped topics | ✗ | ✓ |
| "My App" / "Profile Benchmark" | ✗ | ✓ |

#### OSS Completeness Criteria

Before any Cloud work begins, OSS must satisfy:

- [ ] Self-hosted operator can deploy 3-node cluster
- [ ] `Node.list()` returns other nodes within 30s of deploy
- [ ] Dashboard shows merged activity feed from all nodes
- [ ] Dashboard shows aggregated metrics with coverage indicators
- [ ] Profile-scoped event isolation works (no cross-profile leakage)
- [ ] Event sampling reduces load under high traffic
- [ ] Partial node failure shows graceful degradation (not errors)
- [ ] Zero references to account, api_key, or billing in OSS code paths

#### Cloud Extension Pattern

Cloud extends OSS through **replacement and enrichment**, not modification:

```elixir
# OSS: lib/lasso_web/dashboard/event_subscription.ex
defmodule LassoWeb.Dashboard.EventSubscription do
  def subscribe(profile), do: "routing:decisions:#{profile}"
end

# Cloud: REPLACES the above file entirely
defmodule LassoWeb.Dashboard.EventSubscription do
  def subscribe(socket, profile) do
    if show_all_events?(socket) do
      "routing:decisions:#{profile}"
    else
      "routing:decisions:#{profile}:account:#{socket.assigns.current_account.id}"
    end
  end
end
```

```elixir
# OSS: publishes base event
Phoenix.PubSub.broadcast(Lasso.PubSub, "routing:decisions:#{profile}", event)

# Cloud: wrapper enriches and publishes to additional topic
defp publish_with_account(event, account_id) do
  # Call OSS publisher
  Lasso.Observability.publish_routing_decision(event)

  # Cloud addition: also publish to account topic
  enriched = Map.put(event, :account_id, account_id)
  Phoenix.PubSub.broadcast(
    Lasso.PubSub,
    "routing:decisions:#{event.profile}:account:#{account_id}",
    enriched
  )
end
```

---

## 2. Profile Classes and Dashboard Truth Model

**Note**: Section 2 describes Cloud-specific concepts (profile classes, two-layer dashboard). OSS uses a simpler model: all users are operators, all views are profile-scoped.

### 2.1 Profile Classes

Cloud deployments support three profile classes with different scoping semantics:

| Profile Class | Description | Dashboard Scope |
|---------------|-------------|-----------------|
| **Shared Free** | Public providers, multi-tenant | Profile-scoped analytics shared; account-scoped activity |
| **Shared Premium** | Higher throughput providers, multi-tenant | Profile-scoped analytics shared; account-scoped activity |
| **BYOK / Custom** | Dedicated profiles per account; user provides keys | Private by construction (profile = account) |

### 2.2 Automatic Scoping Model (Cloud)

Cloud dashboards apply **automatic scoping** based on metric type—no user-facing toggle required. The same dashboard shows a mix of account-scoped and profile-scoped data, each in the appropriate context.

#### Account-Scoped Metrics (User's Own Traffic)

| Metric | Source | Rationale |
|--------|--------|-----------|
| Activity feed | Account's requests only | "Is my app healthy?" |
| My success/error rate | Account's requests only | User expectation |
| My RPS | Account's requests only | Avoid confusing feeds |
| My failovers/retries | Account's requests only | Debugging context |

These avoid spamming users with unrelated traffic on shared profiles.

#### Profile-Scoped Metrics (Shared Infrastructure Signal)

| Metric | Source | Rationale |
|--------|--------|-----------|
| Provider topology | Shared profile signals | Health, circuit states |
| Provider benchmarking | Aggregate across profile | Public benchmark positioning |
| Breaker state | Per-region, all traffic | Operational awareness |
| Rate-limit state | Node-local, shared pain | Shared provider reality |

These reflect shared infrastructure health visible to all users of the profile.

### 2.3 What is Shared vs Account-Scoped

#### Shared (Profile-Scoped Domain Truth)

These reflect aggregate traffic on shared profiles and are appropriate to show to all users of that profile:

- Circuit breaker state (per provider/transport, per region)
- Provider health/availability
- Rate-limit state (inherently shared pain on shared providers)
- Provider benchmarking on shared profiles (public benchmark)

#### Account-Scoped (Viewer Truth)

These are private to each account and form the default Cloud UX:

- Activity feed
- "My" success rate / errors
- "My" throughput / RPS
- Failover events for my requests

#### BYOK Profiles

BYOK profiles are private by construction when dedicated per account:
- Profile-scoped = account-scoped in practice
- BYOK provider metrics are private by default

### 2.4 Identity Key

The primary identity key for account attribution is `account_id`. This is available on every HTTP and WS request in Cloud deployments and is used for:

- Account-scoped topic routing
- "My App" dashboard filtering
- CU metering attribution

---

## 3. Infrastructure

### 3.0 Single-Node Support

Lasso RPC fully supports single-node deployments with **zero clustering configuration**.

**Default Behavior**:
- `EXPECTED_NODE_COUNT` defaults to `1`
- If `CLUSTER_DNS_QUERY` is not set, libcluster is not configured
- All dashboard features work identically (just no cross-node aggregation)
- `Node.list()` returns `[]` and this is handled gracefully throughout

**Scaling Path**:
Self-hosters can start with a single node and scale to multiple nodes when needed:

1. Single node: No clustering config needed
2. Adding nodes: Set `CLUSTER_DNS_QUERY`, `CLUSTER_NODE_BASENAME`, `CLUSTER_NODE_IP`, `RELEASE_COOKIE`
3. Code changes: None required

**Feature Parity**:
| Feature | Single-Node | Multi-Node |
|---------|-------------|------------|
| Dashboard | ✓ Full | ✓ Full + aggregation |
| Metrics | ✓ Local | ✓ Cluster-wide |
| Activity Feed | ✓ Local | ✓ Merged from all nodes |
| Coverage Indicator | "1/1 nodes" | "N/N nodes" |

### 3.1 libcluster Configuration

**Dependency** (`mix.exs`):
```elixir
defp deps do
  [
    {:libcluster, "~> 3.3"},
    # ... existing deps
  ]
end
```

**Configuration** (`config/runtime.exs`):
```elixir
# Clustering is optional - only configure if DNS query is set
if dns_query = System.get_env("CLUSTER_DNS_QUERY") do
  config :libcluster,
    topologies: [
      dns: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 5_000,
          query: dns_query,
          node_basename: System.fetch_env!("CLUSTER_NODE_BASENAME")
        ]
      ]
    ]
end
```

**Environment Variables**:
| Variable | Required | Description |
|----------|----------|-------------|
| `CLUSTER_DNS_QUERY` | No | DNS query for node discovery (e.g., `myapp.internal`). If not set, runs in single-node mode. |
| `CLUSTER_NODE_BASENAME` | If clustered | Must match across all nodes (e.g., `lasso-rpc`) |
| `CLUSTER_NODE_IP` | If clustered | This node's cluster-reachable IP |
| `CLUSTER_REGION` | No | Region identifier for metrics (default: `"local"`) |
| `RELEASE_COOKIE` | If clustered | Shared Erlang cookie for cluster authentication |
| `EXPECTED_NODE_COUNT` | No | Expected cluster size for health checks (default: `1`) |

**Supervision** (`lib/lasso/application.ex`):
```elixir
children = [
  # Add after PubSub, before EventBuffer
  {Cluster.Supervisor, [
    Application.get_env(:libcluster, :topologies, []),
    [name: Lasso.ClusterSupervisor]
  ]},
  Lasso.ClusterMonitor,
  # ... existing children
]
```

### 3.2 Node Naming

**Stable naming pattern** (`rel/env.sh.eex`):
```bash
#!/bin/sh
# Only configure distributed node if clustering env vars are set
if [ -n "$CLUSTER_NODE_IP" ] && [ -n "$CLUSTER_NODE_BASENAME" ]; then
  export RELEASE_DISTRIBUTION=name
  export RELEASE_NODE="${CLUSTER_NODE_BASENAME}@${CLUSTER_NODE_IP}"
fi
```

**Critical Requirements**:
- All nodes MUST share the same basename (the part before `@`)
- Each node MUST have a unique full name (basename + IP)
- Do NOT include deployment-specific values (image refs, timestamps) in node names

**Single-Node Mode**: If `CLUSTER_NODE_IP` is not set, the node runs standalone without distributed Erlang.

### 3.3 Cookie and Security

**Set Erlang cookie**: Generate a secure random cookie and set it as an environment variable on all nodes:
```bash
# Generate a secure cookie
openssl rand -base64 32

# Set as environment variable (method depends on your deployment platform)
export RELEASE_COOKIE="your-generated-cookie-here"
```

**Security Note**: This cookie is equivalent to a root password for the cluster. Anyone with this cookie can execute arbitrary code via `:rpc.call/4`. Treat it as sensitive as database credentials.

### 3.4 VM Arguments

**Create** `rel/vm.args.eex`:
```erlang
-kernel inet_dist_listen_min 9000
-kernel inet_dist_listen_max 9010
-kernel net_ticktime 60
-kernel prevent_overlapping_partitions true
```

### 3.5 Cluster Monitoring

**Required GenServer** (`lib/lasso/cluster_monitor.ex`):
```elixir
defmodule Lasso.ClusterMonitor do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Subscribe to node events
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # IMPORTANT: Populate with already-connected nodes
    # On restart, we won't get :nodeup for existing connections
    initial_nodes = MapSet.new(Node.list())

    if MapSet.size(initial_nodes) > 0 do
      Logger.info("ClusterMonitor started with #{MapSet.size(initial_nodes)} existing nodes")
    end

    {:ok, %{nodes: initial_nodes}}
  end

  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Cluster node joined: #{node}")
    :telemetry.execute([:lasso, :cluster, :node_up], %{count: 1}, %{node: node})
    {:noreply, %{state | nodes: MapSet.put(state.nodes, node)}}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("Cluster node left: #{node}")
    :telemetry.execute([:lasso, :cluster, :node_down], %{count: 1}, %{node: node})
    {:noreply, %{state | nodes: MapSet.delete(state.nodes, node)}}
  end

  def connected_nodes, do: GenServer.call(__MODULE__, :get_nodes)
  def handle_call(:get_nodes, _from, state), do: {:reply, MapSet.to_list(state.nodes), state}
end
```

---

## 4. PubSub and Events

See [PUBSUB_EVENTS.md](./PUBSUB_EVENTS.md) for complete event schemas and topic hierarchy.

### 4.1 Topic Hierarchy

```
Profile-Scoped Topics (OSS + Cloud operator view):
├── routing:decisions:{profile}
├── circuit:events:{profile}:{chain}
├── provider_pool:events:{profile}:{chain}
├── ws:conn:{profile}:{chain}
├── block_sync:{profile}:{chain}
└── health_probe:{profile}:{chain}

Account-Scoped Topics (Cloud default UX):
└── routing:decisions:{profile}:account:{account_id}
```

### 4.2 Event Sampling Policy

**Critical**: Publishing every request via PubSub can become a bottleneck. Use publisher-side gating:

#### Always Publish (High Signal)
- `result = :error`
- `failover_count > 0`
- Circuit breaker transitions
- Provider health transitions

#### Sample Successes (Configurable)
- Default: `success_sample_rate = 0.01` to `0.05` (1-5%)
- Per-profile configuration for high-traffic shared profiles (may need lower rates)
- Keeps activity feed "alive" and supports benchmarking without making PubSub the scaling limit

```elixir
defp should_publish_event?(%{result: :error}), do: true
defp should_publish_event?(%{failover_count: n}) when n > 0, do: true
defp should_publish_event?(_event) do
  sample_rate = Application.get_env(:lasso, :success_event_sample_rate, 0.05)
  :rand.uniform() < sample_rate
end
```

### 4.3 Event Publishing

Events MUST be broadcast to profile-scoped topics. For Cloud deployments, additionally broadcast to account-scoped topics:

```elixir
defp broadcast_routing_decision(%{profile: profile} = event) do
  enriched = Map.merge(event, %{
    source_node: node(),
    source_region: System.get_env("CLUSTER_REGION", "local")
  })

  # Profile-scoped topic (OSS + operator view)
  Phoenix.PubSub.broadcast(Lasso.PubSub, "routing:decisions:#{profile}", enriched)

  # Account-scoped topic (Cloud default UX)
  if account_id = Map.get(enriched, :account_id) do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "routing:decisions:#{profile}:account:#{account_id}",
      enriched
    )
  end
end
```

### 4.4 OSS vs Cloud Scoping

**Note**: OSS and Cloud will be separate repositories. Do not embed `oss_mode?()` runtime branching in shared application code. Document differences at the repository/deployment level.

| Deployment | Default Subscription | Full View Access |
|------------|---------------------|------------------|
| **OSS** | Profile-scoped (all events) | All users are operators |
| **Cloud** | Account-scoped (user's events only) | Admins with `?show_all=true` |

#### OSS Repository
Subscribe to profile-scoped topics only:
```elixir
Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:decisions:#{profile}")
```

#### Cloud Repository
Default to account-scoped topics; provide admin toggle for full profile view:
```elixir
topic = if admin_full_view?(socket) do
  "routing:decisions:#{profile}"
else
  account_id = socket.assigns.current_account.id
  "routing:decisions:#{profile}:account:#{account_id}"
end
Phoenix.PubSub.subscribe(Lasso.PubSub, topic)
```

---

## 5. Dashboard Clustering

See [DASHBOARD_CLUSTERING.md](./DASHBOARD_CLUSTERING.md) for complete caching and performance patterns.

### 5.1 ClusterMetricsCache

**Required**: Stale-while-revalidate caching layer for cluster-wide metrics.

```elixir
defmodule LassoWeb.Dashboard.ClusterMetricsCache do
  use GenServer

  @cache_ttl_ms 16_000  # 1s longer than 15s refresh interval to avoid race
  @stale_ttl_ms 30_000

  def get_cluster_metrics(profile, chain) do
    GenServer.call(__MODULE__, {:get, profile, chain})
  end

  # Returns {:ok, data, :fresh | :stale} or blocks for initial fetch
end
```

**Configuration**:
- Fresh TTL: 16 seconds (intentionally offset from refresh interval)
- Stale TTL: 30 seconds
- RPC timeout: 5 seconds
- Dashboard refresh interval: 15 seconds
- Single producer per cache key (prevents duplicate RPC)

**TTL Note**: Fresh TTL (16s) is intentionally 1 second longer than refresh interval (15s) to prevent race conditions where cache expires just before scheduled refresh, causing regular stale periods.

### 5.2 Async RPC Pattern

**NEVER block LiveView processes with synchronous RPC calls.** Use `Task.Supervisor.async_nolink`:

```elixir
def handle_info(:refresh_cluster_metrics, socket) do
  task = Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
    ClusterMetricsCache.get_cluster_metrics(
      socket.assigns.selected_profile,
      socket.assigns.selected_chain
    )
  end)

  {:noreply, assign(socket, :metrics_task, task)}
end

def handle_info({ref, {:ok, metrics, freshness}}, socket)
    when socket.assigns.metrics_task.ref == ref do
  Process.demonitor(ref, [:flush])
  socket = socket
    |> assign(:provider_metrics, metrics)
    |> assign(:metrics_stale, freshness == :stale)
    |> assign(:metrics_task, nil)
  {:noreply, socket}
end

def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
    when socket.assigns.metrics_task.ref == ref do
  {:noreply, assign(socket, :metrics_task, nil)}
end
```

### 5.3 Coverage Indicators

**Global fixed indicator** showing cluster health in bottom-left corner of dashboard.

#### Global Cluster Status Indicator

A fixed-position indicator in the bottom-left corner of the Dashboard and Metrics tabs showing:

```
N/N nodes reporting
```

**Visual states:**
| State | Display | Color |
|-------|---------|-------|
| Full (N/N) | "3/3 nodes reporting" | Gray (subtle) |
| Partial (<N) | "2/3 nodes reporting" | Amber with ⚠ |
| Degraded (<50%) | "1/3 nodes reporting" | Red with ⚠ |

This single indicator provides cluster health awareness without cluttering individual panels.

#### Implementation

```heex
<div class="fixed bottom-4 left-4 z-50">
  <.cluster_status_indicator
    responding={@cluster_metrics.responding_nodes}
    total={@cluster_metrics.total_nodes}
  />
</div>
```

### 5.4 Performance Budgets

| Metric | Target | Max Acceptable |
|--------|--------|----------------|
| Cluster RPC p95 | <500ms | <2000ms |
| Cache hit rate | >80% | >50% |
| Max payload size | 50KB | 100KB |
| Events per second (per node) | 100/s | 150/s |
| LiveView mailbox size p95 | <100 | <1000 |

---

## 6. Metrics Aggregation

### 6.1 Aggregation Rules

| Metric | Method | Formula | Rationale |
|--------|--------|---------|-----------|
| `total_calls` | SUM | `Σ node_calls` | Additive across nodes |
| `success_count` | SUM | `Σ node_successes` | Additive across nodes |
| `success_rate` | WEIGHTED_AVG | `Σ(rate × calls) / Σ calls` | Traffic-weighted accuracy |
| `avg_latency` | WEIGHTED_AVG | `Σ(latency × calls) / Σ calls` | Traffic-weighted accuracy |
| `p50/p95/p99` | **PER_REGION** | N/A | **Never average percentiles** |
| `rps` | **FIXED_WINDOW** | `Σ(calls_in_window) / window_seconds` | See 6.2 below |
| `failover_count` | SUM | `Σ node_failovers` | Events are additive |
| `circuit_state` | AGGREGATE_BADGE | "2/3 healthy" | Show summary + drill-down |
| `provider_score` | WEIGHTED_AVG | By total_calls | Composite metric |

### 6.2 RPS Aggregation (Critical Correctness)

**Problem**: Simple `SUM(node_rps)` is incorrect if nodes use varying time windows.

**Example of incorrect aggregation**:
- Node A: 10 events over 5 seconds → 2.0 RPS
- Node B: 20 events over 60 seconds → 0.33 RPS
- Incorrect sum: 2.33 RPS
- Correct cluster rate over 60s: (10 + 20) / 60 = 0.5 RPS

**Correct formula**:
```elixir
def aggregate_rps(node_metrics, window_seconds \\ 60) do
  total_calls = Enum.sum(Enum.map(node_metrics, & &1.calls_in_window))
  total_calls / window_seconds
end
```

Each node must report `calls_in_window` using the **same fixed window duration** (e.g., 60 seconds).

### 6.2 Provider Ranking Algorithm (Dashboard-Only)

**Important**: This ranking is for **dashboard display purposes only**. It does NOT affect routing or provider selection in the RPC hot path.

```elixir
def calculate_cluster_score(success_rate, avg_latency_ms, total_calls) do
  reliability_factor = :math.pow(success_rate, 2)
  latency_factor = 1000 / (1000 + avg_latency_ms)
  confidence_factor = :math.log10(max(total_calls, 1))

  reliability_factor * latency_factor * confidence_factor
end
```

Alternative (simpler): Sort provider tables by user-selectable keys (success rate, total calls, latency-by-region) and defer composite scoring.

### 6.3 Latency Display

**Never average percentiles across regions.** Use region filter pills to control display.

#### Region Filter Pills

Above the Provider Performance table, show toggleable region pills:

```
[All Regions ✓] [US-East] [EU-West] [Asia]
```

**Behavior:**
- **Default (All Regions):** Show weighted-average latency across all regions
- **Single region selected:** Show metrics from that region only
- Pills are mutually exclusive (select all OR one specific region)

**Visual treatment:**
- Active pill: Filled background with accent color
- Inactive pills: Outlined, clickable
- Position: Above the Provider Performance table header

#### Example Usage

```heex
<div class="flex gap-2 mb-4">
  <.region_pill
    :for={region <- ["all" | @available_regions]}
    region={region}
    selected={@selected_region == region}
    on_click="select_region"
  />
</div>
```

This approach avoids averaging percentiles (statistically invalid) while keeping the table layout simple.

### 6.4 Edge Case Handling

| Edge Case | Handling |
|-----------|----------|
| Node with 0 calls | Exclude from weighted averages |
| Node with <10 calls | Exclude from weighted averages (cold start bias) |
| Stale data (>30s) | Include with staleness indicator |
| Missing provider | Show with "(2/3 nodes)" coverage indicator |
| RPC timeout | Return partial results with coverage warning |
| All nodes timeout | Return cached data with "data may be stale" warning |

### 6.5 Region Tracking Requirement

For per-region metrics display and accurate latency breakdown, **each node must report its region**:

```elixir
# During RPC aggregation, tag each result with its source
defp fetch_and_tag_metrics(nodes) do
  {results, bad_nodes} = :rpc.multicall(nodes, BenchmarkStore, :get_metrics, [], 5_000)

  Enum.zip(nodes -- bad_nodes, results)
  |> Enum.map(fn {node, metrics} ->
    region = get_node_region(node)
    Map.put(metrics, :source_region, region)
  end)
end

defp get_node_region(node) do
  case :rpc.call(node, System, :get_env, ["CLUSTER_REGION"], 1_000) do
    region when is_binary(region) -> region
    _ -> "unknown"
  end
end
```

**Implementation Note**: If modifying BenchmarkStore to track region internally is preferred, add `source_region` field to stored metrics and include in `get_provider_leaderboard/2` response.

### 6.6 Statistical Considerations

#### Percentile Approximation
BenchmarkStore uses a 100-sample reservoir for latency tracking. Percentile calculations are **approximations**, not exact values. Document this in UI tooltips.

#### Simpson's Paradox Risk
When aggregating success rates across nodes with different traffic volumes, weighted averages can mask regional issues:
- Node A: 99% success on 10,000 calls (US-East, healthy)
- Node B: 80% success on 100 calls (EU-West, degraded)
- Weighted average: 97.3% (masks EU-West problem)

**Mitigation**: Show min/max alongside aggregates when regional variance exceeds 10%:
```
Success Rate: 97.3% (80-99% by region)
```

#### Maximum Staleness
Worst-case staleness chain: 15s (BenchmarkStore) + 15s (cache TTL) + 15s (dashboard refresh) = **~45 seconds**. Document this as expected behavior for dashboard data.

#### Cold Start Bias
Newly joined nodes or nodes with very few samples can skew weighted averages. Require minimum 10 calls before including in aggregation.

---

## 7. UX Guidelines

### 7.1 Truth Model

Scoping is **automatic** based on metric type—no user-facing toggle required.

#### Scoping by Metric Type

| Metric/Panel | Scope | Rationale |
|--------------|-------|-----------|
| Activity Feed | Account-scoped | "My requests" - avoids noise from other users |
| RPS / Success Rate | Account-scoped | "My traffic" metrics |
| Failover Events | Account-scoped | Debugging context for user's requests |
| Provider Leaderboard | Profile-scoped | Shared benchmark signal |
| Network Topology | Profile-scoped | Shared provider health |
| Circuit Breaker State | Profile-scoped | Shared infrastructure signal |
| Latency Metrics | Profile-scoped | Aggregate performance data |

#### OSS vs Cloud Behavior

| Deployment | Profile Type | Effective Behavior |
|------------|--------------|-------------------|
| **OSS** | Always custom | Profile-scoped = account-scoped (single operator) |
| **Cloud** | Custom/BYOK | Profile-scoped = account-scoped (private by construction) |
| **Cloud** | Shared (preset) | Account-scoped activity, profile-scoped health signals |

#### Profile Type Detection

- **Default assumption:** Custom profile (profile = account)
- **Cloud preset detection:** Check if `profile` is in preset list (`["free", "premium"]`)
- When preset: Subscribe activity feed to `routing:decisions:{profile}:account:{account_id}`
- When custom: Subscribe to `routing:decisions:{profile}` (equivalent scoping)

#### Admin Full-View (Deferred to V2)

For debugging, admins can access full profile view via `?show_all=true` query param. This is not exposed in the standard UI.

### 7.2 Topology Provider Status

Provider nodes in the network topology show **worst-case status** across all regions:

| Visual | Meaning | Condition |
|--------|---------|-----------|
| ● Green | All regions healthy | All circuits closed, no lag |
| ◐ Yellow | Some degraded | 1+ regions degraded or half-open |
| ⚠ Red | Critical | Any region has open circuit |
| ○ Gray | No data | All regions unreachable |

**Key behavior:** If any single region is experiencing issues, the entire provider node highlights to indicate attention needed. This keeps the topology visualization simple while surfacing problems.

**Click provider node:** Opens Provider Detail Panel with per-region breakdown (see Section 7.4).

### 7.3 Warning Copy

**Partial coverage**:
> Showing data from 2 of 3 nodes. US-West unreachable.

**Circuit breaker tooltip**:
> Circuit breaker state varies by region. US-East: Closed (healthy). EU-West: Open (degraded). Asia: Closed (healthy). Circuit breakers are regional to isolate failures.

### 7.4 Provider Detail Panel: Unified Region Tabs

When a provider node is clicked in the topology, the detail panel uses a **unified region tab group** that controls all sections (not separate tabs for different data types).

**Tab Group Design:**
```
┌─────────────────────────────────────────────────────────────┐
│ Provider: Alchemy                                    [×]    │
├──────────┬──────────┬──────────┬────────────────────────────┤
│Aggregate │ us-east  │ eu-west• │              2/2 regions   │
├──────────┴──────────┴──────────┴────────────────────────────┤
│ [Sync Status section - varies by tab]                       │
│ [Metrics strip - varies by tab]                             │
│ [Circuit Breaker - HIDDEN in aggregate, shown in region]    │
│ [Issues section - filtered by tab]                          │
│ [Method Performance - varies by tab]                        │
└─────────────────────────────────────────────────────────────┘
```

**Key behaviors:**
- Single tab group controls all panel sections
- Tabs with issues (open circuits) show red text + red dot indicator
- Circuit breaker section is **hidden in aggregate view** (circuit states are per-node)
- Region count shown inline (`N/N regions`)
- Default: Aggregate view selected

**Rationale for hiding aggregate circuit view:**
Circuit breakers are inherently per-node state. Showing an "aggregate" circuit state is misleading - a provider may be healthy in one region but failing in another. Instead, regions with issues are highlighted in the tab bar so users can click through to see the specific problem.

### 7.5 Activity Feed: Region Attribution

Each event in the activity feed shows the source region as a badge:

```
[US-East] eth_call → alchemy  45ms  ✓
[EU-West] eth_getBalance → infura  120ms  ✓
[Asia]    eth_blockNumber → quicknode  89ms  ✗ timeout
```

**Implementation:**
- Small region badge before the method name
- Badge color: neutral (gray) - not status-colored
- Source region from event's `source_region` field

This helps users understand geographic distribution of their traffic without cluttering the feed.

### 7.6 Existing Component Integration Summary

| Component | Clustering Change |
|-----------|------------------|
| `network_topology.ex` | Provider status reflects worst-case across regions |
| `provider_details_panel.ex` | Unified region tabs control all sections; circuit breaker hidden in aggregate |
| `region_selector.ex` | **NEW** - Reusable tab-style region selector with issue highlighting |
| `metrics_tab.ex` | Uses RegionSelector for region filtering |
| `event_buffer.ex` | Extend with dedup logic for `request_id` |
| `dashboard.ex` | Add fixed cluster status indicator (bottom-left) |
| `cluster_metrics_cache.ex` | Extended with `p50_latency`, `p95_latency`, `pick_share_5m` per region |
| Activity feed events | Add region badge to each event row |

---

## 8. Testing Strategy

### 8.1 Unit Tests

- Mock `Node.list/0` returning configurable node lists
- Test aggregation functions with edge cases (0 calls, stale data, missing providers)
- Test deduplication with duplicate events

```elixir
test "aggregation excludes nodes with 0 calls" do
  results = [
    %{provider_id: "alchemy", total_calls: 100, success_rate: 0.99},
    %{provider_id: "alchemy", total_calls: 0, success_rate: 0.50}
  ]

  aggregated = aggregate_provider_metrics([results])
  assert aggregated.success_rate == 0.99  # Not averaged with 0.50
end
```

### 8.2 Integration Tests (LocalCluster)

```elixir
test "cluster metrics aggregation across nodes" do
  {:ok, [node1, node2]} = LocalCluster.start_nodes("lasso", 2)

  :rpc.call(node1, BenchmarkStore, :record_success, [...])
  :rpc.call(node2, BenchmarkStore, :record_success, [...])

  {:ok, metrics, _} = ClusterMetricsCache.get_cluster_metrics("default", "ethereum")
  assert metrics.responding_nodes == 2
end
```

### 8.3 Staging Environment Tests

1. **Cluster formation**: Verify `Node.list()` returns other nodes
2. **Rolling deploy**: Verify cluster survives node replacement
3. **Partition simulation**: Use `fly machine stop` to simulate node failure
4. **Load test**: 100 concurrent dashboard viewers, measure cache hit rate

---

## 9. Operational Runbook

### 9.1 Health Endpoint

The `/health` endpoint MUST include cluster state:

```json
{
  "status": "healthy",
  "cluster": {
    "enabled": true,
    "nodes_connected": 2,
    "nodes_total": 3,
    "regions": ["iad", "lhr", "nrt"]
  }
}
```

### 9.2 Deployment Checklist

1. Verify `RELEASE_COOKIE` is set as environment variable on all nodes
2. Deploy one region at a time for rolling deploys
3. Monitor cluster node count during deploy
4. Verify all nodes join cluster within 60 seconds
5. Check dashboard shows correct node coverage

### 9.3 Failure Modes

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Single node crash | Instant (supervisor) | Fly auto-restart (~30s) |
| Network partition | 45-75s (net_ticktime) | libcluster rejoins on heal |
| Cookie mismatch | Instant (connection refused) | Re-set secret, redeploy |
| DNS resolution failure | 5s (polling_interval) | Retry on next poll |

### 9.4 Alerting Thresholds

| Alert | Condition | Severity |
|-------|-----------|----------|
| Cluster Split | `nodes_connected < expected - 1` for >2 min | Critical |
| Zero Nodes | `nodes_connected == 0` for >1 min | Critical |
| Repeated Flaps | >5 nodedown/nodeup cycles in 10 min | Warning |
| Slow RPC | p99 > 2000ms | Warning |

---

## 10. Related Documents

- [PUBSUB_EVENTS.md](./PUBSUB_EVENTS.md) - Event schemas and topic hierarchy
- [DASHBOARD_CLUSTERING.md](./DASHBOARD_CLUSTERING.md) - Caching and performance patterns
- [IMPLEMENTATION_CHECKLIST.md](./IMPLEMENTATION_CHECKLIST.md) - Phase-by-phase implementation tasks
- [CLUSTERING_OPERATIONS_GUIDE.md](./CLUSTERING_OPERATIONS_GUIDE.md) - Operational runbooks and failure modes

---

## 11. V2 Considerations

Items deferred from V1 with criteria for revisiting:

| Item | Trigger to Revisit | V2 Approach |
|------|-------------------|-------------|
| **CU Accumulator flush** | Billing complaints about missing CUs | Node-aware flush with at-least-once semantics |
| **ClusterCircuitState RPC** | Users need real-time cross-region circuit visibility | Lightweight RPC query (not PubSub-based cache) |
| **Adaptive event sampling** | Event rate >1000/s causes dashboard lag | Dynamic rate based on recent event throughput |
| **Per-profile sample rates** | High-traffic profiles overwhelm dashboard | Profile-specific config in database |
| **Region filter toggle** | Users request filtering by region | UI toggle + filtered subscriptions |

### Known Approximations to Document

**RPS Window Alignment**: Nodes may have clock skew of 1-5 seconds. When aggregating call counts:
- Node A's "last 60 seconds" might end at T=100
- Node B's might end at T=103 (RPC latency)

This introduces ~5% error in cluster RPS calculations. Acceptable for dashboard display. If precision is needed later, use wall-clock aligned windows (e.g., "events since last minute boundary").

**EventDedup Memory Bound**: With 5% sampling at high traffic:
- 10,000 req/s × 5% = 500 events/s
- 60s window = 30,000 entries max

A 30K-entry MapSet is acceptable (~1-2MB). Document this as expected ceiling.

---

## Appendix A: Component Clustering Decisions

| Component | Cluster Behavior | Rationale |
|-----------|-----------------|-----------|
| **Circuit Breaker** | Keep node-local | Regional isolation is correct for geo-distributed proxy |
| **ProviderPool** | Keep node-local + publish events | Each node maintains independent health view |
| **BenchmarkStore** | Keep node-local + aggregate on read | Latency is geographic; aggregate for display only |
| **RateLimitState** | Keep node-local | IP-based limits don't transfer across nodes |
| **CU Accumulator** | Keep node-local (defer fix) | 10s loss acceptable |
| **KeyCache** | Keep node-local + broadcast refresh | Eventual consistency acceptable for auth |
| **BlockCache** | Keep node-local | Converges naturally; no coordination needed |

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **Node** | A single Erlang VM instance running Lasso |
| **Cluster** | Multiple connected nodes forming a distributed system |
| **Circuit Breaker** | State machine preventing requests to failing providers |
| **Profile** | A configuration namespace for chains and providers |
| **CU (Compute Unit)** | Billing unit based on request size and method |
| **Stale-While-Revalidate** | Caching pattern that serves stale data while refreshing |

## Appendix C: Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1-0.3 | Jan 2026 | Initial draft through reviews |
| 1.0 | Jan 2026 | V1 spec incorporating all review findings |
