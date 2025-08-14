## Lasso RPC Tech Demo — Implementation Plan

### Guiding Principles

- Keep demo real-time, resilient, and visually coherent with existing grid theme and cards
- Prefer PubSub fan-out for UI reactivity; avoid heavy synchronous calls from LiveView
- Use ETS-backed rolling windows for metrics; cap lists to prevent memory bloat
- Batch UI updates at ~250ms to smooth bursts

### Phasing Overview

- Phase 0: Branding and tab scaffolding
- Phase 1: Event plane (PubSub topics) and telemetry spans
- Phase 2: Metric aggregation and query APIs
- Phase 3: LiveView UI (Overview, Streams, System)
- Phase 4: Network Explorer enhancements
- Phase 5: Benchmarks (leaderboard, matrix, strategy compare)
- Phase 6: Frontend Simulator (JS client-driven load)
- Phase 7: Validation, tests, and polishing

---

### Phase 0 — Branding + Tabs Scaffold

- Rename header branding in `lib/livechain_web/live/dashboard.ex` from `ChainPulse` to `Lasso RPC`
- Replace current tabs with: Overview, Network Explorer, Streams, Benchmarks, Simulator, System
  - Add function components: `overview_tab_content/1`, `network_tab_content/1`, `streams_tab_content/1`, `benchmarks_tab_content/1`, `simulator_tab_content/1`, keep `metrics_tab_content/1` as System
  - Keep existing styles, badges, and gridded background

Acceptance:

- Header shows “Lasso RPC” and new tabs render placeholders

---

### Phase 1 — Event Plane and Telemetry

Add/normalize real-time topics; ensure all producers emit consistent, compact payloads.

Existing topics (keep):

- `"ws_connections"` from `Livechain.RPC.WSSupervisor`
- `"provider_pool:events"` from `Livechain.RPC.ProviderPool`
- `"routing:decisions"` from `LivechainWeb.RPCController`
- `"raw_messages:<chain>"` → `Livechain.RPC.MessageAggregator`
- `"blockchain:<chain>"` + `"aggregated:<chain>"` from `MessageAggregator.forward_message/4`

New topics added:

- `"circuit:events"` in `Livechain.RPC.CircuitBreaker`
- `"clients:events"` in `LivechainWeb.RPCSocket`
- `"blocks:new:<chain>"` in `Livechain.RPC.MessageAggregator`
- `"strategy:events"` in `LivechainWeb.RPCController`

Telemetry:

- `[:livechain, :rpc, :request, :start|:stop]` emitted in RPC forwarding
- `[:livechain, :ws, :message, :received]` emitted in WS pipelines (real and mock)

Acceptance:

- Topics publish; `iex` confirms events

---

### Phase 2 — Metric Aggregation + Query APIs

New `Livechain.Metrics.Rollups` ETS aggregators; attach to Telemetry.

- Tables: `rpc_metrics_<chain>`, `strategy_metrics_<chain>`, `events_ring_<topic>`
- APIs: `get_method_matrix/2`, `get_strategy_compare/2`, `get_leaderboard/1`, `recent_stream/1`
- Periodic PubSub snapshots: `"benchmarks:stats:<chain>"`

Acceptance:

- Aggregators return summaries under synthetic load

---

### Phase 3 — LiveView UI: Overview, Streams, System

- Subscriptions to event topics; buffered assigns with 250ms flush
- Overview KPIs, Streams split view with filters, System sparklines

Acceptance:

- UI updates in near real-time

---

### Phase 4 — Network Explorer Enhancements

- Add metrics/circuit badges; click to open provider drawer with details

Acceptance:

- Nodes reflect state; details drawer updates

---

### Phase 5 — Benchmarks Tab

- Leaderboard, method/provider heatmap, strategy comparison with time ranges

Acceptance:

- Heatmap and leaderboard update quickly

---

### Phase 6 — Frontend Simulator (JS client-driven load)

Implement a browser-side load generator using Viem/fetch/ws, coordinated via LiveView Hooks.

Deliverables:

- `assets/js/lasso_simulator.js`:
  - `startHttpLoad({chains, methods, rps, concurrency, durationMs, strategy})`
  - `stopHttpLoad()`
  - `startWsLoad({chains, connections, topics, durationMs})`
  - `stopWsLoad()`
  - `activeStats()` returns counters (success, error, avg latency, open ws)
- LiveView Hook `SimulatorControl`:
  - Receives `phx-click`/`phx-change` events; calls JS functions; periodically pushes stats back to LiveView via `pushEvent("sim_stats", data)`
- Simulator tab UI wiring:
  - Controls for chains/methods selection, RPS slider, WS connections count, duration
  - Start/Stop buttons for HTTP and WS loads

Behavior:

- HTTP load uses `fetch('/rpc/:chain')` posting JSON-RPC for methods (e.g., `eth_blockNumber`, `eth_getBalance`); optional `?strategy=` or header for selection
- WS load opens `ws://.../rpc/:chain`, sends `eth_subscribe` (newHeads/logs); maintains N connections; auto-close after duration
- All traffic flows through existing server paths to emit `routing:decisions`, `blocks:new:<chain>`, `clients:events`

Acceptance:

- Starting HTTP/WS load immediately surfaces in Streams and Overview; counters reflect activity; can stop cleanly

---

### Phase 7 — Validation, Tests, Polishing

- JS module unit sanity (basic), LiveView hook integration test
- Controller/channel tests still cover server emissions
- Performance: throttle UI updates, cap buffers, ensure no memory leaks in JS (clear timers)

---

### File/Module Touchpoints (Checklist)

- `lib/livechain_web/live/dashboard.ex`: Simulator tab controls and events, subscribe to topics
- `lib/livechain_web/components/network_topology.ex`: badges and click behavior
- `lib/livechain_web/channels/rpc_socket.ex`: publish `clients:events`
- `lib/livechain_web/channels/rpc_channel.ex`: keep for WS RPC forwarding
- `lib/livechain/rpc/ws_supervisor.ex`, `lib/livechain/rpc/ws_connection.ex`, `lib/livechain/rpc/mock_ws_connection.ex`: telemetry + raw_messages
- `lib/livechain/rpc/message_aggregator.ex`: `blocks:new:<chain>`
- `lib/livechain/rpc/provider_pool.ex`: `provider_pool:events`
- `lib/livechain/rpc/circuit_breaker.ex`: `circuit:events`
- `lib/livechain_web/controllers/rpc_controller.ex`: `routing:decisions`, `strategy:events`
- New: `assets/js/lasso_simulator.js` and LiveView Hook wiring in `assets/js/app.js`
- New (later): `Livechain.Metrics.Rollups`

---

### Acceptance Criteria Summary

- Overview: live KPIs, latest blocks, client/prov counts
- Network Explorer: topology with per-node metrics and circuit state
- Streams: real-time RPC and system events with filters
- Benchmarks: leaderboard, method x provider heatmap, strategy compare
- Simulator: client-driven HTTP/WS load; visible effects across tabs
- System: BEAM metrics with sparklines

### Risks / Mitigations

- Browser throttling under heavy JS load → allow configurable concurrency and refresh cadence; keep loops efficient
- Overloading server → cap RPS and connections; provide stop buttons and duration limits
- Demo vs prod separation → gate simulator UI behind dev/demo flag
