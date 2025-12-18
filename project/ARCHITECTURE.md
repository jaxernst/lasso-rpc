# Lasso RPC Architecture

## Core Technical Design

### **System Overview**

Lasso RPC is an Elixir/OTP application that provides intelligent RPC provider orchestration and routing, acting as a 'smart proxy' between blockchain applications and multiple RPC providers. Built on the battle-tested BEAM VM, Lasso delivers production-grade fault tolerance, massive concurrency, and self-healing capabilities for mission-critical blockchain infrastructure.

### **Core Capabilities**

- **Transport-agnostic routing**: Single unified pipeline routes requests across HTTP and WebSocket providers based on real-time performance
- **Multi-provider orchestration**: Pluggable selection strategies (`:fastest`, `:cheapest`, `:priority`, `:round_robin`)
- **Full JSON-RPC compatibility**: HTTP and WebSocket proxies for all standard read-only methods
- **WebSocket subscription management**: Intelligent multiplexing, automatic failover with gap-filling during provider switches
- **Circuit breaker protection**: Per-provider, per-transport circuit breakers prevent cascade failures
- **Method-specific benchmarking**: Passive latency measurement per-chain, per-method, per-transport for intelligent routing
- **Request observability**: Structured logging and optional client-visible metadata for routing transparency
- **Battle testing framework**: Integrated chaos engineering and load testing with sophisticated scenario DSL
- **Live dashboard**: Real-time provider leaderboards, performance metrics, circuit breaker status, and system simulator

---

## Regionality and Latency-Aware Routing

Lasso is designed to operate as a regional-first platform: clients connect to the nearest Lasso node, which then selects the lowest-latency upstream provider using region-local metrics.

- **Client proximity**: Use geo routing at the edge (DNS or managed LB) to land clients on the closest region
- **Region-local benchmarking**: Maintain per-region leaderboards and latency/error metrics; prefer the top provider for that region and method
- **Persistent connections**: Keep warm HTTP pools and provider WebSockets to minimize handshakes and reduce hop latency
- **Failover without regressions**: Circuit breakers, cooldowns, and provider pools ensure graceful rotation to the next best provider
- **Minimal overhead**: Hot-path selection and routing are in-memory (ETS/Registry); typical added latency is single-digit milliseconds, often offset by better upstream choice

**Separation of concerns:**

- **BEAM/Elixir**: Selection logic, benchmarking, circuit breaking, WS/HTTP proxying, telemetry (region-tagged), and per-region supervision (using `Registry`)
- **Infrastructure**: Global ingress/geo routing (DNS/LB), TLS termination and WS stickiness, environment config (`LASSO_REGION`), scaling, and observability stack

---

## OTP Supervision Architecture

Lasso leverages OTP for fault-tolerance and concurrency. The supervision tree provides chain isolation and fault boundaries:

```
Lasso.Application (Supervisor)
├── Phoenix.PubSub (event bus)
├── Finch (HTTP client pool)
├── Lasso.Benchmarking.BenchmarkStore (ETS metrics storage)
├── Lasso.Benchmarking.Persistence (historical snapshots)
├── Lasso.RPC.Caching.MetadataTableOwner (ETS table owner for metadata cache)
├── Registry (Lasso.Registry - dynamic process lookup)
├── DynamicSupervisor (Lasso.RPC.Supervisor)
│   ├── ChainSupervisor (ethereum)
│   │   ├── ProviderSupervisor (alchemy)
│   │   │   ├── CircuitBreaker (HTTP)
│   │   │   ├── CircuitBreaker (WS)
│   │   │   └── WSConnection (if WS configured)
│   │   ├── ProviderSupervisor (other public/private rpc providers)
│   │   ├── ProviderPool (metrics, health, connection tracking)
│   │   ├── ProviderProbe (periodic provider health probing)
│   │   ├── TransportRegistry (request channel discovery)
│   │   ├── UpstreamSubscriptionPool (WS multiplexing)
│   │   └── ClientSubscriptionRegistry (client fan-out)
│   ├── ChainSupervisor (any other evm chain)
├── Lasso.Config.ConfigStore (ETS config cache)
└── LassoWeb.Endpoint
```

### **Key Components**

- **Lasso.Application**: Top-level application supervisor
- **MetadataTableOwner**: Dedicated GenServer owning the `:blockchain_metadata` ETS table, ensuring table persists across monitor crashes
- **ChainSupervisor**: Per-chain supervisor providing fault isolation between networks
- **ProviderSupervisor**: Per-provider supervisor managing circuit breakers and WebSocket connections
- **CircuitBreaker**: GenServer tracking failures per provider+transport, implementing open/half-open/closed states
- **WSConnection**: GenServer managing persistent WebSocket connection to a single provider
- **ProviderPool**: GenServer tracking provider health, availability, and capabilities; stores provider sync state in ETS
- **ProviderProbe**: Per-chain GenServer executing periodic `eth_blockNumber` probes across all providers, reporting results to ProviderPool
- **ChainState**: Stateless module for on-demand consensus height calculation from ProviderPool ETS data (not a process)
- **TransportRegistry**: Registry for discovering available HTTP/WS channels per provider
- **UpstreamSubscriptionPool**: GenServer multiplexing client subscriptions to minimal upstream connections
- **StreamCoordinator**: GenServer managing subscription continuity, backfilling, and failover (spawned per subscription key)
- **ClientSubscriptionRegistry**: Registry for fan-out of subscription events to connected clients
- **RequestContext**: Stateless struct for tracking request lifecycle (not a process)
- **Observability**: Module for structured logging and metadata generation (not a process)
- **ObservabilityPlug**: Phoenix plug for parsing client metadata opt-in preferences

### **Supervision Strategy**

- **Configuration caching**: `ConfigStore` eliminates hot-path YAML loading with fast ETS lookups
- **Chain isolation**: Each blockchain network runs in a separate supervision tree under a dynamic supervisor, allowing chains to be started and stopped independently
- **Provider isolation**: Each provider runs under its own `ProviderSupervisor` with dedicated circuit breakers per transport
- **Transport abstraction**: `TransportRegistry` provides unified channel discovery across HTTP and WebSocket
- **Subscription multiplexing**: `UpstreamSubscriptionPool` reduces upstream connections by sharing subscriptions across multiple clients
- **Fault boundaries**: Provider failures are contained; circuit breakers prevent cascade failures across the system
- **Restart strategy**: Temporary failures trigger process restarts, while persistent failures trigger failover via circuit breakers and provider selection

