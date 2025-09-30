# Battle Testing Framework: Implementation Plan

**Version:** 1.0  
**Date:** September 30, 2025  
**Audience:** Implementation Team

---

## Overview

This document provides a clear, phased plan to implement the battle testing framework over 4 weeks. Each phase has specific deliverables, acceptance criteria, and can be shipped independently.

**Timeline:** 4 weeks (80-100 hours)  
**Team Size:** 1-2 engineers  
**Risk:** Low (isolated from production, incremental delivery)

---

## Phase 1: Core Primitives (Week 1)

**Goal:** Build foundational modules that work end-to-end.

### Deliverables

1. **Scenario API** (`lib/livechain/battle/scenario.ex`)

   - Struct definition with setup/workload/chaos/collect/slo
   - `Scenario.run/1` orchestration
   - Basic error handling

2. **Mock Provider** (`lib/livechain/battle/mock_provider.ex`)

   - HTTP server using `Plug.Cowboy`
   - Configurable latency, reliability
   - JSON-RPC response generation

3. **Workload Generator** (`lib/livechain/battle/workload.ex`)

   - `Workload.http_constant/1` - fixed RPS
   - Rate limiting with `Process.send_after/3`
   - Result collection

4. **Collector** (`lib/livechain/battle/collector.ex`)

   - `Collector.collect_requests/0` - telemetry attachment
   - Event aggregation (counts, durations)
   - `Collector.get_data/1` retrieval

5. **Analyzer** (`lib/livechain/battle/analyzer.ex`)

   - Percentile calculation (P50, P95, P99)
   - Success rate computation
   - Basic SLO verification

6. **Reporter** (`lib/livechain/battle/reporter.ex`)
   - `Reporter.save_json/2` - structured output
   - Basic statistics included

### Acceptance Criteria

- [ ] One complete battle test runs successfully
- [ ] Mock provider responds to RPC requests
- [ ] Telemetry events captured during test
- [ ] JSON report generated with stats
- [ ] Test completes in <5 minutes

### Example Test (Milestone)

```elixir
# test/battle/phase1_test.exs
test "basic HTTP load test" do
  result =
    Scenario.new("Phase 1 Milestone")
    |> Scenario.setup(fn ->
      MockProvider.start_providers([{:provider_a, latency: 50}])
      {:ok, %{chain: "testchain"}}
    end)
    |> Scenario.workload(fn ->
      Workload.http_constant(
        chain: "testchain",
        method: "eth_blockNumber",
        rate: 10,
        duration: 30_000
      )
    end)
    |> Scenario.collect([:requests])
    |> Scenario.slo(success_rate: 0.99)
    |> Scenario.run()

  assert result.passed?
  assert File.exists?("priv/battle_results/#{result.report_id}.json")
end
```

### Implementation Notes

**Mock Provider Details:**

```elixir
defmodule Livechain.Battle.MockProvider do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/" do
    # Parse JSON-RPC request
    # Sleep for configured latency
    # Return success/error based on reliability
    # Track requests for verification
  end

  def start_providers(specs) do
    Enum.map(specs, fn {provider_id, opts} ->
      {:ok, _pid} = Plug.Cowboy.http(__MODULE__, opts, port: random_port())
      # Register provider in ConfigStore
      # Return provider_id => port mapping
    end)
  end
end
```

**Time Estimate:** 30-40 hours

---

## Phase 2: Chaos & Integration (Week 2)

**Goal:** Add failure injection and deep system integration.

### Deliverables

1. **Chaos Module** (`lib/livechain/battle/chaos.ex`)

   - `Chaos.flap_provider/2` - periodic restart
   - `Chaos.kill_provider/1` - process termination
   - `Chaos.degrade_provider/2` - latency injection
   - Chaos orchestration (background task)

2. **BenchmarkStore Integration**

   - Helper to seed metrics before test
   - Comparison after test (regression detection)
   - Isolated chain names for test data

