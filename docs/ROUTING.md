# Routing

Provider selection in Lasso operates as a 4-stage pipeline that transforms a pool of candidate providers into a single execution target. This pipeline balances performance, reliability, and load distribution based on real-time health metrics and historical performance data.

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

Random distribution across available providers. After shuffling, the tiering pipeline reorders based on circuit breaker state and rate limit status.

**Use When**:
- Maximizing throughput across multiple providers
- Avoiding rate limits through even distribution
- You have multiple providers of similar quality

**Behavior**:
- Shuffles providers randomly on each request
- No preference for any provider absent health signals
- Combined with tiering, healthy providers still receive more traffic

### Fastest

**URL**: `/rpc/fastest/:chain`
**Module**: `Lasso.RPC.Strategies.Fastest`

Selects the lowest-latency provider for the specific RPC method based on passive benchmarking. Latency is tracked per provider, per method, per transport.

**Use When**:
- Latency is the primary concern
- You're willing to concentrate load on the fastest provider
- The method being called is latency-sensitive (e.g., `eth_getBlockByNumber`)

**Behavior**:
- Ranks providers by measured latency (lowest first)
- Metrics older than 10 minutes are treated as stale and deprioritized
- Providers with no metrics use a dynamic fallback latency (P75 of known providers)
- Still subject to health tiering (closed-circuit providers preferred)

**Configuration**:
- `FASTEST_MIN_CALLS`: Minimum calls for stable metrics (default: 3)
- `FASTEST_MIN_SUCCESS_RATE`: Minimum success rate filter (default: 0.9)

### Latency Weighted

**URL**: `/rpc/latency-weighted/:chain`
**Module**: `Lasso.RPC.Strategies.LatencyWeighted`

Probabilistic selection weighted by latency, success rate, and confidence. Routes more traffic to faster providers while still using slower ones.

**Use When**:
- You want a balance between performance and distribution
- Avoiding single-provider concentration is important
- You have providers with significantly different performance profiles

**Behavior**:
- Calculates a weight for each provider based on the formula:
  ```
  weight = (1 / latency^beta) * success_rate * confidence * calls_scale
  weight = max(weight, explore_floor)
  ```
- Higher weights = higher selection probability
- Providers with stale metrics (>10min) receive the `explore_floor` weight
- Providers with no metrics use fallback latency and conservative confidence

**Configuration**:
- `LW_BETA`: Latency exponent (default: 3.0, higher = more aggressive preference for low latency)
- `LW_MS_FLOOR`: Minimum latency denominator (default: 30ms, prevents division by near-zero)
- `LW_EXPLORE_FLOOR`: Minimum weight floor (default: 0.05, ensures all providers get some traffic)
- `LW_MIN_CALLS`: Minimum calls for stable metrics (default: 3)
- `LW_MIN_SR`: Minimum success rate (default: 0.85)

### Priority

**URL**: `/rpc/:chain` (implicit when no strategy specified)
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
2. **Tier 2**: Closed circuit + rate-limited
3. **Tier 3**: Half-open circuit + not rate-limited
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

Rate-limited providers are not excluded but are deprioritized to Tier 2 or Tier 4. This allows Lasso to continue using them while preferring providers with available capacity.

## Example: Why Traffic Distribution May Be Uneven

Even with the load-balanced strategy, traffic may appear concentrated on certain providers. This is intentional and reflects health tiering.

**Scenario**: 3 providers (A, B, C)

- Provider A: Closed circuit, not rate-limited → **Tier 1**
- Provider B: Closed circuit, rate-limited → **Tier 2**
- Provider C: Half-open circuit, not rate-limited → **Tier 3**

With load-balanced, Lasso shuffles providers then reorders by tier:

1. Provider A (Tier 1) receives the first attempt on every request
2. Provider B (Tier 2) receives attempts only if A fails
3. Provider C (Tier 3) receives attempts only if A and B both fail

**Result**: Provider A receives ~100% of traffic as long as it succeeds. This is correct behavior—Lasso routes to the healthiest provider while maintaining fallbacks.

To achieve truly even distribution, ensure all providers are in Tier 1 (closed circuit + not rate-limited).

## Strategy-Health Interaction

All strategies are subject to health tiering. The strategy determines the order within each tier, but tier ordering takes precedence.

| Strategy | Within-Tier Behavior | Cross-Tier Impact |
|----------|---------------------|-------------------|
| Load Balanced | Random shuffle | No preference, but healthy tiers dominate |
| Fastest | Latency-ordered | Fastest provider may not receive traffic if unhealthy |
| Latency Weighted | Weighted random | Weights apply only within each tier |
| Priority | Priority-ordered | Priority applies only within each tier |

**Example**: With fastest strategy, if the fastest provider has a half-open circuit, any closed-circuit provider will be tried first, even if it's slower.

## Execution and Failover

After tiering, Lasso attempts providers sequentially until success or all providers are exhausted.

**Success**: First provider that returns a valid RPC response (2xx status, valid JSON-RPC structure)

**Failure**: Provider is skipped and the next provider in the list is tried. Failures increment circuit breaker counters.

**All Exhausted**: Returns `503 Service Unavailable` with details about which providers were tried and why they failed.

See [API_REFERENCE.md](API_REFERENCE.md#error-responses) for error format details.

## Configuration Reference

Strategy behavior can be tuned via environment variables:

| Variable | Strategy | Default | Description |
|----------|----------|---------|-------------|
| `FASTEST_MIN_CALLS` | Fastest | 3 | Minimum calls for stable metrics |
| `FASTEST_MIN_SUCCESS_RATE` | Fastest | 0.9 | Minimum success rate filter |
| `LW_BETA` | Latency Weighted | 3.0 | Latency exponent |
| `LW_MS_FLOOR` | Latency Weighted | 30.0 | Minimum latency denominator (ms) |
| `LW_EXPLORE_FLOOR` | Latency Weighted | 0.05 | Minimum selection probability |
| `LW_MIN_CALLS` | Latency Weighted | 3 | Minimum calls for stable metrics |
| `LW_MIN_SR` | Latency Weighted | 0.85 | Minimum success rate |

See [CONFIGURATION.md](CONFIGURATION.md#routing-strategies) for profile-level strategy configuration.

## Per-Method Routing

Profiles support per-method strategy and provider overrides. This allows fine-grained control for methods with different performance characteristics.

```yaml
routing:
  default_strategy: "load_balanced"
  method_overrides:
    eth_getLogs:
      strategy: "fastest"  # Use fastest for log queries
    eth_call:
      providers: ["alchemy", "quicknode"]  # Restrict call to specific providers
```

See [CONFIGURATION.md](CONFIGURATION.md#per-method-routing) for full per-method configuration options.

## Provider Override

Bypass strategy selection entirely by routing directly to a specific provider:

```
POST /rpc/provider/:provider_id/:chain
```

The provider ID must match a provider configured in the profile. Health checks and circuit breakers still apply—if the provider is open-circuit, the request will fail.

This is useful for debugging, testing specific provider behavior, or implementing custom provider selection logic outside of Lasso.
