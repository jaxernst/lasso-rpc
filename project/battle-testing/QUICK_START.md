# Battle Testing: Quick Start Guide

**Get your first battle test running in 30 minutes.**

---

## What is Battle Testing?

Battle testing validates your system's reliability under chaos by:

1. Generating realistic load (HTTP/WS requests)
2. Injecting failures (provider crashes, network issues)
3. Measuring behavior (latency, success rate, failover)
4. Verifying SLOs (success rate ≥99%, P95 latency ≤200ms)

**Output:** Data-driven proof that your system handles failure gracefully.

---

## Prerequisites

```bash
# Ensure you have Elixir 1.14+ and OTP 25+
elixir --version

# Install dependencies
cd /path/to/lasso-rpc
mix deps.get
```

---

## Step 1: Create Your First Battle Test (5 min)

Create `test/battle/my_first_test.exs`:

```elixir
defmodule Livechain.Battle.MyFirstTest do
  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Workload, MockProvider, Reporter}

  @moduletag :battle
  @moduletag timeout: :infinity

  test "basic HTTP load test" do
    result =
      Scenario.new("My First Battle Test")
      |> Scenario.setup(fn ->
        # Start 1 mock provider
        MockProvider.start_providers([
          {:provider_a, latency: 50, reliability: 1.0}
        ])

        {:ok, %{chain: "testchain"}}
      end)
      |> Scenario.workload(fn ->
        # Generate 300 requests over 30 seconds (10 req/s)
        Workload.http_constant(
          chain: "testchain",
          method: "eth_blockNumber",
          rate: 10,
          duration: 30_000
        )
      end)
      |> Scenario.collect([:requests])
      |> Scenario.slo(success_rate: 0.99)  # Require 99% success
      |> Scenario.run()

    # Generate reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Assertions
    assert result.passed?, result.summary
  end
end
```

---

## Step 2: Run the Test (2 min)

```bash
# Run your battle test
mix test test/battle/my_first_test.exs --only battle

# Output:
# .
# Finished in 30.5 seconds
# 1 test, 0 failures
```

---

## Step 3: View the Report (3 min)

```bash
# Find the latest report
ls -lt priv/battle_results/

# View markdown report
cat priv/battle_results/latest.md
```

**Example Output:**

```markdown
# Battle Test Report: My First Battle Test

**Date:** 2025-09-30 14:32:15
**Duration:** 30s
**Result:** ✅ PASS

## SLO Compliance

| Metric       | Required | Actual | Status |
| ------------ | -------- | ------ | ------ |
| Success Rate | ≥99%     | 100%   | ✅     |

## Performance Summary

- Total Requests: 300
- Succeeded: 300
- Failed: 0
- Success Rate: 100%
- P50 Latency: 52ms
- P95 Latency: 58ms
- P99 Latency: 62ms
```

---

## Step 4: Add Chaos (10 min)

Modify your test to inject failures:

```elixir
test "HTTP load with provider failures" do
  result =
    Scenario.new("Failover Test")
    |> Scenario.setup(fn ->
      # Start 2 mock providers
      MockProvider.start_providers([
        {:provider_a, latency: 50, reliability: 1.0},
        {:provider_b, latency: 100, reliability: 1.0}
      ])

      # Seed BenchmarkStore so provider_a is "fastest"
      BenchmarkStore.record_rpc_call("testchain", "provider_a", "eth_blockNumber", 50, :success)
      BenchmarkStore.record_rpc_call("testchain", "provider_b", "eth_blockNumber", 100, :success)

      {:ok, %{chain: "testchain"}}
    end)
    |> Scenario.workload(fn ->
      Workload.http_constant(
        chain: "testchain",
        method: "eth_blockNumber",
        rate: 50,
        duration: 180_000,  # 3 minutes
        strategy: :fastest
      )
    end)
    |> Scenario.chaos(
      # Kill provider_a after 30 seconds
      Chaos.kill_provider("provider_a", delay: 30_000)
    )
    |> Scenario.collect([:requests, :circuit_breaker])
    |> Scenario.slo(
      success_rate: 0.99,
      p95_latency_ms: 300
    )
    |> Scenario.run()

  Reporter.save_markdown(result, "priv/battle_results/")
  assert result.passed?, result.summary
end
```

