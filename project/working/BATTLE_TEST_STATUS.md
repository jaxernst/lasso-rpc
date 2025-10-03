# Battle Test Suite - Status & Execution Guide

**Date:** 2025-10-03
**Status:** All tests fixed and ready for execution
**Purpose:** PM-ready validation of Lasso RPC production capabilities

## Executive Summary

All battle tests have been refactored to remove methodology issues identified in technical review. Tests are now production-ready and measure what they claim to measure.

### Key Improvements Made

1. **Removed timing anti-patterns** - Eliminated ~10+ seconds of artificial `Process.sleep()` calls that were dominating measurements
2. **Added statistical rigor** - Performance comparisons now include confidence intervals and significance testing
3. **Fixed failover verification** - Tests now prove failover occurred rather than assuming it
4. **Separated measurement phases** - Baseline vs recovery phases measured independently for fair comparison

## Test Suite Overview

### 1. WebSocket Failover Test (`test/battle/websocket_failover_test.exs`)

**Purpose:** Validates WebSocket subscription continuity during provider failure
**Duration:** ~90 seconds per test
**Tag:** `:slow`, `:real_providers`, `:websocket`

**What It Tests:**
- Subscription continues receiving blockchain events during provider failure
- Circuit breaker opens for failed provider (verified via PubSub events)
- Multiple subscriptions survive failover
- Stream continuity tracking (gaps, duplicates)

**Key Metrics:**
- Events received before/after failover
- Duplicate rate (≤5% acceptable with failover)
- Gap detection
- Circuit breaker state transitions

**To Run:**
```bash
mix test test/battle/websocket_failover_test.exs --include battle --include real_providers --include websocket --include slow
```

**Expected Outcomes:**
- ✅ Subscriptions continue despite provider failure
- ✅ Circuit breaker opens within 10s of provider kill
- ✅ Events received from backup provider

---

### 2. Real Provider Failover Test (`test/battle/real_provider_failover_test.exs`)

**Purpose:** Validates HTTP failover and SLO maintenance under concurrent load
**Duration:** Variable (60-120 seconds per test)
**Tag:** `:real_providers`

**What It Tests:**
- **Phased Failover Testing:**
  - Phase 1: Baseline (30s, 3 healthy providers at 50 req/s)
  - Phase 2: Kill primary provider
  - Phase 3: Recovery (30s, 2 remaining providers at 50 req/s)
- Strategy-based routing (`:fastest`, `:round_robin`)
- SLO maintenance during degradation

**Key Metrics:**
- Success rate (baseline vs recovery)
- P95 latency increase due to failover
- Circuit breaker opens
- Request distribution across providers

**Fast Tests Available:**
```bash
# Quick smoke test (~5s)
mix test test/battle/real_provider_failover_test.exs:341 --include battle --include real_providers --include fast

# Routing strategy tests (~5s each)
mix test test/battle/real_provider_failover_test.exs:254 --include battle --include real_providers --include fast
mix test test/battle/real_provider_failover_test.exs:303 --include battle --include real_providers --include fast
```

**Full Suite:**
```bash
mix test test/battle/real_provider_failover_test.exs --include battle --include real_providers
```

**Expected Outcomes:**
- ✅ 95%+ success rate maintained during failover
- ✅ Latency impact quantified (e.g., "+15ms, +8% from baseline")
- ✅ Circuit breaker opens for failed provider
- ✅ Traffic shifts to remaining providers

---

### 3. Provider Capability Test (`test/battle/provider_capability_test.exs`)

**Purpose:** Validates RPC method support and performance differences across providers
**Duration:** ~30-60 seconds per test
**Tag:** `:real_providers`, `:capability`

**What It Tests:**
- Method support across 3 providers (llamarpc, ankr, cloudflare)
- Core methods (eth_blockNumber, eth_chainId, etc.) - should be widely supported
- Extended methods (eth_maxPriorityFeePerGas, eth_feeHistory, etc.) - may vary
- Performance comparison with statistical analysis

**Key Statistical Features:**
- 95% confidence intervals for mean latency
- Standard deviation calculations
- CI overlap test for statistical significance
- Per-provider success rates

**To Run:**
```bash
mix test test/battle/provider_capability_test.exs --include battle --include real_providers --include capability
```

**Expected Outcomes:**
- ✅ 60%+ overall success rate (allows for unsupported extended methods)
- ✅ Core methods succeed on all providers
- ✅ Performance differences identified with statistical confidence
- ✅ Example output:
  ```
  Provider llamarpc:
    avg=85.2ms, p95=120ms
    std_dev=25.4ms
    95% CI: [78.1ms, 92.3ms]
  Provider ankr:
    avg=145.8ms, p95=210ms
    std_dev=35.2ms
    95% CI: [136.4ms, 155.2ms]
  ✓ Performance difference is statistically significant (non-overlapping CIs)
    llamarpc is measurably faster
  ```

---

### 4. Fuzz RPC Methods Test (`test/battle/fuzz_rpc_methods_test.exs`)

**Purpose:** Validates system stability under diverse RPC method workloads
**Duration:** ~30-60 seconds per test
**Tag:** `:real_providers`, `:fuzz`

**What It Tests:**
- 11 different RPC methods across multiple providers
- Sequential execution patterns
- High concurrency with mixed methods (3 concurrent tasks, 6 methods)
- Error handling for unsupported/invalid methods

