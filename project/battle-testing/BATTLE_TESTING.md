## Integration-First + Observable Chaos Testing

**Your intuition is correct**. For this specific system, integration testing with data-driven validation will give you the most confidence per hour invested. Here's why and how.

---

## Analysis: Why Integration-First Makes Sense

### 1. **System Complexity Favors Integration Testing**

Your architecture has **13+ interconnected GenServers** with complex interaction patterns:

- `RequestPipeline` → `Selection` → `CircuitBreaker` → `Transport` → `Metrics` → `ProviderPool`
- `WSConnection` → `UpstreamSubscriptionPool` → `StreamCoordinator` → `GapFiller` → `ClientSubscriptionRegistry`

**The critical bugs won't be caught by unit tests.** They'll be in:

- Circuit breaker state transitions during concurrent failover
- Subscription continuity during provider reconnection
- Memory leaks in long-running WebSocket connections
- Race conditions in request correlation under load
- Metric recording accuracy during chaos scenarios

Your current **1490-line WS connection test** is excellent for unit-level behavior, but you have **zero tests** validating:

- "Does a subscription survive 3 provider failures in 30 seconds?"
- "Can the system handle 1000 concurrent requests with 2 providers failing?"
- "Do metrics remain accurate after 24 hours of operation?"

### 2. **Your Product Vision Demands Real-World Validation**

From `PRODUCT_VISION.md`, your core value proposition is:

> "99.99% uptime, bulletproof infrastructure for consumer-grade apps"

**Unit tests don't prove this.** Enterprise clients will ask:

- "Show me it works under real failure conditions"
- "What's your P95 latency under load with failover?"
- "How do subscriptions behave during provider flapping?"

You need **reproducible, observable proof** that your system works. Data-driven reports that show:

- "After 10,000 requests with 2 random provider failures, 99.8% succeeded, P95 latency was 150ms"
- "Subscription maintained continuity with only 2 missed blocks during failover"

### 3. **Elixir/OTP Gives You Superpowers for Chaos Testing**

Your supervision tree is **designed for chaos**. You can:

- Kill provider processes mid-request
- Simulate network partitions
- Crash circuit breakers
- Stop and restart chain supervisors

**This is your competitive advantage.** Don't just test happy paths—prove your fault tolerance works by **intentionally breaking things**.

---

## Recommended Testing Strategy

### **Tier 1: Integration Test Suite (Priority 1 - Next 2 Weeks)**

Build a **scenario-based integration test framework** that validates critical user journeys with real failure injection.

**Core Scenarios to Test:**

```elixir
# test/integration/resilience_scenarios_test.exs

test "HTTP request succeeds despite primary provider failure" do
  # Setup: 3 providers configured
  # Execute: Send request to "fastest" strategy
  # Inject: Kill primary provider mid-request
  # Assert: Request completes via failover within 2x normal latency
  # Assert: Circuit breaker opens on failed provider
  # Assert: Metrics record failover correctly
end

test "WebSocket subscription maintains continuity during provider reconnection" do
  # Setup: Subscribe to newHeads via Provider A
  # Execute: Receive 10 blocks
  # Inject: Disconnect Provider A, connect Provider B
  # Assert: No duplicate blocks delivered
  # Assert: Maximum 1 block gap (filled by backfill)
  # Assert: Subscription ID remains stable for client
end

test "System handles 1000 concurrent requests with 1 provider down" do
  # Setup: 3 providers (1 down)
  # Execute: Fire 1000 requests over 10 seconds
  # Assert: >99% success rate
  # Assert: P95 latency <300ms
  # Assert: Load balanced across 2 healthy providers
  # Assert: Circuit breaker prevents requests to down provider
end

test "Long-running subscription survives multiple provider failures" do
  # Setup: Subscribe to newHeads
  # Execute: Run for 5 minutes (simulated at 10x speed)
  # Inject: Kill provider every 60 seconds
  # Assert: Subscription never drops
  # Assert: All blocks delivered (deduped)
  # Assert: Maximum 2-block gaps per failover
end
```

**Implementation Pattern:**

```elixir
defmodule Lasso.Integration.ChaosHelper do
  # Orchestrate controlled chaos
  def with_flaky_provider(provider_id, opts, test_fn) do
    # Randomly kill/restart provider during test
    Task.async(fn -> flap_provider(provider_id, opts) end)
    test_fn.()
  end

  def simulate_network_partition(provider_ids, duration_ms) do
    # Drop packets to specific providers
  end

  def measure_scenario(name, test_fn) do
    # Record metrics: latency, success rate, failover count
    # Export to JSON for analysis
  end
end
```

### **Tier 2: Observable Load Testing (Priority 2 - Week 3)**

Build a **data-collection framework** that proves your system works under realistic load.

**Key Script: `scripts/battle_test.exs`**