Run it:

```bash
mix test test/battle/my_first_test.exs::2 --only battle
```

Check the report - you should see:

- Some requests failed over to provider_b
- Circuit breaker opened/closed
- Overall success rate still ≥99%

---

## Step 5: Add More Scenarios (10 min)

Create additional tests for different scenarios:

### Test 2: WebSocket Subscriptions

```elixir
test "WebSocket subscription continuity" do
  result =
    Scenario.new("WS Subscription Test")
    |> Scenario.setup(fn ->
      MockProvider.start_providers([
        {:provider_a, latency: 50, reliability: 1.0}
      ])
      {:ok, %{chain: "testchain"}}
    end)
    |> Scenario.workload(fn ->
      Workload.ws_subscribe(
        chain: "testchain",
        subscription: "newHeads",
        count: 5,           # 5 concurrent subscriptions
        duration: 60_000    # 1 minute
      )
    end)
    |> Scenario.collect([:websocket])
    |> Scenario.slo(
      subscription_uptime: 0.99,
      max_duplicate_rate: 0.01
    )
    |> Scenario.run()

  assert result.passed?
end
```

### Test 3: Concurrent Load

```elixir
test "high concurrency load" do
  result =
    Scenario.new("Concurrent Load Test")
    |> Scenario.setup(fn ->
      MockProvider.start_providers([
        {:provider_a, latency: 50, reliability: 0.98},
        {:provider_b, latency: 100, reliability: 0.95},
        {:provider_c, latency: 150, reliability: 0.99}
      ])
      {:ok, %{chain: "testchain"}}
    end)
    |> Scenario.workload(fn ->
      Workload.http_constant(
        chain: "testchain",
        method: "eth_blockNumber",
        rate: 200,          # 200 req/s
        duration: 60_000    # 1 minute
      )
    end)
    |> Scenario.collect([:requests, :system])
    |> Scenario.slo(
      success_rate: 0.95,
      p95_latency_ms: 500,
      max_memory_mb: 500
    )
    |> Scenario.run()

  assert result.passed?
end
```

---

## Common Patterns

### Pattern 1: Seed Metrics for Routing

```elixir
# Make provider_a "fastest" for :fastest strategy
BenchmarkStore.record_rpc_call("testchain", "provider_a", "eth_blockNumber", 50, :success)
BenchmarkStore.record_rpc_call("testchain", "provider_b", "eth_blockNumber", 100, :success)
```

### Pattern 2: Multiple Chaos Events

```elixir
|> Scenario.chaos(Chaos.kill_provider("provider_a", delay: 30_000))
|> Scenario.chaos(Chaos.degrade_provider("provider_b", latency: 500, after: 60_000))
|> Scenario.chaos(Chaos.flap_provider("provider_c", down: 5_000, up: 30_000))
```

### Pattern 3: Custom Assertions

```elixir
# Beyond SLO verification, add custom checks
assert result.passed?
assert result.analysis.failover_count > 0, "Expected at least one failover"
assert result.analysis.circuit_breaker_changes >= 2, "Expected CB to open and close"
```

---

## Troubleshooting

### Test Fails: "No providers available"

**Issue:** Mock providers didn't start correctly.

**Fix:** Check that providers are registered in ConfigStore:

```elixir
MockProvider.start_providers([...])
|> tap(fn providers ->
  Enum.each(providers, fn {id, port} ->
    IO.puts("Started #{id} on port #{port}")
  end)
end)
```

### Test Hangs

**Issue:** Workload duration too long or rate too high.

**Fix:** Start with small values (10 req/s, 30s duration), then scale up.

### SLO Fails Unexpectedly

**Issue:** Thresholds too tight or chaos too aggressive.