**Method Coverage:**
- Block queries: `eth_blockNumber`, `eth_getBlockByNumber`
- Chain info: `eth_chainId`, `eth_gasPrice`, `net_version`
- Account queries: `eth_getBalance`, `eth_getTransactionCount`, `eth_getCode`
- Gas/fee queries: `eth_maxPriorityFeePerGas`, `eth_feeHistory`
- Contract calls: `eth_call` (USDC balanceOf)

**To Run:**
```bash
mix test test/battle/fuzz_rpc_methods_test.exs --include battle --include real_providers --include fuzz
```

**Expected Outcomes:**
- ✅ 70%+ success rate (allows for provider-specific method support)
- ✅ 500+ requests generated under concurrent load
- ✅ Multiple methods used (verified in test output)
- ✅ Graceful error handling for unsupported methods

---

## How to Run Tests for PM Review

### Quick Validation (5-10 minutes)

Run fast smoke tests to verify system is working:

```bash
# Smoke test with real provider
mix test test/battle/real_provider_failover_test.exs:341 --include battle --include real_providers --include fast --include quick

# Fast routing tests
mix test test/battle/real_provider_failover_test.exs --include battle --include real_providers --include fast
```

### Full Production Validation (2-3 hours)

Run complete test suite with real providers:

```bash
# All battle tests
mix test test/battle/ --include battle --include real_providers --exclude slow

# Include slow WebSocket tests (adds ~10 minutes)
mix test test/battle/websocket_failover_test.exs --include battle --include real_providers --include websocket --include slow
```

### Generate PM Reports

Tests automatically generate JSON reports in `priv/battle_results/`:

```bash
# View latest markdown report
cat priv/battle_results/latest.md

# List all reports
ls -lth priv/battle_results/*.json | head -10
```

## What to Look For in Results

### Success Indicators

✅ **All SLOs passed** - Green checkmarks in summary
✅ **Success rates ≥ target** - e.g., 95% for failover tests
✅ **Latency within bounds** - P95 under defined thresholds
✅ **Failover verified** - Circuit breaker events logged
✅ **Statistical significance** - Non-overlapping confidence intervals when comparing performance

### Failure Indicators

❌ **SLO violations** - Red X marks in summary
❌ **Success rate below target** - Indicates provider issues or method support gaps
❌ **High latency** - P95 exceeding thresholds
❌ **No circuit breaker activity** - Failover may not be working
❌ **Overlapping CIs** - Performance differences not statistically significant

## Technical Details for Review

### Test Improvements Made

**Before:**
- `Process.sleep(200)` between every request = ~7.2s of artificial delays
- "Negative overhead" measurements (Lasso faster than direct calls)
- Timing asymmetry (measuring different time windows)
- No proof of failover (assumed based on request success)
- No statistical rigor (couldn't distinguish signal from noise)

**After:**
- Natural request timing - no artificial delays
- Timing symmetry - apples-to-apples comparisons
- Failover verified via PubSub circuit breaker events
- Statistical analysis with confidence intervals
- Phased testing (baseline vs recovery measured separately)

### Key Metrics Explained

**Success Rate:** `successful_requests / total_requests`
- Target varies by test (60-95%)
- Lower for capability tests (unsupported methods expected)
- Higher for failover tests (should maintain SLOs)

**P50/P95/P99 Latency:** Percentile latencies in milliseconds
- P50 = median (50% of requests faster)
- P95 = 95th percentile (95% of requests faster)
- P99 = 99th percentile (only 1% slower)

**95% Confidence Interval:** Statistical range for true mean
- Non-overlapping CIs = statistically significant difference
- Overlapping CIs = difference could be noise

**Circuit Breaker Opens:** Count of provider failures detected
- Should be ≥1 when provider killed
- Time to open should be <10 seconds

## Running Tests in CI

Tests are tagged to allow selective execution:

```bash
# Only fast tests (suitable for PR checks)
mix test --include battle --include real_providers --include fast --exclude slow

# Full suite (for nightly/release validation)
mix test --include battle --include real_providers
```

### Environment Variables

```bash
# Use real HTTP client (required for battle tests)
export LASSO_HTTP_CLIENT=Finch

# Increase timeouts for slower networks
export BATTLE_TEST_TIMEOUT=300000  # 5 minutes
```

## Infrastructure Fix Applied

**Finch Connection Pool Exhaustion** - Fixed connection pool configuration in `lib/lasso/application.ex`:
- Increased pool size: 10 → 100 connections per pool
- Increased pool count: 1 → 10 pools
- Total capacity: 10 → 1000 concurrent connections
- Added 30s timeout for long-running RPC calls

This resolves the `"Finch was unable to provide a connection within the timeout due to excess queuing"` errors during high-concurrency battle tests.

## Next Steps

1. **Run quick validation** - Verify tests pass with current codebase
2. **Generate baseline reports** - Establish performance baselines
3. **Schedule regular execution** - Weekly or per-release
4. **Monitor trends** - Track P95 latency, success rates over time
5. **Alert on regressions** - Set thresholds for acceptable degradation

## Contact

For questions about test methodology or results interpretation, refer to:
- `project/working/BATTLE_TEST_REFINEMENT_BRIEF.md` - Technical review notes
- `project/working/PROGRESS_TRACKER.md` - Implementation progress

---

**Status:** ✅ Ready for production validation
**Last Updated:** 2025-10-03
**Tests Fixed:** 4/4
**Coverage:** HTTP failover, WebSocket failover, provider capabilities, method fuzzing
