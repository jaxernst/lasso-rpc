# Routing

Provider selection in Lasso operates as a 4-stage pipeline that transforms a pool of candidate providers into an ordered execution plan. Strategy ranking consumes published recent routing evidence, while live admission remains authoritative.

Numeric historical-request age is measured against a fresh concrete head from
the requested file profile, not another profile's upstreams. A qualified or
single-upstream uncorroborated snapshot can provide that height; ambiguous or
missing evidence cannot establish age. Block-hash selectors still require a
declared archival provider because their age is unknown before dispatch.

## Pipeline Overview

```
Candidate Pool → Strategy Ranking → Health Tiering → Execution
```

1. **Candidate Pool**: All providers configured in the profile that support the requested chain and method
2. **Strategy Ranking**: Strategy-specific ordering (latency, weighted random, priority, etc.)
3. **Health Tiering**: Circuit breaker and rate limit state reordering into 4 tiers
4. **Execution**: Sequential attempts with failover

The pipeline ensures that healthy providers receive preference while recovering providers are gradually reintroduced. Open-circuit providers are excluded entirely.

## Routing Strategies

Strategies control the initial ordering of providers. Select via URL path segment: `/rpc/:strategy/:chain`.

### Load Balanced (Default)

**URL**: `/rpc/load-balanced/:chain`
**Module**: `Lasso.RPC.Strategies.LoadBalanced`

Starts from a randomized candidate order. For replay-safe unary reads, fallback
tries distinct physical provider instances before sibling transports within each
availability tier. Alternate transports remain available; a healthy alternate
still precedes a different provider in a lower availability tier. The lazy cursor
bounds healthy-sibling deferral by its remaining candidate limit, and explicit
recovered-head preference takes precedence over diversity.

Unsafe or unknown methods retain their shuffled order and existing replay limits.
This ordering does not increase the three-dispatch budget or deadline, infer
archive capabilities, or guarantee successful historical reads. A hash selector
can leave more distinct providers eligible than the budget can cover. Trying
another provider first can also delay a working alternate transport on the
previous provider.

The strategy provides statistical distribution over time, not exact shares,
capacity awareness, or cluster-global balancing.

### Fastest

**URL**: `/rpc/fastest/:chain`
**Module**: `Lasso.RPC.Strategies.Fastest`

Orders reliability-qualified upstream instances by recent mean successful-attempt latency. Evidence is local to the routing node and keyed by a bounded registered workload key rather than arbitrary RPC method strings.

Client and system attempts use separate fixed method families: basic, state, logs, trace, transaction, and subscription. Unknown methods share one fallback partition. A successful `eth_blockNumber` read can qualify the basic family but does not qualify `eth_getBalance` or `eth_getLogs`; system observations can seed cold-start ordering in their family but cannot qualify client traffic. Exploration remains disabled unless an operator explicitly enables its bounded policy below.

**Use When**:
- Latency is the primary concern
- You're willing to concentrate load on the fastest provider
- The method being called is latency-sensitive (e.g., `eth_getBlockByNumber`)

**Behavior**:
- Ranks qualified upstreams by recent successful mean latency (lowest first)
- Uses successful p95 and deterministic identity to break equal-mean ties
- Never uses lifetime averages for routing
- Preserves all live candidates and emits an availability degradation when none qualifies
- Still subject to health tiering (closed-circuit providers preferred)

### Balanced Fast

**URL**: `/rpc/balanced-fast/:chain` (`latency-weighted` is an alias)
**Module**: `Lasso.RPC.Strategies.BalancedFast`

Produces a weighted random permutation of reliability-qualified upstreams using recent successful-attempt latency. It sits between load-balanced and fastest: load stays spread while the quickest providers receive more of it.

**Use When**:
- You want a balance between performance and distribution
- Avoiding single-provider concentration is important
- You have providers with significantly different performance profiles

**Behavior**:
- Calculates dimensionless relative weights:
  ```
  weight = (best_mean / candidate_mean)^beta
  ```
- Generates the permutation with exponential-race keys: `-log(U) / weight`
- Applies reliability as a qualification boundary, not a weight multiplier
- Uses no latency floor, weight floor, or implicit exploration share
- When no candidate qualifies, emits an availability degradation and orders routes with recent latency measurements before shuffled unmeasured routes; a wholly unmeasured pool is shuffled uniformly.

