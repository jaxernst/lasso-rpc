# Freshness-Based Routing: Design Exploration

**Status:** EXPLORATION (not ready for implementation)
**Last Updated:** 2025-01-14
**Authors:** Jackson Ernst, Claude

---

## Purpose

This document explores approaches for routing requests to providers that are statistically most likely to have the latest block. This is a **future capability** — the immediate priority is fair lag filtering (see `PROPAGATION_TRACKING_SPEC.md`).

**When to revisit this:**
- Measurable user complaints about stale `latest` responses
- A/B tests show freshness routing improves outcomes
- Operational cost is justified by improvement

---

## Problem Statement

Some RPC methods are freshness-sensitive:
- `eth_blockNumber` — returns chain tip
- `eth_getBlockByNumber("latest", ...)` — queries latest state
- `eth_call` with `latest` block parameter
- `eth_getLogs` with `toBlock: "latest"`

For these methods, routing to a provider that's 1-2 blocks behind can return stale data. The goal is to **identify and prefer providers that propagate blocks fastest**.

### What "Fastest" Means

There are several interpretations:

1. **First to receive** — When did the provider's node first see the block?
2. **First to serve** — When can the provider return the block via RPC?
3. **Most consistently fresh** — Which provider is most often at consensus?
4. **Lowest worst-case staleness** — Which provider has the tightest bounds?

These aren't equivalent. A provider might receive blocks fast but have slow RPC response times, or vice versa.

---

## Approaches

### Approach 1: Probe-Based Measurement

**Concept:** Directly measure "time to serve new block" by probing providers when a new block is detected.

```
On new block H detected (via WS reference):
  1. Record T_detected
  2. Probe subset of providers: eth_getBlockByNumber(H)
  3. Record T_served for each successful response
  4. Sample: serve_latency = T_served - T_detected
  5. Update per-provider EMA of serve_latency
```

**Pros:**
- Measures what we care about (can they serve it?)
- No interpolation or inference
- Handles load-balanced providers naturally (measures aggregate behavior)
- Simple mental model

**Cons:**
- Additional RPC calls (probe overhead)
- Sampling bias (only measures during probe windows)
- Requires WS reference(s) to trigger probes
- Probe timing affects measurement (network latency to Lasso)

**Variations:**
- **Full probe:** Probe all providers on every block
- **Sampled probe:** Probe N random providers per block
- **Adaptive probe:** Probe more during high-value periods (volatility)
- **Staggered probe:** Probe at T+100ms, T+500ms, T+1s to build distribution

**Open questions:**
- What's the right probe frequency vs. overhead trade-off?
- How to handle probe failures (timeout vs. "doesn't have block yet")?
- Should probes use a dedicated connection pool?

---

### Approach 2: Passive Observation (Request Piggyback)

**Concept:** Observe freshness from actual request traffic rather than dedicated probes.

```
On each request that returns block height (directly or indirectly):
  1. Extract block height from response
  2. Compare to current consensus
  3. Record: was_at_consensus = (response_height >= consensus_height)
  4. Update per-provider "freshness hit rate"
```

**Pros:**
- Zero additional network overhead
- Measures real-world behavior under actual load
- No sampling bias — uses all traffic
- Works without WS references

**Cons:**
- Not all methods return block height
- Delayed signal (only learn after routing decision)
- Confounded by routing decisions (if we route stale-sensitive to "fresh" providers, they look fresh)
- Can't measure "time to serve" — only "was fresh when asked"

**Variations:**
- **Block number extraction:** Parse responses for block references
- **Header tracking:** For methods returning block headers
- **Implicit freshness:** Track if `latest` queries return expected height

**Open questions:**
- Which methods reliably indicate freshness?
- How to avoid feedback loops (routing affects measurement)?
- Is "hit rate" enough, or do we need latency?

---

### Approach 3: WebSocket Event Timing

**Concept:** Use newHeads subscription timing as a proxy for propagation speed.

```
For providers with WS connections:
  1. Subscribe to newHeads on all (or sampled) providers
  2. Record arrival time for each block per provider
  3. Rank by: mean(arrival_time - first_arrival_time)
```

**Pros:**
- Direct observation of block arrival
- No additional RPC overhead (subscription is passive)
- High-fidelity timing data

**Cons:**
- Requires WS connections to all ranked providers (defeats WS reduction goal)
- Measures "arrival at WS connection" not "can serve via RPC"
- Load-balanced providers may have inconsistent WS vs HTTP behavior
- Clock synchronization matters for cross-provider comparison

**Variations:**
- **Full coverage:** WS to all providers
- **Reference comparison:** WS to references + measure others relative
- **Rotating sample:** Cycle WS connections across providers

**Open questions:**
- Is WS arrival time a good proxy for HTTP serve time?
- How to handle providers without WS support?
- What's the operational cost of many WS connections?

