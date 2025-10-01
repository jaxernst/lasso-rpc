# Lasso RPC Test Plan

Last updated: 10/01/25

## Purpose

Single source of truth for testing: what’s covered today, gaps, and a pragmatic plan forward to gain end-to-end confidence for the RPC aggregator.

## Current State Snapshot

- Manual smoke (local):
  - GET `/api/health` → 200 OK (healthy)
  - GET `/api/metrics/ethereum` → 200 OK (no providers listed yet; system metrics present)
  - POST `/rpc/fastest/ethereum` with `eth_blockNumber` → 200 OK (returned block number)

## Testing Pillars (What matters most)

1. Reliability and Failover: Requests succeed despite provider failures; circuit breakers open/half-open/close correctly.
2. Correct Routing: Strategies select intended provider(s) (especially “fastest” using metrics) with deterministic inputs.
3. Transport Handling: HTTP vs WS; unsupported method fall-through across channels works.
4. JSON-RPC Contract: Response shape, error mapping, and ID handling are spec-compliant.
5. Observability: Telemetry, metrics, and PubSub events reflect reality for trustworthy dashboards.

## Manual Testing Checklist (Quick Validation)

Run these to sanity-check behavior during development:

```bash
# 1) Basic HTTP RPC endpoint (default strategy)
curl -s -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 2) Strategy endpoints
curl -s -X POST http://localhost:4000/rpc/fastest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl -s -X POST http://localhost:4000/rpc/cheapest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl -s -X POST http://localhost:4000/rpc/priority/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl -s -X POST http://localhost:4000/rpc/round-robin/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 3) Provider override
curl -s -X POST http://localhost:4000/rpc/ethereum_ankr/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 4) Batch requests
curl -s -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2}
  ]'

# 5) WebSocket subscriptions (interactive)
wscat -c ws://localhost:4000/rpc/ethereum
> {"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}

# 6) Health & status
curl -s http://localhost:4000/api/health
curl -s http://localhost:4000/api/status
curl -s http://localhost:4000/api/metrics/ethereum

# 7) Error conditions
curl -s -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_sendTransaction","params":[],"id":1}'
```

## Test Inventory & Actions (Merged)

### ✅ Keep & Fix

- `test/livechain/rpc/circuit_breaker_test.exs`: Solid; add edge cases (half-open user errors are neutral, recovery thresholds).
- `test/livechain/rpc/provider_pool_test.exs`: Keep; refine setup to current ProviderPool contract.
- `test/livechain/rpc/selection_test.exs`: Keep; remove config flakiness with deterministic metrics stubs.
- `test/integration/failover_test.exs`: Keep structure; reduce mocking; use local fake providers.
- `test/livechain/error_scenarios_test.exs`: Keep; add realistic retriable vs non-retriable scenarios.

### 🔧 Scrap Implementation, Keep Intent

- `test/livechain_web/controllers/rpc_controller_test.exs`: Rewrite as HTTP integration tests via `ConnCase` against fake providers.
- `test/livechain/rpc/live_stream_test.exs`: Defer until WS subscription architecture stabilizes; then rewrite.
- `test/livechain/rpc/endpoint_test.exs`, `chain_supervisor_test.exs`, `ws_connection_test.exs`: Examine; likely outdated—either remove or fully rewrite for new WS/channel model.

### 🗑️ Scrap Entirely (Low Value)

- Health/status controller tests and YAML parsing tests. Validate manually or via one basic check; not worth ongoing maintenance.

## Roadmap (6 Weeks)

### Week 1: Stabilize and Sanity

- Skip/disable outdated WS tests blocking compilation (`ws_connection_test.exs`).
- Fix and run: circuit breaker, provider pool, selection tests.
- Add deterministic metrics stub to make “fastest” strategy predictable in tests.

### Week 2: Core Resilience & Routing

- Unit/integration tests for: failover loop limits, provider override with/without failover, and channel fall-through on `:unsupported_method`.
- Telemetry assertions for `[:livechain, :rpc, :request, :start|:stop]` and circuit events.

### Week 3: HTTP Integration

- Black-box tests via `/rpc/:strategy/:chain` against fake HTTP providers with scripted outcomes (success, timeout, retriable error).

### Week 4: E2E + Compliance

- JSON-RPC shape compliance and error codes; deny-list write methods; batch requests.
- Multi-chain basic isolation checks.

### Week 5: Performance (Local, Non-CI)

- Short synthetic load against local fakes; capture P95, success rate, breaker open rate.

### Week 6: Chaos & Recovery (Local, Non-CI)

- Simulate provider flaps, partitions, and all-fail conditions; verify graceful degradation and recovery.

## CI Plan

- Tier 1 (fast/unit): strategies, circuit breaker, error mapping, selection.
- Tier 2 (integration): black-box HTTP flow against fake providers and stubbed metrics.
- Nightly (optional): short synthetic load against fakes; generous thresholds; no real providers in CI.

## Test Infrastructure

- Deterministic Metrics Backend (test-only): seed per-method/per-transport latencies.
- Fake Providers:
  - HTTP Plug returning scripted JSON-RPC results/errors/timeouts.
  - Minimal WS endpoint for basic subscribe/unsubscribe (added later when WS stabilizes).
- Libraries (add in `:test`):
  - `:bypass` (HTTP fake), `:stream_data` (property tests), `:benchee` (micro-bench), optional `:wallaby` (dashboard UI).

## Performance & Load Testing Position

