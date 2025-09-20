## Future Features and Enhancements

A living backlog of high-impact improvements to make Livechain reliable, fast, and compelling. Items are grouped by domain and designed to be incremental.

### Dashboard + UI:

- Add provider configuration UI: Add chains and proivders directly through the interface, with API keys and secrets too

### Provider selection strategies

- **Strategy registry + behaviour**: pluggable strategies with a clear behaviour (`pick/3`) and typed options.
- **Method-specific overrides**: per-method strategy and protocol requirements (e.g., `eth_getBlockByNumber -> :race_top2`, protocol `:http`).
- **Built-in strategies**:
  - `:leaderboard` (default) based on ProviderPool health/latency
  - `:priority` config-based fallback
  - `:round_robin` for traffic spreading
  - `:best_sync` prefer providers with most up-to-date head/safe/finalized; thresholdable lag
  - `:race_top_n` (hedged requests) with early-cancel on first success
  - `:cost_aware` (optimize $ given SLO)
  - `:quota_aware` (avoid hitting provider limits)
  - `:sticky_session` (affinity by client/session)
- **Constraints**: protocol filter, exclusion lists, region affinity, timeout budgets.

### Protocol routing

- **Current state**:
  - ✅ HTTP upstream for reads with robust failover, circuit breakers, and 429 handling
  - ✅ WebSocket upstream for subscriptions (eth_subscribe, eth_unsubscribe)
  - ❌ WebSocket RPC calls (eth_getBalance, eth_blockNumber, etc.) lack failover logic
- **Default**: read-only calls over HTTP upstream; subscriptions over WS upstream.
- **WebSocket read support** (OUT OF SCOPE FOR HACKATHON SUBMISSION):
  - `WSRequestClient` with request-id correlation and timeout management
  - **Critical gap**: WebSocket RPC calls need same failover logic as HTTP (`try_failover_with_reporting/7`)
  - **Current issue**: WS RPC calls fail immediately on 429 instead of transparent failover
  - **Solution**: Extract failover logic to shared module or replicate in `RPCChannel`
  - **Note**: WebSocket/HTTP parity implementation deferred to post-hackathon development
- **Per-method protocol policy**: override table in config for fine control.
- **Provider capability flags**: `supports_ws_reads: true/false` per provider
- **Automatic fallback**: WS fails → HTTP fallback for critical methods

### Latency and performance

- **Hedged requests**: race top N providers for hot methods; cancel on first success.
- **MessageAggregator**: early-cancel, dedupe, and metrics for observed p50/p95.
- **Connection pooling**: tune Finch pools per host/region; keep-alive and HTTP/2 where supported.
- **Result caching**: short TTL cache for hot reads (e.g., `eth_blockNumber`, 250–500ms) with instrumentation.
- **Coalescing**: collapse identical concurrent requests while in-flight.
- **MethodPolicy timeouts**: per-method budgets; selection uses budgets as constraints.

### Resilience and fault tolerance

- **Current HTTP strengths** (✅ implemented):
  - **429 rate limit handling**: Automatic detection, exponential backoff (1s → 5min max), provider exclusion
  - **Seamless failover**: `execute_rpc_with_failover/6` + `try_failover_with_reporting/7`
  - **Circuit breaker integration**: Per-provider failure tracking and automatic recovery
  - **Provider cooldown**: Rate-limited providers automatically excluded until cooldown expires
  - **Zero user impact**: Original request succeeds transparently via next best provider
- **WebSocket resilience gaps** (❌ OUT OF SCOPE FOR HACKATHON):
  - **Missing failover logic**: WS RPC calls fail immediately instead of transparent retry
  - **No request correlation**: Need `WSRequestManager` for request/response pairing
  - **Inconsistent error handling**: WS errors not mapped to same taxonomy as HTTP
  - **Circuit breaker gaps**: WS failures not properly integrated with breaker state
  - **Note**: WebSocket parity features deferred to post-hackathon roadmap
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
- **Triage Note (Incomplete Feature)**: The core application code (`RPCController`, `Failover`, `ProviderPool`) contains logic to filter providers by a `region` specified in an `x-livechain-region` header. However, the provider configuration schema does not currently include a `region` field. This makes the feature implemented but not usable, and it doesn't make sense to explicitly define what regions providers are in (this can be revealed via latency and passive benchmarking)
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
- **Failover testing**: 429 injection, provider cooldown validation, WS vs HTTP parity

### Productization

- **Cost-awareness**: track provider cost per call; optimize selection for $ while meeting SLOs.
- **Billing/reporting**: per-tenant usage, p95 latency, error budgets, and spend estimates.
- **SLOs**: publish target p50/p95; alerting on burn rate.

### Roadmap (suggested phases)

- **P0 (Core)**: strategy registry, per-method overrides, telemetry events, MethodPolicy timeouts
- **P1 (Performance)**: hedged requests, cache/coalescing, provider scoreboards + dashboards (WebSocket read support moved to P2)
- **P2 (Resilience/Scale)**: WebSocket read support with failover parity, adaptive rate limiting, staged rollout, geo-aware selection
- **P3 (Product)**: cost-aware routing, multi-tenant quotas, billing/usage reporting

### Implementation Notes

#### WebSocket Read Support Architecture

When implementing WebSocket reads, ensure parity with HTTP failover:

```elixir
# Current HTTP path (rpc_controller.ex:402-431)
case ChainSupervisor.forward_rpc_request(chain, provider_id, method, params) do
  {:ok, result} -> {:ok, result}
  {:error, reason} ->
    # ✅ Has robust failover
    try_failover_with_reporting(chain, method, params, strategy, [provider_id], 1, region_filter)
end

# Current WebSocket path (rpc_channel.ex:211-213)
defp forward_via_http(chain, provider_id, method, params) do
  # ❌ Missing failover logic
  ChainSupervisor.forward_rpc_request(chain, provider_id, method, params)
end
```