---

### Approach 4: Statistical Inference (V0 Approach — Cautionary)

**Concept:** Infer propagation timing from HTTP poll observations.

```
When HTTP poll detects block transition (H1 → H2):
  1. Get reference timestamp for blocks in range
  2. Interpolate: estimate when provider received each block
  3. Calculate delay = estimated_receive - reference_time
  4. Build statistical model (EMA, variance)
```

**Why this was rejected:**
- Interpolation error dominates on fast chains
- Reference timestamps aren't authoritative ("arrival to Lasso" not "network first seen")
- Models noise rather than signal
- High complexity for questionable accuracy

**When it might work:**
- Slow chains (Ethereum L1) where poll interval ≈ block time
- Dedicated providers (no load balancing)
- If interpolation method is significantly improved

**Recommendation:** Avoid unless other approaches prove insufficient.

---

### Approach 5: Hybrid (Probe + Passive)

**Concept:** Combine probing for calibration with passive observation for ongoing tracking.

```
Calibration phase (periodic):
  1. Probe all providers on new block
  2. Establish baseline rankings

Tracking phase (continuous):
  1. Observe freshness from real traffic
  2. Adjust rankings based on hit rates
  3. Re-calibrate periodically or on drift detection
```

**Pros:**
- Lower steady-state overhead than full probing
- More signal than passive-only
- Can detect ranking drift

**Cons:**
- More complex than single approach
- Two systems to maintain
- Potential for calibration/tracking disagreement

---

## Considerations for Any Approach

### Reference Provider Strategy

Most approaches need some way to know "when did a new block appear?" Options:

| Strategy | Pros | Cons |
|----------|------|------|
| 2-3 WS references | Low overhead, reliable | Reference selection matters |
| External feed (block explorer API) | Independent source | Rate limits, latency, dependency |
| Fastest observed | No designated references | Circular (ranking affects detection) |
| Consensus of all providers | Robust | High overhead |

### Ranking Granularity

What level of ranking do we need?

| Granularity | Use Case | Complexity |
|-------------|----------|------------|
| Binary (fresh/stale) | Filter only | Low |
| Tiers (fast/medium/slow) | Coarse routing | Medium |
| Continuous score | Fine-grained selection | High |
| Per-method ranking | Method-specific optimization | Very high |

### Confidence and Cold Start

How to handle:
- New providers with no history
- Providers with few samples
- Sudden ranking changes

Options:
- Require minimum samples before ranking
- Decay old data (EMA handles this)
- Confidence-weighted selection
- Fallback to non-freshness routing

### Staleness vs. Reliability Trade-off

The "freshest" provider might not be the most reliable. Consider:
- Freshness ranking as one factor among many
- Freshness boost rather than override
- Only apply to explicitly freshness-sensitive methods
- User-configurable freshness priority

### Load Balancer Behavior

Many providers are load-balanced fleets. This means:
- Different requests hit different nodes
- Propagation varies by node
- Our measurement is of the aggregate, not individual nodes

Implications:
- Rankings reflect "probability of hitting fresh node"
- High variance is expected for LB providers
- May want to model as distribution, not point estimate

---

## Evaluation Criteria

When comparing approaches, consider:

| Criterion | Weight | Notes |
|-----------|--------|-------|
| Accuracy | High | Does ranking reflect actual freshness? |
| Overhead | High | Additional requests, connections, compute |
| Simplicity | Medium | Implementation and operational complexity |
| Latency | Medium | Does measurement add latency to requests? |
| Coverage | Medium | Works for all providers, or subset? |
| Cold start | Low | How quickly can we rank a new provider? |

---

## Suggested Next Steps

1. **Instrument current behavior:** Before building, measure the problem
   - What % of `latest` requests return stale data?
   - How often are providers at different heights?
   - Is there meaningful differentiation between providers?

2. **Prototype probe-based:** Simplest approach that measures what we care about
   - Start with probing on every Nth block
   - Measure probe overhead vs. ranking accuracy
   - Validate rankings against ground truth

3. **A/B test:** Before full rollout
   - Compare freshness-routed vs. baseline
   - Measure: stale response rate, latency, error rate
   - Ensure freshness routing doesn't degrade other metrics

4. **Iterate based on data:** Let measurements guide design
   - If probe overhead is too high → try passive observation
   - If rankings are unstable → add confidence thresholds
   - If differentiation is low → maybe don't need this at all

---

## Related Documents

- `PROPAGATION_TRACKING_SPEC.md` — Fair lag filtering (V1, implemented)
- `PROPAGATION_TRACKING_SPEC_V0.md` — Original complex approach (archived)
- Review feedback: `GPT_PRODUCT.md`, `GEMINI_SKEPTIC.md`, etc.

---

**This document is intentionally open-ended. The right approach depends on measurements we haven't taken yet.**
