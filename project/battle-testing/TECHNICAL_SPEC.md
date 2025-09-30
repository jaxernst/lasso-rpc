# Battle Testing Framework: Technical Specification

**Version:** 1.0  
**Date:** September 30, 2025  
**Status:** Ready for Implementation

---

## Overview

A pragmatic battle testing framework for Lasso RPC that validates reliability under chaos through composable primitives. Built on real production code paths with deep integration into existing telemetry and metrics infrastructure.

**Design Principles:**

- **Simple primitives** over complex frameworks
- **Observable by default** - leverage existing telemetry
- **Fast feedback** - mock providers for CI, real providers optional
- **Data-driven proof** - generate actionable reports with SLO verification

---

## Architecture

### Five Core Layers

```
┌─────────────────────────────────────┐
│ 5. Reporter                         │  JSON, Markdown, Charts
└─────────────────────────────────────┘
              ▲
┌─────────────────────────────────────┐
│ 4. Analyzer                         │  Stats, SLOs, Baselines
└─────────────────────────────────────┘
              ▲
┌─────────────────────────────────────┐
│ 3. Collector                        │  Telemetry, Metrics
└─────────────────────────────────────┘
              ▲
┌─────────────────────────────────────┐
│ 2. Workload                         │  HTTP, WS Load Generation
└─────────────────────────────────────┘
              ▲
┌─────────────────────────────────────┐
│ 1. Scenario                         │  Test Orchestration
└─────────────────────────────────────┘
```

### Module Organization

```
lib/livechain/battle/
├── scenario.ex              # Test definition & execution
├── workload.ex              # Load generation (HTTP, WS)
├── chaos.ex                 # Failure injection
├── collector.ex             # Event capture & aggregation
├── analyzer.ex              # Statistical analysis
├── reporter.ex              # Report generation
└── mock_provider.ex         # Controllable mock providers
```

---

## Core API

### 1. Scenario Definition

**Purpose:** Compose tests from reusable primitives.

```elixir
alias Livechain.Battle.{Scenario, Workload, Chaos, Collector, Analyzer, Reporter}

# Define test scenario
result =
  Scenario.new("HTTP Failover Under Load")
  |> Scenario.setup(fn ->
    # Start 3 mock providers
    MockProvider.start_providers([
      {:provider_a, latency: 50},
      {:provider_b, latency: 100},
      {:provider_c, latency: 150}
    ])
  end)
  |> Scenario.workload(fn ->
    Workload.http_constant(
      chain: "testchain",
      method: "eth_blockNumber",
      rate: 50,              # 50 req/s
      duration: 180_000      # 3 minutes
    )
  end)
  |> Scenario.chaos(
    Chaos.flap_provider("provider_a", down: 10_000, up: 60_000)
  )
  |> Scenario.collect([:requests, :circuit_breaker, :system])
  |> Scenario.slo(success_rate: 0.99, p95_latency_ms: 300)
  |> Scenario.run()

# Generate reports
Reporter.save_json(result, "priv/battle_results/")
Reporter.save_markdown(result, "priv/battle_results/")

# Assertions
assert result.passed?, result.summary
```

**Key Types:**

```elixir
defmodule Scenario do
  @type t :: %__MODULE__{
    name: String.t(),
    setup: (-> {:ok, context :: map()}),
    workload: (-> {:ok, results :: map()}),
    chaos: [chaos_spec()],
    collectors: [:requests | :circuit_breaker | :system],
    slos: keyword(),
    metadata: map()
  }
end
```

### 2. Workload Generation

**Purpose:** Generate realistic load with simple APIs.