3. **Additional Collectors**

   - `Collector.collect_circuit_breaker/0` - state changes
   - `Collector.collect_system/0` - BEAM metrics

4. **Enhanced Workloads**

   - `Workload.http_poisson/1` - realistic traffic
   - `Workload.ws_subscribe/1` - subscription testing

5. **Markdown Reporter**
   - `Reporter.save_markdown/2` - human-readable
   - Include SLO table, performance summary

### Acceptance Criteria

- [ ] Chaos injection works during test
- [ ] Circuit breaker events captured
- [ ] System metrics (memory, processes) recorded
- [ ] WebSocket subscription test passes
- [ ] Markdown report generated

### Example Test (Milestone)

```elixir
test "HTTP failover with chaos" do
  result =
    Scenario.new("Failover Test")
    |> Scenario.setup(fn ->
      MockProvider.start_providers([
        {:provider_a, latency: 50},
        {:provider_b, latency: 100}
      ])

      # Seed metrics so provider_a is "fastest"
      BenchmarkStore.record_rpc_call("testchain", "provider_a", "eth_blockNumber", 50, :success)
      BenchmarkStore.record_rpc_call("testchain", "provider_b", "eth_blockNumber", 100, :success)

      {:ok, %{chain: "testchain"}}
    end)
    |> Scenario.workload(fn ->
      Workload.http_constant(
        chain: "testchain",
        method: "eth_blockNumber",
        rate: 50,
        duration: 180_000,
        strategy: :fastest
      )
    end)
    |> Scenario.chaos(
      Chaos.flap_provider("provider_a", down: 10_000, up: 60_000)
    )
    |> Scenario.collect([:requests, :circuit_breaker])
    |> Scenario.slo(
      success_rate: 0.99,
      p95_latency_ms: 300
    )
    |> Scenario.run()

  assert result.passed?
  assert result.analysis.failover_count > 0
  assert result.analysis.circuit_breaker_changes >= 2
end
```

**Time Estimate:** 25-30 hours

---

## Phase 3: Analysis & Reporting (Week 3)

**Goal:** Production-quality analysis and actionable reports.

### Deliverables

1. **Advanced Statistics**

   - Percentile calculation with confidence intervals
   - Failover analysis (count, avg latency)
   - Circuit breaker behavior (time open, recovery)

2. **Baseline Comparison**

   - `Reporter.save_baseline/1` - store baseline
   - `Reporter.compare_to_baseline/2` - regression detection
   - Automated threshold checks (±10% performance)

3. **Chart Generation**

   - Latency histogram (using ASCII or vega-lite)
   - Timeseries (requests/s over time)
   - Success rate over time

4. **HTML Reports**

   - `Reporter.save_html/2` - rich interactive report
   - Embedded charts
   - Collapsible sections for raw data

5. **Test Suite**
   - 5 comprehensive battle tests covering:
     - HTTP failover
     - WS subscription continuity
     - Concurrent load
     - Provider degradation
     - Long soak test (30 min)

### Acceptance Criteria

- [ ] Regression detection works (baseline comparison)
- [ ] Charts generated and embedded in reports
- [ ] HTML report renders correctly
- [ ] 5 battle tests pass consistently
- [ ] Reports demonstrate clear SLO pass/fail

### Example Output

**Markdown Report:**

```markdown
# Battle Test Report: HTTP Failover Under Load

**Date:** 2025-09-30 14:32:15  
**Duration:** 180s  
**Result:** ✅ PASS

## SLO Compliance

| Metric       | Required | Actual | Status |
| ------------ | -------- | ------ | ------ |
| Success Rate | ≥99%     | 99.8%  | ✅     |
| P95 Latency  | ≤300ms   | 245ms  | ✅     |
| Max Failover | ≤2000ms  | 1850ms | ✅     |

## Performance Summary

### HTTP Requests

- Total: 9,000
- Success Rate: 99.8%
- P50 Latency: 52ms
- P95 Latency: 245ms
- P99 Latency: 890ms

### Failovers

- Total Failovers: 15
- Avg Failover Latency: 185ms
- Success Rate: 100%

### Circuit Breakers

- State Changes: 6 (3 open, 3 close)
- Time Open: 30,245ms
- Rejected Requests: 12

## System Health

- Peak Memory: 245MB
- Peak Processes: 1,234
- Avg CPU: 15%
```

