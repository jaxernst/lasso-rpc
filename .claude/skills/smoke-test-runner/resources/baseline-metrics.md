# Lasso RPC Performance Baselines

Historical baseline performance data for regression detection.

**Last Updated:** 2024-11-03 (Initial baselines)

---

## Local Development (localhost:4000)

**Environment:**
- MacBook Pro M1 (or similar)
- Local Elixir/Phoenix server
- Mock providers or real provider pool
- No network latency

### eth_blockNumber Performance

| Metric | Baseline | Acceptable Range | Alert Threshold |
|--------|----------|------------------|-----------------|
| P50    | 120ms    | 100-180ms        | >200ms         |
| P95    | 180ms    | 150-250ms        | >300ms         |
| P99    | 220ms    | 180-300ms        | >400ms         |
| Min    | 85ms     | 50-120ms         | N/A            |
| Max    | 245ms    | 200-350ms        | >500ms         |

**Sample size:** 20 requests

**Notes:**
- Local performance varies with machine resources
- Mock providers should be ~50-100ms
- Real providers add network latency

### Routing Strategy Performance

| Strategy | Avg Latency | Expected Rank |
|----------|-------------|---------------|
| fastest  | 98ms        | 1 (best)      |
| latency-weighted | 123ms | 2        |
| round-robin | 156ms    | 3             |

**Notes:**
- Fastest should always be lowest latency
- Round-robin includes all providers (avg)
- Latency-weighted biases toward faster providers

### HTTP Batching

| Metric | Baseline | Notes |
|--------|----------|-------|
| 3 requests (batch) | ~190ms | Should be < 3× single request |
| Parallelization | ~75% | Efficiency factor |

---

## Production (lasso-rpc.fly.dev)

**Environment:**
- Fly.io deployment
- Real RPC providers
- Global network latency
- Multiple regions

### eth_blockNumber Performance

| Metric | Baseline | Acceptable Range | Alert Threshold |
|--------|----------|------------------|-----------------|
| P50    | 220ms    | 180-280ms        | >350ms         |
| P95    | 380ms    | 320-480ms        | >600ms         |
| P99    | 520ms    | 450-650ms        | >800ms         |
| Min    | 145ms    | 100-200ms        | N/A            |
| Max    | 680ms    | 500-900ms        | >1200ms        |

**Sample size:** 20 requests

**Notes:**
- Production includes real provider latency
- Varies by region and provider health
- Acceptable ranges account for network variance

### Routing Strategy Performance

| Strategy | Avg Latency | Expected Behavior |
|----------|-------------|-------------------|
| fastest  | 210ms       | Should track best provider |
| latency-weighted | 265ms | Balanced distribution |
| round-robin | 340ms    | Includes slower providers |

**Notes:**
- Fastest adapts to real-time provider performance
- Gaps between strategies indicate provider variance
- Large gaps (>200ms) may indicate degraded providers

### Multi-Chain Performance

| Chain | avg eth_blockNumber | Expected | Notes |
|-------|---------------------|----------|-------|
| Ethereum | 220ms | 180-300ms | Most providers available |
| Base     | 245ms | 200-350ms | Fewer providers |
| Polygon  | TBD   | TBD       | Baseline needed |

### HTTP Batching (Production)

| Metric | Baseline | Notes |
|--------|----------|-------|
| 3 requests (batch) | ~450ms | Should be < 2× single request |
| Parallelization | ~60% | Lower than local (network) |

---

## Staging (staging-lasso-rpc.fly.dev)

**Environment:**
- Fly.io deployment (staging)
- Same provider configuration as prod
- Lower traffic volume

### Performance Expectations

**Generally 5-15% slower than local, 0-10% difference from prod**

| Metric | Expected Range | Notes |
|--------|---------------|-------|
| P50    | 200-250ms     | Similar to prod |
| P95    | 350-450ms     | May vary more |
| P99    | 500-700ms     | Higher variance acceptable |

**Notes:**
- Staging should match prod performance
- Use staging for deployment validation
- Larger variance acceptable (lower traffic)

---

## Regression Detection Guidelines

### When to Alert

**Critical (🚨):**
- P50 > 50% slower than baseline
- Any timeouts (>5000ms)
- Error rate > 1%
- Any endpoint returns 500 errors

**Warning (⚠️):**
- P50 > 20% slower than baseline
- P95 > 30% slower than baseline
- Strategy ranking changes (fastest not fastest)

**Info (ℹ️):**
- P50 10-20% slower (investigate)
- Single outlier in P99
- Minor strategy reordering

### Factors to Consider

**Before flagging regression:**
1. Time of day (peak vs off-peak traffic)
2. Recent deployments or config changes
3. Provider health (check dashboard)
4. Network conditions
5. Sample size (10 samples vs 50 samples)

**Valid reasons for performance change:**
- Added new slower providers to pool
- Intentional config changes
- Provider degradation (not Lasso's fault)
- Infrastructure scaling

---

## Updating Baselines

### When to Update

**Update baselines after:**
- Intentional infrastructure improvements
- Major provider changes
- Migration to new infrastructure
- Performance optimization work

**Process:**
1. Run 50-sample smoke test
2. Verify results are stable (rerun)
3. Document reason for update
4. Update this file with new baselines
5. Note date and context

### Update Template

```markdown
## Baseline Update: [Date]

**Reason:** [Performance optimization / New providers / Infrastructure change]

**Changes:**
- P50: 220ms → 180ms (-18%)
- P95: 380ms → 320ms (-16%)

**Context:**
- Added 3 new high-performance providers
- Optimized request pipeline
- Reduced connection overhead

**Validation:**
- 50-sample test runs
- Consistent across multiple runs
- All functionality tests passed
```

---

## Historical Data

### 2024-11-03: Initial Baselines

**Context:** First comprehensive baseline measurement

**Local:**
- P50: 120ms, P95: 180ms, P99: 220ms

**Production:**
- P50: 220ms, P95: 380ms, P99: 520ms

**Providers in pool:**
- Ethereum: 6 providers (LlamaRPC, Cloudflare, PublicNode, etc.)
- Base: 4 providers

---

## Testing Recommendations

**Quick check (5 min):**
- 10 samples per test
- Basic RPC methods only
- Accept ±30% variance

**Standard check (15 min):**
- 20 samples per test
- All routing strategies
- HTTP batching
- Accept ±20% variance

**Comprehensive check (30 min):**
- 50 samples per test
- All scenarios
- Multi-chain testing
- Accept ±10% variance

---

## Notes

- Baselines are guidelines, not strict limits
- Real-world variability is expected
- Focus on user-impacting regressions
- Update baselines when infrastructure intentionally changes
- Track trends over time, not just single measurements
