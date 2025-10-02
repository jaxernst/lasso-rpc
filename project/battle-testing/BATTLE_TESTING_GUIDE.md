# Lasso RPC Battle Testing Guide

**Prove your RPC aggregator works under chaos with data-driven validation.**

---

## What is Battle Testing?

Battle testing validates Lasso RPC's reliability under realistic failure conditions by:

1. **Generating production-like load** - HTTP requests and WebSocket subscriptions
2. **Injecting controlled chaos** - Provider failures, network issues, high latency
3. **Measuring system behavior** - Latency, failover, circuit breakers, success rates
4. **Verifying SLOs** - Data-driven proof that reliability claims hold under stress

**Output:** JSON and Markdown reports proving your system handles real-world chaos.

---

## Quick Start (5 Minutes)

### Prerequisites

```bash
# Ensure Elixir 1.14+ and OTP 25+
elixir --version

# Install dependencies
mix deps.get

# Create results directory
mkdir -p priv/battle_results
```

### Run Your First Test

```bash
# Run the smoke test with real providers
mix test test/battle/real_provider_failover_test.exs:139 --only quick

# View the report
cat priv/battle_results/latest.md
```

**Expected output:** Test passes with 99%+ success rate using real Ethereum providers.

---

## Test Architecture

### Core Components

```
Scenario         → Orchestrates test flow
  ├─> Setup      → Register providers, seed metrics
  ├─> Workload   → Generate HTTP/WS load
  ├─> Chaos      → Inject failures (optional)
  ├─> Collect    → Capture telemetry
  ├─> Analyze    → Compute statistics
  └─> Report     → Generate JSON/Markdown
```

### Simple Example

```elixir
defmodule MyBattleTest do
  use ExUnit.Case, async: false

  alias Lasso.Battle.{Scenario, Workload, Reporter, SetupHelper}

  @moduletag :battle
  @moduletag timeout: :infinity

  test "provider failover maintains SLOs" do
    result =
      Scenario.new("Failover Test")
      |> Scenario.setup(fn ->
        # Register real providers dynamically
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # 200 requests over 60 seconds at 10 req/s
        Workload.http_constant(
          chain: "ethereum",
          method: "eth_blockNumber",
          rate: 10,
          duration: 60_000,
          strategy: :fastest
        )
      end)
      |> Scenario.collect([:requests, :circuit_breaker])
      |> Scenario.slo(
        success_rate: 0.99,
        p95_latency_ms: 1000
      )
      |> Scenario.run()

    # Save reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Assert SLOs passed
    assert result.passed?, result.summary
  end
end
```

---

## Real Provider Setup

### Strategy: Use Real Providers, Not Mocks

Battle tests use **real external RPC providers** to validate production behavior:

- ✅ Tests actual failover, not simulated behavior
- ✅ Validates real circuit breaker integration
- ✅ Captures production telemetry events
- ✅ Proves system works with actual network latency/failures

### Dynamic Provider Registration

Use `SetupHelper` to register providers at test runtime:

```elixir
setup do
  Application.ensure_all_started(:lasso)

  on_exit(fn ->
    # Cleanup registered providers
    SetupHelper.cleanup_providers("ethereum", ["llamarpc", "ankr"])
  end)

  :ok
end

test "my test" do
  # Register real providers (no config file changes needed)
  SetupHelper.setup_providers("ethereum", [
    {:real, "llamarpc", "https://eth.llamarpc.com"},
    {:real, "ankr", "https://rpc.ankr.com/eth"},
    {:real, "publicnode", "https://ethereum-rpc.publicnode.com"}
  ])

  # Seed performance metrics for routing
  SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
    {"llamarpc", 80},
    {"ankr", 120},
    {"publicnode", 150}
  ])

  # ... rest of test
end
```

**Why this works:**

- `SetupHelper.setup_providers` registers providers in `ProviderPool` at runtime
- Creates circuit breakers automatically
- No config file modifications needed
- Clean teardown in `on_exit`

### HTTP Client Override Pattern

Tests run in `:test` environment which uses `HttpClientMock` by default. Override for real requests:

```elixir
setup_all do
  # Override to use real HTTP client
  original_client = Application.get_env(:lasso, :http_client)
  Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

  on_exit(fn ->
    Application.put_env(:lasso, :http_client, original_client)
  end)

  :ok
end
```

---

## Writing Tests

### Test Structure

```elixir
defmodule Lasso.Battle.MyTest do
  use ExUnit.Case, async: false  # Battle tests can't run in parallel

  alias Lasso.Battle.{Scenario, Workload, Chaos, Reporter, SetupHelper}

  @moduletag :battle                 # Tag all tests
  @moduletag :real_providers         # Uses external providers
  @moduletag timeout: :infinity      # Disable ExUnit timeout

  setup_all do
    # HTTP client override (see above)
  end

  setup do
    Application.ensure_all_started(:lasso)

    on_exit(fn ->
      # Cleanup providers
      SetupHelper.cleanup_providers("ethereum", ["provider_list"])
    end)

    :ok
  end

  test "test name" do
    # Test implementation
  end
end
```

