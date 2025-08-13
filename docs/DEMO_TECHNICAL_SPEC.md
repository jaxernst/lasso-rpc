# ChainPulse Demo: Technical Feature Specification (Updated)

## Demo Goals

- Showcase a pragmatic, latency-based RPC orchestration MVP with strong reliability and observability.
- Demonstrate provider health, routing decisions, percentiles, and event racing (WS) clearly.
- Provide interactive controls to run tests, simulate failures, and observe system responses in real time.

---

## Tabs and Features

### 1) Live Dashboard (Real-time Monitoring)

- KPIs (global and per-chain)

  - Requests/min, error rate, p50/p90/p99 (overall), healthy providers, open breakers, providers cooling, last failover time
  - Sources:
    - `Livechain.RPC.ChainManager.get_status/0`
    - `Livechain.RPC.ProviderPool.get_status(chain)`
    - `Livechain.Benchmarking.BenchmarkStore.get_realtime_stats(chain)`
    - New PubSub: `"routing:decisions"`

- Provider Health Grid (per-chain)

  - Columns: provider, status (healthy/unhealthy/cooling), circuit state (open/half-open/closed), avg latency (EMA), error rate (EMA), p90 (if available), cooldown remaining, last error
  - Sources:
    - `ProviderPool.get_status(chain)`
    - `CircuitBreaker.get_state(provider_id)`
    - `BenchmarkStore.get_rpc_method_performance(chain, method)` (aggregate p90 across common methods)

- RPC Performance by Method (with percentiles)

  - Methods table: method, p50, p90, p99, success rate, recent call count
  - On select: provider comparison panel ranked by p90 (or avg), highlight currently selected-by-latency provider
  - Source:
    - `BenchmarkStore.get_rpc_method_performance(chain, method)` (use percentiles if available; fallback to avg)

- Event Racing Leaderboard (WS only)

  - Per event type (e.g., `newHeads`): provider win-rate, avg loss margin
  - Note clearly: WS racing is not used for HTTP provider selection
  - Source:
    - `BenchmarkStore.get_provider_leaderboard(chain)`

- Routing Decisions Stream (last 50)

  - Entry: ts, chain, method, strategy, chosen provider, duration_ms, result, failover_count
  - Source: new PubSub `"routing:decisions"` emitted by `RPCController` after each request

- All-Chains Topology + Activity
  - Use `LivechainWeb.NetworkTopology.nodes_display/1` to show chains with active WS connections
  - Overlay recent HTTP activity (last 60s) as heat halos on provider nodes; badges for error-rate threshold breaches or breaker open
  - Sources:
    - `Livechain.RPC.WSSupervisor.list_connections/0`
    - Aggregated recent decisions from `"routing:decisions"`

### 2) Live Test (Controls)

- Quick Call Runner

  - Inputs: chains (multi-select), method (eth_blockNumber, eth_getBalance, eth_getLogs, eth_call), strategy override (latency/cheapest/priority/round_robin), iterations, concurrency, timeout
  - Output: summary (success rate, p50/p90/p99, error breakdown), provider hit counts, mini latency timeline
  - Impl: `Task.Supervisor.async_stream_nolink` with HTTP client behaviour stub/real client; stream results to LiveView

- Failure Drills

  - Buttons: open/close circuit (per provider), mark provider unhealthy (simulate), trigger cooldown (simulate 429)
  - Actions:
    - `Livechain.RPC.CircuitBreaker.open/close(provider_id)`
    - `Livechain.RPC.ProviderPool.trigger_failover(chain, provider_id)`
    - Helper/API to set cooldown in `ProviderPool`

- Strategy Toggles

  - App default strategy override; per-request override in Quick Call
  - Action: `Application.put_env(:livechain, :provider_selection_strategy, ...)`

- Maintenance/Health
  - Buttons: run active health checks, reset metrics (clear recent windows), re-evaluate provider status
  - Actions:
    - Cast to `ProviderPool` to perform health probes
    - `BenchmarkStore.cleanup_old_entries(chain)`
    - Helper to clear cooldowns and close breakers

### 3) System Health (BEAM Observability)

- VM Overview

  - CPU schedulers utilization, total run queue lengths, total processes, memory (total/atom/binary/ets/processes)
  - Sources: `:erlang.system_info/1`, `:erlang.memory/0`, `:erlang.statistics/1`, via `:telemetry_poller`

- ETS and Process Hot-spots

  - ETS table sizes (BenchmarkStore), growth rate; top processes by message queue length; mailbox growth alerts
  - Sources: `:ets.info/2`, `:erlang.processes/0` + sampled `:erlang.process_info/2`

- Telemetry Events
  - Counters: routed requests, failures, breaker open/close, cooldown start/stop; p99 over last 5 minutes
  - Emit from `RPCController`, `ProviderPool`, `CircuitBreaker`; aggregate in-memory for the demo

---

## Data, Events, and APIs

- PubSub topics (new)

  - `"routing:decisions"`: `%{ts, chain, method, strategy, provider_id, duration_ms, result, failover_count}`
  - `"provider_pool:events"`: `%{ts, chain, provider_id, event: :unhealthy|:healthy|:cooldown_start|:cooldown_end, details}`
  - Existing: `"ws_connections"`

- Queries
  - `ChainManager.get_status/0` and `get_chain_status/1`
  - `ProviderPool.get_status(chain)`
  - `BenchmarkStore.get_realtime_stats(chain)`
  - `BenchmarkStore.get_rpc_method_performance(chain, method)` (percentiles/avg + success_rate)
  - `CircuitBreaker.get_state(provider_id)`
  - `WSSupervisor.list_connections/0`

---

## Minimal Wiring Required

- Emit `"routing:decisions"` at the end of `RPCController.forward_rpc_request/4` (and in failover): include method, strategy (resolved), provider, duration, result, failover_count
- Emit `"provider_pool:events"` from `ProviderPool` on status/cooldown transitions
- Optional: add Telemetry spans/counters for routed requests and provider selection decisions

---

## Acceptance Criteria

- Live Dashboard shows:
  - Up-to-date KPIs; provider grid with breaker/cooldown state; RPC method p50/p90/p99 + success rates; WS racing leaderboard; routing decisions stream; topology with active WS and recent HTTP heat halos
- Live Test:
  - Runs multi-chain tests; strategy override works; failure drills immediately visible in grid/decisions; maintenance buttons take effect
- System Health:
  - BEAM metrics update at a safe cadence (1–5s); ETS/process hot spots list; telemetry counters trend visibly
- Smooth rendering: throttle bursts via PubSub debouncing; no long blocking on UI

---

## Example Snippets

- Routing decision broadcast (controller):

```elixir
Phoenix.PubSub.broadcast(
  Livechain.PubSub,
  "routing:decisions",
  %{ts: System.system_time(:millisecond), chain: chain, method: method, strategy: to_string(strategy), provider_id: provider_id, duration_ms: duration_ms, result: :success, failover_count: failovers}
)
```

- Provider pool event broadcast:

```elixir
Phoenix.PubSub.broadcast(
  Livechain.PubSub,
  "provider_pool:events",
  %{ts: System.system_time(:millisecond), chain: state.chain_name, provider_id: provider_id, event: :cooldown_start, details: %{until: cooldown_until}}
)
```

---

## Optional Enhancements (time permitting)

- Percentiles everywhere: when absent, display avg with an indicator
- Consistency sampling: occasional dual-provider checks to detect divergent results
- Dashboard filters: by chain, method, provider state
- Export: download recent routing decisions and metrics as JSON for analysis
