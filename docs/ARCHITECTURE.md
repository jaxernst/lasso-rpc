# Lasso RPC Architecture

## System Overview

Elixir/OTP application providing RPC provider orchestration and routing for blockchain applications.

### Core Capabilities

- **Multi-profile isolation**: Independent routing configurations per profile with isolated metrics and circuit breakers
- **Transport-agnostic routing**: Unified pipeline routes across HTTP and WebSocket based on real-time performance
- **Provider orchestration**: Pluggable selection strategies (`:fastest`, `:latency_weighted`, `:round_robin`)
- **WebSocket subscription management**: Intelligent multiplexing with automatic failover and gap-filling
- **Circuit breaker protection**: Per-provider, per-transport breakers prevent cascade failures
- **Method-specific benchmarking**: Passive latency measurement per-chain, per-method, per-transport
- **Request observability**: Structured logging with optional client-visible metadata
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

# Unique identifier for this node (typically a region name for geo-distributed deployments)
export LASSO_NODE_ID="us-east-1"
```

---

## Profile System Architecture

Multi-tenancy via profiles: isolated routing configurations with independent chains, providers, and rate limits.

### Profile Structure

```yaml
# config/profiles/default.yml
name: "Lasso Public"
slug: "default"
type: "standard"
default_rps_limit: 100
default_burst_limit: 500

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

See `config/profiles/default.yml` for complete configuration reference.

### Profile-Scoped Supervision

Each `(profile, chain)` pair runs in an isolated supervision tree with independent circuit breakers, metrics, and provider state.

### URL Routing

```
# Profile-aware routes
/rpc/profile/:profile/:chain
/rpc/profile/:profile/fastest/:chain

# Default profile (uses "default" profile)
/rpc/:chain
/rpc/fastest/:chain
```

---

## OTP Supervision Architecture

The supervision tree is profile-scoped for complete isolation:

```
Lasso.Application
├── Phoenix.PubSub
├── Finch (HTTP pool)
├── Cluster.Supervisor (libcluster node discovery)
├── Task.Supervisor (async operations)
├── Lasso.Cluster.Topology (cluster membership & health)
├── Lasso.Core.Benchmarking.BenchmarkStore
├── Lasso.Core.Benchmarking.Persistence
├── Lasso.Config.ConfigStore
├── LassoWeb.Dashboard.MetricsStore (cluster-wide metrics cache)
├── Lasso.Dashboard.StreamSupervisor (DynamicSupervisor)
│   └── EventStream {profile} (real-time dashboard aggregation)
├── ProfileChainSupervisor (DynamicSupervisor)
│   └── ChainSupervisor {profile, chain}
│       ├── ProviderPool
│       ├── TransportRegistry
│       ├── BlockSync.Supervisor
│       │   └── BlockSync.Worker
│       ├── HealthProbe.Supervisor
│       │   └── HealthProbe.Worker (per provider)
│       ├── DynamicSupervisor (per-provider)
│       │   └── ProviderSupervisor
│       │       ├── CircuitBreaker (HTTP)
│       │       ├── CircuitBreaker (WS)
│       │       └── WSConnection
│       ├── UpstreamSubscriptionManager
│       ├── UpstreamSubscriptionPool
│       ├── StreamSupervisor
│       │   └── StreamCoordinator (per subscription key)
│       └── ClientSubscriptionRegistry
└── LassoWeb.Endpoint
```

### Key Components

**ProfileChainSupervisor** (`Lasso.ProfileChainSupervisor`)

- Top-level dynamic supervisor managing `(profile, chain)` pairs
- Enables independent lifecycle per configuration

**ChainSupervisor** (`Lasso.ChainSupervisor`)

- Per-(profile, chain) supervisor providing fault isolation
- Manages provider pool, health monitoring, and subscriptions

**ProviderSupervisor** (`Lasso.ProviderSupervisor`)

- Per-provider supervisor managing circuit breakers and connections
- One per provider in each (profile, chain)

**CircuitBreaker** (`Lasso.Core.Support.CircuitBreaker`)

