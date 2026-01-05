# Lasso RPC Architecture

## System Overview

Lasso RPC is an Elixir/OTP application that provides intelligent RPC provider orchestration and routing for blockchain applications. Built on the BEAM VM, Lasso delivers production-grade fault tolerance, massive concurrency, and self-healing capabilities.

### Core Capabilities

- **Multi-profile isolation**: Independent routing configurations per profile with isolated metrics and circuit breakers
- **Transport-agnostic routing**: Unified pipeline routes across HTTP and WebSocket based on real-time performance
- **Provider orchestration**: Pluggable selection strategies (`:fastest`, `:latency_weighted`, `:round_robin`)
- **WebSocket subscription management**: Intelligent multiplexing with automatic failover and gap-filling
- **Circuit breaker protection**: Per-provider, per-transport breakers prevent cascade failures
- **Method-specific benchmarking**: Passive latency measurement per-chain, per-method, per-transport
- **Request observability**: Structured logging with optional client-visible metadata

---

## Profile System Architecture

Lasso implements multi-tenancy through profiles, where each profile represents an isolated routing configuration with independent chains, providers, and rate limits.

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

### Profile-Scoped Supervision

Each `(profile, chain)` pair runs in an isolated supervision tree:

- **Complete isolation**: Independent circuit breakers, metrics, provider state
- **No resource sharing**: Providers in different profiles don't share connections
- **Independent lifecycle**: Profiles can be started/stopped without affecting others

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
├── Lasso.Core.Benchmarking.BenchmarkStore
├── Lasso.Core.Benchmarking.Persistence
├── Lasso.Config.ConfigStore
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

## Transport-Agnostic Request Pipeline

Lasso routes JSON-RPC requests across both HTTP and WebSocket transports based on real-time performance.

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

Lasso provides production-grade WebSocket subscriptions with multiplexing and automatic failover.

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

**Example**: 100 clients subscribe to `eth_subscribe("newHeads")`

- **Without multiplexing**: 100 upstream WebSocket subscriptions
- **With Lasso**: 1 upstream subscription shared across all clients

### Failover with Gap-Filling

When a provider fails mid-stream:

1. StreamCoordinator detects failure
2. Computes gap from `last_seen_block` to current head
3. HTTP backfill via GapFiller fetches missed blocks
4. Injects backfilled events into stream
5. Subscribes to new provider and continues

Result: Clients see continuous event stream with no gaps.

---

## Block Height Monitoring

Lasso tracks blockchain state through two mechanisms:

### BlockSync System

**BlockSync.Worker** (`Lasso.Core.BlockSync.Worker`)
- Tracks block heights from passive traffic
- Periodic `eth_blockNumber` queries
- Stores in centralized ETS registry

**BlockSync.Registry** (`Lasso.Core.BlockSync.Registry`)
- Centralized block height source per (profile, chain)
- <1ms lookups via ETS
- Used for consensus height calculations

### Health Probing

**HealthProbe.Worker** (`Lasso.Core.HealthProbe.Worker`)
- Per-provider periodic probes (configurable interval)
- Sends `eth_blockNumber` to each provider
- Reports results to ProviderPool
- Fire-and-forget (non-blocking)

**Configuration** (per-chain in profile YAML):
```yaml
chains:
  ethereum:
    monitoring:
      probe_interval_ms: 12000  # 12s (mainnet block time)
```

---

## Provider Selection

Selection strategies determine which provider serves each request.

### Available Strategies

**:fastest** (default)
- Selects provider with lowest latency for specific method
- Based on passive benchmarking via BenchmarkStore

**:latency_weighted**
- Weighted random selection based on latency scores
- Prevents overloading single "fastest" provider

**:round_robin**
- Rotates through healthy providers
- Simple load balancing

### Selection API

```elixir
# Best HTTP provider for method
{:ok, provider_id} = Selection.select_best_http_provider(
  profile,
  chain,
  method
)

# Best WebSocket provider for subscription
{:ok, provider_id} = Selection.select_best_ws_provider(
  profile,
  chain,
  method
)
```

---

## Circuit Breaker System

Per-provider, per-transport circuit breakers prevent cascade failures.

### State Machine

**:closed** → **:open**: After `failure_threshold` consecutive failures
**:open** → **:half_open**: After `recovery_timeout` expires
**:half_open** → **:closed**: After `success_threshold` consecutive successes
**:half_open** → **:open**: On any failure

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

---

## Request Observability

Comprehensive request tracking with minimal overhead.

### RequestContext Lifecycle

Every RPC request tracked through:

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
    "selected_provider": {"id": "ethereum_llamarpc"},
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
    "selected_provider": {"id": "ethereum_llamarpc"}
  }
}
```

---

## Provider Adapter System

Provider adapters validate requests before sending upstream, preventing rejections and unnecessary failovers.

### Design

**Lazy Parameter Validation**:
1. Filter by method support (build candidate list)
2. Selection returns ordered channels
3. Validate params for selected channel
4. Failover on validation failure
5. Repeat until success

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
      eth_get_logs_block_range: 50  # Override Alchemy's default (10)
```

### Current Adapters

- **Alchemy**: Block range validation for `eth_getLogs`
- **PublicNode**: Address count limits (HTTP: 25, WS: 20)
- **LlamaRPC**: Block range limits (1000 blocks)
- **Merkle**: Block range limits (1000 blocks)
- **Cloudflare**: No restrictions
- **DRPC**: Rate limit detection
- **1RPC**: Parameter limit detection
- **Generic**: Fallback for unknown providers

---

## Error Classification

Composable error categorization where adapters can override provider-specific codes.

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

ETS-based configuration cache:

```elixir
# Fast lookups (no file I/O)
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

Lasso works as drop-in replacement for existing RPC URLs:

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

| Operation | Latency | Notes |
|-----------|---------|-------|
| Context creation | <1ms | Single struct allocation |
| Provider selection | 2-5ms | ETS lookups + scoring |
| Benchmarking update | <1ms | Async ETS write |
| Circuit breaker check | <0.1ms | GenServer call |
| Request observability | <5ms | Async logger |
| Total overhead | ~10ms | End-to-end added latency |

### Scalability

- **Concurrent requests**: 10,000+ simultaneous (BEAM lightweight processes)
- **Subscriptions per upstream**: 1,000+ clients per upstream subscription
- **Memory per request**: <1KB (RequestContext + temporary state)
- **ETS table scans**: <1ms P99 (consensus height calculation)

---

## Summary

Lasso's architecture delivers:

✅ **Multi-profile isolation** - Complete independence per routing configuration
✅ **Transport-agnostic routing** - Unified pipeline across HTTP and WebSocket
✅ **WebSocket multiplexing** - Orders of magnitude connection reduction
✅ **Comprehensive observability** - Complete visibility into routing decisions
✅ **Massive concurrency** - BEAM VM's lightweight processes enable thousands of concurrent connections

This architecture scales from single self-hosted instances to globally distributed networks.