### Workload Patterns

#### HTTP Constant Rate

```elixir
Workload.http_constant(
  chain: "ethereum",
  method: "eth_blockNumber",
  rate: 50,              # req/s
  duration: 180_000,     # ms (3 minutes)
  strategy: :fastest     # or :cheapest, :priority, :round_robin
)
```

#### WebSocket Subscriptions

```elixir
stats = Workload.ws_subscribe(
  chain: "ethereum",
  subscription: "newHeads",
  count: 5,              # concurrent subscriptions
  duration: 60_000       # ms
)

assert stats.subscriptions == 5
assert stats.events_received >= 5
```

### Chaos Injection

```elixir
# Kill provider after 20 seconds
|> Scenario.chaos(
  Chaos.kill_provider("llamarpc", chain: "ethereum", delay: 20_000)
)

# Provider flaps: down 5s, up 30s, repeat 3 times
|> Scenario.chaos(
  Chaos.flap_provider("ankr",
    chain: "ethereum",
    down: 5_000,
    up: 30_000,
    count: 3,
    initial_delay: 10_000
  )
)
```

### Data Collection

Specify which metrics to collect:

```elixir
|> Scenario.collect([
  :requests,         # RPC request metrics (latency, success rate)
  :circuit_breaker,  # Circuit breaker state changes
  :system,           # BEAM memory/process metrics
  :websocket         # WS subscription events
])
```

Telemetry events are captured from **production code paths**:

- `[:lasso, :rpc, :request, :stop]` - Request pipeline
- `[:lasso, :circuit_breaker, :state_change]` - Circuit breakers
- `[:lasso, :selection, :success]` - Provider selection

### SLO Definition

Define success criteria:

```elixir
|> Scenario.slo(
  success_rate: 0.99,              # 99% of requests succeed
  p95_latency_ms: 500,             # P95 latency ≤ 500ms
  p99_latency_ms: 1000,            # P99 latency ≤ 1000ms
  max_failover_latency_ms: 2000,   # Failover completes in 2s
  max_memory_mb: 500               # Peak memory ≤ 500MB
)
```

Test passes only if **all SLOs** pass.

---

## Running Tests

### Individual Test

```bash
# Run specific test
mix test test/battle/real_provider_failover_test.exs:51

# Run with trace for detailed output
mix test test/battle/real_provider_failover_test.exs --trace
```

### By Tag

```bash
# All battle tests
mix test --only battle

# Fast tests (<30s) for CI
mix test --only battle --only fast

# Smoke tests for quick validation
mix test --only battle --only quick

# Tests using real providers (slower)
mix test --only battle --only real_providers
```

### Test Organization

| Tag               | Purpose            | Duration | When to Run |
| ----------------- | ------------------ | -------- | ----------- |
| `:battle`         | All battle tests   | Varies   | Local dev   |
| `:fast`           | Quick validation   | <30s     | Every PR    |
| `:quick`          | Smoke tests        | <10s     | Pre-commit  |
| `:real_providers` | External providers | 30s-5min | Nightly     |
| `:soak`           | Long-running       | 10min+   | Weekly      |

---

## Analyzing Results

### Reports Generated

After each test, two reports are created:

```
priv/battle_results/
├── 20250930T163333.672051Z_bc7d9be4.json  # Machine-readable
├── 20250930T163333.672051Z_bc7d9be4.md    # Human-readable
└── latest.md                               # Symlink to latest
```

### Markdown Report Example

```markdown
# Battle Test Report: Failover Test

**Duration:** 60s
**Result:** ✅ PASS

## SLO Compliance

| Metric       | Required | Actual | Status |
| ------------ | -------- | ------ | ------ |
| Success Rate | ≥99%     | 99.5%  | ✅     |
| P95 Latency  | ≤500ms   | 342ms  | ✅     |

## Performance Summary

### HTTP Requests

- Total: 600
- Successes: 597
- Failures: 3
- Success Rate: 99.5%
- P50 Latency: 156ms
- P95 Latency: 342ms

### Circuit Breakers

- State Changes: 2
- Opens: 1
- Closes: 1
- Time Open: 5234ms
```

### JSON Report Structure

```json
{
  "report_id": "20250930T163333.672051Z_bc7d9be4",
  "scenario": {
    "name": "Failover Test",
    "duration_ms": 60123
  },
  "passed": true,
  "analysis": {
    "requests": {
      "total": 600,
      "successes": 597,
      "failures": 3,
      "success_rate": 0.995,
      "p50_latency_ms": 156,
      "p95_latency_ms": 342,
      "p99_latency_ms": 489
    },
    "circuit_breaker": {
      "state_changes": 2,
      "opens": 1,
      "closes": 1,
      "time_open_ms": 5234
    }
  },
  "slo_results": {
    "success_rate": {
      "required": 0.99,
      "actual": 0.995,
      "passed": true
    }
  }
}
```

