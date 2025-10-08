# Lasso RPC Testing Guide

**Last Updated**: 2025-10-07
**Status**: Production Ready

This guide covers testing patterns, best practices, and the test infrastructure for Lasso RPC.

---

## Table of Contents

1. [Test Infrastructure Overview](#test-infrastructure-overview)
2. [Writing Integration Tests](#writing-integration-tests)
3. [Writing Battle Tests](#writing-battle-tests)
4. [Test Helpers Reference](#test-helpers-reference)
5. [Common Patterns](#common-patterns)
6. [Troubleshooting](#troubleshooting)

---

## Test Infrastructure Overview

### Test Types

Lasso RPC uses three types of tests:

1. **Unit Tests**: Fast, isolated module tests
2. **Integration Tests**: Multi-component tests with mocked providers
3. **Battle Tests**: Long-running, chaos-engineering tests with real or simulated load

### Test Infrastructure Components

#### Phase 1: Foundational Infrastructure

- **`TelemetrySync`** (`test/support/telemetry_sync.ex`): Event-driven deterministic waiting
- **`Eventually`** (`test/support/eventually.ex`): Polling-based assertions
- **`CircuitBreakerHelper`** (`test/support/circuit_breaker_helper.ex`): Circuit breaker lifecycle management
- **`IntegrationHelper`** (`lib/lasso/testing/integration_helper.ex`): Provider setup and synchronization
- **`LassoIntegrationCase`** (`test/support/lasso_integration_case.ex`): Base test case with automatic isolation

#### Phase 2: Mock Infrastructure

- **`MockProviderBehavior`** (`test/support/mock_provider_behavior.ex`): Rich failure scenario behaviors

#### Phase 3: Battle Test Infrastructure

- **`Chaos`** (`lib/lasso_battle/chaos.ex`): Controlled failure injection
- **`Metrics`** (`lib/lasso_battle/metrics.ex`): Statistical analysis and SLO verification

---

## Writing Integration Tests

### Quick Start

```elixir
defmodule Lasso.RPC.MyIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  test "my integration scenario", %{chain: chain} do
    # Setup providers with behaviors
    providers = setup_providers([
      %{id: "primary", priority: 10, behavior: :healthy},
      %{id: "backup", priority: 20, behavior: :healthy}
    ])

    # Execute request
    {:ok, result} = execute_rpc("eth_blockNumber", [])

    # Assert result
    assert result != nil
  end
end
```

### Best Practices

#### ✅ DO: Use TelemetrySync for deterministic waiting

```elixir
# Good: Wait for actual event
{:ok, meta} = TelemetrySync.wait_for_circuit_breaker_open("provider_id", :http)

# Bad: Arbitrary sleep
Process.sleep(500)  # ❌ Flaky
```

#### ✅ DO: Use `LassoIntegrationCase` for automatic isolation

```elixir
defmodule MyTest do
  use Lasso.Test.LassoIntegrationCase  # ✅ Gets clean state automatically

  test "scenario", %{chain: chain} do
    # Chain is unique, circuit breakers are clean
  end
end
```

#### ✅ DO: Use behavior-based mock providers

```elixir
# Good: Specific realistic behavior
%{
  id: "failing_provider",
  behavior: MockProviderBehavior.intermittent_failures(0.3)
}

# Bad: Generic always-fail
%{id: "provider", behavior: :always_fail}  # ❌ Not realistic
```

#### ❌ DON'T: Use `Process.sleep` for synchronization

```elixir
# Bad
trigger_failover("provider")
Process.sleep(200)  # ❌ Race condition
assert_failover_completed()

# Good
trigger_failover("provider")
wait_for_failover(chain, {:newHeads})  # ✅ Deterministic
assert_failover_completed()
```

#### ❌ DON'T: Pollute test state across tests

```elixir
# Bad: Shared state
@shared_chain "ethereum"  # ❌ State pollution

test "scenario 1" do
  use_chain(@shared_chain)  # Pollutes state for scenario 2
end

# Good: Isolated state
test "scenario 1", %{chain: chain} do
  use_chain(chain)  # ✅ Unique per test
end
```

---

## Writing Battle Tests

### Quick Start

```elixir
defmodule Lasso.Battle.ResilienceTest do
  use ExUnit.Case, async: false

  @moduletag :battle
  @moduletag timeout: 300_000  # 5 minutes

  alias LassoBattle.{Chaos, Metrics}

  test "system maintains SLOs under chaos" do
    chain = setup_test_chain_with_real_providers()

    # Start chaos agents
    chaos_tasks = Chaos.combined_chaos(
      chain: chain,
      provider_chaos: [kill_interval: 5_000, kill_probability: 0.3],
      memory_pressure: [target_mb: 100, interval_ms: 1_000]
    )

    # Run sustained workload
    results = run_workload(chain,
      duration: 60_000,  # 1 minute
      rps: 10,
      methods: ["eth_blockNumber", "eth_gasPrice"]
    )

    # Stop chaos
    Chaos.stop_all_chaos(chaos_tasks)

    # Analyze results
    metrics = Metrics.analyze(results)

    # Verify SLOs
    assert metrics.success_rate >= 0.99
    assert metrics.p95_latency_ms <= 500
    assert metrics.max_gap_size == 0
  end
end
```

### Chaos Engineering Patterns

#### Random Provider Chaos

```elixir
# Kill random providers at intervals
chaos_task = Chaos.random_provider_chaos(
  chain: "ethereum",
  kill_interval: 10_000,
  recovery_delay: 2_000,
  kill_probability: 0.5,
  min_providers: 1
)

# Run workload...

Task.shutdown(chaos_task)
```

#### Provider Flapping

```elixir
# Repeatedly kill and restart a specific provider
chaos_task = Chaos.provider_flapping(
  "ethereum",
  "alchemy",
  flap_interval: 5_000,
  flap_duration: 500,
  total_duration: 30_000
)
```

#### Memory Pressure

```elixir
# Allocate large binaries to trigger GC pressure
chaos_task = Chaos.memory_pressure(
  target_mb: 200,
  interval_ms: 500,
  duration_ms: 60_000
)
```

### SLO Verification

```elixir
slos = %{
  success_rate: 0.99,
  p95_latency_ms: 500,
  max_gap_size: 0,
  circuit_breaker_opens: {:max, 5}
}

case Metrics.verify_slos(metrics, slos) do
  {:ok, _} ->
    IO.puts("✓ All SLOs met")

  {:error, violations} ->
    raise """
    SLO violations detected:
    #{inspect(violations, pretty: true)}
    """
end
```

---

## Test Helpers Reference

### TelemetrySync

Wait for telemetry events deterministically.

```elixir
# Wait for circuit breaker events
{:ok, meta} = TelemetrySync.wait_for_circuit_breaker_open("provider_id", :http)
{:ok, meta} = TelemetrySync.wait_for_circuit_breaker_close("provider_id", :http)
{:ok, meta} = TelemetrySync.wait_for_circuit_breaker_half_open("provider_id", :http)

# Wait for failover events
{:ok, meta} = TelemetrySync.wait_for_failover_completed("chain", {:newHeads})
{:ok, meta} = TelemetrySync.wait_for_failover_initiated("chain", {:newHeads})

# Wait for provider cooldown
{:ok, meta} = TelemetrySync.wait_for_provider_cooldown_start("provider_id")
{:ok, meta} = TelemetrySync.wait_for_provider_cooldown_end("provider_id")

# Wait for RPC requests
{:ok, measurements} = TelemetrySync.wait_for_request_completed(
  method: "eth_blockNumber",
  status: :success
)

# Collect all events for a duration
events = TelemetrySync.collect_events(
  [:lasso, :circuit_breaker, :open],
  timeout: 1000
)
```

### Eventually

Polling-based assertions for when telemetry isn't available.

```elixir
# Wait for condition to become true
Eventually.assert_eventually(fn ->
  CircuitBreaker.get_state(provider).state == :open
end, timeout: 5_000, interval: 100)

# Wait for condition to remain false
Eventually.refute_eventually(fn ->
  Process.whereis(CrashedWorker) != nil
end, timeout: 1_000)

# Wait for value
{:ok, user} = Eventually.wait_for_value(
  fn -> Repo.get(User, id) end,
  match_non_nil: true
)

# Retry until success
{:ok, response} = Eventually.retry_until_success(fn ->
  HTTPClient.get(url)
end, timeout: 10_000, retry_on: [:timeout])
```

### CircuitBreakerHelper

Manage circuit breaker lifecycle in tests.

```elixir
# Setup clean circuit breakers (in test setup)
setup do
  CircuitBreakerHelper.setup_clean_circuit_breakers()
  :ok
end

# Ensure circuit breaker is started
{:ok, state} = CircuitBreakerHelper.ensure_circuit_breaker_started(
  "provider_id",
  :http
)

# Wait for specific state
{:ok, state} = CircuitBreakerHelper.wait_for_circuit_breaker_state(
  {"provider_id", :http},
  fn state -> state.failure_count >= 3 end
)

# Assert state
CircuitBreakerHelper.assert_circuit_breaker_state(
  {"provider_id", :http},
  :open
)

# Force state for testing
CircuitBreakerHelper.force_open({"provider_id", :http})
CircuitBreakerHelper.reset_to_closed({"provider_id", :http})
```

### MockProviderBehavior

Create realistic provider behaviors.

```elixir
# Degraded performance
%{id: "slow", behavior: MockProviderBehavior.degraded_performance(100)}

# Intermittent failures
%{id: "flaky", behavior: MockProviderBehavior.intermittent_failures(0.7)}

# Rate limited
%{id: "limited", behavior: MockProviderBehavior.rate_limited_provider(10)}

# Node out of sync
%{id: "lagging", behavior: MockProviderBehavior.node_out_of_sync(5, 10_000)}

# Cascading failure
%{id: "cascade", behavior: MockProviderBehavior.cascading_failure(
  healthy_duration: 10_000,
  degraded_duration: 20_000,
  failed_duration: 10_000
)}

# Method-specific behavior
%{id: "mixed", behavior: MockProviderBehavior.method_specific(%{
  "eth_blockNumber" => :healthy,
  "eth_getBalance" => MockProviderBehavior.intermittent_failures(0.5)
})}
```

---

## Common Patterns

### Pattern: Testing Failover

```elixir
test "failover to backup provider", %{chain: chain} do
  # Setup primary and backup
  setup_providers([
    %{id: "primary", priority: 10, behavior: :healthy},
    %{id: "backup", priority: 20, behavior: :healthy}
  ])

  # Force primary circuit breaker open
  CircuitBreakerHelper.force_open({"primary", :http})
  wait_for_cb_open("primary", :http)

  # Request should use backup
  {:ok, result} = execute_rpc("eth_blockNumber", [])
  assert result != nil

  # Verify backup was used (check telemetry or provider usage)
end
```

### Pattern: Testing Circuit Breaker Opens

```elixir
test "circuit breaker opens after failures", %{chain: chain} do
  setup_providers([
    %{id: "failing", behavior: :always_fail}
  ])

  # Trigger failures (circuit breaker threshold is typically 3-5)
  for _ <- 1..5 do
    {:error, _} = execute_rpc("eth_blockNumber", [], provider_override: "failing")
  end

  # Wait for circuit breaker to open
  wait_for_cb_open("failing", :http)

  # Verify state
  CircuitBreakerHelper.assert_circuit_breaker_state(
    {"failing", :http},
    :open
  )
end
```

### Pattern: Testing Subscription Continuity

```elixir
test "zero-gap failover during subscription", %{chain: chain} do
  setup_providers([
    %{id: "primary", priority: 10},
    %{id: "backup", priority: 20}
  ])

  # Subscribe
  sub_id = subscribe_test_client({:newHeads})

  # Send blocks from primary
  send_mock_block_sequence("primary", 100, 3)

  # Receive blocks
  assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x64"}}}}
  assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x65"}}}}
  assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x66"}}}}

  # Trigger failover
  trigger_failover("primary")
  wait_for_failover(chain, {:newHeads})

  # Send blocks from backup (continuing sequence)
  send_mock_block_sequence("backup", 103, 3)

  # Verify no gaps
  assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x67"}}}}
  assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x68"}}}}
  assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x69"}}}}

  unsubscribe_test_client(sub_id)
end
```

---

## Troubleshooting

### Tests are Flaky

**Symptom**: Tests pass/fail randomly

**Solutions**:
1. Replace `Process.sleep` with `TelemetrySync` or `Eventually`
2. Use `LassoIntegrationCase` for proper isolation
3. Check for state pollution between tests

### Circuit Breaker Not Found

**Symptom**: `{:error, :not_found}` when accessing circuit breaker

**Solutions**:
1. Use `CircuitBreakerHelper.ensure_circuit_breaker_started/2`
2. Add wait after provider setup: `wait_for_provider_ready(chain, provider_id)`

### Timeout Errors

**Symptom**: Tests timeout waiting for events

**Solutions**:
1. Check telemetry events are actually being emitted
2. Increase timeout values for slow CI environments
3. Use `Eventually` as fallback if telemetry unreliable

### State Pollution

**Symptom**: Tests affect each other, inconsistent results

**Solutions**:
1. Always use `LassoIntegrationCase` for integration tests
2. Generate unique chain IDs per test
3. Call `CircuitBreakerHelper.setup_clean_circuit_breakers()` in setup

---

## Running Tests

```bash
# Run all tests
mix test

# Run only integration tests
mix test --only integration

# Run only battle tests
mix test --only battle

# Run specific test file
mix test test/integration/request_pipeline_integration_test.exs

# Run with detailed output
mix test --trace

# Run battle tests (slow, comprehensive)
mix test --only battle --exclude real_providers
```

---

## Further Reading

- [TEST_INFRASTRUCTURE_IMPROVEMENT_SPEC.md](../specs/TEST_INFRASTRUCTURE_IMPROVEMENT_SPEC.md): Full specification
- [ARCHITECTURE.md](../ARCHITECTURE.md): System architecture
- [Battle Testing](../../lib/lasso_battle/): Battle test framework code
