# Lasso RPC: Feature Backlog & Roadmap

Living backlog of high-impact improvements. Active features are prioritized at top; completed features tracked at bottom as development log.

---

## Triage + Backlog

**State Consistency Monitoring**

Periodic consensus checks by racing requests to 2-3 upstream providers to detect state divergence:
- Client can wait for first response or require 2/3 consensus
- Returns error if consensus fails
- Collects valuable provider health feedback with minimal overhead
- Useful for critical state and gossip queries

**Provider Health Gossiping**

Use BEAM clustering to communicate node-to-node about provider health:
- Nodes share provider health observations across the cluster
- Enables cluster-level circuit breaker coordination
- Reduces time to detect and isolate unhealthy providers

**Transport Channel Improvements**

- Use lazy creation for transport channels
- Create and validate channels at startup
- Fix warning when WS URL not configured but WS channel creation attempted

## Active Roadmap

### Performance Optimizations

**Hedged Requests (Race Top N)**

- Race top N providers for hot methods; cancel on first success
- Configurable per-method hedging policies
- Metrics for hedge success rate and latency improvements
- Early-cancel mechanism to avoid wasted upstream calls

**Result Caching**

- Short TTL cache for hot reads (e.g., `eth_blockNumber`, 250–500ms)
- Cache key normalization for deduplication
- Instrumentation for cache hit rate per method
- Configurable TTLs and cache size limits per chain

**Request Coalescing**

- Collapse identical concurrent requests while in-flight
- Single upstream call for multiple clients requesting same data
- Response fan-out to all waiting clients

**Connection Pool Tuning**

- Fine-tune Finch pools per host/region
- HTTP/2 where supported, keep-alive optimization
- Per-provider connection limits based on rate limits

### Advanced Routing Strategies

**Best Sync Strategy**

- Prefer providers with most up-to-date head/safe/finalized blocks
- Minimize stale reads and chain inconsistencies
- `HeadTracker` for periodic block height sampling
- Configurable `max_lag_blocks` threshold per method
- Fallback to `:fastest` when insufficient synced providers
- See implementation notes below for detailed design

**Per-Method Strategy Overrides**

- Configure routing strategy per JSON-RPC method
- Example: `eth_getBlockByNumber` → `:best_sync`, `eth_gasPrice` → `:fastest`
- Protocol requirements per method (`:http` only, `:ws` preferred, etc.)
- Timeout budgets per method via MethodPolicy

**Cost-Aware Routing**

- Track provider cost per call ($ per request)
- Optimize selection for cost while meeting SLO constraints
- Configurable cost weights vs latency weights

**Quota-Aware Routing**

- Track provider rate limits and quota consumption
- Dynamically reduce traffic to providers approaching limits
- Proactive load balancing before hitting 429s

**Sticky Session Routing**

- Client/session affinity for stateful workflows
- Consistent provider selection for same client over time window

### Per-Method Provider Priorities

Some providers excel at specific methods or handle significantly greater throughput for certain calls.

**Config Example:**

```yaml
providers:
  - id: "alchemy_eth"
    preferred_methods: ["eth_getLogs", "eth_call"] # Archival queries
    priority_multiplier: 1.5 # Boost selection weight for these methods
  - id: "quicknode_eth"
    preferred_subscriptions: ["newHeads", "logs"] # Better WS stability
```

**Benefits:**

- Route archival queries to providers optimized for historical data
- Balance subscription load across providers with proven WS reliability
- Allow manual tuning when passive benchmarking insufficient

### WebSocket Stream Routing

**Challenge:** Benchmarking exists for HTTP methods but not for long-lived WS subscription feeds.

**Current State:** Subscriptions picked via manually configured `priority`

**Improvements Needed:**

- Track WS feed quality metrics: event delivery rate, gap frequency, connection stability
- Load balancing when single provider has too many multiplexed subscriptions
- Automatic failover based on stream health, not just connection failures
- Per-subscription-type performance tracking (newHeads vs logs)

### Resilience Enhancements

**Enhanced Retry/Backoff**

