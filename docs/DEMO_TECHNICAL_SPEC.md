# ChainPulse Demo: Technical Feature Specification

## Core Technical Features for Demonstration

### **1. Real-Time Provider Racing System**

#### **MessageAggregator Racing Algorithm**

- **File**: `lib/livechain/rpc/message_aggregator.ex:166-195`
- **Functionality**: Message deduplication with microsecond-precision racing detection
- **Demo Requirements**:
  - Multiple real providers (Infura, Alchemy) connected to Ethereum mainnet
  - Live block event racing with accurate timing measurements
  - Racing margins displayed in milliseconds
  - Win/loss tracking per provider per event type

#### **Technical Implementation Details**:

```elixir
# Racing detection logic:
case Map.get(state.message_cache, message_key) do
  nil ->
    # First provider wins - record victory with timestamp
    BenchmarkStore.record_event_race_win(chain_name, provider_id, event_type, received_at)
  {_cached_msg, cached_time, cached_provider} ->
    # Calculate precise timing margin for losing provider
    margin_ms = received_at - cached_time
    BenchmarkStore.record_event_race_loss(chain_name, provider_id, event_type, received_at, margin_ms)
end
```

#### **Demo Data Requirements**:

- Live Ethereum mainnet new block events (`newHeads`)
- Multiple provider connections racing same events
- Timing precision to millisecond accuracy
- Historical race data accumulation

---

### **2. Circuit Breaker Fault Tolerance**

#### **State Machine Implementation**

- **File**: `lib/livechain/rpc/circuit_breaker.ex:83-99`
- **Functionality**: Three-state circuit breaker (closed → open → half-open)
- **Demo Requirements**:
  - Simulated provider failures
  - Automatic state transitions
  - Recovery testing with timeout logic
  - Failover to healthy providers

#### **Technical State Transitions**:

```elixir
case state.state do
  :closed -> execute_call(fun, state)           # Normal operation
  :open ->
    if should_attempt_recovery?(state) do
      new_state = %{state | state: :half_open}  # Try recovery
      execute_call(fun, new_state)
    else
      {:reply, {:error, :circuit_open}, state}  # Reject requests
    end
  :half_open -> execute_call(fun, state)        # Test recovery
end
```

#### **Demo Scenarios**:

- Kill Infura connection → circuit opens → traffic routes to Alchemy
- Recovery after timeout → half-open state → successful calls close circuit
- Multiple provider failures → cascading failover logic

---

### **3. Provider Performance Scoring Algorithm**

#### **Mathematical Scoring Function**

- **File**: `lib/livechain/benchmarking/benchmark_store.ex:656-663`
- **Functionality**: Multi-factor performance scoring with confidence weighting
- **Demo Requirements**:
  - Real performance data from multiple providers
  - Live score calculations
  - Ranking stability over time
  - Score-based routing decisions

#### **Algorithm Implementation**:

```elixir
defp calculate_provider_score(win_rate, avg_margin_ms, total_races) do
  confidence_factor = :math.log10(max(total_races, 1))  # More races = higher confidence
  margin_penalty = if avg_margin_ms > 0, do: 1 / (1 + avg_margin_ms / 100), else: 1.0
  win_rate * margin_penalty * confidence_factor
end
```

#### **Demo Metrics**:

- Provider win rates (percentage of races won)
- Average timing margins when losing
- Confidence factors based on sample size
- Real-time score updates and rankings

---

### **4. ETS-Based High-Performance Data Storage**

#### **Memory Management System**

- **File**: `lib/livechain/benchmarking/benchmark_store.ex:673-700`
- **Functionality**: Bounded ETS tables with automatic cleanup
- **Demo Requirements**:
  - High-frequency metric ingestion (multiple events per second)
  - Memory bounds enforcement
  - Efficient data retrieval for dashboard
  - Cleanup operations without service interruption

#### **Technical Implementation**:

```elixir
# Per-chain ETS tables:
racing_table = :"racing_metrics_#{chain_name}"    # Detailed race entries
rpc_table = :"rpc_metrics_#{chain_name}"         # RPC call performance
score_table = :"provider_scores_#{chain_name}"   # Aggregated scores

# Memory management:
if current_size >= @max_entries_per_chain do
  # Remove 10% oldest entries to make room
  entries_to_remove = div(@max_entries_per_chain, 10)
  cleanup_oldest_entries(table_name, entries_to_remove)
end
```

#### **Demo Data Flows**:

- Racing metrics: timestamp, provider_id, event_type, result, margin_ms
- RPC metrics: timestamp, provider_id, method, duration_ms, success/failure
- Score aggregation: wins, losses, average margins, confidence factors

---

### **5. Phoenix LiveView Real-Time Dashboard**

#### **Live Data Visualization Requirements**

