### Vision: “Lasso RPC” Interactive System Explorer

A modern Phoenix LiveView app that feels like an exploratory dashboard: fast, animated, color-rich, and informative. Retain the current gridded background and card aesthetic; elevate with clear information hierarchy, interactive simulations, and real-time motion.

### App Structure (wip - can be updated as we go)

- Overview
- Network Explorer
- Streams
- Benchmarks
- Simulator
- System

### Tab Specs (proposal)

- Overview

  - Hero header: “Lasso RPC” with animated live indicator and chain/provider counts.
  - Cards:
    - Providers summary by chain: total, healthy, degraded, down; mini sparkline for health over time.
    - Live client connections: count + sparkline by minute.
    - Latest blocks per chain: compact list (height-limited, auto-scrolling) with block number, age, proposer/tx count if available.
    - Strategy overview: current default strategy and quick switcher (read-only display in MVP, action in Simulator).
  - Implementation notes:
    - Sources: `Livechain.RPC.WSSupervisor.list_connections/0`, `ProviderPool` events, new blocks PubSub (see below).
    - PubSub topics: `"ws_connections"`, `"provider_pool:events"`, `"blocks:new:<chain>"`.
    - Keep lists bounded (100 entries) with prepend; throttle updates to ~250ms batch.

- Network Explorer

  - Interactive topology (keep the current style) with improvements:
    - Columns per chain; providers as nodes; edges representing WS/HTTP flows.
    - Node badges: latency (p50/p95), error rate, circuit state; glow/pulse when events occur.
    - Click provider → drawer with detail: recent RPC calls, health timeline, failures, circuit state transitions.
  - Implementation notes:
    - Use existing `LivechainWeb.NetworkTopology` component; add assigns for health/metrics, click handlers (`"select_provider"`).
    - Data: provider health from `ProviderPool`, circuit state from `CircuitBreaker`, RPC latency from Telemetry aggregation.

- Streams

  - Live feeds in a split view:
    - RPC call stream (high-signal): chain, method, duration, provider, strategy, result. Color by result; sticky filters for chain/method.
    - System event stream: provider pool events, circuit trips/recoveries, failovers, strategy change events.
  - Implementation notes:
    - Topics: `"routing:decisions"`, `"provider_pool:events"`, `"circuit:events"`, `"strategy:events"`.
    - Publish real events from HTTP proxy and WS forwarder paths; include `failover_count`, `selected_strategy`, `fallback_reason`.

- Benchmarks

  - Comparative metrics:
    - Leaderboard: providers ranked by score (win rate, avg margin, confidence).
    - Method performance matrix: latency by provider x method (heatmap); toggle time range (5m/1h/24h).
    - Strategy comparison: show latency distribution and cost vs latency for multiple strategies (e.g., fastest vs cheapest vs round_robin).
  - Implementation notes:
    - Source: `Livechain.Benchmarking.BenchmarkStore` (leaderboard, real-time stats), ETS-backed matrices (add a tiny aggregator process for rolling windows).
    - Add `:telemetry` to emit `[:livechain, :rpc, :forward, :stop]` with metadata `provider`, `method`, `chain`, `strategy`.

- Simulator

  - Controls:
    - Load generator (JS client-driven): choose chains/methods, target RPS, concurrency, bursts.
    - WS connection generator: open N WebSocket connections to `/rpc/:chain`, subscribe to topics, auto-close after T.
    - Failure injection (server-side optional): open circuit, add latency, drop packets, force rate limits; scoped to provider/chain with duration.
    - Strategy sandbox: switch default strategy and/or override per chain; compare real-time results side-by-side.
    - Scenario presets: “Provider outage”, “Latency spike”, “Rate limit storm”, “Flappy WS”, “HTTP burst”.
  - Visuals:
    - Mini KPIs: success rate, failovers/min, avg latency, selected strategy.
    - Timeline strips: event markers for injections and recoveries.
  - Implementation notes (JS-based approach):
    - Use a frontend module (`assets/js/lasso_simulator.js`) powered by Viem or bare fetch/websocket:
      - HTTP JSON-RPC: POST to `/rpc/:chain` (methods like `eth_blockNumber`, `eth_getBalance`).
      - WebSocket JSON-RPC: connect to `ws://.../rpc/:chain`, send `eth_subscribe` for `newHeads`/`logs`.
    - Orchestrate via LiveView Hooks (e.g., `SimulatorControl`) to start/stop load and report client-side counters back to LiveView assigns.
    - All HTTP calls flow through `LivechainWeb.RPCController` and will emit `routing:decisions`; WS traffic flows through real/mock WS stacks and will surface via `blocks:new:<chain>` and streams.

