## State of ChainPulse (Livechain) — Technical Audit and Action Plan

### Purpose

A comprehensive, handoff-ready assessment of the blockahin RPC orchestration middleware’s current state, risks, and an actionable plan to reach a reliable, marketable MVP. References include exact files and, where useful, line ranges to accelerate implementation.

---

## Executive Summary

- The “fastest provider” vision is currently not achievable globally with the present stack. Benchmarking relies on mocks and lacks region-awareness, so selections based on latency are not representative in production.
- Core differentiators today should focus on: reliability (failover/backoff/circuit breaker), cost control (public-first routing with paid fallback), and clear observability (latency percentiles and success rates per method/provider) within a deployment region.
- Several modules are implemented but not wired into the request path (e.g., circuit breaker, `ProviderPool` latency updates). HTTP forwarding is mocked, so metrics and strategies don’t reflect reality yet.
- A pragmatic v1 feature set and an implementation plan are proposed below to make the system production-credible and marketable.

---

## Current Architecture and Vision Snapshot

- Docs: `docs/ARCHITECTURE.md` (Provider selection strategies, HTTP vs WS responsibilities)
- Config: `config/chains.yml` (chains, providers, global provider management)
- Core runtime:
  - `lib/livechain/rpc/chain_manager.ex`
  - `lib/livechain/rpc/chain_supervisor.ex`
  - `lib/livechain/rpc/provider_pool.ex`
  - `lib/livechain/rpc/ws_connection.ex`
  - `lib/livechain/benchmarking/benchmark_store.ex`
  - `lib/livechain/benchmarking/persistence.ex`
- HTTP/WS ingress:
  - `lib/livechain_web/controllers/rpc_controller.ex`
  - `lib/livechain_web/channels/rpc_channel.ex`
- Circuit breaker (not wired): `lib/livechain/rpc/circuit_breaker.ex`

Key stated strategies (docs/ARCHITECTURE.md):

- Leaderboard-based, priority, round-robin with future “cheapest” and “latency_based”. No region awareness.

---

## Findings (With References)

### 1) HTTP RPC forwarding is mocked (no real upstream calls)

- `lib/livechain/rpc/ws_connection.ex` → `make_http_rpc_request/3` returns mock data, not a real HTTP request.
  - Lines ~382–404: returns `{:ok, "mock_response_for_#{method}"}`
- Impact: “fastest” or latency-based strategies cannot work; HTTP benchmarking is not real.

### 2) Benchmarking partly records fake durations for HTTP path

- `lib/livechain_web/controllers/rpc_controller.ex` records 0ms durations on success/failure:
  - `record_rpc_success/3` and `record_rpc_failure/4` call `BenchmarkStore.record_rpc_call(..., 0, ...)` (~452–461)
- WS path does record durations, but WS request/response is also mocked in places.

### 3) Latency-based selection in `ProviderPool` cannot work as designed

- `lib/livechain/rpc/provider_pool.ex` selects by `avg_latency` when `load_balancing == "latency_based"` (~279–307)
- However, `ProviderPool.report_success/Failure` is not invoked from request paths (no call sites found), so `avg_latency` never updates from real traffic.

### 4) Circuit breaker is implemented but unused in request path

- `lib/livechain/rpc/circuit_breaker.ex` exists and is complete, but not integrated into forwarding/calls.
- Impact: Providers with repeated failures won’t be automatically gated, causing cascading errors.

### 6) No region/geo awareness

- `lib/livechain/config/chain_config.ex` `Provider` struct has: `type`, `priority`, `latency_target`, etc., but no `region` or `pop`.
- Impact: Latency varies heavily by geography. Global “fastest” routing is misguided unless deployed per-region and routed by client region.

### 7) WS benchmarking uses mocks for JSON-RPC in places

- `lib/livechain/rpc/ws_connection.ex` → request handling often returns `mock_json_rpc_response` (~706–713).
- Impact: Recorded durations do not represent real network/provider performance.