---

## Transport-Agnostic Request Pipeline

Lasso implements a unified request pipeline that routes JSON-RPC requests across both HTTP and WebSocket transports based on real-time performance metrics.

### **Core Design Principles**

- **Single selection interface**: `RequestPipeline.execute_via_channels/4` routes to best provider regardless of transport
- **Transport behaviour**: Both HTTP and WebSocket implement `Lasso.RPC.Transport` behaviour
- **Channel abstraction**: `Channel` struct represents a realized connection (HTTP pool or WS connection)
- **Protocol-aware selection**: Selection considers transport capabilities, method support, and performance per transport
- **Unified metrics**: Circuit breakers and benchmarking track per-provider, per-transport, per-method metrics

### **Request Flow**

```
Client Request
     ↓
RequestPipeline.execute_via_channels/4
     ↓
Selection.select_channels(chain, method, strategy, transport_filter)
     ↓
Returns ordered candidates: [
  %Channel{provider: "alchemy", transport: :ws, ...},
  %Channel{provider: "infura", transport: :http, ...},
  %Channel{provider: "ankr", transport: :http, ...}
]
     ↓
Attempt request on first channel via Transport behaviour
     ↓
On failure: Try next channel (automatic failover across transports)
     ↓
Record metrics per provider+transport+method
```

### **Transport Implementations**

**`Lasso.RPC.Transport.HTTP`**

- Uses Finch connection pools for HTTP/2 multiplexing
- Implements `request/3` for single JSON-RPC calls
- Per-provider circuit breaker wraps all requests
- Supports batch requests (future)

**`Lasso.RPC.Transport.WebSocket`**

- Uses persistent WSConnection GenServers
- Implements `request/3` via correlation ID mapping
- Supports both unary calls and subscriptions
- Connection pooling for high concurrency (configurable)

### **Benefits**

- **Automatic optimization**: Fastest strategy can route `eth_blockNumber` to WS if it has lower latency than HTTP
- **Seamless failover**: HTTP failure can failover to WS provider automatically
- **Unified observability**: All requests tracked with same RequestContext regardless of transport
- **Simplified client code**: Applications use one endpoint; Lasso handles transport selection

---

## WebSocket Subscription Management

Lasso provides production-grade WebSocket subscription management with intelligent multiplexing, automatic failover, and gap-filling.

### **Architecture Overview**

