---
name: smoke-test-runner
description: Automated endpoint validation and performance regression testing for local/staging/prod Lasso RPC instances
---

# Smoke Test Runner

Execute comprehensive smoke tests against Lasso RPC endpoints to validate functionality, performance, and catch regressions before they reach production.

## When to Auto-Invoke

This skill should be **automatically triggered** when:

1. **User requests endpoint testing**
   - "test the prod endpoint"
   - "smoke test staging"
   - "validate local instance"
   - "check if prod is working"

2. **After deployment**
   - User mentions deployment to staging/prod
   - "I just deployed to prod"
   - "Can you check if the deploy worked?"

3. **Performance concerns**
   - "Is prod slow?"
   - "Check endpoint performance"
   - "Validate response times"

## Core Responsibilities

### 1. Determine Target Environment

**Ask user if not specified:**
```
Which environment should I test?
1. local (http://localhost:4000)
2. staging (https://staging-lasso-rpc.fly.dev)
3. prod (https://lasso-rpc.fly.dev)
4. custom (specify URL)

Default: local
```

**Store in variable:**
```bash
HOST="https://lasso-rpc.fly.dev"  # or user-specified
```

### 2. Run Comprehensive Smoke Tests

Execute all test scenarios from `/smoke-test` slash command:

**A. Basic RPC Methods (All Chains)**

For each chain (ethereum, base):

```bash
# eth_blockNumber
curl -s -w "Time: %{time_total}s\n" -X POST "$HOST/rpc/{chain}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# eth_chainId
curl -s -w "Time: %{time_total}s\n" -X POST "$HOST/rpc/{chain}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2}'

# eth_gasPrice
curl -s -w "Time: %{time_total}s\n" -X POST "$HOST/rpc/{chain}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":3}'
```

**Validate each response:**
- Returns valid JSON-RPC 2.0 structure
- Has `result` field (not `error`)
- Response time < 500ms for P95
- Block numbers are reasonable (recent blocks)
- Chain IDs match expected (0x1 for ethereum, 0x2105 for base)

**B. Routing Strategy Tests**

Test each strategy with `eth_blockNumber`:

```bash
strategies=("round-robin" "fastest" "latency-weighted")

for strategy in "${strategies[@]}"; do
  curl -s -w "\n%{time_total}" -X POST "$HOST/rpc/$strategy/ethereum" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
done
```

**Validate:**
- All strategies return successful responses
- Block numbers consistent (within 2-3 blocks)
- No routing errors
- Fastest strategy shows best avg performance

**C. HTTP Batching**

```bash
curl -s -w "\n%{time_total}" -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2},
    {"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":3}
  ]'
```

**Validate:**
- Returns array with 3 responses
- Each response has correct `id`
- All successful
- Total time < 600ms

**D. Observability Metadata**

```bash
# Headers mode
response=$(curl -s -i -X POST "$HOST/rpc/ethereum?include_meta=headers" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

# Check for headers
echo "$response" | grep "X-Lasso-Request-ID"
echo "$response" | grep "X-Lasso-Meta"

# Body mode
curl -s -X POST "$HOST/rpc/ethereum?include_meta=body" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq '.lasso_meta'
```

**Validate:**
- Headers mode: Both headers present
- Body mode: `lasso_meta` field exists with routing info

**E. Performance Baseline**

Run 20 requests and measure latency distribution:

```bash
times=()
for i in {1..20}; do
  time=$(curl -s -w "%{time_total}" -o /dev/null -X POST "$HOST/rpc/ethereum" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')
  times+=($time)
done

# Calculate percentiles (using simple sort)
printf '%s\n' "${times[@]}" | sort -n
```

**Validate against baselines:**
- P50 < 300ms (local), < 400ms (prod)
- P95 < 500ms (local), < 700ms (prod)
- P99 < 1000ms
- No timeouts

**F. Provider-Specific Endpoints (If Configured)**

```bash
# Test direct provider routing
curl -s -X POST "$HOST/rpc/provider/ethereum_llamarpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### 3. Compare Against Baseline

**Load baseline metrics** from `resources/baseline-metrics.md`

**Compare:**
- Current P50/P95/P99 vs baseline
- Success rate vs baseline (should be 100%)
- Strategy performance ranking

**Flag regressions:**
- Response times >20% slower than baseline
- Any failed requests
- Missing features that worked before

### 4. Generate Report

Provide comprehensive, actionable report:

```
🔥 LASSO RPC SMOKE TEST REPORT
Target: https://lasso-rpc.fly.dev (prod)
Executed: 2024-11-03 16:45:32 UTC
================================

✅ BASIC RPC METHODS (6/6 passed)
┌──────────────────┬──────────┬───────────┬────────┐
│ Chain            │ Method   │ Time (ms) │ Result │
├──────────────────┼──────────┼───────────┼────────┤
│ ethereum         │ blockNum │    134    │   ✅   │
│ ethereum         │ chainId  │     89    │   ✅   │
│ ethereum         │ gasPrice │    145    │   ✅   │
│ base             │ blockNum │    156    │   ✅   │
│ base             │ chainId  │     92    │   ✅   │
│ base             │ gasPrice │    134    │   ✅   │
└──────────────────┴──────────┴───────────┴────────┘