### 8) Active health checks are stubbed conceptually

- `ProviderPool.perform_health_checks/1` comment mentions relying on connection monitoring and success/failure reports; no active probes (e.g., periodic `eth_blockNumber`) are issued.
- Impact: Health never improves/deteriorates proactively; failover/reactivity is delayed.

### 9) Observability metrics exist but need percentiles/SLOs

- `BenchmarkStore` tracks averages and counts, can snapshot to disk, but does not compute percentiles (p50/p90/p99) or error budgets per method/provider.
- Impact: Averages can mask tail latency; routing/alerting lacks SLO context.

---

## Misguided or Risky Areas (Reframe)

- “Global fastest provider” routing from a single deployment is unrealistic. Make “fastest in region” the promise, and promote multi-region deployment with region-affinity routing.
- Complex leaderboard-based routing for HTTP is premature without real HTTP metrics. Use simpler, reliable strategies until real data exists.
- “Cheapest” without rate-limit awareness will degrade UX; add public-first with paid fallback and cooldowns.

---

## Recommendations and MVP Feature Set

### A) Reliability-first core (High priority)

1. Real HTTP client in forwarding path
   - Replace mocks in `make_http_rpc_request/3` with Finch/Mint/HTTPoison.
   - Measure per-call duration; propagate to benchmarking and `ProviderPool.report_success/Failure`.
2. Integrate circuit breaker
   - Wrap per-provider calls via `CircuitBreaker.call/3` (open on repeated failures; cooldown).
3. Timeouts and budgets per method
   - Define per-method timeouts in config; fail fast, attempt one failover, then return a shaped error.
4. 429/backoff & cooldowns
   - Detect 429/5xx (and JSON-RPC rate limit responses). Exponentially back off provider, mark as cooling, and deprioritize temporarily.

### B) Cost control (“Cheapest” pragmatic) (High priority)

1. Public-first routing with paid fallback
   - Filter providers by `type: "public"` first, round robin across them; fallback to paid on rate-limit/health signals.
2. Per-method policy
   - Allow configuring which methods use public-first (e.g., trivial reads) vs always-paid (heavier calls).
3. Quotas/budgets
   - Optional: caps on paid usage per day; degrade gracefully to public.

### C) Region-aware routing (Medium priority)

1. Add `region` to provider config
   - Extend `Provider` with `region` (e.g., `us-east-1`, `eu-west`, `ap-sg`).
2. Client region selection
   - Allow `X-Livechain-Region` header or `/rpc/:region/:chain` to select region affinity.
3. Deploy per-region replicas
   - “Fastest” claims apply within region; for global, use edge/load-balancer to route client to nearest region.

### D) Observability & SLOs (Medium priority)

1. Percentiles
   - Track p50/p90/p99 per method/provider and use percentiles in dashboards and routing decisions.
2. Error budgets
   - Track success rate per method/provider; auto-deprioritize providers breaching SLOs.
3. Consistency sampling
   - Sample a small fraction of calls to a second provider to detect divergent responses and auto-deprioritize.

### E) Active health checks (Medium priority)

- Periodically issue cheap methods (e.g., `eth_chainId`, `eth_blockNumber`) per provider; update `avg_latency`, recover health after `recovery_threshold` successes.

---

## Detailed Implementation Plan (Step-by-step)

### 1) Real HTTP client and duration recording

- Files to modify:
  - `lib/livechain/rpc/ws_connection.ex`
    - `make_http_rpc_request/3`: send real HTTP requests using Finch (preferred) or HTTPoison; return parsed result/error.
    - For every call site that forwards HTTP (controller path), measure duration and call `ProviderPool.report_success/Failure`.
  - `lib/livechain_web/controllers/rpc_controller.ex`
    - Replace 0ms benchmarking in `record_rpc_success/3` and `record_rpc_failure/4` with real duration capture from forwarding layer (plumb duration through return tuple or use telemetry).
  - `lib/livechain/rpc/chain_supervisor.ex`
    - Ensure `forward_rpc_request/4` uses the updated `WSConnection.forward_rpc_request/3` and returns duration for benchmarking.