- Keep `Livechain.Testing` Load Tester as a manual benchmarking/demo tool (not CI gating).
- Add base URL override + random seed for reproducibility; prefer targeting local fakes first.
- Track: success rate, P95 latency by method, failover rate, breaker open rate, RPS, and memory over time.

## Minimal SLOs (Initial)

- Read-only methods: ≥99% success (with retries) per method over 10 min against healthy providers.
- Added latency budget (Lasso vs upstream): P95 ≤ 20–30 ms locally.
- Failover completes within one additional upstream timeout after initial failure.
- Circuit breaker opens after N consecutive failures and recovers within M seconds when upstream is healthy.

## Recommended Commands

```bash
# Focused runs by tag (once tags are added)
mix test --only unit
mix test --only integration

# CI-friendly
mix test --include integration --exclude load --exclude chaos
```

---

Last verified locally:

- Tests: compile fail at `ws_connection_test.exs` (legacy). Action: disable/rewrite.
- Manual smoke: health OK, metrics OK, fastest RPC endpoint returns block number.

---

## WebSocket Subscription Implementation Status (Sept 29, 2025)

### Issues Found & Fixed

#### ✅ FIXED: UpstreamSubscriptionPool Crash (Line 141-142)

**Problem:** `put_in(nil, [:upstream, provider_id], upstream_id)` crashed when entry was nil

**Fix:** Added nil check with case statement in upstream_subscription_pool.ex:138-177

**Status:** No more crashes during subscription flow

### 🔍 Currently Investigating: No Subscription Events Received

**Symptoms:**

- Client connects successfully to RPCSocket
- Provider (LlamaRPC) is selected for eth_subscribe
- WebSocketClient waits 30 seconds
- **0 events received**

**Test Command:**

```bash
mix test test/battle/websocket_subscription_test.exs:12 --trace
```

**Result:** Test runs 30s without crashing, but fails expecting >= 1 event (got 0)

**Server Logs Show:**

- ✅ Client connects: "JSON-RPC WebSocket client connected: ethereum"
- ✅ Provider selected: "Selected provider: ethereum_llamarpc for ethereum.eth_subscribe"
- ❌ No subscription request log
- ❌ No subscription ID confirmation
- ❌ No events from StreamCoordinator

**Next Steps:**

1. Add debug logging to `send_upstream_subscribe` (upstream_subscription_pool.ex:389-416)
2. Verify WSConnection.send_message is being called
3. Check WSConnection handle_frame for responses
4. Verify PubSub subscription at line 44
5. Manual IEx debugging session

## WebSocket Subscriptions – Integration Test Update (Oct 1, 2025)

### What We Did

- Implemented a realistic WS mock provider and end-to-end integration for subscription flow.
  - Mock registers under `{:via, Registry, {Livechain.Registry, {:ws_conn, provider_id}}}` (WSConnection-compatible).
  - Added sync handlers in the mock to support `WSConnection.send_message/2` and `WSConnection.request/5` via `Channel.request/3`.
  - Made `eth_unsubscribe` fire-and-forget in `UpstreamSubscriptionPool` to reduce coupling in tests.
- Stabilized `UpstreamSubscriptionPool` integration tests.
  - Dynamic chain/provider IDs per test; robust teardown for provider + chain supervisor + ConfigStore.
  - Fixed assertions to use dynamic `provider` from setup.
- Verified transport-agnostic routing.
  - `eth_subscribe` flows through `TransportRegistry` → `Transport.WebSocket` → WS mock, with confirmations processed by the pool.

### Files Touched (Core)

- `lib/livechain/testing/mock_ws_provider.ex` (WSConnection naming, handle_call support, resilient stop)
- `lib/livechain/rpc/upstream_subscription_pool.ex` (unsubscribe send made fire-and-forget)
- `test/livechain/rpc/upstream_subscription_pool_integration_test.exs` (dynamic IDs, fixed assertions/teardown)

### Results

- Integration suite passes locally: 7 tests, 0 failures.
- Confirms end-to-end routing with real subscription confirmations observed by the pool.

### Remaining Gaps (High Priority)

- Client delivery assertion: After `MockWSProvider.send_block/3` or `send_log/3`, assert the client receives `{:subscription_event, sub_id, payload}`.
- Failover behavior: With 2+ WS mocks, kill primary; assert automatic switch and continued events.
- Pending confirmation paths:
  - Delayed confirmation (`confirm_delay > 0`) → pending then confirms.
  - Timeout (auto_confirm: false) → pending cleaned after `subscription_timeout_ms` with telemetry.
- Logs filter correctness: Multiple subscriptions with different filters; only matching events route.
- Concurrency dedupe: Burst `subscribe_client` for same key yields one upstream subscribe (count in mock or PubSub tap).
- Unsubscribe semantics: No upstream unsubscribe when refcount > 1; exactly one when refcount drops to 0; upstream state cleared.
- Resilience: Kill mock PID mid-stream; verify provider pool state transitions and sub continuity/cleanup.
- Cleanup/leaks: After `on_exit`, assert no lingering `{:ws_conn, provider}` registry entries or `TransportRegistry` channels.

### Nice-to-Haves

- Event without subscription ID: Send `eth_subscription` lacking `subscription` and assert fallback routing via payload detection.
- Mixed transports: Include HTTP-only mock; ensure excluded from subscription selection but usable for HTTP requests elsewhere.

### Follow-ups

- Add 1–2 tests now: client receive assertion and basic two-provider failover.
- Remove unused aliases flagged by warnings in tests and `RequestPipeline`.