**Configuration**:
- `BALANCED_FAST_BETA`: Latency exponent (default: 3.0, higher = more aggressive preference for low latency)

### Bounded read exploration

Exploration is disabled by default. When enabled, an eligible `fastest` or
`balanced-fast` client read may sample a different configured upstream that
lacks qualified client evidence for the same method family. The ordinary first
choice must already be qualified and eligible. System observations cannot
qualify either route, and explicit capability and parameter restrictions still
apply. Exploration learns routing latency evidence; it does not infer provider
method support or change a file profile.

Only known replay-safe unary reads can explore. Priority, load-balanced,
provider overrides, system requests, writes, subscriptions and unknown methods
retain ordinary routing. A request selects at most one exploratory attempt,
which counts against Core's three-dispatch limit. At least 500 ms must remain
before reservation. The exploration deadline is the smaller of 100 ms and ten
percent of the remaining request budget, including admission and I/O. The
original deadline stays in force, and the ordinary first choice remains the
fallback. This is a capped attempt budget, not a whole-request latency promise.

An exploration timeout is censored evidence and does not penalize provider
reliability or its circuit breaker. Actual provider errors retain their normal
attribution. Opaque server and vendor errors are ambiguous: replay-safe reads
may fall back without a health penalty, while unsafe requests return the
original error without replay. Each node admits at most one active exploration
per configured profile, chain and family, at least one second apart. Route
cooldowns are ten seconds after success and thirty seconds after other
outcomes. Reload and route retirement remove stale reservations and cooldowns.

