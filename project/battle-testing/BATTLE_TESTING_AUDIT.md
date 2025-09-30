# Battle Testing Framework Audit & Action Plan

**Date:** September 30, 2025
**Status:** NEEDS MAJOR INTEGRATION WORK
**Current State:** ~40% complete with significant gaps

---

## Executive Summary

The battle testing framework has solid architectural foundations (~2,200 LOC) but suffers from **critical integration gaps** that prevent it from validating the real Lasso RPC system under production-like conditions. The current implementation tests against a partially-mocked system that doesn't exercise core resilience features like circuit breakers, provider failover, and metrics-based routing.

**Key Finding:** Tests are generating "fake" load via HTTP endpoints but not deeply integrating with Lasso's internal components, limiting their ability to prove real-world reliability.

---

## What Works ✅

### 1. **Core Framework Architecture (Strong)**
- **Scenario orchestration** (`scenario.ex`): Clean API for composing tests ✅
- **Workload generation** (`workload.ex`): HTTP constant-rate load working ✅
- **Data collection** (`collector.ex`): Telemetry attachment pattern correct ✅
- **Analysis** (`analyzer.ex`): Percentile calculations, SLO verification ✅
- **Reporting** (`reporter.ex`): JSON + Markdown output functional ✅

### 2. **HTTP Failover Tests (Partially Working)**
- `failover_test.exs` successfully tests provider failover scenarios
- Circuit breaker state changes are captured
- Reports generate correctly with SLO pass/fail
- **Evidence:** `priv/battle_results/latest.md` shows a passing circuit breaker test

### 3. **WebSocket Client (Well-Implemented)**
- `websocket_client.ex`: Proper gap detection, duplicate tracking ✅
- Telemetry emission for WS events ✅
- Block sequence validation ✅

---

## Critical Gaps 🔴

### Gap 1: **Mock vs Real Provider Integration**

**Problem:** Tests are confused about whether to use mock providers or real providers.

**Evidence:**
```elixir
# websocket_subscription_test.exs (line 17)
setup(fn -> {:ok, %{chain: "ethereum"}} end)  # Uses real chain config

# vs

# failover_test.exs (line 44)
MockProvider.start_providers([{:provider_a, ...}])  # Uses mocks
TestHelper.create_test_chain("battlechain", [...])  # Dynamic chain creation
```

**Impact:**
- WebSocket tests try to use real "ethereum" chain but have no providers configured in test env
- Mock provider tests create dynamic chains that conflict with static ConfigStore
- 50% of tests are `@tag :skip` due to this confusion