**Fix:**

- Loosen SLOs initially (95% → 99%)
- Reduce chaos frequency
- Check mock provider reliability settings

### Reports Not Generated

**Issue:** Output directory doesn't exist.

**Fix:**

```bash
mkdir -p priv/battle_results
```

---

## Next Steps

1. **Read the full spec:** `TECHNICAL_SPEC.md` for API details
2. **Review implementation plan:** `IMPLEMENTATION_PLAN.md` for phased rollout
3. **Write more tests:** Cover your critical failure modes
4. **Set up CI:** Automate battle tests in your pipeline

---

## Useful Commands

```bash
# Run all battle tests
mix test --only battle

# Run fast tests only (CI)
mix test --only battle_fast

# Generate baseline
mix battle.baseline

# Compare to baseline
mix battle.compare

# Clean up reports
rm -rf priv/battle_results/*
```

---

## Example: Real-World Battle Test

Here's a complete example that mimics production behavior:

```elixir
defmodule Livechain.Battle.ProductionLikeTest do
  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Workload, Chaos, Reporter}

  @moduletag :battle
  @moduletag timeout: :infinity

  test "production-like scenario: mixed load with flapping provider" do
    result =
      Scenario.new("Production Simulation")
      |> Scenario.setup(fn ->
        # Start 3 providers with realistic characteristics
        MockProvider.start_providers([
          {:alchemy, latency: 45, reliability: 0.999},
          {:infura, latency: 60, reliability: 0.998},
          {:ankr, latency: 80, reliability: 0.95}
        ])

        # Seed realistic metrics
        seed_realistic_metrics("testchain")

        {:ok, %{chain: "testchain"}}
      end)
      |> Scenario.workload(fn ->
        # Mix of methods (like production)
        Workload.http_mixed(
          chain: "testchain",
          methods: [
            {"eth_blockNumber", 0.4},
            {"eth_getBalance", 0.3},
            {"eth_getLogs", 0.2},
            {"eth_call", 0.1}
          ],
          rate: {:poisson, lambda: 100},  # Realistic traffic
          duration: 300_000,               # 5 minutes
          strategy: :fastest
        )
      end)
      |> Scenario.chaos([
        # Ankr flaps (common in production)
        Chaos.flap_provider("ankr", down: 15_000, up: 90_000),
        # Infura degrades temporarily
        Chaos.degrade_provider("infura", latency: 300, after: 120_000, duration: 30_000)
      ])
      |> Scenario.collect([:requests, :circuit_breaker, :system])
      |> Scenario.slo(
        success_rate: 0.995,
        p95_latency_ms: 250,
        p99_latency_ms: 500,
        max_failover_latency_ms: 2000
      )
      |> Scenario.run()

    # Generate comprehensive report
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")
    Reporter.save_html(result, "priv/battle_results/")

    # Verify SLOs
    assert result.passed?, """
    Production simulation failed!

    #{result.summary}

    Full report: priv/battle_results/#{result.report_id}.html
    """

    # Additional production-like assertions
    assert result.analysis.total_requests > 25_000, "Expected ~30k requests"
    assert result.analysis.failover_count > 0, "Expected failovers during flapping"
    assert result.analysis.peak_memory_mb < 500, "Memory leak detected"
  end

  defp seed_realistic_metrics(chain) do
    # Simulate 1 hour of traffic to build realistic metrics
    providers = [
      {"alchemy", 45, 0.999},
      {"infura", 60, 0.998},
      {"ankr", 80, 0.95}
    ]

    Enum.each(providers, fn {id, latency, reliability} ->
      Enum.each(1..100, fn _ ->
        result = if :rand.uniform() < reliability, do: :success, else: :error
        BenchmarkStore.record_rpc_call(chain, id, "eth_blockNumber", latency, result)
      end)
    end)
  end
end
```

This test simulates real production conditions and validates your system can handle them reliably.

---

**Ready to battle test your system?** Start with the simple example, then build up to production-like scenarios. 🚀
