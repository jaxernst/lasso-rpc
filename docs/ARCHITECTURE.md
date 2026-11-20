# Lasso RPC Architecture

## System Overview

Elixir/OTP application providing RPC provider orchestration and routing for blockchain applications.

Domain terms are defined in [CONTEXT.md](../CONTEXT.md).

### Core Capabilities

- **Multi-profile isolation**: Independent routing configuration and metrics per profile; profiles that reference the same upstream share its health and circuit breakers
- **Transport-agnostic routing**: Unified pipeline routes across HTTP and WebSocket based on real-time performance
- **Provider orchestration**: Pluggable selection strategies (`:fastest`, `:balanced_fast`, `:load_balanced`, `:priority`)
- **WebSocket subscription management**: Intelligent multiplexing with automatic failover and gap-filling
- **Circuit breaker protection**: Per-provider, per-transport breakers prevent cascade failures
- **Method-specific benchmarking**: Passive latency measurement per-chain, per-method, per-transport
- **Request observability**: Request telemetry with optional client-visible metadata
- **Cluster aggregation**: Optional BEAM clustering for aggregated observability across geo-distributed nodes

---

## Geo-Distributed Proxy Design

Lasso is designed for geo-distributed deployments where each node operates independently while optionally sharing observability data.

### Deployment Model

```
┌─────────────────────────────────────────────────────────────┐
│ Application (US-East)                                       │
│ └─> Lasso Node (US-East)                                   │
│     └─> Routes to fastest providers for this region        │
├─────────────────────────────────────────────────────────────┤
│ Application (EU-West)                                       │
│ └─> Lasso Node (EU-West)                                   │
│     └─> Routes to fastest providers for this region        │
├─────────────────────────────────────────────────────────────┤
│ Cluster Aggregation (optional)                              │
│ ├─> Topology monitoring (node health across regions)       │
│ ├─> Regional metrics aggregation for dashboard             │
│ └─> No impact on routing hot path                          │
└─────────────────────────────────────────────────────────────┘
```

### Key Principles

**Independent Node Operation**

- Each Lasso node runs a complete, isolated supervision tree
- Routing decisions are based on local latency measurements only
- No cluster consensus or coordination in the request hot path
- A single node works standalone without clustering

**Regional Latency Awareness**

- Passive benchmarking reveals which providers are fastest from each region
- Applications connect to their nearest Lasso node for region-optimized routing
- Provider performance varies significantly by geography

**Observability-First Clustering**

- Clustering aggregates metrics for dashboards and operational visibility
- View the cluster as a unified whole or drill into individual regions
- Identify providers struggling in specific regions
- No routing impact: clustering is purely for observability

### Configuration

**Single node (default)**: No additional configuration needed.

**Multi-node cluster**:

```bash
# Enable clustering with DNS-based node discovery
export CLUSTER_DNS_QUERY="lasso.internal"
export CLUSTER_NODE_BASENAME="lasso"

# Unique identifier for this node (typically a region name for geo-distributed deployments)
export LASSO_NODE_ID="us-east-1"
```

---

## Profile System Architecture

Profiles select routing configurations, chains, and provider credentials. Profile names are routing namespaces, not authentication boundaries. Profile rate settings configure the dashboard tester; enforce incoming client quotas at the reverse proxy.

### Profile Structure

```yaml
# config/profiles/public.yml
---
name: "Lasso Public"
slug: "public"
rps_limit: 100
burst_limit: 500
---

chains:
  ethereum:
    chain_id: 1
    monitoring:
      probe_interval_ms: 12000
    providers:
      - id: "ethereum_llamarpc"
        url: "https://eth.llamarpc.com"
        ws_url: "wss://eth.llamarpc.com"
```

See `config/profiles/public.yml` for complete configuration reference.

### Profile-Scoped Supervision

Each `(profile, chain)` pair owns its routing configuration and profile metrics. Profiles referencing the same upstream instance share instance health, circuit breakers, and transport state; separate credentials identify separate upstream instances.

### URL Routing

```
# Profile-aware routes
/rpc/profile/:profile/:chain
/rpc/profile/:profile/fastest/:chain

# Default route (uses the included "public" profile)
/rpc/:chain
/rpc/fastest/:chain
```

---

## OTP Supervision Architecture

The supervision tree is profile-scoped. Upstream instances, with their health, circuit breakers and transports, are shared by every profile that references them:

```
Lasso.Application
├── Phoenix.PubSub
├── Finch (HTTP pool)
├── Cluster.Supervisor (libcluster node discovery)
├── Task.Supervisor (async operations)
├── Lasso.Cluster.Topology (cluster membership & health)
├── Lasso.Benchmarking.BenchmarkStore
├── Lasso.Benchmarking.Persistence
├── Lasso.Config.ConfigStore
├── LassoWeb.Dashboard.MetricsStore (cluster-wide metrics cache)
├── Lasso.Dashboard.StreamSupervisor (DynamicSupervisor)
│   └── EventStream {profile} (real-time dashboard aggregation)
├── Lasso.Providers.InstanceDynamicSupervisor (shared provider infrastructure)
│   └── InstanceSupervisor {instance_id} (one per unique upstream)
│       ├── CircuitBreaker {instance_id, :http}
│       ├── CircuitBreaker {instance_id, :ws}
│       ├── WSConnection {instance_id}
│       └── InstanceSubscriptionManager {instance_id}
├── Lasso.Providers.ProbeSupervisor (DynamicSupervisor)
│   └── ProbeCoordinator {chain} (one per unique chain)
├── Lasso.BlockSync.DynamicSupervisor
│   └── BlockSync.Worker {chain, instance_id} (one per unique instance per chain)
├── ProfileChainSupervisor (DynamicSupervisor)
│   └── ChainSupervisor {profile, chain}
│       ├── TransportRegistry
│       ├── ClientSubscriptionRegistry
│       ├── UpstreamSubscriptionPool
│       └── StreamSupervisor
│           └── StreamCoordinator (per subscription key)
└── LassoWeb.Endpoint
```

### Key Components

**Lasso.Providers.Catalog** (Module, not GenServer)

- Maps profiles to shared provider instances
- Builds ETS catalog from ConfigStore, swaps via persistent_term atomically
- Provides O(1) lookups: instance config, instance refs, profile providers

**Lasso.Providers.InstanceSupervisor**

- Per-instance supervisor for shared circuit breakers, WebSocket connection, and upstream subscription manager
- One supervisor per unique `instance_id` (derived from chain + URL + auth)
- Started under `InstanceDynamicSupervisor`
- Children: CircuitBreaker (HTTP), CircuitBreaker (WS), WSConnection, InstanceSubscriptionManager

**Lasso.Providers.ProbeCoordinator**

- Per-chain health probe coordinator (one per unique chain)
- 200ms tick cycle, probes one instance per tick with exponential backoff
- Writes results to `:lasso_instance_state` ETS
- Replaces per-(profile, chain) BatchCoordinator (deleted)

**Lasso.Providers.CandidateListing** (Module, not GenServer)

- Pure ETS reads for provider selection
- 8-stage filter pipeline: transport availability, WS liveness, circuit state, rate limits, lag, min block height filtering, archival, exclusions
- Replaces ProviderPool.list_candidates (ProviderPool deleted)

**ProfileChainSupervisor** (`Lasso.ProfileChainSupervisor`)

- Top-level dynamic supervisor managing `(profile, chain)` pairs
- Enables independent lifecycle per configuration

**ChainSupervisor** (`Lasso.RPC.ChainSupervisor`)

- Per-(profile, chain) supervisor providing policy isolation
- No longer starts per-provider processes (health/CBs/WS/BlockSync are shared at instance level)
- Children: TransportRegistry, ClientSubscriptionRegistry, UpstreamSubscriptionPool, StreamSupervisor

**CircuitBreaker** (`Lasso.Core.Support.CircuitBreaker`)

- GenServer tracking failures per `{instance_id, transport}`
- Implements open/half-open/closed state machine
- Writes state to `:lasso_instance_state` ETS on every transition
- Shared across all profiles using the same upstream

**WSConnection** (`Lasso.RPC.Transport.WebSocket.Connection`)

- GenServer managing persistent WebSocket connection
- Started via `start_shared_link/1` under InstanceSupervisor
- Shared across all profiles using the same upstream

**BlockSync.Supervisor** (`Lasso.BlockSync.Supervisor`)

- Singleton interface to `BlockSync.DynamicSupervisor`
- Manages one Worker per `(chain, instance_id)` pair
- Workers track block heights via HTTP polling or WebSocket subscriptions
- Broadcasts block updates to all profiles referencing that instance

**BlockSync.Worker** (`Lasso.BlockSync.Worker`)