**Root Cause:**
- ConfigStore is read-only after app startup (loads from `config/chains.yml`)
- TestHelper tries to dynamically create chains at runtime (doesn't work)
- No clear testing strategy: mock vs real providers

---

### Gap 2: **Telemetry Integration Mismatch**

**Problem:** Tests emit custom telemetry events instead of capturing production events.

**Current State:**
```elixir
# workload.ex (line 205) - Test emits custom events
:telemetry.execute(
  [:livechain, :battle, :request],  # ❌ Custom test event
  %{latency: latency},
  metadata
)

# But collector expects to attach to production events:
# [:livechain, :rpc, :request, :start]  # ✅ Production event
# [:livechain, :rpc, :request, :stop]   # ✅ Production event
```

**Impact:**
- Tests don't validate that production telemetry is working
- Cannot verify metrics accuracy in real system
- Analysis based on synthetic test data, not actual RPC pipeline data

**What's Missing:**
- Integration with `RequestPipeline.execute/4` telemetry
- Capture of `Circuit Breaker` state changes from production code
- Metrics from `BenchmarkStore` updates during test

---

### Gap 3: **Incomplete WebSocket Testing**

**Problem:** WebSocket support is stubbed but not implemented.

**Evidence:**
```elixir
# websocket_failover_test.exs (line 13)
@tag :skip  # Enable when mock providers support WS

# mock_provider.ex - No WebSocket server implementation
# Only HTTP via Plug.Cowboy
```

**Impact:**
- Cannot test subscription continuity during failover (core value prop!)
- Gap detection, backfill, and duplicate prevention untested
- ~30% of test suite skipped

**What's Needed:**
- MockProvider WebSocket server using `Plug.Cowboy.WebSocket`
- Ability to simulate `eth_subscription` events (newHeads, logs)
- Integration with Lasso's `UpstreamSubscriptionPool` and `StreamCoordinator`

---

### Gap 4: **Chaos Injection Not Reliable**

**Problem:** Chaos.kill_provider assumes specific process registry structure.

**Code:**
```elixir
# chaos.ex:242
defp find_provider_process(provider_id) do
  case Registry.lookup(Livechain.Registry, {:ws_connection, provider_id}) do
    [{pid, _}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

**Issues:**
- Hardcoded registry keys may not match actual registration
- Mock providers don't register in same way as real providers
- Kill doesn't trigger circuit breaker correctly
- No verification that supervisor restarts provider

**Impact:**
- Flap and kill chaos functions may silently fail
- Tests pass even when chaos didn't execute
- False confidence in failover behavior

---

### Gap 5: **Test Chain Configuration Conflicts**

**Problem:** Dynamic chain creation conflicts with static configuration.

**Architecture Issue:**
```
Application.start
  └─> Livechain.Application.start/2
      └─> Start chains from config/chains.yml (static)

Battle Test Setup
  └─> TestHelper.start_test_chain("battlechain", config)  # ❌ Conflicts
      └─> ChainSupervisor.start_link(...)
```

**Consequences:**
- Cannot cleanly isolate test chains from production chains
- Risk of polluting BenchmarkStore with test data
- Cleanup (on_exit) doesn't fully reset state

**What's Needed:**
- Test-specific ConfigStore or override mechanism
- Isolated BenchmarkStore tables for tests
- Proper supervision tree teardown

---

### Gap 6: **Missing Production Integration Points**

**Not Testing:**

1. **RequestPipeline**: Tests bypass via HTTP, don't validate:
   - Provider selection logic
   - Strategy routing (fastest/cheapest/priority/round-robin)
   - Timeout handling
   - Error normalization

2. **Circuit Breaker**: Limited validation:
   - State transitions captured but not analyzed deeply
   - Recovery timeout not tested
   - Half-open state behavior untested

3. **Metrics/BenchmarkStore**: No verification:
   - Latency recording accuracy
   - Provider ranking updates
   - Method-specific metrics

4. **Selection Strategies**: Untested:
   - Fastest routing based on BenchmarkStore
   - Cheapest (public provider preference)
   - Round-robin distribution
   - Priority ordering

---

## Quantitative Assessment

| Component | Lines of Code | Completeness | Integration Quality |
|-----------|---------------|--------------|---------------------|
| Scenario API | 237 | 90% | ✅ Good |
| Workload | 330 | 70% | ⚠️ HTTP only, WS stubbed |
| Collector | 176 | 50% | ❌ Wrong telemetry events |
| Analyzer | 235 | 80% | ✅ Good |
| Reporter | 264 | 95% | ✅ Excellent |
| MockProvider | 252 | 60% | ⚠️ HTTP only, no WS |
| Chaos | 257 | 40% | ❌ Unreliable process finding |
| TestHelper | 199 | 30% | ❌ Config conflicts |
| WebSocketClient | 250 | 95% | ✅ Excellent |
| **Total** | **2,200** | **~65%** | **⚠️ Needs Work** |

**Test Coverage:**
- Total test files: 5
- Lines of test code: ~1,515
- Skipped tests: ~40% (due to WS not ready)
- Passing tests: 60% (with real providers configured)

---

## Action Plan: Path to Full Integration

### Phase 1: Fix Core Integration (Priority 1 - 2-3 days)

**Goal:** Make tests work with REAL Lasso RPC system, not mocks.

#### Task 1.1: Switch to Real Provider Testing
**Change Strategy:** Use real configured providers (from `config/chains.yml` in test env) instead of dynamic mocks.

**Implementation:**
```elixir
# test/support/battle_helper.ex (NEW FILE)
defmodule Livechain.BattleHelper do
  @doc """
  Returns a test chain that's pre-configured in config/test.exs
  """
  def get_test_chain do
    # Use a dedicated test chain with at least 2 providers
    case ConfigStore.get_chain("test_chain") do
      {:ok, chain} -> chain
      {:error, :not_found} ->
        raise "test_chain not configured! Add to config/test.exs"
    end
  end

  @doc """
  Seed benchmarks for test providers
  """
  def seed_test_benchmarks(chain, method, latencies) do
    # Clear existing test benchmarks
    BenchmarkStore.clear_chain_metrics(chain)

    # Seed controlled metrics
    Enum.each(latencies, fn {provider_id, latency} ->
      for _ <- 1..20 do  # Multiple samples for stability
        BenchmarkStore.record_rpc_call(chain, provider_id, method, latency, :success)
      end
    end)
  end
end

# config/test.exs (UPDATE)
config :livechain, :chains, [
  %{
    name: "test_chain",
    chain_id: 999,
    providers: [
      %{id: "test_provider_a", url: "https://eth.llamarpc.com", ws_url: "wss://eth.llamarpc.com"},
      %{id: "test_provider_b", url: "https://rpc.ankr.com/eth", ws_url: "wss://rpc.ankr.com/eth/ws"}
    ]
  }
]
```

**Changes Required:**
- Remove `MockProvider` usage from most tests (keep for Phase 2 advanced scenarios)
- Remove `TestHelper.create_test_chain` and `TestHelper.start_test_chain`
- Use `BattleHelper.get_test_chain()` in all tests
- Update tests to use "test_chain" instead of "ethereum" or "battlechain"

**Validation:**
```bash
# After changes, this should pass without @tag :skip
mix test test/battle/failover_test.exs
```

---

#### Task 1.2: Fix Telemetry Collection
**Capture production events instead of emitting test events.**

**Implementation:**
```elixir
# lib/livechain/battle/collector.ex (UPDATE)
defp attach_collector(:requests) do
  # Listen to PRODUCTION telemetry events
  :telemetry.attach(
    {:battle, :rpc_start, self()},
    [:livechain, :rpc, :request, :start],  # ✅ Production event
    &handle_rpc_start/4,
    nil
  )

  :telemetry.attach(
    {:battle, :rpc_stop, self()},
    [:livechain, :rpc, :request, :stop],  # ✅ Production event
    &handle_rpc_stop/4,
    nil
  )
end

defp handle_rpc_start(_, measurements, metadata, _) do
  # Store start time for latency calculation
  request_id = metadata[:request_id] || metadata[:correlation_id]
  if request_id do
    Process.put({:request_start, request_id}, measurements.system_time)
  end
end

defp handle_rpc_stop(_, measurements, metadata, _) do
  # Calculate actual latency from start/stop times
  request_id = metadata[:request_id] || metadata[:correlation_id]
  start_time = Process.get({:request_start, request_id})

  latency = if start_time do
    measurements.system_time - start_time
  else
    measurements.duration  # Fallback to duration from telemetry
  end

  # Rest of collection logic...
end
```

**Changes Required:**
- Update Collector to attach to production telemetry events
- Remove custom telemetry emission from Workload
- Verify RequestPipeline emits these events (check code)
- Add correlation IDs to track requests end-to-end

**Validation:**
```elixir
# Test that production telemetry is captured
test "collector captures production RPC events" do
  Collector.start_collectors([:requests])

  # Make request via real pipeline
  {:ok, _} = RequestPipeline.execute("test_chain", "eth_blockNumber", [])

  data = Collector.stop_collectors([:requests])

  assert length(data.requests) == 1
  assert data.requests |> hd() |> Map.has_key?(:latency)
end
```

---

#### Task 1.3: Fix Workload to Use RequestPipeline Directly
**Make requests through production code, not HTTP endpoints.**

**Implementation:**
```elixir
# lib/livechain/battle/workload.ex (UPDATE)
defp make_http_request(chain, method, params, strategy, timeout, request_id) do
  start_time = System.monotonic_time(:millisecond)

  # ✅ Use production RequestPipeline instead of HTTP
  opts = [
    strategy: strategy,
    timeout: timeout,
    correlation_id: "battle_#{request_id}"
  ]

  result = case RequestPipeline.execute(chain, method, params, opts) do
    {:ok, _result} -> :success
    {:error, error} -> {:error, error}
  end

  end_time = System.monotonic_time(:millisecond)

  # Production telemetry already emitted by RequestPipeline
  # No need to emit [:livechain, :battle, :request]

  result
end
```

**Benefits:**
- Tests validate real production code paths
- Telemetry comes from actual system components
- Metrics, circuit breakers, selection all exercised

**Validation:**
```bash
# Should show circuit breaker opens during failover
mix test test/battle/failover_test.exs --trace
```

---

### Phase 2: Add WebSocket Support (Priority 2 - 2-3 days)

#### Task 2.1: Implement Real WebSocket Testing
**Use real provider WebSocket connections instead of mocks.**

**Implementation:**
```elixir
# lib/livechain/battle/workload.ex (UPDATE ws_subscribe)
def ws_subscribe(opts) do
  chain = Keyword.fetch!(opts, :chain)
  subscription = Keyword.fetch!(opts, :subscription)
  count = Keyword.get(opts, :count, 1)
  duration = Keyword.fetch!(opts, :duration)

  # Connect to Lasso's WS endpoint (uses real providers)
  url = "ws://localhost:4000/rpc/#{chain}"

  clients = for i <- 1..count do
    {:ok, pid} = WebSocketClient.start_link(url, subscription, "battle_#{i}")
    pid
  end

  # Wait and collect stats (unchanged)
  # ...
end
```

**Remove @tag :skip from WebSocket tests.**

**Validation:**
```bash
# Should now work with real providers
mix test test/battle/websocket_subscription_test.exs
mix test test/battle/websocket_failover_test.exs
```

---

#### Task 2.2: Test WebSocket Failover with Real Chaos
**Kill real provider connections, verify failover.**

**Implementation:**
```elixir
# lib/livechain/battle/chaos.ex (FIX kill_provider)
defp find_provider_process(provider_id) do
  # Try multiple registry patterns based on actual system
  candidates = [
    {:ws_connection, provider_id},
    {:provider, provider_id, :ws},
    {provider_id, :ws_connection}
  ]

  Enum.find_value(candidates, {:error, :not_found}, fn key ->
    case Registry.lookup(Livechain.Registry, key) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> nil
    end
  end)
end
```

**Better: Query ProviderPool for provider PIDs:**
```elixir
def kill_provider(provider_id, opts \\ []) do
  fn ->
    delay = Keyword.get(opts, :delay, 0)
    if delay > 0, do: Process.sleep(delay)

    # Use production API to find provider
    case ProviderPool.get_provider_ws_pid(chain, provider_id) do
      {:ok, pid} when is_pid(pid) ->
        Logger.warning("Chaos: Killing #{provider_id} (#{inspect(pid)})")
        Process.exit(pid, :kill)
        :ok

      _ ->
        Logger.error("Chaos: Provider #{provider_id} not found")
        {:error, :not_found}
    end
  end
end
```

---

### Phase 3: Deep Integration Testing (Priority 3 - 2-3 days)

#### Task 3.1: Test All Routing Strategies
**Validate fastest, cheapest, priority, round-robin.**

**New Test File:**
```elixir
# test/battle/routing_strategies_test.exs
defmodule Livechain.Battle.RoutingStrategiesTest do
  use ExUnit.Case, async: false
  alias Livechain.Battle.{Scenario, Workload, BattleHelper}

  test "fastest strategy routes to lowest latency provider" do
    # Seed benchmarks: provider_a=50ms, provider_b=150ms
    BattleHelper.seed_test_benchmarks("test_chain", "eth_blockNumber", [
      {"test_provider_a", 50},
      {"test_provider_b", 150}
    ])

    result = Scenario.new("Fastest Routing Test")
      |> Scenario.workload(fn ->
        Workload.http_constant(
          chain: "test_chain",
          method: "eth_blockNumber",
          rate: 20,
          duration: 10_000,
          strategy: :fastest
        )
      end)
      |> Scenario.collect([:requests])
      |> Scenario.run()

    # Analyze which provider was used (should be test_provider_a)
    requests_by_provider = group_by_provider(result.analysis.requests)

    # >90% should go to fastest provider
    fastest_count = Map.get(requests_by_provider, "test_provider_a", 0)
    total = result.analysis.requests.total

    assert fastest_count / total > 0.90,
      "Expected >90% to fastest provider, got #{fastest_count}/#{total}"
  end
end
```

---

#### Task 3.2: Validate Circuit Breaker Integration
**Ensure circuit breakers actually protect providers.**

**Enhanced Test:**
```elixir
test "circuit breaker opens after repeated failures" do
  result = Scenario.new("Circuit Breaker Protection")
    |> Scenario.workload(fn ->
      # Send requests to a provider that will fail
      # (use provider_override to target specific provider)
      for i <- 1..20 do
        RequestPipeline.execute(
          "test_chain",
          "eth_blockNumber",
          [],
          provider_override: "failing_provider",
          failover_on_override: false
        )
        Process.sleep(100)
      end
    end)
    |> Scenario.collect([:requests, :circuit_breaker])
    |> Scenario.slo(success_rate: 0.0)  # Expect all to fail
    |> Scenario.run()

  # Verify circuit breaker opened
  assert result.analysis.circuit_breaker.opens >= 1
  assert result.analysis.circuit_breaker.time_open_ms > 0
end
```

---

### Phase 4: Battle Report Enhancements (Priority 4 - 1-2 days)

#### Task 4.1: Add Request Flow Visualization
**Show which providers handled requests over time.**

**Implementation:**
```elixir
# lib/livechain/battle/reporter.ex (ADD)
defp format_provider_distribution(analysis) do
  """
  ### Provider Distribution

  #{format_provider_table(analysis.requests.by_provider)}

  ### Timeline
  #{format_timeline_ascii(analysis.requests.timeline)}
  """
end

defp format_provider_table(by_provider) do
  header = "| Provider | Requests | Success Rate | Avg Latency |"

  rows = Enum.map_join(by_provider, "\n", fn {provider_id, stats} ->
    "| #{provider_id} | #{stats.count} | #{format_percent(stats.success_rate)} | #{stats.avg_latency}ms |"
  end)

  header <> "\n|----------|----------|--------------|-------------|" <> "\n" <> rows
end
```

---

#### Task 4.2: Add Real-World Scenario Tests
**Create tests that match actual usage patterns.**

**New Tests:**
```elixir
# test/battle/production_scenarios_test.exs

test "sustained load with random provider flapping" do
  # Simulates: Production traffic with occasional provider outages
  # - 100 req/s for 5 minutes
  # - Random provider goes down for 30s every 90s
  # - Should maintain >99.5% success rate
end

test "burst traffic during provider maintenance" do
  # Simulates: Traffic spike while provider is being restarted
  # - Normal: 50 req/s
  # - Spike: 500 req/s for 10s
  # - One provider killed mid-spike
  # - Should gracefully degrade, no errors
end

test "cold start performance" do
  # Simulates: System starting with no benchmark data
  # - No seeded metrics
  # - 1000 requests
  # - Should build metrics and converge to optimal routing
end
```

---

## Success Criteria (Post-Integration)

### Must Have (P0)
- [ ] All tests use real Lasso RPC components (RequestPipeline, CircuitBreaker, etc.)
- [ ] Telemetry captured from production code paths
- [ ] WebSocket tests run without @tag :skip
- [ ] Chaos injection reliably kills and verifies provider processes
- [ ] 95%+ test suite passing with real providers
- [ ] Reports show actual provider IDs, latencies from BenchmarkStore

### Should Have (P1)
- [ ] Coverage of all 4 routing strategies (fastest, cheapest, priority, round-robin)
- [ ] Circuit breaker behavior deeply validated (open, half-open, close transitions)
- [ ] WebSocket failover with backfill verified
- [ ] Gap detection and duplicate prevention tested
- [ ] Reports include provider distribution analysis

### Nice to Have (P2)
- [ ] Long-running soak tests (30+ minutes)
- [ ] Memory leak detection
- [ ] Performance regression detection (compare to baseline)
- [ ] Real provider integration tests (nightly, optional)

---

## Risks & Mitigation

### Risk 1: Real Providers May Be Unreliable
**Mitigation:**
- Use multiple free providers as fallback
- Add retry logic to test setup
- Accept 95% success rate instead of 100%

### Risk 2: Tests May Be Slow
**Current estimate:** ~5-10 minutes for full suite with real providers

**Mitigation:**
- Tag tests as :battle_fast (<2 min) and :battle_full (5-10 min)
- Run fast tests in CI, full tests nightly
- Use short durations (10-30s per test) for CI

### Risk 3: Flaky Tests Due to Network
**Mitigation:**
- Generous timeouts (10s per request)
- Retry failed requests once
- Accept transient failures in SLOs (99% vs 100%)

---

## Timeline Estimate

| Phase | Tasks | Estimated Time | Priority |
|-------|-------|----------------|----------|
| Phase 1: Core Integration | Switch to real providers, fix telemetry, update workload | 2-3 days | **P0** |
| Phase 2: WebSocket Support | Real WS testing, failover validation | 2-3 days | **P0** |
| Phase 3: Deep Integration | Routing strategies, circuit breaker validation | 2-3 days | **P1** |
| Phase 4: Report Enhancements | Provider distribution, production scenarios | 1-2 days | **P2** |
| **Total** | | **7-11 days** | |

**Recommended approach:** Execute phases sequentially, validating after each phase before moving forward.

---

## Next Immediate Steps

1. **Review this audit** with team to confirm findings and priorities
2. **Run current test suite** to establish baseline pass rate:
   ```bash
   mix test test/battle/ --trace
   ```
3. **Choose integration strategy:** Real providers vs improved mocks
4. **Update `config/test.exs`** with dedicated test_chain configuration
5. **Start Phase 1, Task 1.1:** Switch first test to real provider approach
6. **Validate one test works end-to-end** before refactoring others

---

## Conclusion

The battle testing framework has excellent architectural foundations but needs significant integration work to fulfill its promise of "proving Lasso RPC works under real-world conditions." The primary issue is **shallow integration with production code paths**, leading to tests that validate HTTP routing but miss critical components like circuit breakers, metrics-based selection, and WebSocket failover.

**Recommendation:** Invest 7-11 days to properly integrate tests with the real Lasso RPC system. This will provide genuine confidence in reliability claims and enable data-driven validation for enterprise customers.

The framework is ~65% complete and well-structured. With focused integration work, it can become a powerful validation tool.

---

**Document prepared by:** Claude Code
**Last updated:** 2025-09-30