### 2) Wire `ProviderPool` updates and selection

- Files to modify:
  - `lib/livechain/rpc/provider_pool.ex`
    - Keep EMA latency update in `update_provider_success/3`; ensure error handling marks unhealthy after threshold.
  - Call sites to add:
    - When HTTP request completes: call `ProviderPool.report_success(chain, provider_id, latency_ms)`.
    - On error/timeout/429: call `ProviderPool.report_failure(chain, provider_id, reason)` and apply cooldown if needed.
  - Config: `config/chains.yml`
    - Ensure `global.provider_management.load_balancing` can be set to `latency_based` and behaves meaningfully after wiring updates.

### 3) Circuit breaker integration

- Files to modify:
  - `lib/livechain/rpc/chain_supervisor.ex` (or `ChainManager`): wrap calls with `CircuitBreaker.call(provider_id, fn -> WSConnection.forward_rpc_request(...) end)`.
  - Policy: configure thresholds via `config.exs`/`chains.yml` (failure_threshold, recovery_timeout, success_threshold) and add sensible defaults.

### 4) 429/backoff/cooldown

- Files to modify:
  - `lib/livechain/rpc/ws_connection.ex` and HTTP client wrapper: detect 429/5xx; return typed errors.
  - `lib/livechain/rpc/provider_pool.ex`: on rate-limit error, mark provider cooling with exponential backoff (store next-eligible timestamp); exclude from selection until elapsed.
  - Optionally store per-method rate-limit counters in `BenchmarkStore` for analytics.

### 5) “Cheapest” = public-first with fallback

- Files to modify:
  - `lib/livechain_web/controllers/rpc_controller.ex`: add `:cheapest` strategy to `parse_strategy/1` and `select_best_provider/3`.
  - `lib/livechain/rpc/chain_manager.ex` and/or `ProviderPool`: add helper to list providers by `type` and availability.
  - Config: use existing `type: "public" | "paid" | "dedicated"` in `chains.yml`.

### 6) Region awareness

- Files to modify:
  - `lib/livechain/config/chain_config.ex`: extend `Provider` with `region :: String.t()`; parse from YAML.
  - `config/chains.yml`: add `region:` to each provider entry.
  - Routing: in `rpc_controller`, read `X-Livechain-Region` header or `/:region/:chain` path; restrict candidates to matching region.
  - Docs: reflect “fastest within region” positioning.

### 7) Observability enhancements

- Files to modify:
  - `lib/livechain/benchmarking/benchmark_store.ex`: maintain rolling histograms or percentile approximations per method/provider; compute p50/p90/p99.
  - Dashboards: surface percentiles and SLOs (success rate) in existing LiveView pages.
  - Telemetry: emit events for request start/stop, errors, circuit breaker transitions.

### 8) Active health checks

- Files to modify:
  - `lib/livechain/rpc/provider_pool.ex`: schedule periodic probes per provider (e.g., `eth_blockNumber`); update EMA latency and success counters; trigger recovery after `recovery_threshold`.

---

## Proposed Configuration Additions

- `chains.yml` → per-provider:
  - `region: "us-east-1"` (string)
  - Optional: `cooldown_base_ms`, `cooldown_max_ms` (overrides)
- `config.exs` → circuit breaker defaults:
  - `failure_threshold`, `recovery_timeout_ms`, `success_threshold`
- Per-method policies (either in `chains.yml` or app config):
  - `timeouts`, `retries`, `strategy_overrides` (e.g., `eth_getLogs: always_paid`)

---

## Documentation and Product Positioning Updates

- Clarify “Fastest” → “Fastest within region.” Recommend multi-region deployment/edge routing for global latency.
- Emphasize reliability, cost control, and observability as core differentiators.
- Add guidance for public-first with paid fallback, quotas, and per-method policy examples.
- Document headers/paths for region selection and strategy selection (e.g., `/rpc/cheapest/:chain`, header-based overrides).