The `[:lasso, :routing, :exploration, :selected]`, `:completed`, and `:skipped`
telemetry events carry bounded profile, chain and workload-family metadata.
Completed events distinguish outcome and success; skipped events include a
bounded reason. Attempt facts retain `attempt_kind: :exploration`. The fact
codec writes major version 2 and reads ordinary version-1 facts; version 1
cannot express exploration or ambiguous response semantics. See
[configuration](CONFIGURATION.md#read-exploration-policy) for opt-in settings.

### Priority

**URL**: `/rpc/:chain` when `config :lasso, :provider_selection_strategy, :priority` is set. The shipped default is `:load_balanced`.
**Module**: `Lasso.RPC.Strategies.Priority`

Selects providers in the order defined by the `priority` field in the profile. Lower priority values are tried first.

**Use When**:
- You have a preferred provider (e.g., your own node) with fallbacks
- Predictable routing order is more important than performance optimization
- You want explicit control over provider precedence

**Behavior**:
- Sorts providers by priority field (ascending)
- No dynamic reordering based on performance
- Still subject to health tiering (closed-circuit providers preferred)

**Configuration**:
Set `priority` in the profile YAML:

```yaml
providers:
  - id: "my_node"
    url: "https://my-node.example.com"
    priority: 1
  - id: "alchemy_backup"
    url: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    priority: 2
```

## Health-Based Tiering

After strategy ranking, the pipeline applies a 4-tier reordering based on circuit breaker state and rate limit status. This ensures healthy providers receive traffic first while allowing recovering providers to gradually reintegrate.

### The 4 Tiers

Providers are reordered into these tiers (descending preference):

1. **Tier 1**: Closed circuit + not rate-limited
2. **Tier 2**: Half-open circuit + not rate-limited
3. **Tier 3**: Closed circuit + rate-limited
4. **Tier 4**: Half-open circuit + rate-limited

**Excluded**: Open circuit providers are filtered out entirely.

Within each tier, the strategy's original ranking is preserved. For example, with load-balanced, Tier 1 providers remain shuffled relative to each other.

### Circuit Breaker States

Circuit breakers track provider health per transport (HTTP/WS independently):

- **Closed**: Healthy. Provider is tried normally.
- **Half-open**: Recovering. Provider is deprioritized but periodically probed for recovery.
- **Open**: Failing. Provider is excluded from selection entirely until timeout expires.

Circuit breakers trip based on consecutive failures and success rate thresholds. See [OBSERVABILITY.md](OBSERVABILITY.md#circuit-breaker-metrics) for metrics and configuration.

### Rate Limit Detection

Rate limit status is tracked separately from circuit breakers. A provider can be closed-circuit but rate-limited, meaning it's healthy but temporarily throttled.

Rate-limited providers are not excluded but are deprioritized to Tier 3 or Tier 4. This allows Lasso to try a recovering channel with available capacity before one already marked capacity-limited.

## Example: Why Traffic Distribution May Be Uneven

Even with the load-balanced strategy, traffic may appear concentrated on certain providers. This is intentional and reflects health tiering.

**Scenario**: 3 providers (A, B, C)

- Provider A: Closed circuit, not rate-limited → **Tier 1**
- Provider B: Closed circuit, rate-limited → **Tier 3**
- Provider C: Half-open circuit, not rate-limited → **Tier 2**

With load-balanced, Lasso shuffles providers then reorders by tier:

1. Provider A (Tier 1) receives the first attempt on every request
2. Provider C (Tier 2) receives attempts only if A fails
3. Provider B (Tier 3) receives attempts only if A and C both fail

**Result**: Provider A receives ~100% of traffic as long as it succeeds. This is correct behavior—Lasso routes to the healthiest provider while maintaining fallbacks.

To allow statistical distribution, keep multiple providers in Tier 1 (closed
circuit + not rate-limited). Load-balanced routing does not guarantee exact
shares or account for provider capacity.

## Strategy-Health Interaction

All strategies are subject to health tiering. The strategy determines the order within each tier, but tier ordering takes precedence.

| Strategy | Within-Tier Behavior | Cross-Tier Impact |
|----------|---------------------|-------------------|
| Load Balanced | Randomized; replay-safe fallback gives distinct physical instances a bounded first pass | Health tiers and recovered-head preference dominate |
| Fastest | Latency-ordered | Fastest provider may not receive traffic if unhealthy |
| Latency Weighted | Weighted random | Weights apply only within each tier |
| Priority | Priority-ordered | Priority applies only within each tier |

**Example**: With fastest strategy, if the fastest provider has a half-open circuit, any closed-circuit provider will be tried first, even if it's slower.

## Execution and Failover

After tiering, Lasso attempts providers sequentially until success or all providers are exhausted.

**Success**: First provider that returns a valid RPC response (2xx status, valid JSON-RPC structure)

**Failure**: Provider is skipped and the next provider in the list is tried. Failures increment circuit breaker counters.

**All Exhausted**: Returns HTTP `200 OK` with a standard JSON-RPC error response. The error uses code `-32000`, preserves the client's request ID, and does not expose internal provider-attempt details.

See [API_REFERENCE.md](API_REFERENCE.md#error-responses) for error format details.

## Configuration Reference

Strategy behavior can be tuned via environment variables:

| Variable | Strategy | Default | Description |
|----------|----------|---------|-------------|
| `BALANCED_FAST_BETA` | Balanced Fast | 3.0 | Latency exponent |

See [CONFIGURATION.md](CONFIGURATION.md#routing-strategies) for the application default and URL strategy configuration.

## Method and Subscription Policy

Choose request strategies through the URL. YAML does not support a `routing` or
`method_overrides` block. Provider `capabilities` can exclude specific methods
and constrain block ranges and history; see [Configuration](CONFIGURATION.md#provider-capabilities).

WebSocket URL strategies apply to forwarded JSON-RPC calls. `eth_subscribe`
uses a shared subscription pool that selects eligible providers by priority,
independently of the URL strategy. An explicit provider URL constrains the
subscription to that provider and cannot fail over to another provider.

During log recovery, buffered events preserve each log identity's addition/removal
order through its last removal before final additions from replacement blocks are
delivered. Core deduplicates positive and removed events separately by block hash
and log index. Repeated removal and re-addition of the same identity within the
dedupe window is not fully modeled; this ordering rule is not a claim of complete
recovery for every repeated reorg sequence.

## Provider Override

Bypass strategy selection entirely by routing directly to a specific provider:

```
POST /rpc/provider/:provider_id/:chain
```

The provider ID must match a provider configured in the profile. Health checks and circuit breakers still apply—if the provider is open-circuit, the request will fail.

This is useful for debugging, testing specific provider behavior, or implementing custom provider selection logic outside of Lasso.