```elixir
defmodule Workload do
  @doc """
  Generate HTTP requests at constant rate.

  ## Example
      Workload.http_constant(
        chain: "ethereum",
        method: "eth_blockNumber",
        params: [],
        rate: 100,              # requests per second
        duration: 60_000,       # 1 minute
        strategy: :fastest
      )

  Returns: %{total: 6000, succeeded: 5940, failed: 60, results: [...]}
  """
  def http_constant(opts)

  @doc """
  Generate HTTP requests with Poisson distribution (realistic traffic).

  Lambda = average rate, actual rate varies naturally.
  """
  def http_poisson(opts)

  @doc """
  Generate burst of requests (load spike simulation).
  """
  def http_burst(opts)

  @doc """
  Start WebSocket subscriptions and collect events.

  ## Example
      Workload.ws_subscribe(
        chain: "ethereum",
        subscription: "newHeads",
        count: 10,              # 10 concurrent subscriptions
        duration: 300_000       # 5 minutes
      )

  Returns: %{subscriptions: 10, events_received: 250, duplicates: 2}
  """
  def ws_subscribe(opts)
end
```

### 3. Chaos Injection

**Purpose:** Controlled failure injection during tests.

```elixir
defmodule Chaos do
  @doc """
  Flap provider (periodic disconnect/reconnect).

  ## Example
      Chaos.flap_provider("provider_a",
        down: 10_000,    # Down for 10s
        up: 60_000       # Up for 60s
      )
  """
  def flap_provider(provider_id, opts)

  @doc """
  Kill provider process (supervisor will restart).
  """
  def kill_provider(provider_id, delay_ms \\ 0)

  @doc """
  Degrade provider (inject latency, errors).
  """
  def degrade_provider(provider_id, opts)

  @doc """
  Simulate network partition (drop packets).
  """
  def partition(provider_ids, duration_ms)

  @doc """
  Random chaos - unpredictable failures.
  """
  def random_failures(providers, mean_time_between_ms)
end
```

### 4. Data Collection

**Purpose:** Capture telemetry events during test execution.

```elixir
defmodule Collector do
  @doc """
  Collect request metrics (latency, success rate, failovers).

  Automatically attaches to:
  - [:livechain, :rpc, :request, :start]
  - [:livechain, :rpc, :request, :stop]

  Captures: duration, result, provider, failover count
  """
  def collect_requests()

  @doc """
  Collect circuit breaker state changes.

  Tracks: open/close events, recovery time, rejected requests
  """
  def collect_circuit_breaker()

  @doc """
  Collect BEAM system metrics.

  Samples every 1s: memory, process count, scheduler utilization
  """
  def collect_system()

  @doc """
  Collect all (convenience).
  """
  def collect_all()
end
```

### 5. Analysis & Reporting

**Purpose:** Compute statistics and verify SLOs.

```elixir
defmodule Analyzer do
  @doc """
  Compute request statistics.

  Returns:
    %{
      total: 10000,
      succeeded: 9980,
      failed: 20,
      success_rate: 0.998,
      latency: %{p50: 45, p95: 120, p99: 250, max: 1200},
      failovers: %{count: 15, avg_latency_ms: 180}
    }
  """
  def analyze_requests(collected_data)

  @doc """
  Verify SLO compliance.

  ## Example
      Analyzer.verify_slos(analysis,
        success_rate: 0.99,
        p95_latency_ms: 200
      )

  Returns:
    %{
      passed: true,
      violations: [],
      summary: "All SLOs passed"
    }
  """
  def verify_slos(analysis, slo_specs)
end

defmodule Reporter do
  @doc """
  Save JSON report (machine-readable).
  """
  def save_json(result, output_dir)

  @doc """
  Save Markdown report (human-readable).

  Includes: SLO results, performance summary, system health
  """
  def save_markdown(result, output_dir)

  @doc """
  Compare against baseline (regression detection).
  """
  def compare_to_baseline(result, baseline_path)
end
```

---

## Integration with Existing System

### 1. Telemetry Events (Zero Duplication)

Battle tests use **production telemetry events**:

```elixir
# Production code emits:
:telemetry.execute([:livechain, :rpc, :request, :stop],
  %{duration_ms: 123},
  %{chain: "ethereum", method: "eth_blockNumber", result: :success}
)

# Battle test attaches handler:
Collector.collect_requests()  # Captures same events

# Validates that:
# 1. Telemetry is instrumented correctly
# 2. Metrics match production behavior
# 3. No test-only code paths
```

### 2. BenchmarkStore Integration