- Per-(chain, instance_id) GenServer tracking block heights
- Polls via HTTP or subscribes via WS depending on provider capabilities
- Fan-out broadcasts to all profiles using this instance
- Replaces per-(profile, provider_id) workers (migrated from profile-scoped to instance-scoped)

**TransportRegistry** (`Lasso.RPC.TransportRegistry`)

- Registry for discovering available HTTP/WS channels per provider
- Caches channel references in `:transport_channel_cache` ETS

**InstanceSubscriptionManager** (`Lasso.Core.Streaming.InstanceSubscriptionManager`)

- Per-instance_id GenServer managing upstream WebSocket subscriptions
- Handles subscription lifecycle (`eth_subscribe`, `eth_unsubscribe`) with the upstream provider
- Receives events from WSConnection via PubSub topic `ws:subs:instance:{instance_id}`
- Dispatches events to consumers via `InstanceSubscriptionRegistry` (duplicate-key Registry)
- Replaces per-profile `UpstreamSubscriptionManager` (deleted)

**UpstreamSubscriptionPool** (`Lasso.Core.Streaming.UpstreamSubscriptionPool`)

- Per-(profile, chain) GenServer multiplexing client subscriptions to minimal upstream connections
- Resolves `provider_id` → `instance_id` via Catalog
- Calls `InstanceSubscriptionManager.ensure_subscription` to share upstream subscriptions across profiles
- Registers in `InstanceSubscriptionRegistry` to receive events

**StreamCoordinator** (`Lasso.Core.Streaming.StreamCoordinator`)

- Per-subscription-key GenServer managing continuity and gap-filling

**ClientSubscriptionRegistry** (`Lasso.Core.Streaming.ClientSubscriptionRegistry`)

- Registry for fan-out of subscription events to connected clients

---

## Cluster Topology & Aggregation

When BEAM clustering is enabled, Lasso nodes form a topology-aware cluster for aggregated observability.

### Topology Module

**Topology** (`Lasso.Cluster.Topology`)

Single source of truth for cluster membership and node health:

```
Lasso.Cluster.Topology (GenServer)
├── :net_kernel.monitor_nodes/1  (only subscriber in codebase)
├── Periodic health checks (15s intervals via :rpc.multicall)
├── Region discovery with retry/backoff
└── PubSub broadcasts → "cluster:topology"
```

All cluster-aware modules subscribe to the `"cluster:topology"` PubSub topic rather than monitoring nodes directly.

**Node Lifecycle States:**

| State           | Description                                       |
| --------------- | ------------------------------------------------- |
| `:connected`    | Erlang distribution connection established        |
| `:discovering`  | Region identification via RPC in progress         |
| `:responding`   | Passes health checks, region known                |
| `:unresponsive` | Connected but failing health checks (3+ failures) |
| `:disconnected` | Previously connected, now offline                 |

### Dashboard Event Streaming

**EventStream** (`LassoWeb.Dashboard.EventStream`)

Per-profile GenServer aggregating real-time events for dashboard LiveViews:

- Subscribes to: topology changes, routing decisions, circuit events, block sync
- Batches events (50ms intervals, max 100 per batch)
- Computes per-provider metrics grouped by region
- Broadcasts to LiveView subscribers

**Subscriber Messages:**

- `{:metrics_update, %{metrics: provider_metrics}}`
- `{:events_batch, %{events: recent_events}}`
- `{:cluster_update, %{connected: n, responding: n, regions: [...]}}`
- `{:circuit_update, %{provider_id: id, region: region, circuit: state}}`

### Cluster-Wide Metrics

**MetricsStore** (`LassoWeb.Dashboard.MetricsStore`)

Caches aggregated metrics from all cluster nodes using stale-while-revalidate:

```elixir
# Queries all responding nodes, aggregates results
MetricsStore.get_provider_leaderboard("public", "ethereum")
# => %{data: [...], coverage: %{responding: 2, total: 3}, stale: false}
```

- **Cache TTL**: 15 seconds
- **RPC timeout**: 5 seconds
- **Invalidation**: Automatic on node connect/disconnect
- **Aggregation**: Weighted averages by call volume across nodes

Dashboard coverage is responding nodes out of expected nodes. The total uses
`:expected_cluster_nodes` when configured (at least the connected node count),
so a missing configured node does not shrink the denominator. Without that
setting, the total remains the connected node count. Traffic summaries require
responses from every expected node before treating the figures as complete.