```elixir
# Runs a 30-minute battle test with chaos injection
# Outputs: JSON report with metrics, charts, pass/fail SLOs

defmodule Lasso.BattleTest do
  @doc """
  Scenario: 10,000 requests over 30 minutes with:
  - 2 providers healthy, 1 flapping (up/down every 3 min)
  - Mix of methods: eth_blockNumber (70%), eth_getBalance (20%), eth_getLogs (10%)
  - 10 concurrent WebSocket subscriptions to newHeads

  Success Criteria (SLOs):
  - HTTP: ≥99% success, P95 ≤200ms
  - WS: ≥99.5% block delivery, ≤1% duplicates
  - Failover: Completes within 2x normal timeout
  - Circuit Breakers: Open within 5s of failure, recover within 60s
  """
  def run do
    # Setup
    configure_3_providers()
    start_chaos_injector(flap_interval: 180_000)

    # Execute
    results = %{
      http: run_http_load(),
      ws: run_ws_subscriptions(),
      failovers: track_failovers(),
      metrics: capture_system_metrics()
    }

    # Report
    generate_report(results)
    verify_slos(results)
  end
end

# Run: mix run scripts/battle_test.exs
# Output: priv/battle_test_results/2025-09-30-14-32.json
```

**Why This Matters:**

- **Automated proof** for enterprise clients: "Here's 30-minute test report showing 99.8% success"
- **Regression detection**: Run before each deploy, compare to baseline
- **Performance characterization**: Know your system's limits with data

### **Tier 3: Targeted Unit Tests (Priority 3 - Ongoing)**

Keep unit tests **focused and pragmatic**:

**DO write unit tests for:**

- Error normalization logic (`JError.from/2` edge cases)
- Selection strategy algorithms (deterministic with mocked metrics)
- Circuit breaker state machine (isolated from I/O)
- JSON-RPC compliance (batch requests, error codes)

**DON'T write unit tests for:**

- Complex GenServer interactions (test via integration)
- WebSocket lifecycle (too much mocking, test real connections)
- Metrics collection (validate in battle tests)

**Fix existing test compilation issues:**

```bash
# Week 1: Stabilize what exists
mix test test/lasso/rpc/circuit_breaker_test.exs
mix test test/lasso/rpc/selection_test.exs
# Remove/skip failing WS tests until integration suite is ready
```

---

## Specific Action Plan (Next 4 Weeks)

### **Week 1: Foundation**

- ✅ Fix compilation errors in existing tests
- ✅ Create `test/integration/` directory structure
- ✅ Build `ChaosHelper` module for controlled failures
- ✅ Write 3 core integration scenarios (HTTP failover, WS subscription, concurrent load)

### **Week 2: Coverage**

- ✅ Add 5 more integration scenarios (see Tier 1 above)
- ✅ Implement metrics collection in tests (`Telemetry` handlers)
- ✅ Create baseline SLOs (based on manual testing)

### **Week 3: Battle Testing**

- ✅ Build `battle_test.exs` script with chaos injection
- ✅ Run 3x 30-minute tests, tune SLOs based on results
- ✅ Generate first data-driven report (JSON + charts)

### **Week 4: Proof & Polish**

- ✅ Run 48-hour soak test (memory leaks, connection stability)
- ✅ Document test results in `project/VALIDATION_REPORT.md`
- ✅ Create demo video showing failover in action
- ✅ Build CI pipeline for integration tests (parallel execution)

---

## Why This Beats Pure Unit Testing

| Approach              | Time Investment | Confidence Gained                 | Maintenance Cost            |
| --------------------- | --------------- | --------------------------------- | --------------------------- |
| **More unit tests**   | 80 hours        | Medium (isolated behaviors)       | High (mocking complexity)   |
| **Integration-first** | 60 hours        | **Very High** (real interactions) | Medium (fewer moving parts) |
| **Battle testing**    | 40 hours        | **Extreme** (data-driven proof)   | Low (self-documenting)      |

**Your time is most valuable building integration + battle tests.**

---

## Concrete Deliverables for "Battle-Tested" Status

After 4 weeks, you'll have:

1. **Integration Test Suite** (~15 scenarios)

   - Covers critical failure modes
   - Runs in CI in 5 minutes
   - Green = ready to deploy

2. **Battle Test Reports** (3+ runs)

   - 30-minute chaos tests with SLO verification
   - JSON data + charts showing P95, success rates, failover behavior
   - **Show these to clients** as proof of reliability

3. **Validation Documentation**

   - `VALIDATION_REPORT.md` summarizing test results
   - Known limits (max RPS, failover latency bounds)
   - Failure modes and recovery behaviors

4. **CI/CD Integration**
   - Automated integration tests on PR
   - Nightly battle test runs
   - Alerts on SLO violations

---

## Tools & Libraries to Add

```elixir
# mix.exs
defp deps do
  [
    # ... existing deps
    {:stream_data, "~> 0.6", only: :test},  # Property-based testing
    {:benchee, "~> 1.3", only: [:dev, :test]},  # Micro-benchmarks
    {:briefly, "~> 0.4", only: :test},  # Temp file handling
    {:statistex, "~> 1.0", only: :test}  # P95, P99 calculations
  ]
end
```

---

## Final Recommendation

**Start with integration tests + battle testing immediately.** Unit tests are useful, but they won't prove your system is bulletproof.

Your competitive advantage is **provable reliability under chaos**. Lean into that.

In 4 weeks, you can have **data-driven proof** that your system handles real-world failure modes. That's **infinitely more valuable** than 100 more unit tests.

**Next step:** Create `test/integration/http_failover_test.exs` and `scripts/battle_test.exs` this week. Start building the proof.

Let me know if you want me to scaffold either of these files to get you started! 🚀