**Read from BenchmarkStore for realistic routing:**

```elixir
# Before test: Seed metrics
BenchmarkStore.record_rpc_call("testchain", "provider_a", "eth_blockNumber", 50, :success)
BenchmarkStore.record_rpc_call("testchain", "provider_b", "eth_blockNumber", 100, :success)

# During test: Selection.select_provider/3 uses these metrics
# "fastest" strategy picks provider_a (50ms avg)

# After test: Compare metrics
baseline = BenchmarkStore.get_provider_metrics("testchain", "provider_a")
assert baseline.avg_latency_ms < 60, "Latency regressed"
```

**Note:** Battle test metrics are isolated (separate chain name like `"testchain"`) to avoid polluting production data.

### 3. Mock Provider Backend

**Fast, deterministic testing with controllable providers:**

```elixir
defmodule MockProvider do
  @doc """
  Start mock HTTP server that responds to JSON-RPC requests.

  ## Options
  - :latency - base response time (ms)
  - :reliability - success probability (0.0-1.0)
  - :responses - method => response map

  ## Example
      MockProvider.start_providers([
        {:provider_a, latency: 50, reliability: 1.0},
        {:provider_b, latency: 100, reliability: 0.95}
      ])

  Providers are accessible via Lasso's normal routing:
    RequestPipeline.execute("testchain", "eth_blockNumber", [])
  """
  def start_providers(specs)

  # Runtime control for chaos injection
  def set_latency(provider_id, latency_ms)
  def set_reliability(provider_id, rate)
  def set_failure_mode(provider_id, :timeout | :error | :disconnect)
end
```

---

## Example: Complete Battle Test

```elixir
# test/battle/http_failover_test.exs
defmodule Livechain.Battle.HTTPFailoverTest do
  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Workload, Chaos, Reporter}

  @moduletag :battle
  @moduletag timeout: :infinity

  test "HTTP requests succeed despite provider failures" do
    result =
      Scenario.new("HTTP Failover Under Load")
      |> Scenario.setup(fn ->
        # Start 3 mock providers
        MockProvider.start_providers([
          {:provider_a, latency: 50, reliability: 1.0},
          {:provider_b, latency: 100, reliability: 1.0},
          {:provider_c, latency: 150, reliability: 1.0}
        ])

        # Seed BenchmarkStore so "fastest" selects provider_a
        BenchmarkStore.record_rpc_call("testchain", "provider_a", "eth_blockNumber", 50, :success)
        BenchmarkStore.record_rpc_call("testchain", "provider_b", "eth_blockNumber", 100, :success)
        BenchmarkStore.record_rpc_call("testchain", "provider_c", "eth_blockNumber", 150, :success)

        {:ok, %{chain: "testchain"}}
      end)
      |> Scenario.workload(fn ->
        # Generate 9000 requests over 3 minutes (50 req/s)
        Workload.http_constant(
          chain: "testchain",
          method: "eth_blockNumber",
          rate: 50,
          duration: 180_000
        )
      end)
      |> Scenario.chaos(
        # Provider A down for 10s, up for 60s (repeats)
        Chaos.flap_provider("provider_a", down: 10_000, up: 60_000)
      )
      |> Scenario.collect([:requests, :circuit_breaker, :system])
      |> Scenario.slo(
        success_rate: 0.99,
        p95_latency_ms: 300,
        max_failover_latency_ms: 2000
      )
      |> Scenario.run()

    # Save reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Assertions
    assert result.passed?, """
    Battle test failed!

    #{result.summary}

    See: priv/battle_results/#{result.report_id}.md
    """
  end
end
```

**Run it:**

```bash
# Run all battle tests
mix test --only battle

# Run specific test
mix test test/battle/http_failover_test.exs

# Generate baseline
mix battle.baseline
```

---

## File Organization

### Source Files

```
lib/livechain/battle/
├── scenario.ex              # 150 LOC - Orchestration
├── workload.ex              # 200 LOC - Load generation
├── chaos.ex                 # 150 LOC - Failure injection
├── collector.ex             # 200 LOC - Event capture
├── analyzer.ex              # 250 LOC - Statistics
├── reporter.ex              # 200 LOC - Report generation
└── mock_provider.ex         # 150 LOC - Mock backend
                             # ≈1300 LOC total
```