- **File**: `lib/livechain_web/live/orchestration_live.ex` (Benchmarks tab)
- **Functionality**: Real-time provider performance visualization
- **Demo Requirements**:
  - Live racing leaderboard updates
  - Provider performance metrics matrix
  - Chain selection and filtering
  - Real-time chart updates (not static data)

#### **Technical Components**

```elixir
# Real data integration (not hardcoded):
def load_benchmark_data(socket) do
  chain_name = socket.assigns.benchmark_chain
  provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
  realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)
  # ... actual data from ETS tables
end
```

#### **Dashboard Features to Demo**

- **Racing Leaderboard**: Live provider rankings with win rates
- **Performance Matrix**: RPC call latencies by provider and method
- **Chain Switching**: Ethereum, Polygon, Arbitrum performance comparison
- **Real-Time Updates**: Data refreshes as new events arrive

---

### **6. Multi-Provider JSON-RPC Integration**

#### **Real Provider Connections**

- **Files**: `lib/livechain/rpc/ws_connection.ex`, `lib/livechain/rpc/real_endpoints.ex`
- **Functionality**: Actual connections to Infura, Alchemy, other RPC providers
- **Demo Requirements**:
  - Working API key configuration
  - Multiple providers per chain
  - Standard JSON-RPC method support
  - Provider pool management

#### **Technical Implementation Needed**:

```elixir
# Real endpoint configuration:
ethereum_infura = %WSEndpoint{
  id: "infura_ethereum",
  name: "Infura Ethereum",
  chain_id: 1,
  url: "wss://mainnet.infura.io/ws/v3/#{api_key}",
  provider_type: :infura
}

ethereum_alchemy = %WSEndpoint{
  id: "alchemy_ethereum",
  name: "Alchemy Ethereum",
  chain_id: 1,
  url: "wss://eth-mainnet.alchemyapi.io/v2/#{api_key}",
  provider_type: :alchemy
}
```

#### **JSON-RPC Methods to Support**

- `eth_subscribe("newHeads")` - Block subscriptions for racing
- `eth_getLogs` - Historical log queries with benchmarking
- `eth_getBlockByNumber` - Block data retrieval
- `eth_getBalance` - Account balance queries

---

### **7. Provider Selection Strategies (New)**

#### **Feature Overview**

- Pluggable strategy for selecting providers when forwarding HTTP JSON-RPC:
  - `:leaderboard` (default): highest score from `BenchmarkStore`
  - `:priority`: first available provider by configured priority
  - `:round_robin`: rotate among available providers
  - Future: `:cheapest`, `:latency_based`, hybrid

#### **Configuration**

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :leaderboard
# Alternatives: :priority | :round_robin
```

#### **Demo Plan**

- Live toggle strategy to showcase different routing behaviors:

  1. Start with `:leaderboard` and display current leader on the dashboard
  2. Switch to `:priority` at runtime (using `Application.put_env/3` in a console or a small admin control) and demonstrate deterministic routing to priority-1 provider
  3. Switch to `:round_robin` and show sequential routing across available providers (e.g., via a simple `eth_blockNumber` loop)
  4. Simulate a provider failure; observe automatic failover and how each strategy reacts

- Visualizations to show during demo:

  - Current strategy label on the dashboard
  - Per-request annotations (provider used) in a lightweight request log panel
  - Leaderboard scores vs chosen provider to illustrate strategy difference

- Scripted commands for the demo:

```elixir
# In IEx attached to the running app
Application.put_env(:livechain, :provider_selection_strategy, :leaderboard)
Application.put_env(:livechain, :provider_selection_strategy, :priority)
Application.put_env(:livechain, :provider_selection_strategy, :round_robin)
```

- HTTP examples to trigger routing:

```bash
# Repeated block number calls to observe rotation/selection
for i in {1..10}; do
  curl -s -X POST http://localhost:4000/rpc/ethereum \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' >/dev/null; \
  sleep 0.5; \
  done
```

- Success criteria:
  - Strategy switching changes provider selection behavior in real time
  - Failover continues to work under each strategy
  - Dashboard reflects racing metrics and provider selections

---

## Performance and Scale Targets for Demo

### **Racing Performance**

- **Event processing**: 100+ events/second per chain
- **Timing precision**: ±1ms accuracy for meaningful benchmarks
- **Memory usage**: <50MB for 24 hours of racing data
- **Dashboard updates**: <100ms latency for new race results

### **Provider Management**

- **Concurrent providers**: 2-4 providers per chain
- **Supported chains**: Ethereum, Polygon, Arbitrum
- **Connection health**: <5 second detection of provider failures
- **Failover time**: <1 second to switch providers

### **System Reliability**

- **Circuit breaker response**: <100ms to open on failure
- **Process restart**: <500ms recovery from GenServer crash
- **Data persistence**: No race data loss during normal operation
- **Dashboard availability**: 99%+ uptime during demo period

---

This specification focuses on the core technical implementations that showcase the engineering depth and algorithmic sophistication of the ChainPulse system.