```
Client (Viem/Wagmi)
     ↓
RPCSocket (Phoenix Channel)
     ↓
SubscriptionRouter (thin facade)
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

### **Key Components**

**UpstreamSubscriptionPool** (`lib/lasso/rpc/upstream_subscription_pool.ex`)

- **Multiplexing**: Multiple clients subscribe to same upstream subscription (efficiency)
- **Capability tracking**: Learns which providers support which subscription types
- **Provider selection**: Uses Selection module to pick best WS provider
- **Confirmation handling**: Maps upstream subscription IDs to client subscription IDs
- **Automatic failover**: Detects provider failures and switches to next best provider

**StreamCoordinator** (`lib/lasso/rpc/stream_coordinator.ex`)

- **Spawned per subscription key**: Each `(chain, subscription_type, filter)` gets own coordinator
- **Continuity management**: Tracks last seen block number/log index
- **Gap detection**: Computes missing events during provider switch
- **HTTP backfilling**: Uses `GapFiller` to fetch missed blocks/logs via HTTP
- **Deduplication**: `StreamState` ensures events delivered once and in-order

**ClientSubscriptionRegistry** (`lib/lasso/rpc/client_subscription_registry.ex`)

- **Fan-out**: Distributes upstream events to all subscribed clients
- **Client tracking**: Maps subscription IDs to Phoenix Channel PIDs
- **Clean-up**: Automatically removes disconnected clients

### **Subscription Flow**

1. **Client subscribes**: `{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}`
2. **UpstreamSubscriptionPool checks**: Do we already have upstream subscription for `(ethereum, newHeads, {})`?
   - **Yes**: Add client to fan-out list, return existing subscription ID
   - **No**: Select best WS provider, send `eth_subscribe` upstream
3. **Upstream confirms**: `{"jsonrpc":"2.0","id":1,"result":"0xabc123"}`
4. **Pool maps IDs**: Store `upstream_sub_id -> client_sub_ids`
5. **Events arrive**: `{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xabc123","result":{...}}}`
6. **StreamCoordinator processes**: Dedupe, order, track continuity
7. **Registry fans out**: Send to all subscribed clients

### **Failover with Gap-Filling**

When a provider fails mid-stream:

1. **Failure detected**: WSConnection crashes or subscription stops delivering events
2. **StreamCoordinator triggered**: `handle_info(:provider_failure, state)`
3. **Gap computation**:
   ```elixir
   last_seen = StreamState.last_block_num(state.stream_state)
   {:ok, new_provider} = Selection.select_best_ws_provider(state.chain)
   {:ok, current_head} = fetch_current_head(new_provider)
   gap = ContinuityPolicy.needed_block_range(last_seen, current_head, max_backfill: 32)
   ```
4. **HTTP backfill**: `GapFiller.ensure_blocks(chain, from_block, to_block, timeout: 30_000)`
5. **Inject missed events**: Cast backfilled blocks to self as subscription events
6. **Resume live stream**: Subscribe to new provider, continue from current head
7. **Client sees**: Continuous event stream with no gaps

### **Multiplexing Benefits**

**Example**: 100 clients subscribe to `eth_subscribe("newHeads")` on Ethereum

**Without multiplexing:**

- 100 upstream WebSocket subscriptions
- 100x bandwidth usage
- 100x rate limit consumption
- Providers may reject excess connections

**With multiplexing (Lasso):**

- 1 upstream WebSocket subscription
- 1x bandwidth usage
- Shared across all clients
- Scales to thousands of clients per upstream subscription

### **Configuration**

```elixir
# config/config.exs
config :lasso, :subscriptions,
  # Maximum blocks to backfill during failover
  max_backfill_blocks: 32,

  # Timeout for HTTP backfill requests
  backfill_timeout_ms: 30_000,

  # Subscription confirmation timeout
  subscription_timeout_ms: 10_000,

  # Enable gap-filling on provider switch
  enable_gap_filling: true
```

---

## Request Observability Architecture

**Files**:

- `lib/lasso/rpc/request_context.ex` - Request lifecycle tracking
- `lib/lasso/rpc/observability.ex` - Structured logging and metadata
- `lib/lasso_web/plugs/observability_plug.ex` - HTTP metadata injection

Lasso provides comprehensive request observability with minimal overhead:

### **RequestContext Lifecycle**

Every RPC request is tracked through its entire lifecycle using a `RequestContext` struct:

```elixir
%RequestContext{
  request_id: "uuid",
  chain: "ethereum",
  method: "eth_blockNumber",
  params_present: false,
  transport: :http,
  strategy: :cheapest,

  # Selection phase
  candidate_providers: ["ethereum_cloudflare:http", "ethereum_llamarpc:http"],
  selected_provider: %{id: "ethereum_llamarpc", protocol: :http},
  selection_reason: "cost_optimized",
  selection_latency_ms: 3,

  # Execution phase
  retries: 2,
  circuit_breaker_state: :closed,
  upstream_latency_ms: 592,
  end_to_end_latency_ms: 595,

  # Result phase
  status: :success,
  result_type: "string",
  error: nil
}
```

### **Context Threading**

RequestContext flows through the execution pipeline:

1. **Created** in `RequestPipeline.execute_via_channels/4` with initial request details
2. **Updated** during provider selection with candidates and timing
3. **Enriched** during execution with CB state, retries, and latencies
4. **Logged** via `Observability.log_request_completed/1` after completion
5. **Stored** in Process dictionary for controller access

```elixir
# RequestPipeline threads context through execution
def execute_via_channels(chain, method, params, opts) do
  ctx = RequestContext.new(chain, method, params_present: params != [])

  case execute_with_channel_selection(chain, rpc_request, ctx, transport, timeout) do
    {:ok, result, updated_ctx} ->
      Observability.log_request_completed(updated_ctx)
      Process.put(:request_context, updated_ctx)
      {:ok, result}
  end
end
```

### **Structured Log Events**

All requests emit structured JSON logs at configurable level (default `:info`):

```json
{
  "event": "rpc.request.completed",
  "request_id": "21027f767548a9b6ddff97c860e7e58c",
  "strategy": "cheapest",
  "chain": "ethereum",
  "transport": "http",
  "jsonrpc_method": "eth_blockNumber",
  "params_present": false,
  "routing": {
    "candidate_providers": [
      "ethereum_cloudflare:http",
      "ethereum_llamarpc:http"
    ],
    "selected_provider": { "id": "ethereum_llamarpc", "protocol": "http" },
    "selection_latency_ms": 0,
    "retries": 2,
    "circuit_breaker_state": "closed"
  },
  "timing": {
    "upstream_latency_ms": 592,
    "end_to_end_latency_ms": 592
  },
  "response": {
    "status": "success",
    "result_type": "string"
  }
}
```

### **Client-Visible Metadata (Opt-in)**

Clients can request routing metadata via query parameters or headers:

- `?include_meta=headers` - Adds `X-Lasso-Request-ID` and `X-Lasso-Meta` (base64url JSON) to response headers
- `?include_meta=body` - Adds `lasso_meta` field to JSON-RPC response body
- Header alternative: `X-Lasso-Include-Meta: headers|body`

**ObservabilityPlug** parses the opt-in preference and stores it in `conn.assigns`:

```elixir
# In router pipeline
pipeline :api_with_logging do
  plug(Plug.Logger, log: :info)
  plug(:accepts, ["json"])
  plug(LassoWeb.Plugs.ObservabilityPlug)
end
```

**RPCController** injects metadata when rendering responses:

```elixir
defp maybe_inject_observability_metadata(conn) do
  case conn.assigns[:include_meta] do
    :headers ->
      case Process.get(:request_context) do
        nil -> conn
        ctx -> ObservabilityPlug.inject_metadata(conn, ctx)
      end
    _ -> conn
  end
end
```

### **Privacy & Redaction**

- **Params digest**: SHA-256 hash instead of raw params (configurable)
- **Error truncation**: Max 256 chars for error messages (configurable)
- **Size limits**: Max 4KB for header metadata (fallback to request ID only)
- **Sampling**: Configurable sampling rate (0.0-1.0) for high-volume scenarios

### **Configuration**

```elixir
# config/config.exs
config :lasso, :observability,
  log_level: :info,
  max_error_message_chars: 256,
  max_meta_header_bytes: 4096,
  sampling: [rate: 1.0]
```

### **Performance Overhead**

- **Context creation**: <1ms (single struct allocation)
- **Timing markers**: <0.1ms per marker (System.monotonic_time/0)
- **Log emission**: <5ms (async logger with sampling support)
- **Header encoding**: <2ms (JSON encode + base64url)

---

## Production Architecture Design

### **Configuration Management**

**File**: `lib/lasso/config/config_store.ex`

In-memory configuration store:

- **ETS-based caching**: Configurations are loaded once at startup and cached in ETS tables
- **Fast lookups**: Chain and provider configurations are retrieved via in-memory lookups
- **Runtime reload**: Supports atomic configuration updates without restart
- **Typed structures**: Uses ChainConfig and ProviderConfig structs for type safety

```elixir
# Hot-path lookup (no file I/O)
{:ok, chain_config} = ConfigStore.get_chain("ethereum")
{:ok, provider_config} = ConfigStore.get_provider("ethereum", "alchemy")
```

### **Dynamic Chain Management**

Chain supervisors boot from the static config in `config/chains.yml`, but chains + providers can be added/removed/updated dynamically

- **Automatic startup**: `Application.start/2` enumerates configured chains and starts ChainSupervisors
- **Independent lifecycles**: Each chain can be started/stopped without affecting others
- **Status tracking**: Per-chain health and provider status available via `ChainSupervisor.get_chain_status/1`
- **Provider/chain registration**: Lasso.RPC.Provider exposes CRUD operations for chains/providers that orchestrate Chain/Provider supervisors

### **Provider Probing and Chain State**

**Files**:

- `lib/lasso/core/providers/provider_probe.ex` - Per-chain probe execution GenServer
- `lib/lasso/core/chain_state.ex` - Stateless consensus height calculation API
- `lib/lasso/core/providers/provider_pool.ex` - Provider state storage in ETS

Lasso maintains real-time blockchain state information through periodic probing and on-demand consensus calculation:

#### **Architecture**

**Separation of Concerns:**

- **ProviderProbe**: Execution-only (probing logic, scheduling, HTTP requests)
- **ProviderPool**: State-only (health status, sync state, ETS storage)
- **ChainState**: Read-only API (lazy consensus calculation from fresh data)

**Components:**

- **ProviderProbe**: Per-chain GenServer executing probes
  - Probes all providers via `eth_blockNumber` at configurable intervals (default: 12s)
  - Runs probes concurrently using `Task.Supervisor.async_stream`
  - Reports results to ProviderPool (fire-and-forget)
  - Tracks latency and errors for each probe
  - Emits telemetry events per probe cycle

- **ProviderPool**: Stores provider sync state in ETS
  - Receives probe results via `report_probe_results/2`
  - Updates per-provider sync state: `{block_height, timestamp, sequence}`
  - Calculates and stores per-provider lag relative to consensus
  - ETS table per chain with public read access

- **ChainState**: Stateless lazy evaluation API
  - `consensus_height/1` - Calculates max height from recent provider data
  - `provider_lag/2` - Returns blocks behind consensus for a provider
  - `consensus_fresh?/1` - Checks if consensus data is within probe window
  - No caching: recalculates on every call from fresh ETS data
  - Sub-millisecond performance (<1ms for 3-10 providers)

#### **Use Cases**

**1. Adapter Parameter Validation** (`merkle.ex`, `llamarpc.ex`, `alchemy.ex`)

Provider adapters use consensus height to validate `eth_getLogs` block ranges:

```elixir
# Validates that range doesn't exceed provider limits
def validate_params("eth_getLogs", params, _transport, ctx) do
  chain = Map.get(ctx, :chain, "ethereum")

  case ChainState.consensus_height(chain, allow_stale: true) do
    {:ok, height} -> validate_range(params, height)
    {:ok, height, :stale} -> validate_range(params, height)
    {:error, _} -> :ok  # Skip validation if unavailable (fail-open)
  end
end
```

**Benefits**: Real-time validation with accurate block heights, graceful degradation

**2. StreamCoordinator Failover Optimization** (`stream_coordinator.ex`)

Gap calculation during WebSocket subscription failover uses consensus height:

```elixir
defp fetch_head(chain, _provider_id) do
  case ChainState.consensus_height(chain) do
    {:ok, height} -> height  # <1ms calculation
    {:error, _} -> fetch_head_blocking(chain)  # Fallback to HTTP (200-500ms)
  end
end
```

**Benefits**: Failover performance improved from 200-500ms to <1ms P99

**3. Provider Lag Detection** (routing decisions)

```elixir
# Filter out providers >10 blocks behind consensus
{:ok, lag} = ChainState.provider_lag(chain, provider_id)
if lag < -10, do: :reject, else: :accept
```

#### **Configuration**

Probe intervals are configured per-chain in `config/chains.yml`:

```yaml
chains:
  ethereum:
    monitoring:
      probe_interval_ms: 12000  # Default: 12s (one per block on mainnet)
  base:
    monitoring:
      probe_interval_ms: 2000   # Default: 2s (faster L2 blocks)
```

Application-level defaults:

```elixir
# config/config.exs
config :lasso, :provider_probe,
  default_probe_interval_ms: 12_000,
  probe_interval_by_chain: %{
    "ethereum" => 12_000,
    "base" => 2_000
  }
```

**Key differences from old system:**
- Probes ALL providers every cycle (not just top N)
- No caching: ChainState calculates consensus on-demand
- Configurable per-chain via YAML
- Fire-and-forget reporting (no blocking)

#### **Telemetry Events**

```elixir
# Probe cycle events
[:lasso, :provider_probe, :cycle_completed]
# Measurements: %{successful: count, failed: count, duration_ms: ms}
# Metadata: %{chain: chain_name}
```

#### **Design Philosophy**

The probe system follows **separation of concerns**:

- **ProviderProbe**: Only executes probes and reports results (no state)
- **ProviderPool**: Only stores state and calculates lag (no execution)
- **ChainState**: Only reads and calculates consensus (no storage, no caching)

This architecture provides:

- **No stale data**: Consensus calculated on-demand from fresh provider data
- **Explicit error handling**: Callers handle unavailable data with `allow_stale` option
- **Fail-open by default**: Adapters skip validation if consensus unavailable
- **Observable failures**: All probe failures tracked via telemetry and logs
- **Easy testing**: Each component testable independently

**Key insight**: ETS scans are fast enough (<1ms) that on-demand calculation outperforms caching with staleness tracking.

#### **Performance Characteristics**

- **Consensus calculation**: <1ms P99 (ETS scan of 3-10 providers)
- **Provider lag lookup**: <5μs P99 (single ETS read)
- **Probe cycle**: <500ms P95 (concurrent probes via Task.Supervisor)
- **Memory overhead**: <10KB per chain (ETS table)
- **Failover optimization**: 200-500ms → <1ms (200-500x improvement vs blocking HTTP)

### **Unified Provider Selection**

**File**: `lib/lasso/rpc/selection.ex`

Selection module consolidates all provider picking logic:

- **Strategy-aware**: Supports latency optimized (:fastest), price optimized (:cheapest), and round_robin strategies
- **Protocol filtering**: Handles HTTP vs WebSocket protocol requirements
- **Pool-first fallback**: Tries ProviderPool first, falls back to config-based selection
- **Exclusion support**: Can exclude failed providers during failover

```elixir
# Unified selection interface
{:ok, provider_id} = Selection.pick_provider(
  "ethereum",
  "eth_getBalance",
  strategy: :fastest,
  protocol: :http
)
```

---

### **Circuit Breaker State Machine**

**File**: `lib/lasso/rpc/circuit_breaker.ex`

```elixir
def handle_call({:call, fun}, _from, state) do
  case state.state do
    :closed ->
      execute_call(fun, state)
    :open ->
      if should_attempt_recovery?(state) do
        new_state = %{state | state: :half_open}
        execute_call(fun, new_state)
      else
        {:reply, {:error, :circuit_open}, state}
      end
    :half_open ->
      execute_call(fun, state)
  end
end
```

**State Transitions**:

- `:closed` → `:open`: After failure_threshold consecutive failures
- `:open` → `:half_open`: After recovery_timeout expires
- `:half_open` → `:closed`: After success_threshold consecutive successes
- `:half_open` → `:open`: On any failure

---

## JSON-RPC Integration

### **Standard Method Support**

```elixir
# WebSocket subscriptions:
eth_subscribe("newHeads")        # Block events
eth_subscribe("logs")            # Transaction logs

# HTTP endpoints for benchmarking/proxying (read-only):
eth_getLogs(filter)              # Historical log queries
eth_getBlockByNumber(number)     # Block data retrieval
eth_getBalance(address)          # Account balance queries
```

### **Transport Capabilities**

- **HTTP**: Unary JSON-RPC method calls (e.g., `eth_blockNumber`, `eth_getBalance`)
- **WebSocket**: Both unary calls AND subscriptions (`eth_subscribe`, `eth_unsubscribe`)
- **Transport-agnostic routing**: RequestPipeline can route unary calls to either transport based on performance

### **Provider Selection Strategies**

Provider selection is pluggable. The main strategies include:

- **:fastest (default)**: Picks the highest-scoring provider from the `BenchmarkStore`. The score is based on method-specific RPC latency measurements and success rates, effectively making this a performance-based strategy.
- **:priority**: First available provider based on its statically configured `priority`.
- **:round_robin**: Rotates across available, healthy providers.
- **:cheapest**: Prefers providers marked as `type: "public"` before using others.

Configuration:

```elixir
# config/config.exs
config :lasso, :provider_selection_strategy, :fastest
# Alternatives: :cheapest | :priority | :round_robin
```

---

## Battle Testing Framework

Lasso includes a custom battle testing framework for validating reliability under load and chaos conditions.

### **Architecture**

```
Battle.Scenario (fluent DSL)
     ├─→ Battle.Workload (HTTP request generation)
     ├─→ Battle.Chaos (provider kill/flap/degrade)
     ├─→ Battle.Collector (telemetry aggregation)
     ├─→ Battle.Analyzer (percentile calculation, SLO verification)
     └─→ Battle.Reporter (JSON + Markdown reports)
```

### **Key Components**

**`Lasso.Battle.Scenario`** (`lib/lasso/battle/scenario.ex`)

- Fluent API for orchestrating complex test flows
- Step-by-step execution with timing control
- Automatic telemetry attachment and collection
- Clean-up and teardown management

**`Lasso.Battle.Workload`** (`lib/lasso/battle/workload.ex`)

- Configurable HTTP workload generation
- Concurrent request execution
- Method distribution (eth_blockNumber, eth_gasPrice, etc.)
- Per-request telemetry events

**`Lasso.Battle.Chaos`** (`lib/lasso/battle/chaos.ex`)

- **Kill**: Terminate provider processes to simulate crashes
- **Flap**: Repeatedly kill/restart to simulate instability
- **Degrade**: Inject latency or errors to simulate degraded performance

**`Lasso.Battle.Analyzer`** (`lib/lasso/battle/analyzer.ex`)

- Percentile calculation (P50, P95, P99)
- Success rate computation
- Failover detection (>2x average latency = failover)
- SLO verification with configurable thresholds

**`Lasso.Battle.Reporter`** (`lib/lasso/battle/reporter.ex`)

- JSON and Markdown report generation
- Human-readable summaries
- Detailed metrics breakdowns

### **Example Usage**

```elixir
# test/battle/failover_test.exs
test "HTTP failover under provider chaos" do
  Scenario.new("HTTP failover test")
  |> Scenario.setup_chain(:ethereum, providers: [:alchemy, :infura, :ankr])
  |> Scenario.run_workload(
    duration: 10 * 60_000,
    concurrency: 50,
    methods: ["eth_blockNumber", "eth_gasPrice"]
  )
  |> Scenario.inject_chaos(:kill_provider, target: :alchemy, interval: 30_000)
  |> Scenario.verify_slo(success_rate: 1, p95_latency_ms: 400)
  |> Scenario.generate_report()
end
```

### **Benefits**

- **Automated validation**: CI/CD integration for continuous reliability testing
- **Chaos engineering**: Prove system resilience under failure conditions
- **Performance regression**: Catch latency regressions before production
- **SLO enforcement**: Define and verify service level objectives

---

## Real-Time Dashboard Integration

### **Phoenix LiveView Components**

- **Latency Metrics**: Live provider rankings based on RPC performance
- **Routing Decision Events**: See how requests are routed in real time
- **Performance matrix**: RPC call latencies by provider and method
- **Circuit breaker status**: Real-time circuit breaker state visualization
- **Chain selection**: Switch between Ethereum, Base, Polygon, Arbitrum
- **System simulator**: Generate load for testing routing strategies
- **Real-time updates**: WebSocket push updates on new RPC metrics

### **Data Integration**

```elixir
def load_benchmark_data(socket) do
  chain_name = socket.assigns.benchmark_chain
  provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
  realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)
  # Leaderboard based on method-specific RPC latency and success rate metrics
end
```

---

## Configuration and Deployment

### **Environment Configuration**

```elixir
# config/prod.exs
config :lasso,
  providers: [
    ethereum: [
      %{id: "infura", url: "wss://mainnet.infura.io/ws/v3/#{api_key}", type: :infura},
      %{id: "alchemy", url: "wss://eth-mainnet.alchemyapi.io/v2/#{api_key}", type: :alchemy}
    ]
  ]
```

---

## Multichain Provider Adapter Architecture

**Files**:

- `lib/lasso/core/providers/adapter_registry.ex` - Provider-type extraction and adapter resolution
- `lib/lasso/core/providers/adapter_filter.ex` - Method capability filtering and parameter validation
- `lib/lasso/core/providers/adapter_helpers.ex` - Shared utilities for all adapters
- `lib/lasso/core/providers/adapters/*.ex` - Provider-specific adapter implementations
- `lib/lasso/config/chain_config.ex` - Configuration parsing with type validation
- `config/chains.yml` - Chain and provider configuration with adapter_config overrides

Lasso's provider adapter system validates RPC requests before sending them upstream, preventing rejections and unnecessary failovers. The architecture is designed for multichain scalability, allowing a single adapter implementation to work across all chains (Ethereum, Base, Polygon, etc.) with per-provider, per-chain configuration overrides.

### **Design Philosophy**

**Lazy Parameter Validation**

The adapter system performs only method-level capability filtering during provider selection, deferring parameter validation to execution time:

1. **Filter by method support** - Build candidate list of method-capable providers
2. **Selection** - Return ordered channels based on strategy
3. **Execution** - Validate params for selected channel before request
4. **Failover on validation failure** - Invalid params trigger same failover as request errors
5. **Repeat** - Until success or all candidates exhausted

**Benefits:**

- Only 1 parameter validation per request (not N validations upfront)
- Natural failover integration
- Clear separation of concerns (filter = capability, execution = validation)

**Fail-Closed Error Handling**

Adapter crashes during parameter validation return `{:error, :adapter_crash}` to trigger failover rather than allowing potentially malicious requests through. However, `supports_method?` is intentionally not wrapped in try/rescue - if it crashes, that's a critical bug requiring immediate attention.

### **Provider-Type Extraction**

The system automatically resolves adapters using pattern matching on provider IDs, supporting both naming conventions without manual mappings:

**Supported Patterns:**

- `{provider}_{chain}`: `"alchemy_base"`, `"llamarpc_polygon"`
- `{chain}_{provider}`: `"ethereum_cloudflare"`, `"base_publicnode"`
- Exact match: `"alchemy"`, `"infura"`

**Collision Prevention:**

Provider types are sorted by length (descending) before pattern matching to prevent prefix collisions:

```elixir
# Example: If we have both "alchemy" and "alchemy_pro"
# Without sorting: "alchemy_pro_ethereum" incorrectly matches "alchemy"
# With DESC sorting: "alchemy_pro_ethereum" correctly matches "alchemy_pro"

defp extract_provider_type(provider_id) do
  provider_types =
    @provider_type_mapping
    |> Map.keys()
    |> Enum.sort_by(&String.length/1, :desc)  # Longer patterns first

  # Try prefix: "alchemy_ethereum"
  # Try suffix: "ethereum_alchemy"
  # Try exact: "alchemy"
end
```

**Adapter Registry:**

```elixir
@provider_type_mapping %{
  "alchemy" => Lasso.RPC.Providers.Adapters.Alchemy,
  "publicnode" => Lasso.RPC.Providers.Adapters.PublicNode,
  "llamarpc" => Lasso.RPC.Providers.Adapters.LlamaRPC,
  "merkle" => Lasso.RPC.Providers.Adapters.Merkle,
  "cloudflare" => Lasso.RPC.Providers.Adapters.Cloudflare
}

# All resolve to Adapters.Alchemy
AdapterRegistry.adapter_for("alchemy_ethereum")    # ✓
AdapterRegistry.adapter_for("alchemy_base")        # ✓
AdapterRegistry.adapter_for("alchemy_polygon")     # ✓

# All resolve to Adapters.PublicNode
AdapterRegistry.adapter_for("ethereum_publicnode") # ✓
AdapterRegistry.adapter_for("base_publicnode")     # ✓

# Unknown providers fallback to Generic adapter
AdapterRegistry.adapter_for("unknown_provider")    # → Generic
```

**Scalability:** Adding new chains requires zero code changes - adapters automatically work across all chains.

### **Per-Chain Configuration System**

While adapters provide sensible defaults, some providers have different limits per chain. The `adapter_config` field in provider configuration allows YAML-based overrides:

**Configuration Structure:**

```yaml
# config/chains.yml
base:
  chain_id: 8453
  providers:
    - id: "alchemy_base"
      url: "https://base-mainnet.g.alchemy.com/v2/..."
      adapter_config:
        eth_get_logs_block_range: 10 # Override Alchemy's default

    - id: "base_publicnode"
      url: "https://base.publicnode.com"
      adapter_config:
        max_addresses_http: 50 # Base allows more addresses
        max_addresses_ws: 30

ethereum:
  chain_id: 1
  providers:
    - id: "alchemy_ethereum"
      url: "https://eth-mainnet.g.alchemy.com/v2/..."
      # No adapter_config - uses adapter defaults (10 blocks)
```

**Type Validation:**

Configuration values are validated at parse time with clear error messages:

```elixir
# Integer config keys are validated
@integer_config_keys [
  :eth_get_logs_block_range,  # Alchemy: block range limit
  :max_block_range,            # LlamaRPC/Merkle: block range limit
  :max_addresses_http,         # PublicNode: HTTP address limit
  :max_addresses_ws            # PublicNode: WS address limit
]

# Accepts integers or numeric strings from YAML
adapter_config: %{max_block_range: 1000}       # ✓
adapter_config: %{max_block_range: "1000"}     # ✓ (auto-converts)
adapter_config: %{max_block_range: "invalid"}  # ✗ (raises with clear error)
adapter_config: %{max_block_range: -5}         # ✗ (must be positive)
```

**Unknown keys pass through** to support future extensibility without breaking changes.

### **Adapter Implementation Pattern**

All adapters follow a consistent pattern using shared helpers:

```elixir
defmodule Lasso.RPC.Providers.Adapters.Alchemy do
  @behaviour Lasso.RPC.ProviderAdapter

  import Lasso.RPC.Providers.AdapterHelpers

  # Default limits (provider-specific)
  @default_eth_get_logs_block_range 10

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    # Read from config or use default
    limit = get_adapter_config(ctx, :eth_get_logs_block_range, @default_eth_get_logs_block_range)

    case validate_block_range(params, ctx, limit) do
      :ok -> :ok
      {:error, reason} = err ->
        # Emit telemetry for monitoring
        :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
          adapter: __MODULE__,
          method: "eth_getLogs",
          reason: reason
        })
        err
    end
  end

  def validate_params(_method, _params, _transport, _ctx), do: :ok
end
```

### **AdapterHelpers Module**

The shared `AdapterHelpers` module eliminates code duplication across adapters:

```elixir
defmodule Lasso.RPC.Providers.AdapterHelpers do
  @doc """
  Reads adapter config value from context with fallback to default.

  Handles missing provider_config, nil adapter_config, and missing keys gracefully.
  """
  @spec get_adapter_config(map(), atom(), any()) :: any()
  def get_adapter_config(ctx, key, default) when is_map(ctx) and is_atom(key) do
    adapter_config =
      ctx
      |> Map.get(:provider_config, %{})
      |> Map.get(:adapter_config)

    case adapter_config do
      nil -> default
      %{} = config -> Map.get(config, key, default)
      _ -> default
    end
  end
end
```

**Usage:** All adapters import and use `get_adapter_config/3` for consistent configuration access.

### **Validation Context**

During execution, the adapter filter builds a comprehensive validation context:

```elixir
# Base context always includes provider_id and chain
ctx = %{
  provider_id: "alchemy_base",
  chain: "base"
}

# Provider config is merged if available (via ConfigStore lookup)
ctx = %{
  provider_id: "alchemy_base",
  chain: "base",
  provider_config: %Provider{
    id: "alchemy_base",
    url: "https://...",
    adapter_config: %{eth_get_logs_block_range: 10}
  }
}
```

**Fail-Open Config Lookup:**

If ConfigStore lookup fails (e.g., during startup or reload), the system returns base context without provider_config, allowing adapters to use their defaults. This ensures requests can proceed even during transient config unavailability.

**Fail-Closed Parameter Validation:**

However, adapter crashes during actual validation are caught and return `{:error, :adapter_crash}` to trigger failover:

```elixir
defp safe_validate_params?(provider_id, method, params, transport, chain) do
  adapter = AdapterRegistry.adapter_for(provider_id)
  ctx = build_validation_context(provider_id, chain)

  try do
    adapter.validate_params(method, params, transport, ctx)
  rescue
    e ->
      Logger.error("Adapter crash in validate_params: #{inspect(adapter)}, #{Exception.message(e)}")
      :telemetry.execute([:lasso, :capabilities, :crash], %{...})

      # Fail closed - treat crash as validation failure to trigger failover
      {:error, :adapter_crash}
  end
end
```

### **Current Adapter Implementations**

**Alchemy** (`adapters/alchemy.ex`)

- Validates `eth_getLogs` block range (default: 10 blocks)
- Configurable via `eth_get_logs_block_range`
- Uses BlockchainMetadataCache for "latest" block resolution

**PublicNode** (`adapters/public_node.ex`)

- Validates `eth_getLogs` address count
- Separate limits for HTTP (default: 25) and WebSocket (default: 20)
- Configurable via `max_addresses_http` and `max_addresses_ws`

**LlamaRPC** (`adapters/llamarpc.ex`)

- Validates `eth_getLogs` block range (default: 1000 blocks)
- Configurable via `max_block_range`
- Uses BlockchainMetadataCache for "latest" block resolution

**Merkle** (`adapters/merkle.ex`)

- Validates `eth_getLogs` block range (default: 1000 blocks)
- Configurable via `max_block_range`
- Uses BlockchainMetadataCache for "latest" block resolution

**Cloudflare** (`adapters/cloudflare.ex`)

- Currently no parameter restrictions
- Delegates all normalization to Generic adapter

**Generic** (`generic.ex`)

- Fallback adapter for unknown provider types
- No parameter validation
- Basic request/response normalization

### **Integration with BlockchainMetadataCache**

Adapters use the metadata cache to resolve "latest" block numbers for accurate range validation:

```elixir
defp parse_block_number("latest", ctx) do
  chain = Map.get(ctx, :chain, "ethereum")

  case BlockchainMetadataCache.get_block_height(chain) do
    {:ok, height} -> {:ok, height}
    {:error, _} -> {:ok, 0}  # Fail-open: allow request if cache unavailable
  end
end

# Example validation flow:
# Request: eth_getLogs({fromBlock: "latest", toBlock: "0x100"})
# Cache lookup: latest = 21845678
# Range: abs(21845678 - 256) = 21845422 blocks
# Alchemy limit: 10 blocks
# Result: {:error, {:param_limit, "max 10 block range (got 21845422)"}}
```

**Benefits:**

- Accurate validation with real-time block numbers (<1ms via ETS)
- Graceful degradation if cache unavailable (fail-open)
- No hardcoded block number estimates

### **Telemetry Events**

The adapter system emits comprehensive telemetry for monitoring:

```elixir
# Parameter validation rejection
[:lasso, :capabilities, :param_reject]
%{count: 1}
%{adapter: Adapters.Alchemy, method: "eth_getLogs", reason: {:param_limit, "..."}}

# Adapter crash during validation
[:lasso, :capabilities, :crash]
%{count: 1}
%{adapter: Adapters.Alchemy, provider_id: "alchemy_base", phase: :param_validation, exception: "..."}

# Method filtering (capability check)
[:lasso, :capabilities, :filter]
%{method: "eth_subscribe", total_candidates: 6, filtered_count: 2}
```

### **Performance Characteristics**

- **Method filtering**: <20μs P99 (6 providers × ~2μs each)
- **Parameter validation**: <50μs P99 (single validation per request)
- **Config lookup**: <5μs (ETS-based ConfigStore)
- **Total overhead**: <100μs P99 for filtering + validation

The lazy validation approach (validating only the selected provider) is significantly more efficient than eager validation (validating all candidates upfront).

### **Backward Compatibility**

The system maintains full backward compatibility:

**Missing adapter_config:**

```yaml
providers:
  - id: "alchemy_ethereum"
    url: "https://..."
    # No adapter_config field
```

**Result:** Uses adapter defaults (e.g., 10 blocks for Alchemy)

**Nil adapter_config:**

```yaml
providers:
  - id: "alchemy_ethereum"
    url: "https://..."
    adapter_config: null
```

**Result:** Uses adapter defaults

**Empty adapter_config:**

```yaml
providers:
  - id: "alchemy_ethereum"
    url: "https://..."
    adapter_config: {}
```

**Result:** Uses adapter defaults

**Missing provider_config in context:**

```elixir
ctx = %{provider_id: "alchemy_base", chain: "base"}
# No :provider_config field
```

**Result:** Uses adapter defaults

All existing configurations continue to work without modification.

### **Adding New Adapters**

To add a new provider adapter:

1. **Create adapter module** in `lib/lasso/core/providers/adapters/`
2. **Implement ProviderAdapter behaviour:**
   - `supports_method?/3` - Method capability check
   - `validate_params/4` - Parameter validation with configurable limits
   - `normalize_request/2`, `normalize_response/2`, `normalize_error/2` - Request/response handling
   - `headers/1` - Custom headers (e.g., API keys)
   - `metadata/0` - Adapter metadata
3. **Register in AdapterRegistry:**
   ```elixir
   @provider_type_mapping %{
     "new_provider" => Lasso.RPC.Providers.Adapters.NewProvider
   }
   ```
4. **Import AdapterHelpers** for config access
5. **Define configurable limits** with sensible defaults
6. **Document in metadata** what limits are configurable

**Example:**

```elixir
defmodule Lasso.RPC.Providers.Adapters.NewProvider do
  @behaviour Lasso.RPC.ProviderAdapter
  import Lasso.RPC.Providers.AdapterHelpers

  @default_max_logs 1000

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    limit = get_adapter_config(ctx, :max_logs, @default_max_logs)
    # Validation logic...
  end

  @impl true
  def metadata do
    %{
      configurable_limits: [
        max_logs: "Maximum logs returned per request (default: #{@default_max_logs})"
      ]
    }
  end
end
```

### **Testing Strategy**

The adapter system has comprehensive test coverage (37 tests):

1. **Multichain resolution** - All provider types across all chains
2. **Collision prevention** - Overlapping provider type names
3. **Per-chain config overrides** - Custom limits per provider/chain
4. **Backward compatibility** - nil/empty/missing configs use defaults
5. **AdapterHelpers edge cases** - Nil handling, missing keys
6. **Type validation** - Integer conversion and validation

**Example test:**

```elixir
test "respects adapter_config for custom block range" do
  provider_config = %Provider{
    id: "alchemy_base",
    adapter_config: %{eth_get_logs_block_range: 50}
  }

  ctx = %{
    provider_id: "alchemy_base",
    chain: "base",
    provider_config: provider_config
  }

  # 31 blocks should pass with limit of 50
  params = [%{"fromBlock" => "0x1", "toBlock" => "0x20"}]
  assert :ok = Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)

  # But 51 should fail
  params = [%{"fromBlock" => "0x1", "toBlock" => "0x34"}]
  assert {:error, {:param_limit, message}} =
    Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)
  assert message =~ "max 50 block range"
end
```

### **Production Deployment Considerations**

**Configuration Management:**

- Use environment-specific `chains.yml` files
- Override adapter_config per environment (e.g., higher limits in production)
- Validate configuration on boot via ConfigStore

**Monitoring:**

- Track `[:lasso, :capabilities, :param_reject]` events to identify clients hitting limits
- Alert on `[:lasso, :capabilities, :crash]` events (indicates adapter bugs)
- Monitor rejection rates per adapter/method

**Scaling:**

- Adapter validation is stateless and highly concurrent
- No coordination required between requests
- Performance scales linearly with request volume

---

## Error Classification Architecture

**Files**: `error_classifier.ex`, `error_classification.ex`, `error_normalizer.ex`, `adapters/*.ex`

Lasso implements a composable error classification system where provider adapters can override error categorization for provider-specific codes while ensuring consistent failover and circuit breaker behavior.

### **Design: Classify Once, Derive Everything**

The system classifies errors once, then derives all properties from the final category to ensure adapter overrides propagate correctly:

```elixir
# Single call returns complete classification
%{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
  ErrorClassifier.classify(code, message, provider_id: provider_id)

# Flow:
# 1. Try adapter.classify_error(code, message) → {:ok, category} or :default
# 2. Fallback to ErrorClassification.categorize(code, message) if :default
# 3. Derive retriable? from category (not from code/message re-classification)
# 4. Derive breaker_penalty? from category
```

**Why this matters:** Without deriving from the final category, adapter overrides wouldn't affect failover behavior. For example, DRPC code 30 ("timeout on free tier") is classified as `:rate_limit` by the adapter, which makes it retriable—derived from the `:rate_limit` category. Note that rate limits do NOT penalize the circuit breaker (see Rate Limit Handling below).

### **Provider Adapter Classification**

Adapters can optionally override classification via `classify_error/2` callback:

```elixir
@impl true
def classify_error(30, message) when is_binary(message) do
  if String.contains?(String.downcase(message), "timeout on the free tier") do
    {:ok, :rate_limit}  # Override
  else
    :default  # Defer to central classification
  end
end

def classify_error(_code, _message), do: :default
```

**Current adapter overrides:**

- **DRPC**: Code 30/35, "timeout on free tier", "ranges over"
- **PublicNode**: Code -32701, "specify less/an address"
- **1RPC**: Code -32602 + "is limited to" (overrides standard invalid_params)
- **Cloudflare**: Code -32046, "cannot fulfill request"

### **Category-Based Behavior**

All error behavior is derived from the final category:

**Retriability** (triggers failover):

- Retriable: `:rate_limit`, `:network_error`, `:server_error`, `:capability_violation`, `:method_not_found`, `:auth_error`
- Non-retriable: `:invalid_params`, `:user_error`, `:client_error`

**Circuit Breaker Penalty**:

- No penalty: `:capability_violation` (permanent constraint, not transient failure), `:rate_limit` (temporary backpressure with known recovery time)
- Penalty: All other categories (`:network_error`, `:server_error`, `:timeout`, `:auth_error`, etc.)

### **Rate Limit Handling**

Rate limits are handled independently from circuit breakers via `RateLimitState`:

- **Time-based recovery**: Rate limits use `Retry-After` headers for automatic expiry, not count-based circuit breaker recovery
- **No circuit breaker penalty**: Rate limits (`breaker_penalty?: false`) don't increment failure counts or trip circuit breakers
- **Independent tracking**: `RateLimitState` tracks per-transport rate limit expiry separately from provider health status
- **Health status preserved**: Provider health remains unchanged during rate limits (stays `:healthy` or `:connecting`)
- **Auto-expiry**: Rate limit state automatically clears when `Retry-After` time elapses
- **Dashboard visibility**: `http_rate_limited`/`ws_rate_limited` fields indicate current rate limit state

This separation ensures rate-limited providers recover as soon as the provider allows, rather than waiting for circuit breaker recovery timeouts.

---

## Summary

Lasso RPC leverages Elixir/OTP's fault tolerance and concurrency to deliver production-ready blockchain RPC orchestration. Key architectural advantages:

**Transport-agnostic routing** - Unified pipeline routes across HTTP and WebSocket based on real-time performance, providing seamless failover and automatic optimization.

**WebSocket subscription management** - Intelligent multiplexing reduces upstream connections by orders of magnitude while providing automatic failover with gap-filling.

**Comprehensive observability** - Structured logging, client-visible metadata, and real-time dashboard provide complete visibility into routing decisions and performance.

**Battle-tested reliability** - Integrated chaos engineering framework validates system behavior under failure conditions, ensuring production resilience.

**Massive concurrency** - BEAM VM's lightweight processes and fault isolation enable thousands of concurrent connections with minimal overhead.

This architecture scales from single self-hosted instances to globally distributed networks, providing blockchain developers with infrastructure-grade reliability without infrastructure-grade complexity.