### Test Files

```
test/battle/
├── http_failover_test.exs
├── ws_subscription_test.exs
├── concurrent_load_test.exs
├── provider_degradation_test.exs
└── long_soak_test.exs
```

### Output Files

```
priv/battle_results/
├── 2025-09-30-14-32-http-failover.json
├── 2025-09-30-14-32-http-failover.md
├── baseline.json
└── regression_report.md
```

---

## Data Flow

```
┌──────────────┐
│ Battle Test  │
└──────┬───────┘
       │
       ├─ Start MockProviders
       │       │
       ├─ Generate Workload ──────┐
       │       │                   │
       ├─ Inject Chaos            │
       │       │                   │
       │       ▼                   ▼
       │  RequestPipeline ──> [telemetry events]
       │       │                   │
       │       ├─ Selection        │
       │       ├─ CircuitBreaker   │
       │       ├─ Transport        │
       │       └─ Metrics          │
       │                           │
       │                           ▼
       ├─ Collector ◄──────── [aggregates]
       │       │
       │       ▼
       ├─ Analyzer ──────────> [stats, SLOs]
       │       │
       │       ▼
       └─ Reporter ──────────> [JSON, MD]
```

**Key Insight:** Battle tests exercise the **exact same code paths** as production, just with mock providers and telemetry collection enabled.

---

## Performance Characteristics

### Test Execution Speed

- **Fast test** (mock, 1 min, 100 req/s): ~60s total
- **Medium test** (mock, 5 min, 100 req/s): ~300s total
- **Long test** (mock, 30 min, 100 req/s): ~1800s total

### Resource Usage

- **Memory:** ~50MB per test (collector data)
- **CPU:** ~10-20% (workload generation)
- **Disk:** ~1MB per report

### Bottlenecks

- **Collector storage** limits test duration (keep aggregates only for long tests)
- **Mock provider concurrency** limits max RPS (~500 req/s per provider)

---

## Design Decisions

### 1. Mock Providers by Default

**Decision:** Use fast mock providers for CI, optional real providers for nightly.

**Rationale:**

- CI needs fast (<5 min), deterministic tests
- Mock providers give precise control over latency, failures
- Real providers for occasional validation only

**Implementation:**

```elixir
# Default: mock
MockProvider.start_providers([...])

# Optional: real (via env var)
if System.get_env("BATTLE_REAL_PROVIDERS") == "true" do
  RealProvider.start_from_config()
end
```

### 2. Streaming Data Collection

**Decision:** Aggregate metrics in-memory, optionally store raw events.

**Rationale:**

- Long tests (30+ min) can generate millions of events
- Most analysis only needs aggregates (percentiles, counts)
- Raw events optional for debugging

**Implementation:**

```elixir
Collector.collect_requests(store_raw: false)  # Default: aggregates only
Collector.collect_requests(store_raw: true)   # Keep all events (debugging)
```

### 3. No Time Acceleration

**Decision:** Use real time for all tests.

**Rationale:**

- Simpler implementation (no time mocking)
- More realistic (catches timer bugs)
- Tests run fast enough with mocks (5-30 min acceptable)

**Alternative:** Run shorter tests frequently (5 min CI), longer tests nightly (30 min+).

### 4. SLO-Driven Assertions

**Decision:** Define SLOs in test, auto-verify in assertions.

**Rationale:**

- Clear pass/fail criteria
- Consistent across tests
- Enables regression detection

**Implementation:**

```elixir
result = Scenario.new("...")
  |> Scenario.slo(
    success_rate: 0.99,      # ≥99% requests succeed
    p95_latency_ms: 200,     # P95 ≤200ms
    max_failover_ms: 2000    # Failover completes in 2s
  )
  |> Scenario.run()

assert result.passed?  # Auto-verifies all SLOs
```

---

## Next Steps

See `IMPLEMENTATION_PLAN.md` for phased rollout and handoff instructions.
