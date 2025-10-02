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
├── Registry (Lasso.Registry - dynamic process lookup)
├── DynamicSupervisor (Lasso.RPC.Supervisor)
│   ├── ChainSupervisor (ethereum)
│   │   ├── ProviderSupervisor (alchemy)
│   │   │   ├── CircuitBreaker (HTTP)
│   │   │   ├── CircuitBreaker (WS)
│   │   │   └── WSConnection (if WS configured)
│   │   ├── ProviderSupervisor (other public/private rpc providers)
│   │   ├── ProviderPool (metrics, health, connection tracking)
│   │   ├── ProviderHealthMonitor (monitor and probe health metrics)
│   │   ├── TransportRegistry (request channel discovery)
│   │   ├── UpstreamSubscriptionPool (WS multiplexing)
│   │   └── ClientSubscriptionRegistry (client fan-out)
│   ├── ChainSupervisor (any other evm chain)
├── Lasso.Config.ConfigStore (ETS config cache)
└── LassoWeb.Endpoint
```

### **Key Components**

- **Lasso.Application**: Top-level application supervisor
- **ChainSupervisor**: Per-chain supervisor providing fault isolation between networks
- **ProviderSupervisor**: Per-provider supervisor managing circuit breakers and WebSocket connections
- **CircuitBreaker**: GenServer tracking failures per provider+transport, implementing open/half-open/closed states
- **WSConnection**: GenServer managing persistent WebSocket connection to a single provider
- **ProviderPool**: GenServer tracking provider health, availability, and capabilities
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
  params_digest: "sha256:...",
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
  include_params_digest: true,
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

## Performance Characteristics

### **Throughput**

- **RPC latency measurement**: <5ms overhead for latency tracking
- **Provider Configuration + capability lookups**: <1ms via ETS cache (no file I/O)
- **Provider selection**: <2ms via ETC Cache based Selection module (metrics lookup)
- **Dashboard updates**: <100ms from RPC metrics to UI update

### **Fault Tolerance**

- **Provider failures**: Detected within 5 seconds, failover in <1 second
- **Process crashes**: Automatic restart within 500ms
- **Network partitions**: Circuit breakers prevent cascade failures
- **Data persistence**: No RPC metrics loss during normal operation

### **Scalability**

- **Concurrent providers**: Can support an unbounded number of RPC providers
- **Multiple chains**: Independent supervision trees scale horizontally
- **Historical data**: Bounded memory with persistent snapshots

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

## Summary

Lasso RPC leverages Elixir/OTP's fault tolerance and concurrency to deliver production-ready blockchain RPC orchestration. Key architectural advantages:

**Transport-agnostic routing** - Unified pipeline routes across HTTP and WebSocket based on real-time performance, providing seamless failover and automatic optimization.

**WebSocket subscription management** - Intelligent multiplexing reduces upstream connections by orders of magnitude while providing automatic failover with gap-filling.

**Comprehensive observability** - Structured logging, client-visible metadata, and real-time dashboard provide complete visibility into routing decisions and performance.

**Battle-tested reliability** - Integrated chaos engineering framework validates system behavior under failure conditions, ensuring production resilience.

**Massive concurrency** - BEAM VM's lightweight processes and fault isolation enable thousands of concurrent connections with minimal overhead.

This architecture scales from single self-hosted instances to globally distributed networks, providing blockchain developers with infrastructure-grade reliability without infrastructure-grade complexity.