**Time Estimate:** 25-30 hours

---

## Phase 4: CI/CD Integration (Week 4)

**Goal:** Automated testing in CI pipeline.

### Deliverables

1. **Mix Task**

   - `mix battle` - run all battle tests
   - `mix battle.baseline` - generate baseline
   - `mix battle.compare` - compare to baseline

2. **GitHub Actions Workflow**

   - Fast tests on PR (<5 min)
   - Full suite on merge to main
   - Nightly long tests (30 min+)

3. **Notification Integration**

   - Slack webhook on failure
   - GitHub PR comment with summary
   - Email digest for nightly tests

4. **Performance Tracking**

   - Store baselines in git (JSON)
   - Track performance over time
   - Alert on regressions

5. **Documentation**
   - README with usage examples
   - CI setup guide
   - Troubleshooting guide

### Acceptance Criteria

- [ ] Battle tests run in CI automatically
- [ ] PR comment shows test summary
- [ ] Baseline stored and tracked
- [ ] Regression alerts work
- [ ] Documentation complete

### CI Workflow Example

```yaml
# .github/workflows/battle-tests.yml
name: Battle Tests

on:
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 2 * * *" # Nightly at 2 AM

jobs:
  fast-battle:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "26"
          elixir-version: "1.18"

      - name: Install dependencies
        run: mix deps.get

      - name: Run fast battle tests
        run: mix battle --fast

      - name: Compare to baseline
        run: mix battle.compare

      - name: Post PR comment
        uses: actions/github-script@v6
        with:
          script: |
            const report = require('./priv/battle_results/latest.json')
            // Post summary as PR comment

  full-battle:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    steps:
      - uses: actions/checkout@v3

      - name: Run full battle suite
        run: mix battle --full
        timeout-minutes: 60

      - name: Upload reports
        uses: actions/upload-artifact@v3
        with:
          name: battle-reports
          path: priv/battle_results/

      - name: Send Slack notification
        if: failure()
        run: |
          curl -X POST ${{ secrets.SLACK_WEBHOOK }} \
            -d '{"text": "Battle tests failed! Check CI for details."}'
```

**Time Estimate:** 20-25 hours

---

## Dependencies

### Required Libraries

Add to `mix.exs`:

```elixir
defp deps do
  [
    # Existing deps...

    # Battle testing (only :test env)
    {:plug_cowboy, "~> 2.7", only: :test},     # Mock providers
    {:jason, "~> 1.4"},                        # JSON encoding
    {:statistex, "~> 1.0", only: :test},       # Percentile calculation
    {:vega_lite, "~> 0.1", only: [:dev, :test]} # Charts (optional)
  ]
end
```

### System Requirements

- Elixir 1.14+
- OTP 25+
- 4GB RAM (for long tests)
- ~100MB disk (for reports)

---

## Risk Mitigation

### Risk 1: Mock Provider Unrealistic

**Mitigation:** Add optional real provider support for periodic validation.

```elixir
# CI: Fast mocks
BATTLE_BACKEND=mock mix test --only battle

# Nightly: Real providers
BATTLE_BACKEND=real mix test --only battle
```

### Risk 2: Test Duration

**Mitigation:** Split into fast (<5 min) and slow (>5 min) tests with tags.

```elixir
@tag :battle_fast   # Runs in CI
@tag :battle_slow   # Runs nightly
```

### Risk 3: Flaky Tests