---

## Validation Plan (Post-Implementation)

- Unit tests for:
  - Circuit breaker state transitions and integration with forwarding.
  - ProviderPool latency EMA updates and selection logic for `latency_based`.
  - 429/cooldown logic with exponential backoff.
  - Region-filtered provider selection.
- Integration tests (scripts in `scripts/validation`):
  - Simulate rate limits and failures; verify failover and cooldown behavior.
  - Measure end-to-end latency distributions; ensure percentiles populate.
- Load tests: verify throughput and stability with multi-provider pools.
- Dashboard verification: percentiles, success rates, and provider states visible and accurate.

---

## Prioritized Roadmap (2–3 sprints)

- Sprint 1 (Reliability foundation)
  - Real HTTP client + duration plumbed end-to-end
  - ProviderPool `report_success/Failure` wiring
  - Circuit breaker integration
  - 429/backoff/cooldown
- Sprint 2 (Cost + region basics)
  - Public-first “cheapest” strategy
  - Per-method policies
  - Region field + header/path routing
  - Active health checks (basic)
- Sprint 3 (Observability + polish)
  - Percentiles, SLOs, consistency sampling
  - Dashboards updates and alerts
  - Docs/positioning refresh; examples and scripts

---

## Risks and Mitigations

- Risk: Provider heterogeneity (error formats, rate-limit semantics)
  - Mitigation: Normalize errors; maintain provider-specific adapters if needed.
- Risk: Added complexity in config/policies
  - Mitigation: Sensible defaults; minimal knobs for v1.
- Risk: Multi-region ops overhead
  - Mitigation: Start single-region; document path to multi-region when needed.

---

## Appendix: Direct Code Pointers

- Mocked HTTP forwarding: `lib/livechain/rpc/ws_connection.ex` (~382–404)
- Zero-duration benchmarking in HTTP controller: `lib/livechain_web/controllers/rpc_controller.ex` (~452–461)
- Latency-based selection (depends on `avg_latency`): `lib/livechain/rpc/provider_pool.ex` (~279–307)
- Provider success/failure API (not called): `lib/livechain/rpc/provider_pool.ex` (~96–107)
- Circuit breaker (unused): `lib/livechain/rpc/circuit_breaker.ex`
- Mocked WS JSON-RPC responses: `lib/livechain/rpc/ws_connection.ex` (~706–713)
- Provider config lacks region: `lib/livechain/config/chain_config.ex` (`defmodule Provider`) and `config/chains.yml`

This document is intended to be directly actionable by engineers (or an LLM agent) to implement the plan end-to-end. Keep changes scoped and iterative, verifying reliability and metrics at each step before enabling more advanced strategies.

---

### Refinement: MVP routing = latency ranking (not leaderboard)

- Deprecate `:leaderboard` for HTTP provider selection. Keep it only (optionally) for WS event streams where “first delivery wins” is meaningful.
- Introduce `:latency` strategy (make it the default for HTTP): select the provider with the lowest recent latency.
  - Minimal v1: use `ProviderPool`’s `avg_latency` once `report_success/Failure` is wired in.
  - Better v1.5: use `BenchmarkStore.get_rpc_method_performance(chain, method)` and pick the provider with lowest `avg_duration_ms`, guarded by `success_rate`.
- Guardrails:
  - Enforce a minimum success-rate threshold (e.g., 98%) before choosing a low-latency provider.
  - Exclude providers in circuit-open or cooldown states.
  - One failover attempt if latency budget/timeout exceeded.
- Implementation points:
  - `lib/livechain_web/controllers/rpc_controller.ex`: add `:latency` to `parse_strategy/1`, implement `select_best_provider/3` for `:latency`, and set `default_provider_strategy` to `:latency` for HTTP.
  - `lib/livechain/rpc/provider_pool.ex`: rely on `latency_based` selection as an option once `report_success/Failure` is called from the forwarding path.
  - Optional per-method overrides: allow methods to opt out of `:latency` (e.g., always use `:priority` for heavy/log-intensive calls).

