## Future Features and Enhancements

A living backlog of high-impact improvements to make Livechain reliable, fast, and compelling. Items are grouped by domain and designed to be incremental.

### Provider selection strategies

- **Strategy registry + behaviour**: pluggable strategies with a clear behaviour (`pick/3`) and typed options.
- **Method-specific overrides**: per-method strategy and protocol requirements (e.g., `eth_getBlockByNumber -> :race_top2`, protocol `:http`).
- **Built-in strategies**:
  - `:leaderboard` (default) based on ProviderPool health/latency
  - `:priority` config-based fallback
  - `:round_robin` for traffic spreading
  - `:race_top_n` (hedged requests) with early-cancel on first success
  - `:cost_aware` (optimize $ given SLO)
  - `:quota_aware` (avoid hitting provider limits)
  - `:sticky_session` (affinity by client/session)
- **Constraints**: protocol filter, exclusion lists, region affinity, timeout budgets.

### Protocol routing

- **Default**: read-only calls over HTTP upstream; subscriptions over WS upstream.
- **Optional WS upstream for reads**: `WSRequestClient` with request-id correlation and timeout; used selectively per method.
- **Per-method protocol policy**: override table in config for fine control.

### Latency and performance

- **Hedged requests**: race top N providers for hot methods; cancel on first success.
- **MessageAggregator**: early-cancel, dedupe, and metrics for observed p50/p95.
- **Connection pooling**: tune Finch pools per host/region; keep-alive and HTTP/2 where supported.
- **Result caching**: short TTL cache for hot reads (e.g., `eth_blockNumber`, 250–500ms) with instrumentation.
- **Coalescing**: collapse identical concurrent requests while in-flight.
- **MethodPolicy timeouts**: per-method budgets; selection uses budgets as constraints.

### Resilience and fault tolerance

- **Circuit breaker tuning**: per-provider thresholds; breaker state in telemetry; partial brownout handling.
- **Adaptive retry/backoff**: selective retries on retryable errors; jittered backoff; method-aware retry limits.
- **Rate-limit adaptation**: detect provider 429s; dynamically reduce traffic; use alternative providers.
- **Auto-disable/rehabilitate**: remove severely degraded providers; probation upon recovery.

### Observability and telemetry

- **Unified events**: `[:livechain, :rpc, :request]` start/stop/error with chain, provider_id, method, protocol, duration_ms, breaker_state.
- **Selection events**: success/failure with strategy, reason, candidate set.
- **Dashboards**: per-provider latency, error rates, selection outcomes, breaker states, cache hit rate.
- **Tracing**: OpenTelemetry spans across selection -> upstream -> response.

### Config and lifecycle

- **Live reload**: atomic config reloads via `ConfigStore.reload/1` with validation.
- **Staged rollout**: canary percentage for new providers; progressive traffic shifting.
- **Versioned config**: schema versioning + migration helpers; CI validation.
- **Admin tooling**: CLI or dashboard for enabling/disabling providers and changing weights at runtime.

### Regional and multi-region routing

- **Geo-aware selection**: client region detection and region-tagged providers; prefer lowest RTT.
- **Failover across regions**: bounded-latency cross-region fallback.
- See also: [REGIONAL_LATENCY_ROUTING_DESIGN_CONSIDERATIONS.md](REGIONAL_LATENCY_ROUTING_DESIGN_CONSIDERATIONS.md)

### Security and multi-tenant controls

- **API keys & auth**: tenant identity; per-tenant policies.
- **Quotas and rate limits**: global and tenant-scoped.
- **Abuse detection**: anomaly detection, IP reputation, WAF integration.

### API compatibility and semantics

- **JSON-RPC normalization**: consistent error taxonomy; provider-specific quirks masked.
- **Client compatibility**: Viem/Ethers-first testing; recorded fixtures for tricky methods.
- **Batching**: support JSON-RPC batch calls with per-item fallback and partial errors.

### Testing and TRDs

- **Strategy matrix tests**: property-based tests across strategies, protocols, and exclusions.
- **Latency injection**: simulate p95/p99 to validate hedged requests and failover.
- **Chaos tests**: breaker opening/closing, provider disappear/return.
- **Contract tests**: provider-specific JSON-RPC diffs; normalization tests.
- **Benchmarks**: per-method latency, throughput under load, and aggregator overhead.

### Productization

- **Cost-awareness**: track provider cost per call; optimize selection for $ while meeting SLOs.
- **Billing/reporting**: per-tenant usage, p95 latency, error budgets, and spend estimates.
- **SLOs**: publish target p50/p95; alerting on burn rate.

### Roadmap (suggested phases)

- **P0 (Core)**: strategy registry, per-method overrides, telemetry events, MethodPolicy timeouts
- **P1 (Performance)**: hedged requests, cache/coalescing, provider scoreboards + dashboards
- **P2 (Resilience/Scale)**: adaptive rate limiting, staged rollout, geo-aware selection
- **P3 (Product)**: cost-aware routing, multi-tenant quotas, billing/usage reporting