**Mitigation:**

- Use deterministic mock providers
- Avoid hard-coded timeouts (use `eventually/2` helper)
- Generous SLO thresholds initially (99% vs 99.9%)

---

## Success Metrics

After 4 weeks, we should have:

### Quantitative

- [ ] 5-10 battle tests implemented
- [ ] Tests run in CI (<5 min for fast suite)
- [ ] 100% passing rate (non-flaky)
- [ ] Coverage of critical failure modes:
  - [ ] Provider failover
  - [ ] Circuit breaker behavior
  - [ ] WebSocket continuity
  - [ ] Concurrent load

### Qualitative

- [ ] Clear documentation for writing new tests
- [ ] Actionable reports (JSON + Markdown + HTML)
- [ ] Regression detection working
- [ ] Team confident in system reliability

### Business Impact

- [ ] Data-driven proof for enterprise clients
- [ ] Automated reliability validation before deploy
- [ ] Known performance characteristics documented

---

## Handoff Checklist

### For Implementation Team

- [ ] Clone repository
- [ ] Review `TECHNICAL_SPEC.md` (architecture)
- [ ] Review this document (phases)
- [ ] Set up dev environment (`mix deps.get`)
- [ ] Create `lib/livechain/battle/` directory
- [ ] Start with Phase 1, Week 1 deliverables

### For Project Manager

- [ ] Allocate 1-2 engineers for 4 weeks
- [ ] Schedule weekly demos (end of each phase)
- [ ] Prepare for nightly CI runs (cost ~$10/month)
- [ ] Plan customer demo (Week 4, show reports)

### For Code Reviewers

- [ ] Ensure tests are fast (<5 min for CI)
- [ ] Verify mock providers are controllable
- [ ] Check SLOs are realistic (not too tight)
- [ ] Validate reports are actionable

---

## Iteration Plan

### Post-MVP (Week 5+)

**Quick Wins:**

- Add more chaos patterns (network latency, packet loss)
- Implement HTML charts (vega-lite)
- Add property-based testing with StreamData
- Create visual dashboard for results

**Long-term:**

- Real provider support for nightly tests
- Performance trend tracking over weeks/months
- Automated tuning of SLOs based on history
- Integration with monitoring (Datadog, New Relic)

---

## Questions & Support

**Technical Questions:**

- Review `TECHNICAL_SPEC.md` for API details
- Check existing telemetry handlers in `lib/livechain/telemetry.ex`
- See `lib/livechain/benchmarking/benchmark_store.ex` for metrics integration

**Implementation Help:**

- Week 1: Focus on getting one test working end-to-end
- Week 2: Add chaos, iterate on collector
- Week 3: Polish reports, add analysis
- Week 4: Automate in CI

**Blockers:**

- If mock providers are slow: Consider in-memory response (no HTTP)
- If tests are flaky: Increase timeouts, add retry logic
- If reports are unclear: Get feedback from team/stakeholders

---

## Appendix: Quick Reference

### Running Battle Tests

```bash
# Run all battle tests
mix test --only battle

# Run specific test
mix test test/battle/http_failover_test.exs

# Generate baseline
mix battle.baseline

# Compare to baseline
mix battle.compare

# Run with real providers (nightly)
BATTLE_BACKEND=real mix test --only battle
```

### File Locations

```
lib/livechain/battle/       # Source code
test/battle/                 # Battle tests
priv/battle_results/         # Reports (gitignored)
priv/battle_baseline.json    # Baseline (committed)
```

### Key Modules

- `Scenario` - Test orchestration
- `Workload` - Load generation
- `Chaos` - Failure injection
- `Collector` - Event capture
- `Analyzer` - Statistics
- `Reporter` - Report generation
- `MockProvider` - Mock backend

---

**Ready to implement?** Start with Phase 1, Week 1. Build the first working test, then iterate from there. Good luck! 🚀
