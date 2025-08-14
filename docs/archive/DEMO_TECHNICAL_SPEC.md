# ChainPulse Demo: Technical Feature Specification

## Brief

Building a technical demo for a hackathon project - this demo should show off some of the core/fundamental components of livechain - a BLock Node RPC provider orchestration service.

The demo will use Phoenix Livewviews to give an impressive realtime view into the livechain system

## Goals + Ideas to show/demo ('what' to show)

- Overview info for all available providers
- Live Provider activity groupd by chain
- Live websocket connections to providers
- Live client connections
- RPC method call stream
  - Include the chain, response time, and provider the call was routed to
- Any relevant system pubsub streams that might be interesting
- Live latest blocks for chains (shows blocks live updating)
- Average latencies + other relevant JSON RPC call performance grouped by method, comparing the latency difference by 'strategy' used (i.e. compare the 'cheapest' responses with the 'fastest' responses)
- Elixir/BEAM VM stats (memory, processes, etc.)

Desired + Possible Interactive elements:

- Some interactive 'testing' controls to simulate client loads, failure conditions, and other neat demonstrations that can show off interesting properties of the system such as failover, connection redundancy, fault tolerance, etc.

## UI Structure for Demo

### Tabs

- Live Dashboard: High-level visualizations
  - Network topology of active connections
  - Quick stats (connection count, recent routing and provider events)
  - Live feeds for routing decisions and provider pool events
- Live Test: Control panel to kick off simulated RPC client actions and live tests
  - Demo controls: start/stop mock WebSocket connections
  - Routing sampler: synthetic request stream to visualize selection/failover in UI
  - Provider event emitters: trigger cooldown/healthy events to verify UI/telemetry
- System Metrics: Telemetry and low-level metrics (initially preview counters)
  - Counts of connections, routing events buffered, provider events buffered

## Minimal Demo Implementation Plan (Now)

- Start/Stop mock connections
  - Use `Livechain.RPC.MockWSEndpoint` for Ethereum and Polygon
  - Start/Stop via `Livechain.RPC.WSSupervisor.start_connection/1` and `.stop_connection/1`
- Routing sampler
  - Periodic synthetic routing decisions published to `routing:decisions`
  - Fields: ts, chain, method, strategy, provider_id, duration_ms, result, failover_count
- Provider event emitters
  - Buttons to emit `:cooldown_start` and `:healthy` events to `provider_pool:events`
- Live feeds
  - Subscribe to `routing:decisions` and `provider_pool:events`
  - Display latest 100 entries with minimal styling

## Core Technical Features for Demonstration (Long-Term Vision)

### 1. Real-Time Provider Racing System

#### MessageAggregator Racing Algorithm

- **File**: `lib/livechain/rpc/message_aggregator.ex:166-195`
- **Functionality**: Message deduplication with microsecond-precision racing detection
- **Demo Requirements**:
  - Multiple real providers (Infura, Alchemy) connected to Ethereum mainnet
  - Live block event racing with accurate timing measurements
  - Racing margins displayed in milliseconds
  - Win/loss tracking per provider per event type

#### Technical Implementation Details:

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

#### Demo Data Requirements:

- Live Ethereum mainnet new block events (`newHeads`)
- Multiple provider connections racing same events
- Timing precision to millisecond accuracy
- Historical race data accumulation

---

### 2. Circuit Breaker Fault Tolerance

#### State Machine Implementation

- **File**: `lib/livechain/rpc/circuit_breaker.ex:83-99`
- **Functionality**: Three-state circuit breaker (closed → open → half-open)
- **Demo Requirements**:
  - Simulated provider failures
  - Automatic state transitions
  - Recovery testing with timeout logic
  - Failover to healthy providers

#### Technical State Transitions:

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

#### Demo Scenarios:

- Kill Infura connection → circuit opens → traffic routes to Alchemy
- Recovery after timeout → half-open state → successful calls close circuit
- Multiple provider failures → cascading failover logic

---

### 3. Provider Performance Scoring Algorithm

#### Mathematical Scoring Function

- **File**: `lib/livechain/benchmarking/benchmark_store.ex:656-663`
- **Functionality**: Multi-factor performance scoring with confidence weighting
- **Demo Requirements**:
  - Real performance data from multiple providers
  - Live score calculations
  - Ranking stability over time
  - Score-based routing decisions

#### Algorithm Implementation:

```elixir
defp calculate_provider_score(win_rate, avg_margin_ms, total_races) do
  confidence_factor = :math.log10(max(total_races, 1))  # More races = higher confidence
  margin_penalty = if avg_margin_ms > 0, do: 1 / (1 + avg_margin_ms / 100), else: 1.0
  win_rate * margin_penalty * confidence_factor
end
```

#### Demo Metrics:

- Provider win rates (percentage of races won)
- Average timing margins when losing
- Confidence factors based on sample size
- Real-time score updates and rankings

---

### 4. ETS-Based High-Performance Data Storage

#### Memory Management System

- **File**: `lib/livechain/benchmarking/benchmark_store.ex:673-700`
- **Functionality**: Bounded ETS tables with automatic cleanup
- **Demo Requirements**:
  - High-frequency metric ingestion (multiple events per second)
  - Memory bounds enforcement
  - Efficient data retrieval for dashboard
  - Cleanup operations without service interruption

#### Technical Implementation:

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

#### Demo Data Flows:

- Racing metrics: timestamp, provider_id, event_type, result, margin_ms
- RPC metrics: timestamp, provider_id, method, duration_ms, success/failure
- Score aggregation: wins, losses, average margins, confidence factors

---

### 5. Phoenix LiveView Real-Time Dashboard

#### Live Data Visualization Requirements

- **File**: `lib/livechain_web/live/dashboard.ex`
- **Functionality**: Real-time provider performance visualization
- **Demo Requirements**:
  - Live racing leaderboard updates (later)
  - Provider performance metrics matrix (later)
  - Chain selection and filtering (later)
  - Real-time chart updates (later)

#### Minimal Implementation (Now)

- Live Dashboard tab: topology, quick stats, simple event feeds
- Live Test tab: demo controls + routing sampler + provider event emitters
- System Metrics tab: simple counters preview; expand to Telemetry later

---

### 6. Multi-Provider JSON-RPC Integration

#### Real Provider Connections

- **Files**: `lib/livechain/rpc/ws_connection.ex`, `lib/livechain/rpc/real_endpoints.ex`
- **Functionality**: Actual connections to Infura, Alchemy, other RPC providers
- **Demo Requirements**:
  - Working API key configuration
  - Multiple providers per chain
  - Standard JSON-RPC method support
  - Provider pool management

#### JSON-RPC Methods to Support

- `eth_subscribe("newHeads")` - Block subscriptions for racing
- `eth_getLogs` - Historical log queries with benchmarking
- `eth_getBlockByNumber` - Block data retrieval
- `eth_getBalance` - Account balance queries

---

### 7. Provider Selection Strategies (New)

#### Feature Overview

- Pluggable strategy for selecting providers when forwarding HTTP JSON-RPC:
  - `:leaderboard` (default): highest score from `BenchmarkStore`
  - `:priority`: first available provider by configured priority
  - `:round_robin`: rotate among available providers
  - Future: `:cheapest`, `:latency_based`, hybrid

#### Configuration

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :leaderboard
# Alternatives: :priority | :round_robin
```

#### Demo Plan (Later)

- Live toggle strategy to showcase different routing behaviors:

  1. Start with `:leaderboard` and display current leader
  2. Switch to `:priority` and demonstrate deterministic routing to priority-1 provider
  3. Switch to `:round_robin` and show rotation across providers via `eth_blockNumber` loop
  4. Simulate a provider failure; observe automatic failover under each strategy

- Visualizations to show during demo:
  - Current strategy label on the dashboard
  - Per-request annotations (provider used) in a request log panel
  - Leaderboard scores vs chosen provider to illustrate strategy difference

---

## Performance and Scale Targets for Demo

### Racing Performance

- Event processing: 100+ events/second per chain
- Timing precision: ±1ms accuracy for meaningful benchmarks
- Memory usage: <50MB for 24 hours of racing data
- Dashboard updates: <100ms latency for new race results

### Provider Management

- Concurrent providers: 2-4 providers per chain
- Supported chains: Ethereum, Polygon, Arbitrum
- Connection health: <5 second detection of provider failures
- Failover time: <1 second to switch providers

### System Reliability

- Circuit breaker response: <100ms to open on failure
- Process restart: <500ms recovery from GenServer crash
- Data persistence: No race data loss during normal operation
- Dashboard availability: 99%+ uptime during demo period

---

This specification includes the minimal implementation plan to make the demo usable immediately as well as the longer-term vision to showcase ChainPulse's provider racing and orchestration capabilities.