- GenServer tracking failures per provider+transport
- Implements open/half-open/closed state machine

**WSConnection** (`Lasso.Core.Transport.WebSocket.Connection`)

- GenServer managing persistent WebSocket connection to single provider

**ProviderPool** (`Lasso.Core.Providers.ProviderPool`)

- GenServer tracking provider health and sync state in ETS

**HealthProbe.Worker** (`Lasso.Core.HealthProbe.Worker`)

- Per-provider worker executing periodic `eth_blockNumber` probes
- Reports results to ProviderPool

**BlockSync.Worker** (`Lasso.Core.BlockSync.Worker`)

- Tracks block heights from passive traffic and probes
- Centralized source for consensus height

**TransportRegistry** (`Lasso.Core.Transport.Registry`)

- Registry for discovering available HTTP/WS channels per provider

**UpstreamSubscriptionPool** (`Lasso.Core.Streaming.UpstreamSubscriptionPool`)

- GenServer multiplexing client subscriptions to minimal upstream connections

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
MetricsStore.get_provider_leaderboard("default", "ethereum")
# => %{data: [...], coverage: %{responding: 3, total: 3}, stale: false}
```

- **Cache TTL**: 15 seconds
- **RPC timeout**: 5 seconds
- **Invalidation**: Automatic on node connect/disconnect
- **Aggregation**: Weighted averages by call volume across nodes

### Node Identity

Each node has a unique `LASSO_NODE_ID` (convention: use geographic region names like `"us-east-1"`). State is partitioned by `{provider_id, node_id}` keys for per-node latency comparison, circuit breaker visibility, and traffic analysis.

---

## Transport-Agnostic Request Pipeline

Routes JSON-RPC requests across HTTP and WebSocket transports based on real-time performance.

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

**HTTP Transport** (`Lasso.Core.Transport.HTTP`)

- Uses Finch connection pools for HTTP/2 multiplexing
- Per-provider circuit breaker wraps all requests

**WebSocket Transport** (`Lasso.Core.Transport.WebSocket`)

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
├─→ GapFiller (HTTP backfill)
└─→ ClientSubscriptionRegistry (fan-out)
```

### Multiplexing

100 clients subscribing to `eth_subscribe("newHeads")` share a single upstream subscription.

### Failover with Gap-Filling

On provider failure mid-stream:

1. StreamCoordinator detects failure
2. Computes gap: `last_seen_block` to current head
3. GapFiller backfills missed blocks via HTTP
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
- Enables optimistic lag calculation with known staleness
- Resilient to WebSocket failures

**WebSocket Subscription** (Optional):

- Sub-second block notifications when healthy
- Degrades gracefully to HTTP on failure

HTTP polling provides predictable observation delay, enabling fair lag comparison across providers. WebSocket subscriptions can stale unpredictably (network issues, rate limits, provider cleanup), causing unbounded observation delay.

### BlockSync Components

**BlockSync.Worker** (`Lasso.Core.BlockSync.Worker`)

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

**BlockSync.Registry** (`Lasso.Core.BlockSync.Registry`)

Centralized ETS-based block height storage:

```elixir
# Registry key structure
{:height, chain, provider_id} => {height, timestamp, source, metadata}

# Example
{:height, "arbitrum", "drpc"} => {421_535_503, 1736894871234, :http, %{latency_ms: 45}}
```

- Single source of truth for height data
- Both HTTP and WS write to same key (last write wins)
- <1ms lookups for lag calculations
- Supports consensus height derivation

### Dynamic Block Time Measurement

**BlockTimeMeasurement** (`Lasso.Core.BlockSync.BlockTimeMeasurement`)

Derives per-chain block intervals using Exponential Moving Average (EMA) for optimistic lag calculation:

```elixir
@ema_alpha 0.15        # Adapts in ~10-15 samples
@min_block_time_ms 50  # Floor: filters multi-provider convergence noise
@max_block_time_ms 60_000  # Ceiling: rejects chain halts
@min_samples 5         # Warmup threshold
```