### Node Identity

Each node has a unique `LASSO_NODE_ID` (convention: use geographic region names like `"us-east-1"`). State is partitioned by `{provider_id, node_id}` keys for per-node latency comparison, circuit breaker visibility, and traffic analysis.

---

## Transport-Agnostic Request Pipeline

Routes JSON-RPC requests across HTTP and WebSocket transports based on real-time performance.

`Lasso.Core.Request.TransactionConfirmation` confirms rejected raw transactions
with a single lookup and decorates transaction send errors before terminal projection.

### Request Flow

```
Client Request
     ↓
RequestPipeline.execute_via_channels/4
     ↓
Selection.select_best_http_provider(profile, chain, method)
     ↓
Returns ordered channels: [
  %Channel{provider: "alchemy", transport: :http},
  %Channel{provider: "infura", transport: :ws}
]
     ↓
Attempt request on first channel
     ↓
On failure: Try next channel (automatic failover)
     ↓
Record metrics per provider+transport+method
```

### Transport Implementations

**HTTP Transport** (`Lasso.RPC.Transports.HTTP`)

- Uses Finch connection pools for HTTP/2 multiplexing
- Per-provider circuit breaker wraps all requests

**WebSocket Transport** (`Lasso.RPC.Transports.WebSocket`)

- Uses persistent WSConnection GenServers
- Supports both unary calls and subscriptions
- Correlation ID mapping for request/response

---

## WebSocket Subscription Management

WebSocket subscriptions with multiplexing and automatic failover.

### Architecture

```
Client (Viem/Wagmi)
     ↓
RPCSocket (Phoenix Channel)
     ↓
SubscriptionRouter
     ↓
UpstreamSubscriptionPool (multiplexing)
     ↓
WSConnection (upstream provider)
     ↓
StreamCoordinator (per-subscription key)
     ↓
├─→ Backfill → GapFiller (HTTP backfill)
└─→ ClientSubscriptionRegistry (fan-out)
```

### Multiplexing

100 clients subscribing to `eth_subscribe("newHeads")` share a single upstream subscription.

### Failover with Gap-Filling

On provider failure mid-stream:

1. StreamCoordinator detects failure
2. Computes gap: `last_seen_block` to current head
3. Backfill reconciles missed blocks and logs via GapFiller HTTP requests
4. Injects backfilled events into stream
5. Subscribes to new provider

Clients receive continuous event stream without gaps.

---

## Block Height Monitoring

Lasso tracks blockchain state using HTTP polling as a reliable foundation with optional WebSocket subscription.

### BlockSync System Architecture

**Dual-Strategy Design:**

**HTTP Polling** (Always Running):

- Bounded observation delay (`probe_interval_ms`)
- Captures available reference evidence before HTTP polls
- Resilient to WebSocket failures

**WebSocket Subscription** (Optional):

- Sub-second block notifications when healthy
- Degrades gracefully to HTTP on failure

HTTP polling provides predictable observation delay, enabling fair lag comparison across providers. WebSocket subscriptions can stale unpredictably (network issues, rate limits, provider cleanup), causing unbounded observation delay.

### BlockSync Components

**BlockSync.Worker** (`Lasso.BlockSync.Worker`)

Per-provider GenServer managing block height tracking:

```
┌─────────────────────────────────────┐
│      BlockSync.Worker               │
├─────────────────────────────────────┤
│  HTTP: eth_blockNumber polling      │
│  WS (optional): newHeads events     │
└─────────────────────────────────────┘
           ↓
    BlockSync.Registry (ETS)
```

**Operating Modes**:

- `:http_only` - HTTP polling only
- `:http_with_ws` - HTTP + WebSocket subscription

**BlockSync.Registry** (`Lasso.BlockSync.Registry`)

The local ETS registry keeps the compatibility latest-height row and at most one
validated HTTP fact and one validated WebSocket fact per physical upstream.
The HTTP fact carries any qualified profile references captured before that
poll began. Removing the final profile reference to an upstream clears its
retained facts; a profile reload does not leave a removed upstream voting.

**Profile-scoped reference** (`Lasso.Providers.HeadEvidence` and
`Lasso.Observations.HeadComparison`)

A snapshot contains only the active physical upstreams for one `(profile,
chain)` pair. Each upstream has one vote, even when it has both transport
facts or is shared by several profiles. Recent WebSocket evidence represents
an upstream when it is close enough to the latest observation; otherwise the
latest fact does. The comparison aligns observation times only to decide
whether votes agree. Its reference height always comes from a concrete
upstream observation, never from a projected block.