---

## CI Integration

### GitHub Actions Example

```yaml
name: Battle Tests

on:
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 2 * * *" # Nightly at 2 AM

jobs:
  fast-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "26.0"
          elixir-version: "1.15.0"

      - name: Install dependencies
        run: mix deps.get

      - name: Run fast battle tests
        run: mix test --only battle --only fast --exclude real_providers
        timeout-minutes: 10

  integration-tests:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "26.0"
          elixir-version: "1.15.0"

      - name: Install dependencies
        run: mix deps.get

      - name: Run real provider tests
        run: mix test --only battle --only real_providers --exclude soak
        timeout-minutes: 30
```

---

## Troubleshooting

### Test Fails: "No providers available"

**Cause:** Providers not registered correctly.

**Fix:**

```elixir
# Verify providers are registered
SetupHelper.setup_providers("ethereum", [
  {:real, "llamarpc", "https://eth.llamarpc.com"}
])

# Check ProviderPool
candidates = Lasso.RPC.ProviderPool.list_candidates("ethereum", %{})
IO.inspect(candidates, label: "Registered providers")
```

### Test Hangs

**Cause:** Timeout or rate too high.

**Fix:**

- Reduce `duration` (start with 10_000ms)
- Lower `rate` (start with 5-10 req/s)
- Check provider connectivity manually:
  ```bash
  curl -X POST https://eth.llamarpc.com \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  ```

### SLO Fails Unexpectedly

**Cause:** Thresholds too strict or real provider issues.

**Fix:**

- Loosen SLOs initially (95% → 99%)
- Check provider latency in reports
- Use `--trace` to see individual request failures

### Circuit Breaker Not Opening

**Cause:** Not enough consecutive failures.

**Fix:**

- Check circuit breaker config:
  ```elixir
  # config/config.exs
  config :lasso, :circuit_breaker,
    failure_threshold: 5,      # Failures needed to open
    recovery_timeout: 60_000,  # ms before retry
    success_threshold: 2       # Successes needed to close
  ```
- Verify provider is actually failing (check logs)

### Tests Pass But Nothing Collected

**Cause:** Telemetry not attached correctly.

**Fix:**

```elixir
# Verify telemetry is firing
:telemetry.attach_many(
  :debug_handler,
  [
    [:lasso, :rpc, :request, :stop],
    [:lasso, :circuit_breaker, :state_change]
  ],
  fn event_name, measurements, metadata, _config ->
    IO.inspect({event_name, measurements, metadata}, label: "Telemetry Event")
  end,
  nil
)
```

---

## Advanced Topics

### Baseline & Regression Detection

```bash
# Save current test as baseline
mix test test/battle/my_test.exs
# Manually copy report to priv/battle_baseline.json

# Compare future runs
Reporter.compare_to_baseline(result)
# Fails if >10% regression in key metrics
```

### Custom Chaos Functions

```elixir
defmodule MyCustomChaos do
  def network_partition(provider_ids, opts) do
    fn ->
      delay = Keyword.get(opts, :delay, 0)
      duration = Keyword.get(opts, :duration, 30_000)

      Process.sleep(delay)

      # Your custom chaos logic
      Enum.each(provider_ids, fn pid ->
        # Simulate network partition
      end)

      Process.sleep(duration)

      # Restore
    end
  end
end
```

### Custom Collectors

```elixir
# Attach to any telemetry event
:telemetry.attach(
  :my_collector,
  [:my_app, :custom_event],
  &handle_custom_event/4,
  nil
)
```

---

## Framework API Reference

See `project/battle-testing/TECHNICAL_SPEC.md` for complete API documentation.

---

## Best Practices

### DO ✅

- Use real providers to validate production behavior
- Start with small load (10 req/s, 30s) and scale up
- Tag tests appropriately (`:fast`, `:real_providers`, etc.)
- Generate and review reports after every test
- Use generous timeouts for real providers
- Seed benchmarks for consistent routing behavior
- Clean up providers in `on_exit`

### DON'T ❌

- Run battle tests with `async: true` (they modify global state)
- Use 100% success rate SLOs with real providers (network issues happen)
- Skip cleanup in `on_exit` (providers linger in ProviderPool)
- Use overly strict P99 latency SLOs (real providers vary)
- Forget to override HTTP client in `setup_all`
- Mix mock providers with real providers in same test

---

## Support & Resources

- **Technical Spec:** `project/battle-testing/TECHNICAL_SPEC.md`
- **Audit Report:** `project/battle-testing/BATTLE_TESTING_AUDIT.md`
- **Example Tests:** `test/battle/real_provider_failover_test.exs`
- **Transport Architecture:** `project/TRANSPORT_AGNOSTIC_ARCHITECTURE.md`

---

**Ready to prove your system is bulletproof?** Start with the Quick Start above! 🚀