### Benchmarking modules: intent vs. misapplication

- Intent is sound, but routing usage needs to be corrected:
  - Event racing (“speed to first event”) metrics in `BenchmarkStore` are appropriate for WS stream racing and deduplication.
  - RPC call metrics (avg duration and success rate) are the right signal for HTTP provider selection.
- Current misapplication:
  - HTTP routing via `:leaderboard` pulls event racing scores (`get_provider_leaderboard/1`) rather than `get_rpc_method_performance/2`.
  - Fix: use `:latency` strategy for HTTP and select by `avg_duration_ms` (with success-rate guard), not by event racing wins/margins.
- Future improvements:
  - Move from averages to percentiles (p50/p90/p99) and recent-window EMAs for responsiveness.
  - Apply method-aware weighting if some methods have systematically different provider characteristics.

---

### Addendum: Additional oversights from another codebase pass

- Router strategy paths are cosmetic right now

  - File: `lib/livechain_web/router.ex` lines ~53–56 define `/rpc/fastest/:chain_id` and `/rpc/cheapest/:chain_id`, but the controller does not read the path segment into a `strategy` param. The controller only checks `params["strategy"]` or query param `strategy`.
  - Fix options:
    - Prefer a single dynamic route: `post("/:strategy/:chain_id", RPCController, :rpc)` and rely on `parse_strategy/1`.
    - Or add a plug in this scope to set `conn.params["strategy"]` based on the matched static path (fastest/cheapest).

- Strategy parsing doesn’t include latency/cheapest/fastest aliases

  - File: `lib/livechain_web/controllers/rpc_controller.ex` `parse_strategy/1` (lines ~358–366) supports only `leaderboard | priority | round_robin`.
  - Fix: add `"latency" -> :latency`, `"cheapest" -> :cheapest`, and optionally `"fastest" -> :latency` as an alias to match the new MVP framing.
  - Also update `default_provider_strategy/0` to `:latency` for HTTP (per the refinement section).

- Leaderboard return shape mismatch (bug)

  - File: `lib/livechain/benchmarking/benchmark_store.ex` `get_provider_leaderboard/1` returns a list (see `handle_call` around ~214–223), not `{:ok, list}`.
  - File: `lib/livechain_web/controllers/rpc_controller.ex` `select_best_provider/3` (lines ~376–387) expects `{:ok, leaderboard}`.
  - Same pattern exists in `lib/livechain_web/channels/rpc_channel.ex`.
  - Fix: either change `BenchmarkStore.get_provider_leaderboard/1` to return `{:ok, list}` consistently, or update both callers to handle a bare list and empty list appropriately.

- Mock function/name mismatches and state field misuse (bugs)

  - File: `lib/livechain/rpc/ws_connection.ex`
    - `send_json_rpc_request/2` references `state.websocket_pid`, but state uses `connection`/`connected` elsewhere. This likely always branches to error or wrong path.
    - There is a `mock_json_rpc_response(request)` call (around ~709) but later a function appears as `defp mock_ssjson_rpc_response(...)` (typo/mismatch). This will crash when called.
  - Fix: unify state keys (use `connection` consistently) and fix the mock function name if keeping mocks temporarily. Replace mocks with a real HTTP client as recommended.

- `cheapest` strategy not implemented

  - No references beyond router and comments. Implement as “public-first with paid fallback” (see Recommendations section) and wire into `parse_strategy/1` and `select_best_provider/3`.

- Latency-based selection partially present but not wired
  - `ProviderPool` supports a `"latency_based"` option but requires `report_success/Failure` to be called from forwarding paths; add those calls when replacing mock HTTP.

These changes are small, high-impact correctness fixes that align the code with the MVP routing and benchmarking guidance above.