**Required changes**:

1. Extract `try_failover_with_reporting/7` to shared module
2. Add `ChainSupervisor.forward_ws_rpc_request/4`
3. Implement `WSRequestManager` for request correlation
4. Map WS errors to same taxonomy (rate_limit, server_error, etc.)
5. Integrate with circuit breakers and `BenchmarkStore.record_rpc_call/5`

#### Provider Protocol Support Matrix

Track provider capabilities to enable intelligent protocol selection:

```elixir
# config/chains.yml
providers:
  infura:
    supports_ws_reads: true
    ws_method_whitelist: ["eth_blockNumber", "eth_chainId", "eth_gasPrice"]
  alchemy:
    supports_ws_reads: false  # HTTP only for reads
  quicknode:
    supports_ws_reads: true
    ws_method_whitelist: "*"  # All methods
```

This ensures WebSocket reads are only attempted when providers support them, with automatic HTTP fallback for unsupported methods or providers.

#### "Best Sync" Routing Strategy

Goal: Prefer providers that are most up-to-date with chain head to minimize stale reads and inconsistencies. Applies to time-sensitive reads (e.g., `eth_blockNumber`, latest state queries) and can be relaxed for historical queries.

- Signals to track per provider (passive + active):

  - Latest observed `block_number` from normal traffic and/or periodic `eth_blockNumber` probe
  - `eth_syncing` status and current block vs highest block
  - Optional: Ethereum `safe` and `finalized` heads via `eth_getBlockByNumber("safe"|"finalized")`
  - Last-updated timestamp to avoid using stale measurements

- Global head estimation per chain:

  - Maintain a lightweight `HeadTracker` that periodically samples a subset of providers with jitter (e.g., every 1–2s under load, 3–5s idle)
  - Compute `global_best_head` as a k-of-n majority or trimmed max to avoid outliers
  - Track `global_safe_head` and `global_finalized_head` when supported

- Selection/scoring (simplified precedence):

  1. Filter to providers with `head_lag <= max_lag_blocks` relative to chosen reference (latest|safe|finalized)
  2. Within the filtered set, sort by health score → latency → recent success rate
  3. If fewer than `min_viable` remain, widen `max_lag_blocks` gradually or fall back to `:leaderboard`

  Pseudocode:

  ```elixir
  def pick_best_sync(candidates, opts) do
    reference = opts[:reference] || :latest # :latest | :safe | :finalized
    max_lag  = opts[:max_lag_blocks] || 1
    min_ok   = opts[:min_viable] || 2

    fresh = Enum.filter(candidates, fn p -> lag(p, reference) <= max_lag end)
    ranked = fresh |> sort_by([:health_desc, :latency_asc, :success_rate_desc])

    cond do
      length(ranked) >= min_ok -> ranked
      true -> fallback(:leaderboard, candidates)
    end
  end
  ```

- Config (chains.yml):

  ```yaml
  selection:
    default_strategy: :best_sync
    method_overrides:
      eth_getBlockByNumber:
        { strategy: :best_sync, reference: latest, max_lag_blocks: 0 }
      eth_getBalance:
        { strategy: :best_sync, reference: safe, max_lag_blocks: 1 }
    strategies:
      best_sync:
        reference: latest # latest | safe | finalized
        max_lag_blocks: 1 # initial filter threshold
        min_viable: 2 # minimum candidates to keep
        fallback_strategy: :leaderboard
  ```

- Telemetry:

  - Emit `[:livechain, :selection, :best_sync]` with `provider_id`, `head`, `lag_blocks`, `reference`, `max_lag`, `reason`
  - Track `global_best_head`, `global_safe_head`, `global_finalized_head` gauges

- Failure modes and safeguards:
  - Cold start: use fallback until enough head samples collected
  - Outliers/malicious: require k-of-n concordance on heads; trim extreme values
  - Oscillation: apply small hysteresis (e.g., require sustained freshness for N samples before promoting)
  - Sparse traffic: rely on periodic probes with jittered schedule

### Block Height Awareness and Reorg Awareness

Pretty much just need to figure out how to deal with the challenges around block height syncing, reorg impacts, and related complexities. That has mostly been handwaved thus far, but here's the challenge outlined:

Consistency challenges emerge from temporal differences between providers. Different blockchain sync states, block height variations, and chain reorganization handling create scenarios where identical queries return different results. arXiv +2 Mitigation strategies include block height awareness (routing queries to providers within acceptable lag thresholds) and quorum-based validation for critical queries.

### Per-method Provider Priority configuration

Some providers excel in specific methods, and some providers can handle signficaintly greater throughput for specific methods. It would be nice to specify 'favored' method or 'prioritized' methods on a per-provider basis. For example: If Alchemy is way cheaper or faster for a particular archival query, a user could config historical 'get logs' queries to prefer that provider. Still need to be smart about this design and this of the best api to declare such preferences.

This may also include flags for providers that should be preferred to eth_subscribe streams (some providers may perform better with long running ws feeds, but we don't have explicit benchmarking for those yet)

### Improved routing/selection strategies for eth_subscribe feeds

Benchmarking is implemented for HTTP methods but there's not a good performance/reliability equivalent to make routing decisions for multiplexed upstream proivder websocket feeds. CUrrent these are picked based on manually configured 'priority', but there is likely a smarter way to go about this to ensure best websocket stream performance. (Multiplexing is an important considerations here, and it may be important to balance out/fan out websocket connections to multiple providers if any single provider get too much eth_subscribe load - i.e. there could be many clients subscirbe to many different logs feed filters that might need some degree of load balancing). THis is fairly complex and will require some careful consideration and design.