At least two agreeing upstreams and a strict majority of current voters are
required for a **qualified** reference. A single voter is uncorroborated;
conflicting heads are ambiguous, and no voters means unavailable. The
reference freshness window is bounded from the configured `block_time_ms`
(30–60 seconds), with a
2-second agreement window. These are local observations, not fork finality or
fleet-wide consensus.

When recent WebSocket facts report different concrete hashes at the same
height, height alignment cannot qualify them. A strict physical majority must
report the same hash at that height; unknown hashes cannot break the tie. This
detects an observed branch conflict, not canonical ancestry across heights.

**Request and operator assessment**

Selection captures each route's latest observation once per request and judges
it against what the request needs: a numeric block, the moving head, or
nothing. The moving-head target is the highest fresh observation less the
agreement band. A route proven short of its target, or fresh at the qualified
reference height on a different hash, is deferred within its health tier and
never excluded; see [Head freshness](ROUTING.md#head-freshness). Operator
assessment is separate: the dashboard compares HTTP observations with the
reference captured before their poll and WebSocket observations with the
current qualified reference, using `monitoring.lag_alert_threshold_blocks`. A
stale fact, missing poll reference, wrong scope, or unqualified snapshot is
**unknown**, not a lagging verdict, and a same-height hash conflicting with the
qualified majority is also unknown to operators. For its lag component, any eligible
transport means synced; all assessable transports must lag before it reports
lagging. Circuit, rate-limit, and connection states still affect overall
provider status.

Historical request age uses a fresh, concrete reference from the requested
profile's head snapshot. A qualified or single-upstream uncorroborated reference
can classify a numeric selector; ambiguous or unavailable evidence cannot.
Another profile's higher head never makes this profile's request archival.

The older chain-wide `ChainState.consensus_height/1` remains available for
compatibility callers. It derives a P75 height from fresh observations
(maximum with fewer than four providers), with bounded time alignment for HTTP
samples. `BlockTimeMeasurement` tracks a dynamic interval for that older
optimistic calculation. This chain-wide height does not qualify a
profile-scoped routing or dashboard verdict.

### Health Probing

**Lasso.Providers.ProbeCoordinator**

Per-chain health probe coordinator (one per unique chain):

- 200ms tick cycle, probes one instance per tick
- Periodic `eth_chainId` probes (health check + version detection)
- Exponential backoff on failure (2s base, 30s max, ±20% jitter)
- Probes an instance on the next tick after a request to it times out, beside the scheduled visit, with at most one probe of an instance in flight
- Reports chain identity and probe health; two consecutive probe timeouts open the HTTP circuit
- Writes health status to `:lasso_instance_state` ETS

**Configuration**:

```yaml
chains:
  ethereum:
    block_time_ms: 12000 # Head agreement band and block credit
    monitoring:
      lag_alert_threshold_blocks: 5
```

Note: `probe_interval_ms` is no longer configurable per profile. ProbeCoordinator uses a fixed 200ms tick interval with per-instance exponential backoff.

### Health Probe Backoff

ProbeCoordinator implements exponential backoff for degraded instances to reduce probe load:

| Consecutive Failures | Backoff |
|---------------------|---------|
| 0-1 | 0 (probe on next tick) |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |
| 5 | 16 seconds |
| 6+ | 30 seconds (capped) |

- Backoff uses monotonic time to avoid wall-clock jump issues
- ±20% jitter prevents synchronized probe storms across instances
- Backoff resets immediately on success
- Each instance tracks its own backoff state independently
- Probes are dispatched as async Tasks to prevent slow instances from blocking the cycle

---

## Provider Selection

### Available Strategies

**:load_balanced**

- Distributes requests across healthy providers with health-aware tiering

**:fastest**

- Lowest recent successful mean among reliability-qualified upstream instances
- Reads published routing-evidence summaries rather than BenchmarkStore lifetime averages

**:balanced_fast** (default)

- Scale-free relative latency weights with exponential-race permutation
- Reliable upstreams are weighted on their best latency evidence; unreliable ones follow

### Selection API

[`Lasso.RPC.Selection`](../lib/lasso/core/selection/selection.ex) holds the
selection API and its types. `select_channels/4` returns a plain list of
[`Channel`](../lib/lasso/core/transport/channel.ex) structs.

---

## Circuit Breaker System

Per-provider, per-transport circuit breakers.

### State Machine

- **:closed** → **:open**: After `failure_threshold` consecutive failures
- **:open** → **:half_open**: After `recovery_timeout`
- **:half_open** → **:closed**: After `success_threshold` consecutive successes
- **:half_open** → **:open**: On any failure

Proven pre-send HTTP connection failures open the circuit after three failures.
Their cooldown starts at 1 second and doubles on failed probation up to 4 seconds,
plus jitter. The existing single half-open lease limits probation traffic; one
successful leased HTTP attempt closes a connection-class circuit. A free
connection probation lease keeps the route at its normal priority position so
ordinary requests can recover it even with background observations disabled.
Other failure classes retain their normal cooldown and success threshold.
A request timeout is neutral to the circuit, because it shows only that a
provider was slower than that attempt's share of one request's budget. It asks
the probe coordinator to probe the instance instead. The coordinator runs one
probe of an instance at a time and counts consecutive probe timeouts; at two it
opens the HTTP circuit, so an upstream that accepts requests and never answers
leaves the route. A probe success resets only that count. Probes never close a
circuit or count toward its probation, and no other probe outcome reaches the
breaker. Routed request and head-poll outcomes drive circuit recovery.

### Configuration

```elixir
config :lasso, :circuit_breaker,
  failure_threshold: 5,
  success_threshold: 2,
  recovery_timeout: 30_000
```

### Integration

- Selection excludes providers with open breakers
- Automatic recovery probing in half-open state
- Telemetry events for state transitions

### Telemetry Schema

All circuit breaker events use consistent metadata:

| Event | Required Metadata | Optional Metadata |
|-------|-------------------|-------------------|
| `[:lasso, :circuit_breaker, :open]` | chain, provider_id, transport, from_state, to_state, reason | error_category, failure_count, recovery_timeout_ms |
| `[:lasso, :circuit_breaker, :close]` | chain, provider_id, transport, from_state, to_state, reason | - |
| `[:lasso, :circuit_breaker, :half_open]` | chain, provider_id, transport, from_state, to_state, reason | - |
| `[:lasso, :circuit_breaker, :proactive_recovery]` | chain, provider_id, transport, from_state, to_state, reason | - |
| `[:lasso, :circuit_breaker, :failure]` | chain, provider_id, transport, error_category, circuit_state | - |

**Reason values:**

- `:failure_threshold_exceeded` - Opened due to consecutive failures
- `:reopen_due_to_failure` - Re-opened from half_open after failure
- `:recovered` - Closed after successful recovery
- `:attempt_recovery` - Transitioning to half_open to test recovery
- `:proactive_recovery` - Timer-based recovery attempt
- `:manual_open` / `:manual_close` - Manual intervention

---

## Request Observability

### RequestContext Lifecycle

Each request carries a
[`Lasso.RPC.RequestContext`](../lib/lasso/core/request/request_context.ex);
the struct and its type list the current fields.

### Request Telemetry

The pipeline emits `[:lasso, :rpc, :request, :stop]` with a `duration`
measurement in milliseconds and chain, method, provider, strategy, transport,
result, and failover metadata. Operational logs cover failures and state
transitions. See [Observability](OBSERVABILITY.md) for the supported signals.

### Client-Visible Metadata (Opt-in)

**Query parameter**: `?include_meta=headers|body`

**Headers mode**:

```
X-Lasso-Request-ID: uuid
X-Lasso-Meta: eyJ2ZXJzaW9u... (base64url JSON)
```

**Body mode**:

```json
{
  "jsonrpc": "2.0",
  "result": "0x8471c9a",
  "lasso_meta": {
    "request_id": "uuid",
    "strategy": "fastest",
    "selected_provider": { "id": "ethereum_llamarpc" }
  }
}
```

---

## Provider Capabilities System

Adapters validate requests before sending upstream to prevent rejections and unnecessary failovers.

### Lazy Parameter Validation

1. Filter candidates by method support
2. Select ordered channels
3. Validate params for selected channel
4. On validation failure: failover to next channel

### Declarative Capabilities

Provider capabilities are declared in YAML and evaluated by a single engine (`Lasso.RPC.Providers.Capabilities`):

```yaml
providers:
  - id: "ethereum_drpc"
    url: "https://eth.drpc.org"
    capabilities:
      unsupported_categories: []
      unsupported_methods: []
      limits:
        max_block_range: 10000
      error_rules:
        - code: 30
          message_contains: "timeout on the free tier"
          category: rate_limit
        - code: 35
          category: capability_violation
```

When `capabilities` is omitted, defaults to permissive behavior (only `:local_only` methods blocked).

The capabilities engine handles:
- **Method filtering**: `unsupported_categories` and `unsupported_methods`
- **Parameter validation**: `max_block_range` (eth_getLogs), `max_block_age` (state methods)
- **Error classification**: `error_rules` evaluated top-to-bottom, first match wins

---

## Error Classification

Composable error categorization with per-provider overrides via capabilities.

### Classification Flow

```elixir
# 1. Try per-provider error_rules from capabilities
case Capabilities.classify_error(code, message, capabilities) do
  {:ok, category} -> category
  :default -> ErrorClassification.categorize(code, message)
end

# 2. Derive behavior from category
%{
  category: category,
  retriable?: retriable?(category),
  breaker_penalty?: breaker_penalty?(category)
}
```

### Categories

**Retriable** (triggers failover):

- `:rate_limit`, `:network_error`, `:server_error`
- `:capability_violation`, `:method_not_found`, `:method_error`
- `:auth_error`, `:internal_error`, `:chain_error`, `:block_not_available`

**Non-retriable**:

- `:invalid_params`, `:invalid_request`, `:parse_error`, `:user_error`, `:client_error`

**No circuit breaker penalty**:

- `:rate_limit` - Temporary backpressure with known recovery
- `:capability_violation` - Permanent constraint, not transient failure
- `:block_not_available` - Provider healthy but slightly behind chain head
- `:client_error` - Client fault, not a provider failure

---

## Configuration Management

### ConfigStore

ETS-based configuration cache for fast lookups:

```elixir
{:ok, chain_config} = ConfigStore.get_chain(profile, "ethereum")
{:ok, provider_config} = ConfigStore.get_provider(profile, "ethereum", "alchemy")
```

### Profile Loading

**Two-phase initialization**:

1. ConfigStore.init creates ETS tables
2. Application calls `load_all_profiles()` after supervision tree is up

**Configuration backend abstraction**:

- File backend: Loads from `config/profiles/*.yml`

---

## JSON-RPC Compatibility

Drop-in replacement for existing RPC URLs.

### Supported Transports

- **HTTP**: Unary JSON-RPC methods
- **WebSocket**: Both unary calls and subscriptions (`eth_subscribe`)

### Method Support

**Read-only methods** (full support):

- Block queries: `eth_blockNumber`, `eth_getBlockByNumber`
- State queries: `eth_getBalance`, `eth_call`, `eth_getLogs`
- Gas queries: `eth_gasPrice`, `eth_estimateGas`

**Subscriptions** (WebSocket):

- `eth_subscribe("newHeads")`
- `eth_subscribe("logs", filter)`
- `eth_unsubscribe(subscription_id)`

**Batch Requests** (HTTP):

- JSON-RPC batch arrays supported (up to 50 requests per batch, configurable)
- A single provider is selected upfront for the whole batch for consistency; all items prefer that provider but can failover independently per-item
- Responses preserve request order

**Transactions**:

- `eth_sendRawTransaction` is supported. Without a chain `transactions` block, a send runs once and is not retried after dispatch. With one, sends go only to the listed providers and may be resent among them within the request deadline. See [RPC Standards](RPC_STANDARDS.md#transaction-sends).
- Methods that need node-held keys, such as `eth_sendTransaction`, are rejected.

---

## Performance Characteristics

Capacity depends on upstream limits, request mix, subscriptions, instrumentation,
and node resources. BEAM processes and ETS support concurrent routing, but do not
establish a throughput or latency guarantee. Benchmark representative workloads
on the intended deployment; no reproducible capacity benchmark is published here.

---

## Summary

Core architectural properties:

- **Geo-distributed proxy**: Each node routes independently based on local latency measurements
- **Multi-profile isolation**: Independent supervision trees per (profile, chain)
- **Transport-agnostic routing**: Unified pipeline across HTTP and WebSocket
- **WebSocket multiplexing**: N:1 client-to-upstream subscription ratio
- **Cluster aggregation**: Optional BEAM clustering for unified observability without routing impact
- **Request observability**: Request telemetry with optional client metadata
- **BEAM concurrency**: Requests use lightweight processes