✅ ROUTING STRATEGIES (3/3 passed)
┌────────────────┬───────────┬─────────────┐
│ Strategy       │ Avg (ms)  │ Status      │
├────────────────┼───────────┼─────────────┤
│ fastest        │    98     │ ✅ Best     │
│ round-robin    │   156     │ ✅          │
│ latency-weight │   123     │ ✅          │
└────────────────┴───────────┴─────────────┘

✅ HTTP BATCHING: 187ms (3 reqs) ✅

✅ OBSERVABILITY
   Headers: X-Lasso-Request-ID, X-Lasso-Meta present ✅
   Body: lasso_meta field present ✅

✅ PERFORMANCE BASELINE (20 samples)
┌────────┬─────────┬──────────┬────────────┐
│ Metric │ Current │ Baseline │ Status     │
├────────┼─────────┼──────────┼────────────┤
│ P50    │  134ms  │  120ms   │ ⚠️  +12%   │
│ P95    │  187ms  │  180ms   │ ✅ +4%     │
│ P99    │  245ms  │  220ms   │ ⚠️  +11%   │
│ Min    │   89ms  │   85ms   │ ✅         │
│ Max    │  267ms  │  245ms   │ ⚠️  +9%    │
└────────┴─────────┴──────────┴────────────┘

⚠️  REGRESSION DETECTED:
   P50 latency increased by 12% (134ms vs baseline 120ms)
   P99 latency increased by 11% (245ms vs baseline 220ms)

   Possible causes:
   - Increased provider latency
   - Network congestion
   - Recent config changes

   Recommendation: Check provider metrics dashboard

✅ PROVIDER-SPECIFIC (2/2 passed)
   ethereum_llamarpc: 142ms ✅
   base_publicnode: 156ms ✅

════════════════════════════════════════════
OVERALL: ✅ FUNCTIONAL (⚠️  Performance Degradation)
════════════════════════════════════════════

SUMMARY:
- All endpoints operational ✅
- All routing strategies working ✅
- Observability functioning ✅
- Performance: 10-12% slower than baseline ⚠️

NEXT STEPS:
1. Monitor provider latency in dashboard
2. Check if specific providers are degraded
3. Consider running load test for deeper analysis
4. Update baseline if new normal performance

Full test execution time: 8.3 seconds
```

### 5. Handle Failures Gracefully

**If critical failure (500 errors, timeouts):**

```
❌ SMOKE TEST FAILED
===================

CRITICAL: Endpoint appears down or severely degraded

Failed Tests:
- eth_blockNumber: Connection timeout after 5000ms
- eth_chainId: 502 Bad Gateway
- All routing strategies: Connection refused

Possible Issues:
1. Lasso RPC instance not running
2. Network connectivity problem
3. All providers down or unreachable
4. Configuration error

RECOMMENDED ACTIONS:
1. Check if server is running: curl $HOST/health (if health endpoint exists)
2. Check deployment logs: fly logs (if Fly.io)
3. Verify DNS resolves: nslookup lasso-rpc.fly.dev
4. Check provider status: try direct provider URLs

Cannot proceed with full smoke test until endpoint is reachable.
```

## Resources

- `resources/test-scenarios.md` - Detailed test scenarios and validation criteria
- `resources/baseline-metrics.md` - Historical baseline performance data
- `/smoke-test` slash command - Execute tests manually

## Integration with Other Features

**Compose with:**
- `/smoke-test` - Use internally for test execution
- `/health-check` - Can run locally before testing remote
- Load test scripts in `scripts/rpc_load_test.mjs` - For deeper analysis

**Store results:**
- Update `resources/baseline-metrics.md` with new baselines (if user confirms)
- Track regression trends over time

## When to Update Baselines

**Update baselines when:**
- Intentional infrastructure changes (new providers, regions)
- After optimization work that improves performance
- Major version updates
- User explicitly requests: "update the baseline"

**Don't update baselines for:**
- Temporary performance issues
- Single regression
- External provider issues

## Automation Opportunities

**This skill enables:**
- Pre-deployment validation
- Post-deployment verification
- Continuous monitoring (scheduled runs)
- Regression detection in CI/CD

**Future integration:**
- GitHub Actions workflow
- Scheduled Fly.io checks
- Alerting on regressions
- Performance dashboard

## Success Criteria

- All core RPC methods work across chains
- All routing strategies operational
- Performance within acceptable range (±20% of baseline)
- Observability metadata functions correctly
- Clear, actionable report generated
- Regressions detected and flagged

## Notes

- Keep tests fast (<30 seconds total execution)
- Focus on user-impacting functionality
- Flag anomalies but don't be overly sensitive
- Provide clear next steps for issues found
- Remember this is smoke testing, not comprehensive load testing