**Algorithm**:

1. On height update: calculate `interval = elapsed_ms / blocks_advanced`
2. If `min <= interval <= max`: update EMA
3. After 5 samples: prefer dynamic measurement over config

EMA adapts to variable block production (e.g., Arbitrum's 100ms-5s range) while smoothing noise.

### Optimistic Lag Calculation

Compensates for observation delay on fast chains to prevent false lag detection.

**Algorithm**:

```elixir
elapsed_ms = now - timestamp
block_time_ms = Registry.get_block_time_ms(chain) || config.block_time_ms
staleness_credit = min(div(elapsed_ms, block_time_ms), div(30_000, block_time_ms))
optimistic_height = height + staleness_credit
optimistic_lag = optimistic_height - consensus_height
```

**Example** (Arbitrum - 250ms blocks, 2s poll):

```
reported_height: 421,535,503
consensus_height: 421,535,511
raw_lag: -8 blocks

elapsed: 2000ms → credit: 2000/250 = 8 blocks
optimistic_height: 421,535,503 + 8 = 421,535,511
optimistic_lag: 0 blocks
```

Bounded observation delay from HTTP polling enables accurate credit calculation. The 30s cap prevents runaway values on stale connections.

### Health Probing

**HealthProbe.Worker** (`Lasso.Core.HealthProbe.Worker`)

Per-provider health monitoring independent of BlockSync:

- Periodic `eth_chainId` probes (health check + version detection)
- Bypasses circuit breakers to detect recovery
- Reports to ProviderPool

**Configuration**:

```yaml
chains:
  ethereum:
    block_time_ms: 12000 # Optimistic lag calculation
    monitoring:
      probe_interval_ms: 12000 # HTTP polling interval
      lag_alert_threshold_blocks: 5
```

### Health Probe Backoff

Health probes implement exponential backoff for degraded providers to reduce probe load:

| Consecutive Failures | Backoff |
|---------------------|---------|
| 0-1 | 0 (probe normally) |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |
| 5 | 16 seconds |
| 6+ | 30 seconds (capped) |

- Backoff uses monotonic time to avoid wall-clock jump issues
- ±20% jitter prevents synchronized probe storms across providers
- Backoff resets immediately on success
- HTTP and WebSocket probes track backoff independently
- Round-robin advancement is unaffected (only the individual probe may be skipped)

---

## Provider Selection

### Available Strategies

**:fastest** (default)

- Lowest latency provider for method (passive benchmarking via BenchmarkStore)

**:latency_weighted**

- Weighted random selection by latency scores

**:round_robin**

- Simple rotation through healthy providers

### Selection API

```elixir
# Select best provider for a method
{:ok, provider_id} = Selection.select_provider(
  profile,
  chain,
  method
)

# Select ordered list of channels (provider + transport combinations)
{:ok, channels} = Selection.select_channels(
  profile,
  chain,
  method
)
# Returns: [%Channel{provider: "alchemy", transport: :http}, ...]

# Select specific provider channel
{:ok, channel} = Selection.select_provider_channel(
  profile,
  chain,
  provider_id,
  transport  # :http or :ws
)
```

---

## Circuit Breaker System

Per-provider, per-transport circuit breakers.

### State Machine

- **:closed** → **:open**: After `failure_threshold` consecutive failures
- **:open** → **:half_open**: After `recovery_timeout`
- **:half_open** → **:closed**: After `success_threshold` consecutive successes
- **:half_open** → **:open**: On any failure

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

RPC requests tracked via:

```elixir
%RequestContext{
  request_id: "uuid",
  chain: "ethereum",
  method: "eth_blockNumber",
  transport: :http,
  strategy: :fastest,

  # Selection
  candidate_providers: ["ethereum_llamarpc:http"],
  selected_provider: %{id: "ethereum_llamarpc", protocol: :http},
  selection_latency_ms: 3,

  # Execution
  retries: 0,
  circuit_breaker_state: :closed,
  upstream_latency_ms: 592,

  # Result
  status: :success
}
```

### Structured Logging

All requests emit JSON logs:

```json
{
  "event": "rpc.request.completed",
  "request_id": "uuid",
  "strategy": "fastest",
  "chain": "ethereum",
  "transport": "http",
  "jsonrpc_method": "eth_blockNumber",
  "routing": {
    "selected_provider": { "id": "ethereum_llamarpc" },
    "retries": 0,
    "circuit_breaker_state": "closed"
  },
  "timing": {
    "upstream_latency_ms": 592,
    "end_to_end_latency_ms": 595
  }
}
```

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

## Provider Adapter System

Adapters validate requests before sending upstream to prevent rejections and unnecessary failovers.

### Lazy Parameter Validation

1. Filter candidates by method support
2. Select ordered channels
3. Validate params for selected channel
4. On validation failure: failover to next channel

### Adapter Behavior

```elixir
defmodule Lasso.Core.Providers.ProviderAdapter do
  @callback supports_method?(method, transport, ctx) :: boolean()
  @callback validate_params(method, params, transport, ctx) ::
    :ok | {:error, reason}
  @callback normalize_request(request, ctx) :: request
  @callback normalize_response(response, ctx) :: response
  @callback normalize_error(error, ctx) :: error
end
```

### Per-Chain Configuration

Adapters provide defaults, but `adapter_config` in YAML allows per-chain overrides:

```yaml
providers:
  - id: "alchemy_base"
    url: "https://..."
    adapter_config:
      eth_get_logs_block_range: 50 # Override Alchemy's default (10)
```

### Current Adapters

- **Alchemy**: `eth_getLogs` block range validation
- **PublicNode**: Address count limits (HTTP: 25, WS: 20)
- **LlamaRPC/Merkle**: 1000 block range limit
- **DRPC/1RPC**: Rate/parameter limit detection
- **Cloudflare**: No restrictions
- **Generic**: Fallback adapter

---

## Error Classification

Composable error categorization with provider-specific overrides.

### Classification Flow

```elixir
# 1. Try adapter override
case adapter.classify_error(code, message) do
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
- `:capability_violation`, `:method_not_found`

**Non-retriable**:

- `:invalid_params`, `:user_error`, `:client_error`

**No circuit breaker penalty**:

- `:rate_limit` - Temporary backpressure with known recovery
- `:capability_violation` - Permanent constraint, not transient failure

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
- Database backend: SaaS extension (not in OSS)

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

**Not yet supported**:

- Write methods: `eth_sendRawTransaction`, `eth_sendTransaction`
- Batch requests (planned)

---

## Performance Characteristics

### Overhead

| Operation             | Latency | Notes                    |
| --------------------- | ------- | ------------------------ |
| Context creation      | <1ms    | Single struct allocation |
| Provider selection    | 2-5ms   | ETS lookups + scoring    |
| Benchmarking update   | <1ms    | Async ETS write          |
| Circuit breaker check | <0.1ms  | GenServer call           |
| Request observability | <5ms    | Async logger             |
| Total overhead        | ~10ms   | End-to-end added latency |

### Scalability

- **Concurrent requests**: 10,000+ simultaneous (BEAM lightweight processes)
- **Subscriptions per upstream**: 1,000+ clients per upstream subscription
- **Memory per request**: <1KB (RequestContext + temporary state)
- **ETS table scans**: <1ms P99 (consensus height calculation)

---

## Summary

Core architectural properties:

- **Geo-distributed proxy**: Each node routes independently based on local latency measurements
- **Multi-profile isolation**: Independent supervision trees per (profile, chain)
- **Transport-agnostic routing**: Unified pipeline across HTTP and WebSocket
- **WebSocket multiplexing**: N:1 client-to-upstream subscription ratio
- **Cluster aggregation**: Optional BEAM clustering for unified observability without routing impact
- **Request observability**: Structured logging with optional client metadata
- **BEAM concurrency**: 10,000+ concurrent requests via lightweight processes