- **Jittered backoff** - Add randomization to exponential backoff (prevent thundering herd)
- **Selective retries** - Only retry retriable errors (don't retry invalid params, auth failures)
- **Method-aware limits** - Per-method retry configuration (don't retry expensive archival queries)
- Note: Basic exponential backoff (1s → 5min) for 429s already implemented

**Auto-Disable/Rehabilitate**

- Remove severely degraded providers from rotation automatically
- Probationary period upon recovery with limited traffic
- Gradual traffic ramp-up when provider health improves

**Circuit Breaker Tuning**

- Per-provider thresholds based on provider tier (premium vs public)
- Breaker state included in telemetry and dashboard
- Partial brownout handling (allow some traffic through open breaker for probing)

### Regional & Geo-Aware Routing

**Current State:** Header-based region filtering implemented but provider config lacks `region` field

**Design Decision:** Don't explicitly tag providers with regions; infer from latency benchmarking

**Roadmap:**

- Passive latency measurement reveals effective "regions" per provider
- Client region detection (header, IP geolocation, or config)
- Prefer providers with lowest RTT for client's region
- Cross-region failover with bounded latency budget

### Configuration & Operations

**Live Config Reload**

- Atomic config reloads via `ConfigStore.reload/1` with validation
- Zero-downtime provider additions/removals
- Config version tracking and rollback support

**Staged Rollout**

- Canary percentage for new providers (5% → 25% → 100%)
- Progressive traffic shifting with automatic rollback on errors
- A/B testing for new routing strategies

**Admin Tooling**

- Dashboard UI for enabling/disabling providers at runtime
- Provider weight adjustments without config file edits
- Real-time circuit breaker control (force open/close)

### Observability Enhancements

**OpenTelemetry Integration**

- Distributed tracing spans: selection → upstream → response
- Context propagation across service boundaries
- Integration with standard observability stacks (Datadog, New Relic, Honeycomb)

**Enhanced Dashboards**

- Cache hit rate visualization per method
- Hedged request success rate and latency improvements
- Regional latency heatmaps
- Provider cost analytics ($ per request, $ per method)

### Multi-Tenant & Productization

**API Keys & Auth**

- Tenant identity via API keys
- Per-tenant routing policies and provider access controls
- Usage attribution per tenant

**Quotas & Rate Limits**

- Global and tenant-scoped request quotas
- Rate limiting per API key
- Soft limits with overage billing vs hard cutoffs

**Billing & Reporting**

- Per-tenant usage breakdowns (requests, methods, latency percentiles)
- Provider cost tracking and spend estimates
- SLO compliance reporting (P95 latency, error budget burn rate)

**Abuse Detection**

- Anomaly detection for unusual traffic patterns
- IP reputation checks and blocklists
- WAF integration for DDoS protection

### API Compatibility

**JSON-RPC Batching**

- Support batch requests with per-item routing
- Partial error handling (some requests succeed, some fail)
- Per-item failover and retry logic

**JSON-RPC Normalization**

- Consistent error taxonomy across providers
- Provider-specific quirks masked from clients
- Error code mapping to standard JSON-RPC error codes

**Client Library Testing**

- Viem/Wagmi/Ethers compatibility testing
- Recorded fixtures for tricky methods
- Provider-specific JSON-RPC diff tests

### Block Height & Reorg Awareness

**Challenge:** Temporal differences between providers create consistency issues

**Symptoms:**

- Block height variations (provider A at block N, provider B at N-2)
- Chain reorg handling differences
- Identical queries returning different results

**Mitigation Strategies:**

- Block height awareness (route to providers within acceptable lag)
- Quorum-based validation for critical queries
- Reorg detection and automatic retry with consistent provider set
- See "Best Sync Strategy" above for implementation approach

### Dashboard UI Enhancements

**Provider Configuration UI**

- Add chains and providers directly through dashboard
- API key management with secure storage
- Provider health visualization and manual override controls

---

## Priority Phases

**P0 (Core Routing)** - Q1 2026 (In Progress)

- Per-method strategy overrides
- Best sync routing strategy
- MethodPolicy timeout configuration
- Per-method provider priorities

**P1 (Performance)** - Q2 2026 (Apr-Jun)

- Hedged requests (race top N)
- Result caching with instrumentation
- Request coalescing
- Enhanced telemetry and OpenTelemetry integration

**P2 (Resilience & Scale)** - Q3 2026 (Jul-Sep)

- Adaptive retry/backoff
- Regional/geo-aware routing
- Live config reload
- Staged provider rollouts

**P3 (Product & Multi-Tenancy)** - Q4 2026 (Oct-Dec)

- Cost-aware routing
- Multi-tenant quotas and auth
- Billing and usage reporting
- Admin tooling and provider UI

---

## Implementation Notes

### Best Sync Strategy Design

**Goal:** Minimize stale reads by routing to most up-to-date providers

**Signals to Track (per provider):**

- Latest observed `block_number` from passive traffic
- Periodic `eth_blockNumber` probes (every 1-2s under load, 3-5s idle)
- `eth_syncing` status (current block vs highest block)
- Optional: `safe` and `finalized` heads via `eth_getBlockByNumber`
- Timestamp of last update (avoid stale measurements)

**Global Head Tracking:**

- `HeadTracker` GenServer samples subset of providers with jitter
- Compute `global_best_head` via k-of-n majority (avoid outliers)
- Track `global_safe_head` and `global_finalized_head` when supported

**Selection Algorithm:**

```elixir
def pick_best_sync(candidates, opts) do
  reference = opts[:reference] || :latest # :latest | :safe | :finalized
  max_lag  = opts[:max_lag_blocks] || 1
  min_ok   = opts[:min_viable] || 2

  # Filter providers within acceptable lag
  fresh = Enum.filter(candidates, fn p ->
    lag(p, reference) <= max_lag
  end)

  # Sort by health → latency → success rate
  ranked = fresh |> sort_by([
    :health_desc,
    :latency_asc,
    :success_rate_desc
  ])

  # Fallback if insufficient synced providers
  if length(ranked) >= min_ok do
    ranked
  else
    fallback(:fastest, candidates)
  end
end
```

**Configuration:**

```yaml
selection:
  default_strategy: :best_sync
  method_overrides:
    eth_getBlockByNumber:
      strategy: :best_sync
      reference: latest
      max_lag_blocks: 0 # Require perfect sync
    eth_getBalance:
      strategy: :best_sync
      reference: safe
      max_lag_blocks: 1 # Allow 1 block lag
  strategies:
    best_sync:
      reference: latest
      max_lag_blocks: 1
      min_viable: 2
      fallback_strategy: :fastest
```

**Telemetry:**

- Emit `[:lasso, :selection, :best_sync]` with provider_id, head, lag_blocks, reference
- Track global head gauges: `global_best_head`, `global_safe_head`, `global_finalized_head`

**Safeguards:**

- Cold start: use fallback until enough samples collected
- Outlier detection: require k-of-n concordance on heads
- Oscillation prevention: hysteresis for N samples before promoting provider
- Sparse traffic: rely on periodic probes with jittered schedule

---

## Completed Features

Development log of implemented features, moved from active roadmap.

### ✅ Transport-Agnostic Architecture (Oct 2025)

- Unified request pipeline routing across HTTP and WebSocket
- `Transport` behaviour with HTTP and WebSocket implementations
- `Channel` abstraction for realized connections
- `TransportRegistry` for channel discovery
- Per-provider, per-transport circuit breakers
- Method-specific benchmarking across both transports
- Automatic failover across transports (HTTP → WS or WS → HTTP)

### ✅ WebSocket Subscription Management (Sept 2025)

- Intelligent multiplexing via `UpstreamSubscriptionPool`
- Automatic failover with gap-filling during provider switches
- `StreamCoordinator` per subscription key for continuity management
- HTTP backfilling via `GapFiller` for missed events
- `ClientSubscriptionRegistry` for efficient fan-out
- Deduplication and ordering via `StreamState`
- Reduced upstream connections by orders of magnitude

### ✅ Circuit Breaker System (Sept 2025)

- Per-provider circuit breakers with open/half-open/closed states
- Configurable failure thresholds and recovery timeouts
- Integration with provider selection (exclude open breakers)
- Automatic recovery probing in half-open state
- Telemetry events for breaker state transitions

### ✅ HTTP Failover & Rate Limit Handling (Sept 2025)

- Automatic 429 detection with exponential backoff (1s → 5min max, `base * 2^failures`)
- Provider exclusion during cooldown period via `HealthPolicy`
- Seamless failover via `execute_rpc_with_failover/6`
- Zero client impact (original request succeeds via alternate provider)
- Per-provider cooldown tracking with telemetry events
- Note: Jittered backoff and selective retry logic still pending

### ✅ Method-Specific Benchmarking (Aug 2025)

- Passive latency measurement per chain, provider, method, transport
- ETS-based metrics storage with 24-hour retention
- Provider leaderboards based on real RPC performance
- Automatic cleanup and snapshot persistence
- Feeds `:fastest` routing strategy

### ✅ Four Routing Strategies (Aug 2025)

- `:fastest` - Performance-based via benchmarking
- `:cheapest` - Cost-optimized (public providers first)
- `:priority` - Static config-based ordering
- `:round_robin` - Load balancing across healthy providers
- Strategy selection per endpoint: `/rpc/fastest/:chain`, etc.

### ✅ Request Observability (Sept 2025)

- `RequestContext` struct threading through execution pipeline
- Structured JSON logs: `rpc.request.completed` events
- Client-visible metadata (opt-in via headers or body)
- Privacy-first: params digests, error truncation, size limits
- Configurable sampling for high-volume scenarios
- See [OBSERVABILITY.md](OBSERVABILITY.md) for details

### ✅ Battle Testing Framework (Sept 2025)

- Fluent scenario DSL for complex test orchestration
- HTTP workload generation with configurable concurrency
- Chaos engineering: kill, flap, degrade providers
- Telemetry collection and percentile analysis (P50, P95, P99)
- SLO verification and automated reporting

### ✅ Live Dashboard (Aug 2025)

- Real-time provider leaderboards with Phoenix LiveView
- Performance matrix: latency by provider and method
- Circuit breaker status visualization
- Chain selection UI
- System simulator for load testing
- WebSocket push updates for live metrics

### ✅ Telemetry Events (Aug 2025)

- `[:lasso, :rpc, :request]` start/stop/error events
- Per-request metadata: chain, provider, method, protocol, duration, breaker state
- Integration with standard Elixir telemetry ecosystem
- Dashboard data sourced from telemetry streams

---

**Last Updated:** January 6, 2026
