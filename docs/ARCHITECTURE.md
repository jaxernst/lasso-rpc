# Livechain Architecture

## Core Technical Design

### **System Overview**

Livechain is an Elixir/OTP application that provides intelligent RPC provider orchestration and client router, acting as a 'smart proxy' between blockchain RPC services and/or self hosted node infrastructure.

### **Core Capabilities**

- Multi-provider orchestration with pluggable provider selection strategies (default `:leaderboard`; also `:priority`, `:round_robin`)
- WS + HTTP JSON-RPC proxy for all standard read-only methods; WS also supports real-time subscriptions (`eth_subscribe`, `eth_unsubscribe`)
- Strong failover across HTTP and WS via per-provider circuit breakers and provider pools
- Passive provider benchmarking on a per-chain and per-method basis with event racing for lowest-latency delivery
- Live dashboard with real-time insights, provider performance metrics, chain status, and a system load simulator

### **Key Innovation: Passive Provider Racing**

Instead of synthetic benchmarks, Livechain deduplicates identical events from multiple providers and measures which provider delivers them fastest in real time. This produces production-grounded performance data without introducing artificial load.

- Deterministic message keys (block/tx hashes or content digests) enable identical-event detection
- Microsecond-level timing to compute precise win/loss margins
- First-wins forwarding: clients receive the earliest provider's message; subsequent arrivals update scores
- Memory-bounded cache preserves race integrity with predictable resource usage

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

### **Supervision Strategy**

- **Configuration caching**: `ConfigStore` eliminates hot-path YAML loading with fast ETS lookups.
- **Lifecycle separation**: `ChainRegistry` handles only start/stop operations, never request processing.
- **Chain isolation**: Each blockchain network runs in a separate supervision tree under a dynamic supervisor, allowing for chains to be started and stopped dynamically.
- **Provider isolation**: Individual provider failures don't affect others, thanks to the `CircuitBreaker` and `ProviderPool`.
- **Unified selection**: The `Selection` module handles all provider picking logic.
- **Restart strategy**: Temporary failures trigger process restarts, while persistent failures trigger failover via the `CircuitBreaker`.

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
  strategy: :latency,
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

### **Event Processing Pipeline**

```
[RPC Provider] → [WSConnection] → [MessageAggregator] → [Racing Logic] → [BenchmarkStore]
     ↓              ↓                    ↓                   ↓              ↓
  WebSocket      Connection         Message Cache      Timing Analysis   ETS Tables
 Subscription     Health           Deduplication     Race Win/Loss      Metrics Storage
```

### **Performance Data Storage**

```
ETS Tables (Per Chain):
├── racing_metrics_#{chain}     # {timestamp, provider_id, event_type, result, margin_ms}
├── rpc_metrics_#{chain}        # {timestamp, provider_id, method, duration_ms, result}
└── provider_scores_#{chain}    # {provider_id, event_type, :racing} => {wins, total, avg_margin}
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
# WebSocket subscriptions for racing:
eth_subscribe("newHeads")        # Block event racing
eth_subscribe("logs")            # Transaction log racing

# HTTP endpoints for benchmarking/proxying (read-only):
eth_getLogs(filter)              # Historical log queries
eth_getBlockByNumber(number)     # Block data retrieval
eth_getBalance(address)          # Account balance queries
```

### **HTTP vs WebSocket Responsibilities**

- **WebSocket (WS)**: Real-time subscriptions only. Methods like `eth_subscribe` and `eth_unsubscribe` are WS-only. In addition, WS supports generic forwarding of read-only JSON-RPC methods using the same provider selection and failover logic as HTTP.
- **HTTP**: Read-only JSON-RPC methods are forwarded to upstream providers via a smart proxy. HTTP requests to WS-only methods return a JSON-RPC error advising clients to use WS.

### **Provider Selection Strategies**

Provider selection is pluggable and defaults to leaderboard-based selection:

- **:leaderboard (default)**: Picks highest-scoring provider from `BenchmarkStore`
- **:priority**: First available provider by configured priority
- **:round_robin**: Rotates across available providers
- Future strategies can include **:cheapest**, **:latency_based**, or **hybrid** approaches

Configuration:

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :leaderboard
# Alternatives: :priority | :round_robin
```

---

## Real-Time Dashboard Integration

### **Phoenix LiveView Components**

- **Racing leaderboard**: Live provider rankings with win rates
- **Performance matrix**: RPC call latencies by provider and method
- **Chain selection**: Switch between Ethereum, Polygon, Arbitrum
- **Real-time updates**: WebSocket push updates on new race results

### **Data Integration**

```elixir
def load_benchmark_data(socket) do
  chain_name = socket.assigns.benchmark_chain
  provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
  realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)
end
```

---

## Performance Characteristics

### **Throughput**

- **Event processing**: 1000+ events/second per chain
- **Racing latency**: <5ms from event receipt to race result
- **Provider Configuration + capability lookups**: <1ms via ETS cache (no file I/O)
- **Provider selection**: <2ms via Selection module
- **Dashboard updates**: <100ms from race result to UI update
- **Memory usage**: ~10MB per chain for 24 hours of data

### **Fault Tolerance**

- **Provider failures**: Detected within 5 seconds, failover in <1 second
- **Process crashes**: Automatic restart within 500ms
- **Network partitions**: Circuit breakers prevent cascade failures
- **Data persistence**: No race data loss during normal operation

### **Scalability**

- **Concurrent providers**: Can support an unbounded number of RPC providers
- **Multiple chains**: Independent supervision trees scale horizontally
- **Client connections**: 1000+ concurrent WebSocket clients
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