- System
  - BEAM metrics:
    - CPU, run queue, reductions/sec
    - Memory breakdown
    - Process/Port/ETS counts
    - Scheduler utilization avg
  - Implementation notes:
    - Keep your current implementation; just add historical sparklines (store last 60 samples in socket assigns).

### Data & Events: Shapes and Topics

- RPC decisions (publish from HTTP/WS forwarders)

```json
{
  "ts": 1731630452123,
  "chain": "ethereum",
  "method": "eth_getBalance",
  "strategy": "leaderboard",
  "provider_id": "alchemy_ethereum",
  "duration_ms": 73,
  "result": "success",
  "failover_count": 0
}
```

Topic: `routing:decisions`

- Provider pool events (already in place)

```json
{
  "ts": 1731630452123,
  "chain": "polygon",
  "provider_id": "infura_polygon",
  "event": "cooldown_start",
  "details": { "until": 1731630458123 }
}
```

Topic: `provider_pool:events`

- Circuit events

```json
{
  "ts": 1731630452123,
  "chain": "ethereum",
  "provider_id": "alchemy_ethereum",
  "from": "closed",
  "to": "open",
  "reason": "failure_threshold_exceeded"
}
```

Topic: `circuit:events`

- New blocks

```json
{
  "ts": 1731630452123,
  "chain": "ethereum",
  "block_number": 20714562,
  "hash": "0x...",
  "tx_count": 142,
  "provider_first": "alchemy_ethereum",
  "margin_ms": 12
}
```

Topic: `blocks:new:<chain>`

- Client connections

```json
{
  "ts": 1731630452123,
  "event": "client_connected",
  "transport": "ws",
  "remote_ip": "1.2.3.4"
}
```

Topic: `clients:events`

### Telemetry: Recommended Spans

- `[:livechain, :rpc, :forward, :start|:stop]` with metadata: `chain`, `method`, `strategy`, `provider_id`, `result`, `error?`.
- `[:livechain, :ws, :message, :received]` with metadata: `chain`, `provider_id`, `event_type` (newHeads/logs), `message_key`.
- `[:livechain, :circuit, :state_change]` with metadata: `chain`, `provider_id`, `from`, `to`, `reason`.

Wire Telemetry to ETS aggregators for:

- Latency per method/provider/strategy (rolling 5m/1h).
- Success/error counts.
- Failover counts.
  Expose to LiveView via simple getters or PubSub snapshots (`benchmarks:stats:<chain>`).

### UI/UX Notes

- Keep the gridded background; add subtle animated gradients per card header on state change (success: emerald glow; error: rose; degraded: amber).
- Use badges for chain, method, strategy; align with current color palette.
- Sparklines: small SVGs to keep it snappy.
- Batching: buffer incoming PubSub and flush at 25

### Mapping “What” → “How” → Source

- Overview info for all providers → Provider status cards → `ProviderPool`, `CircuitBreaker`
- Live provider activity by chain → Streams + Topology pulses → `provider_pool:events`
- Live WS connections to providers → Topology node states → `WSSupervisor.list_connections/0` + `"ws_connections"`
- Live client connections → Overview KPI + Streams → `clients:events`
- RPC method call stream → Streams panel → `routing:decisions` + Telemetry
- Relevant system PubSub → Streams panel → `provider_pool:events`, `circuit:events`, `strategy:events`
- Live latest blocks → Overview “Latest blocks” + Streams → `blocks:new:<chain>`
- Latencies by method + strategy comparison → Benchmarks heatmap + comparison → Telemetry + BenchmarkStore
- BEAM stats → System tab → existing `collect_vm_metrics/0`

### Stretch “Wow” Ideas

- Strategy A/B sandbox: split traffic (e.g., 20% `fastest`, 80% `leaderboard`) and show deltas live.
- Cost overlays: add “estimated $/1k calls” per provider, render latency vs cost scatter.
- Anomaly hints: badge cards with “spike detected” when Z-score deviates >2σ for 5m.
