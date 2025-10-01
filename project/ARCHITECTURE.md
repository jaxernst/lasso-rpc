# Livechain Architecture

## Core Technical Design

### **System Overview**

Livechain is an Elixir/OTP application that provides intelligent RPC provider orchestration and client router, acting as a 'smart proxy' between blockchain RPC services and/or self hosted node infrastructure.

### **Core Capabilities**

- Multi-provider orchestration with pluggable provider selection strategies (default `:fastest`; also `:cheapest`, `:priority`, `:round_robin`)
- WS + HTTP JSON-RPC proxy for all standard read-only methods; WS also supports real-time subscriptions (`eth_subscribe`, `eth_unsubscribe`)
- Strong failover across HTTP and WS via per-provider circuit breakers and provider pools
- Passive provider benchmarking on a per-chain and per-method basis using real RPC call latencies for intelligent routing
- Live dashboard with real-time insights, provider performance metrics, chain status, and a system load simulator

---

## Regionality and Latency-Aware Routing

Livechain is designed to operate as a regional-first platform: clients connect to the nearest Livechain node, which then selects the lowest-latency upstream provider using region-local metrics.

- **Client proximity**: Use geo routing at the edge (DNS or managed LB) to land clients on the closest region.
- **Region-local benchmarking**: Maintain per-region leaderboards and latency/error metrics; prefer the top provider for that region and method.
- **Persistent connections**: Keep warm HTTP pools and provider WebSockets to minimize handshakes and reduce hop latency.
- **Failover without regressions**: Circuit breakers, cooldowns, and provider pools ensure graceful rotation to the next best provider.
- **Minimal overhead**: Hot-path selection and routing are in-memory (ETS/Registry); typical added latency is single-digit milliseconds, often offset by better upstream choice.

Separation of concerns:

- **BEAM/Elixir**: Selection logic, benchmarking, circuit breaking, WS/HTTP proxying, telemetry (region-tagged), and per-region supervision (using `Registry`).
- **Infrastructure**: Global ingress/geo routing (DNS/LB), TLS termination and WS stickiness, environment config (`LIVECHAIN_REGION`), scaling, and observability stack.

---

## OTP Supervision Architecture

Livechain leverages OTP for fault-tolerance and concurrency. The supervision tree is structured as follows:

- **Livechain.Application**: The top-level application supervisor.
- **DynamicSupervisor**: A dynamic supervisor named `Livechain.RPC.Supervisor` is used to start and stop `ChainSupervisor` processes on demand.
- **Livechain.RPC.ChainSupervisor**: A supervisor for each blockchain network, managing all processes related to that chain.
- **Livechain.RPC.WSConnection**: A GenServer for each provider's WebSocket connection, supervised by the `ChainSupervisor`.
- **Livechain.RPC.MessageAggregator**: A GenServer that deduplicates messages from different providers for a single chain.
- **Livechain.RPC.ProviderPool**: Manages the health and status of providers for a chain.
- **Livechain.RPC.CircuitBreaker**: A GenServer for each provider to track failures and open/close the circuit.
- **Livechain.RPC.RequestContext**: Stateless struct for tracking request lifecycle (not a process).
- **Livechain.RPC.Observability**: Module for structured logging and metadata generation (not a process).
- **LivechainWeb.Plugs.ObservabilityPlug**: Phoenix plug for parsing client metadata opt-in preferences.

### **Supervision Strategy**

- **Configuration caching**: `ConfigStore` eliminates hot-path YAML loading with fast ETS lookups.
- **Lifecycle separation**: `ChainRegistry` handles only start/stop operations, never request processing.
- **Chain isolation**: Each blockchain network runs in a separate supervision tree under a dynamic supervisor, allowing for chains to be started and stopped dynamically.
- **Provider isolation**: Individual provider failures don't affect others, thanks to the `CircuitBreaker` and `ProviderPool`.
- **Unified selection**: The `Selection` module handles all provider picking logic.
- **Restart strategy**: Temporary failures trigger process restarts, while persistent failures trigger failover via the `CircuitBreaker`.

---

## Request Observability Architecture

**Files**:
- `lib/livechain/rpc/request_context.ex` - Request lifecycle tracking
- `lib/livechain/rpc/observability.ex` - Structured logging and metadata
- `lib/livechain_web/plugs/observability_plug.ex` - HTTP metadata injection

Livechain provides comprehensive request observability with minimal overhead:

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
    "candidate_providers": ["ethereum_cloudflare:http", "ethereum_llamarpc:http"],
    "selected_provider": {"id": "ethereum_llamarpc", "protocol": "http"},
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
  plug(LivechainWeb.Plugs.ObservabilityPlug)
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
config :livechain, :observability,
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

**File**: `lib/livechain/config/config_store.ex`

Livechain uses a centralized configuration store to eliminate hot-path YAML loading:

- **ETS-based caching**: Configurations are loaded once at startup and cached in ETS tables
- **Fast lookups**: Chain and provider configurations are retrieved via in-memory lookups
- **Runtime reload**: Supports atomic configuration updates without restart
- **Typed structures**: Uses ChainConfig and ProviderConfig structs for type safety

```elixir
# Hot-path lookup (no file I/O)
{:ok, chain_config} = ConfigStore.get_chain("ethereum")
{:ok, provider_config} = ConfigStore.get_provider("ethereum", "alchemy")
```

### **Lifecycle Management**

**File**: `lib/livechain/rpc/chain_registry.ex`

ChainRegistry provides thin lifecycle management separated from business logic:

- **Start/stop operations**: Manages chain supervisor lifecycle only
- **Registry maintenance**: Tracks running chain PIDs
- **Status reporting**: Provides chain lifecycle information
- **No hot-path involvement**: Never called during request processing

### **Unified Provider Selection**

**File**: `lib/livechain/rpc/selection.ex`

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

**File**: `lib/livechain/rpc/circuit_breaker.ex`

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

## Data Flow Architecture

### **Request Processing Pipeline**

```
[Client Request] → [ObservabilityPlug] → [RPCController] → [RequestPipeline]
       ↓                  ↓                     ↓                  ↓
  include_meta?      Parse Opt-in       Create Context     Select Provider
       ↓                  ↓                     ↓                  ↓
[Provider Call] → [Circuit Breaker] → [Update Context] → [Log & Store]
       ↓                  ↓                     ↓                  ↓
  HTTP/WS Call      Track Failures      Record Timing     Observability
```

### **Event Processing Pipeline**

```
[RPC Provider] → [RPC Call] → [Latency Measurement] → [BenchmarkStore]
     ↓              ↓              ↓                     ↓
  HTTP/WS        Request         Response Time         ETS Tables
 Connection      Processing      Tracking             Metrics Storage
```

### **Performance Data Storage**

```
ETS Tables (Per Chain):
├── rpc_metrics_#{chain}        # {timestamp, provider_id, method, duration_ms, result}
└── provider_scores_#{chain}    # {provider_id, method, :rpc} => {successes, total, avg_duration}
```

### **Memory Management**

- **24-hour retention**: Detailed metrics kept for last 24 hours
- **Automatic cleanup**: Hourly removal of oldest entries
- **Bounded tables**: Maximum 86,400 entries per chain (~1 per second)
- **Snapshot persistence**: Hourly JSON dumps for historical analysis

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

### **HTTP vs WebSocket Responsibilities**

- **WebSocket (WS)**: Real-time subscriptions only. Methods like `eth_subscribe` and `eth_unsubscribe` are WS-only. In addition, WS supports generic forwarding of read-only JSON-RPC methods using the same provider selection and failover logic as HTTP.
- **HTTP**: Read-only JSON-RPC methods are forwarded to upstream providers via a smart proxy. HTTP requests to WS-only methods return a JSON-RPC error advising clients to use WS.

### **Provider Selection Strategies**

Provider selection is pluggable. The main strategies include:

- **:fastest (default)**: Picks the highest-scoring provider from the `BenchmarkStore`. The score is based on method-specific RPC latency measurements and success rates, effectively making this a performance-based strategy.
- **:priority**: First available provider based on its statically configured `priority`.
- **:round_robin**: Rotates across available, healthy providers.
- **:cheapest**: Prefers providers marked as `type: "public"` before using others.

Configuration:

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :fastest
# Alternatives: :cheapest | :priority | :round_robin
```

---

## Real-Time Dashboard Integration

### **Phoenix LiveView Components**

- **Latency Metrics**: Live provider rankings based on RPC performance
- **Routing Decision Events**: See how requests are routed in real time
- **Performance matrix**: RPC call latencies by provider and method
- **Chain selection**: Switch between Ethereum, Polygon, Arbitrum
- **Real-time updates**: WebSocket push updates on new RPC metrics

### **Data Integration**

```elixir
def load_benchmark_data(socket) do
  chain_name = socket.assigns.benchmark_chain
  provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
  realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)
  # Leaderboard now based on RPC latency and success rate metrics
end
```

---

## Performance Characteristics

### **Throughput**

- **RPC latency measurement**: <5ms overhead for latency tracking
- **Provider Configuration + capability lookups**: <1ms via ETS cache (no file I/O)
- **Provider selection**: <2ms via Selection module
- **Dashboard updates**: <100ms from RPC metrics to UI update
- **Memory usage**: ~10MB per chain for 24 hours of data

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
config :livechain,
  providers: [
    ethereum: [
      %{id: "infura", url: "wss://mainnet.infura.io/ws/v3/#{api_key}", type: :infura},
      %{id: "alchemy", url: "wss://eth-mainnet.alchemyapi.io/v2/#{api_key}", type: :alchemy}
    ]
  ]
```

---

This architecture leverages Elixir/OTP's fault tolerance and concurrency strengths to create a production-ready RPC orchestration system with unique competitive advantages through passive performance benchmarking and intelligent provider selection.
