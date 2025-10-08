# Test Infrastructure Improvement Specification

**Status**: Draft
**Author**: Test Suite Audit (2025-10-07)
**Objective**: Establish production-grade integration and battle test infrastructure to validate real-world reliability before deployment

---

## Executive Summary

Lasso RPC requires **high-confidence validation** of critical paths (failover, circuit breaking, rate limiting, gap detection) under real-world conditions before production deployment. Current integration test infrastructure has **brittleness issues** that block reliable testing:

- Circuit breaker registration timing issues
- Timing-based assertions (`Process.sleep`) causing flakes
- State pollution between tests
- Missing real-world failure simulation patterns

**This spec defines a phased approach** to:
1. Fix foundational infrastructure issues (Phase 1)
2. Implement RequestPipeline integration tests as pilot (Phase 2)
3. Expand battle test capabilities for production scenarios (Phase 3)

**Goal**: Uncover real-world bugs through rigorous integration and battle testing, gain confidence for production deployment.

---

## Current State Assessment

### What's Working

**Integration Test Framework** (`test/integration/`):
- ✅ Good separation from unit tests
- ✅ `IntegrationHelper` provides clean chain setup
- ✅ `MockWSProvider` enables controlled WebSocket simulation
- ✅ Comprehensive failover tests (zero-gap streaming)

**Battle Test Framework** (`test/battle/`):
- ✅ Well-documented SLO validation patterns
- ✅ Real provider testing infrastructure
- ✅ Statistical analysis (transport latency comparison)
- ✅ Chaos scenarios (provider failover, concurrent load)

### Critical Infrastructure Gaps

**1. Test Reliability Issues** (Blocking New Tests)

```elixir
# Current pattern - BRITTLE:
test "failover works" do
  setup_providers(...)
  trigger_failure(...)
  Process.sleep(150)  # ❌ Hope failover completes
  assert_failover_occurred()
end
```

**Problems**:
- Circuit breaker registration races with test execution
- Timing assumptions fail under load
- No deterministic way to wait for async state transitions
- State pollution: CB/metrics persist across tests

**Evidence from audit**:
```
[error] Task #PID<0.936.0> terminating
** (stop) exited in: GenServer.call({:via, Registry,
    {:circuit_breaker, "ws_primary:http"}}, ...)
** (EXIT) no process: the process is not alive
```

**2. Missing Real-World Failure Patterns**

Current integration tests use **simplistic failure injection**:
- Provider returns error → next provider tried
- Circuit breaker manually opened → failover triggered

**Real-world failures are complex**:
- Partial failures (some methods work, others timeout)
- Degraded performance (slow responses, not errors)
- Network-level issues (connection drops mid-stream)
- Provider-specific quirks (rate limit headers, sync errors)
- Cascading failures (CB opens → load shifts → next provider overloads)

**3. Limited Battle Test Scope**

Current battle tests validate SLOs but have gaps:
- ❌ No chaos engineering (random provider kills, network partitions)
- ❌ No sustained load testing (hours-long stability)
- ❌ No resource exhaustion scenarios (memory leaks, connection pools)
- ❌ Limited failure combinations (e.g., rate limit + node sync lag)

---

## Phase 1: Fix Foundational Infrastructure

**Objective**: Make integration tests reliable and deterministic.

### 1.1 Replace Timing-Based Assertions

**Current Problem**:
```elixir
test "circuit breaker opens after failures" do
  cause_failures(provider, count: 3)
  Process.sleep(100)  # ❌ Race condition
  assert CircuitBreaker.get_state(provider).state == :open
end
```

**Solution Options**:

#### **Option A: Telemetry-Based Synchronization** (Recommended)

```elixir
defmodule TestSupport.TelemetrySync do
  @moduledoc """
  Wait for specific telemetry events with timeout.
  Replaces Process.sleep with deterministic event waiting.
  """

  def wait_for_event(event_name, timeout \\ 5000) do
    test_pid = self()
    ref = make_ref()

    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {ref, :event, measurements, metadata})
      end,
      nil
    )

    receive do
      {^ref, :event, measurements, metadata} ->
        :telemetry.detach(handler_id)
        {:ok, measurements, metadata}
    after
      timeout ->
        :telemetry.detach(handler_id)
        {:error, :timeout}
    end
  end

  def wait_for_circuit_breaker_open(provider_id, transport, timeout \\ 5000) do
    wait_for_event(
      [:lasso, :circuit_breaker, :state_change],
      timeout,
      match: %{provider_id: ^provider_id, transport: ^transport, new_state: :open}
    )
  end
end

# Usage in tests:
test "circuit breaker opens after failures" do
  cause_failures(provider, count: 3)
  assert {:ok, _} = TelemetrySync.wait_for_circuit_breaker_open(provider, :http)
  # No sleep, deterministic
end
```

**Pros**:
- Deterministic (waits for actual state change, not arbitrary time)
- No false positives from slow CI
- Validates telemetry events work correctly (double value)

**Cons**:
- Requires telemetry events are emitted (need to add if missing)
- More complex test setup

#### **Option B: Polling with Backoff**

```elixir
defmodule TestSupport.Eventually do
  def assert_eventually(fun, timeout \\ 5000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(fun, deadline, interval)
  end

  defp do_poll(fun, deadline, interval) do
    case fun.() do
      true -> :ok
      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "Assertion failed within timeout"
        else
          Process.sleep(interval)
          do_poll(fun, deadline, interval)
        end
    end
  end
end

# Usage:
test "circuit breaker opens" do
  cause_failures(provider, count: 3)
  Eventually.assert_eventually(fn ->
    CircuitBreaker.get_state(provider).state == :open
  end)
end
```

**Pros**:
- Simple, no infrastructure changes
- Works with any assertion

**Cons**:
- Still uses sleep (better than fixed sleep though)
- Doesn't validate events

**Recommendation**: **Option A** for critical paths (CB state, failover), **Option B** for simple assertions.

### 1.2 Circuit Breaker Lifecycle Management

**Current Problem**: Circuit breakers persist across tests, causing state pollution.

**Solution: Test-Scoped Circuit Breaker Registry**

```elixir
defmodule TestSupport.CircuitBreakerHelper do
  @doc """
  Ensures circuit breakers are reset before each test.
  Tracks CBs created during test and cleans up on exit.
  """

  def setup_clean_circuit_breakers do
    # Get all existing CBs
    existing_cbs = CircuitBreaker.list_all()

    # Reset them to :closed with zero failures
    Enum.each(existing_cbs, fn {key, _pid} ->
      CircuitBreaker.reset(key)
    end)

    on_exit(fn ->
      # Get CBs created during test
      current_cbs = CircuitBreaker.list_all()
      new_cbs = current_cbs -- existing_cbs

      # Clean up new ones
      Enum.each(new_cbs, fn {key, pid} ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      end)
    end)

    :ok
  end

  def ensure_circuit_breaker_started(provider_id, transport) do
    # Synchronously ensure CB is registered before test proceeds
    case CircuitBreaker.get_state({provider_id, transport}) do
      %{state: _} = state ->
        {:ok, state}

      {:error, :not_started} ->
        # Start it explicitly
        CircuitBreaker.start_link({provider_id, transport})
        # Wait for registration
        TelemetrySync.wait_for_event([:lasso, :circuit_breaker, :started], 1000)
        {:ok, CircuitBreaker.get_state({provider_id, transport})}
    end
  end
end

# Usage in test setup:
setup do
  CircuitBreakerHelper.setup_clean_circuit_breakers()

  # For each provider, ensure CB is ready
  CircuitBreakerHelper.ensure_circuit_breaker_started("test_provider", :http)

  :ok
end
```

### 1.3 Provider Registration Synchronization

**Current Problem**: Providers registered asynchronously, tests start before providers ready.

**Solution**:

```elixir
defmodule TestSupport.IntegrationHelper do
  # Enhanced version

  def setup_test_chain_with_providers(chain, provider_configs, opts \\ []) do
    # Create chain supervisor
    {:ok, _sup} = ChainSupervisor.start_chain(chain, provider_configs)

    # Wait for all providers to be fully registered
    provider_ids = Enum.map(provider_configs, & &1.id)

    Enum.each(provider_ids, fn provider_id ->
      wait_for_provider_ready(chain, provider_id, opts[:timeout] || 5000)
    end)

    {:ok, provider_ids}
  end

  defp wait_for_provider_ready(chain, provider_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_provider(chain, provider_id, deadline)
  end

  defp do_wait_for_provider(chain, provider_id, deadline) do
    case ProviderPool.get_provider_status(chain, provider_id) do
      {:ok, %{status: status}} when status in [:healthy, :connecting] ->
        # Provider registered and circuit breaker ready
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "Provider #{provider_id} not ready within timeout"
        else
          Process.sleep(10)
          do_wait_for_provider(chain, provider_id, deadline)
        end
    end
  end
end
```

### 1.4 Isolation Improvements

**Ensure true test isolation**:

```elixir
defmodule LassoIntegrationCase do
  @moduledoc """
  Base case for integration tests with proper isolation.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import TestSupport.{TelemetrySync, CircuitBreakerHelper, IntegrationHelper}

      setup do
        # Unique chain per test (already done)
        chain = "test_#{:rand.uniform(999_999)}"

        # Clean circuit breakers
        CircuitBreakerHelper.setup_clean_circuit_breakers()

        # Clean metrics (if needed)
        Metrics.reset_test_data()

        on_exit(fn ->
          # Ensure chain cleanup
          ChainSupervisor.stop_chain(chain)

          # Wait for async cleanup to complete
          Process.sleep(50)
        end)

        {:ok, chain: chain}
      end
    end
  end
end

# All integration tests now use:
defmodule MyIntegrationTest do
  use LassoIntegrationCase  # Gets all the setup

  test "my test", %{chain: chain} do
    # Test has clean CB state, unique chain, proper cleanup
  end
end
```

---

## Phase 2: RequestPipeline Integration Tests (Pilot)

**Objective**: Implement focused RequestPipeline tests using improved infrastructure.

### 2.1 Test Specification

Based on tech-lead review, focus on **pipeline-specific responsibilities**:

```elixir
defmodule Lasso.RPC.RequestPipelineIntegrationTest do
  use LassoIntegrationCase

  alias Lasso.RPC.RequestPipeline

  describe "circuit breaker coordination" do
    test "fails over when circuit breaker is open", %{chain: chain} do
      # Setup: Two providers, open CB on primary
      {:ok, [primary, backup]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [
          %{id: "primary", url: "http://primary", priority: 10},
          %{id: "backup", url: "http://backup", priority: 20}
        ]
      )

      # Open circuit breaker on primary
      CircuitBreaker.open({primary, :http})
      {:ok, _} = TelemetrySync.wait_for_circuit_breaker_open(primary, :http)

      # Execute request - should automatically use backup
      result = RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        strategy: :priority
      )

      assert {:ok, _block_number} = result

      # Verify backup was used (via telemetry or request context)
      assert_provider_used(backup)
    end

    test "circuit breaker opens after repeated failures, excludes from selection", %{chain: chain} do
      {:ok, [failing, healthy]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [
          %{id: "failing", url: "http://failing", behavior: :always_fail},
          %{id: "healthy", url: "http://healthy"}
        ]
      )

      # First request triggers failures
      {:error, _} = RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        provider_override: "failing",
        failover_on_override: false
      )

      # Wait for CB to open (3 failures by default)
      {:ok, _} = TelemetrySync.wait_for_circuit_breaker_open("failing", :http, 2000)

      # Subsequent requests should skip failing provider
      {:ok, _} = RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        strategy: :round_robin
      )

      assert_provider_used("healthy")
      refute_provider_used("failing")
    end
  end

  describe "adapter validation and failover" do
    test "fails over when adapter rejects parameters", %{chain: chain} do
      # Setup: Provider with parameter limitations
      {:ok, [limited, unlimited]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [
          %{
            id: "limited",
            adapter: Lasso.RPC.Providers.Adapters.LimitedAdapter,
            adapter_config: %{max_addresses: 1}
          },
          %{id: "unlimited", adapter: Lasso.RPC.Providers.Adapters.Generic}
        ]
      )

      # Request with parameters that exceed limited provider's capabilities
      params = [
        %{
          "address" => ["0xaddr1", "0xaddr2", "0xaddr3"],  # 3 addresses, limited allows 1
          "fromBlock" => "0x1",
          "toBlock" => "latest"
        }
      ]

      result = RequestPipeline.execute_via_channels(
        chain,
        "eth_getLogs",
        params,
        strategy: :priority
      )

      # Should fail over to unlimited provider
      assert {:ok, _logs} = result
      assert_provider_used("unlimited")

      # Verify telemetry shows adapter rejection
      assert_received {:telemetry_event, [:lasso, :adapter, :validation_failed],
        %{provider_id: "limited", reason: :param_limit}}
    end
  end

  describe "error classification and retry logic" do
    test "retries on retriable errors, stops on non-retriable", %{chain: chain} do
      {:ok, [provider1, provider2]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [
          %{id: "p1", behavior: {:error, :connection_timeout}},  # Retriable
          %{id: "p2", url: "http://p2"}
        ]
      )

      # Retriable error should trigger failover
      {:ok, _} = RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        strategy: :round_robin
      )

      assert_provider_used("p2")  # Failover occurred
    end

    test "stops immediately on non-retriable user error", %{chain: chain} do
      {:ok, [p1]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [%{id: "p1", behavior: {:error, %JError{code: -32602, retriable?: false}}}]
      )

      # Non-retriable error (invalid params) should not trigger failover
      {:error, %JError{code: -32602}} = RequestPipeline.execute_via_channels(
        chain,
        "eth_call",
        [%{"to" => "invalid"}],
        strategy: :priority
      )

      # Verify no failover attempts
      assert_telemetry_count([:lasso, :rpc, :failover, :attempt], 0)
    end
  end

  describe "provider override behavior" do
    test "respects failover_on_override: false", %{chain: chain} do
      {:ok, [failing, backup]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [
          %{id: "failing", behavior: :always_timeout},
          %{id: "backup", url: "http://backup"}
        ]
      )

      {:error, _} = RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        provider_override: "failing",
        failover_on_override: false
      )

      # Should NOT have tried backup
      refute_provider_used("backup")
    end

    test "fails over when failover_on_override: true and retriable error", %{chain: chain} do
      {:ok, [failing, backup]} = IntegrationHelper.setup_test_chain_with_providers(
        chain,
        [
          %{id: "failing", behavior: {:error, :timeout}},  # Retriable
          %{id: "backup", url: "http://backup"}
        ]
      )

      {:ok, _} = RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        provider_override: "failing",
        failover_on_override: true
      )

      # Should have failed over to backup
      assert_provider_used("backup")

      # Verify telemetry shows override failover
      assert_received {:telemetry_event, [:lasso, :rpc, :override_failover], _}
    end
  end
end
```

### 2.2 Enhanced Mock Provider Infrastructure

**Problem**: Current mocks don't support rich failure behaviors.

**Solution: Behavior-Based MockProvider**

```elixir
defmodule TestSupport.MockProvider do
  @moduledoc """
  Enhanced mock provider with configurable behaviors for integration tests.
  """

  def start_link(config) do
    # Register provider with specific behavior
    behavior = config[:behavior] || :healthy

    GenServer.start_link(__MODULE__, %{
      id: config.id,
      behavior: behavior,
      call_count: 0
    }, name: via_tuple(config.id))
  end

  def handle_rpc_request(provider_id, method, params) do
    GenServer.call(via_tuple(provider_id), {:rpc_request, method, params})
  end

  def handle_call({:rpc_request, method, params}, _from, state) do
    state = %{state | call_count: state.call_count + 1}

    response = case state.behavior do
      :healthy ->
        {:ok, mock_response(method, params)}

      :always_fail ->
        {:error, %JError{code: -32000, message: "Mock failure"}}

      :always_timeout ->
        Process.sleep(10_000)  # Timeout

      {:error, error} ->
        {:error, error}

      {:conditional, condition_fun} ->
        condition_fun.(method, params, state)

      {:sequence, responses} ->
        # Return different response based on call count
        response = Enum.at(responses, state.call_count - 1, List.last(responses))
        response
    end

    {:reply, response, state}
  end

  # Behavioral patterns

  def degraded_performance(base_latency \\ 100) do
    {:conditional, fn _method, _params, state ->
      # Gradually increase latency
      latency = base_latency * (1 + state.call_count * 0.1)
      Process.sleep(trunc(latency))
      {:ok, mock_response("eth_blockNumber", [])}
    end}
  end

  def intermittent_failures(success_rate \\ 0.7) do
    {:conditional, fn _method, _params, _state ->
      if :rand.uniform() < success_rate do
        {:ok, mock_response("eth_blockNumber", [])}
      else
        {:error, %JError{code: -32603, message: "Intermittent failure"}}
      end
    end}
  end

  def rate_limited_provider(requests_before_limit \\ 10) do
    {:conditional, fn _method, _params, state ->
      if state.call_count > requests_before_limit do
        {:error, %JError{
          code: -32005,
          message: "Rate limit exceeded",
          category: :rate_limit,
          retriable?: true
        }}
      else
        {:ok, mock_response("eth_blockNumber", [])}
      end
    end}
  end
end

# Usage in tests:
test "handles degraded provider performance", %{chain: chain} do
  {:ok, [slow, fast]} = IntegrationHelper.setup_test_chain_with_providers(
    chain,
    [
      %{id: "slow", behavior: MockProvider.degraded_performance(50)},
      %{id: "fast", url: "http://fast"}
    ]
  )

  # First few requests might use slow provider
  # As latency increases, strategy should shift to fast provider

  results = for _ <- 1..10 do
    {:ok, _} = RequestPipeline.execute_via_channels(
      chain,
      "eth_blockNumber",
      [],
      strategy: :fastest
    )
  end

  # Verify adaptive routing occurred
  assert provider_usage_shifted_from("slow", to: "fast")
end
```

---

## Phase 3: Battle Test Infrastructure for Production Scenarios

**Objective**: Simulate real-world conditions to uncover production bugs.

### 3.1 Real-World Failure Pattern Catalog

**Design**: Create reusable failure scenarios that mirror production issues.

```elixir
defmodule Lasso.Battle.FailureScenarios do
  @moduledoc """
  Catalog of real-world failure patterns for battle testing.

  Each scenario is a reusable behavior that can be composed
  into battle tests to simulate production conditions.
  """

  @doc """
  Scenario: Provider node out of sync

  Behavior:
  - Provider returns stale block numbers (lagging by N blocks)
  - Eventually catches up after sync completes

  Real-world trigger: Node restart, network partition recovery
  """
  def node_out_of_sync(lag_blocks \\ 10, recovery_time_ms \\ 30_000) do
    start_time = System.monotonic_time(:millisecond)
    current_block = 1000

    fn method, _params ->
      elapsed = System.monotonic_time(:millisecond) - start_time

      if elapsed < recovery_time_ms do
        # Still lagging
        block = current_block - lag_blocks
        {:ok, %{"result" => "0x#{Integer.to_string(block, 16)}"}}
      else
        # Caught up
        {:ok, %{"result" => "0x#{Integer.to_string(current_block, 16)}"}}
      end
    end
  end

  @doc """
  Scenario: Provider experiences cascading failure

  Behavior:
  - Initial requests succeed
  - Sudden spike in traffic causes performance degradation
  - Eventually circuit breaker opens
  - After cooldown, provider recovers

  Real-world trigger: Traffic surge, DDoS, upstream API issues
  """
  def cascading_failure(opts \\ []) do
    healthy_duration = Keyword.get(opts, :healthy_duration, 5_000)
    degraded_duration = Keyword.get(opts, :degraded_duration, 10_000)
    recovery_duration = Keyword.get(opts, :recovery_duration, 5_000)

    start_time = System.monotonic_time(:millisecond)

    fn method, params ->
      elapsed = System.monotonic_time(:millisecond) - start_time

      cond do
        elapsed < healthy_duration ->
          # Phase 1: Healthy
          {:ok, mock_response(method, params)}

        elapsed < healthy_duration + degraded_duration ->
          # Phase 2: Degraded (slow responses, intermittent failures)
          latency = 500 + :rand.uniform(1000)
          Process.sleep(latency)

          if :rand.uniform() < 0.3 do
            {:error, %JError{code: -32603, message: "Service overloaded"}}
          else
            {:ok, mock_response(method, params)}
          end

        elapsed < healthy_duration + degraded_duration + recovery_duration ->
          # Phase 3: Circuit breaker open (all requests fail fast)
          {:error, %JError{code: -32000, message: "Circuit breaker open"}}

        true ->
          # Phase 4: Recovery
          {:ok, mock_response(method, params)}
      end
    end
  end

  @doc """
  Scenario: Rate limit with header-based backoff

  Behavior:
  - Provider returns rate limit errors with Retry-After header
  - Lasso should honor the backoff period
  - Requests during backoff should fail over to other providers

  Real-world trigger: API rate limits (Infura, Alchemy, etc.)
  """
  def rate_limit_with_backoff(requests_per_window \\ 10, window_ms \\ 1_000) do
    window_start = System.monotonic_time(:millisecond)
    request_count = 0

    fn method, params ->
      now = System.monotonic_time(:millisecond)

      # Reset window if expired
      {window_start, request_count} =
        if now - window_start > window_ms do
          {now, 0}
        else
          {window_start, request_count}
        end

      if request_count >= requests_per_window do
        retry_after_ms = window_ms - (now - window_start)

        {:error, %JError{
          code: -32005,
          message: "Rate limit exceeded",
          category: :rate_limit,
          data: %{"retry_after_ms" => retry_after_ms},
          retriable?: true
        }}
      else
        request_count = request_count + 1
        {:ok, mock_response(method, params)}
      end
    end
  end

  @doc """
  Scenario: WebSocket connection instability

  Behavior:
  - WS connection drops randomly during active subscriptions
  - Some messages arrive out of order
  - Duplicate messages occasionally sent

  Real-world trigger: Network issues, provider restarts, load balancer failover
  """
  def websocket_instability(opts \\ []) do
    drop_probability = Keyword.get(opts, :drop_probability, 0.05)
    duplicate_probability = Keyword.get(opts, :duplicate_probability, 0.02)
    reorder_probability = Keyword.get(opts, :reorder_probability, 0.03)

    message_buffer = []

    fn :send_subscription_event, event ->
      # Simulate connection drops
      if :rand.uniform() < drop_probability do
        {:error, :connection_lost}
      else
        # Simulate duplicates
        events = if :rand.uniform() < duplicate_probability do
          [event, event]  # Send twice
        else
          [event]
        end

        # Simulate reordering
        events = if :rand.uniform() < reorder_probability and length(message_buffer) > 0 do
          # Delay this message, send buffered one first
          [hd(message_buffer) | events]
        else
          events
        end

        {:ok, events}
      end
    end
  end
end
```

### 3.2 Chaos Engineering Framework

**Design**: Structured chaos injection during battle tests.

```elixir
defmodule Lasso.Battle.Chaos do
  @moduledoc """
  Chaos engineering framework for battle tests.

  Injects controlled failures during test execution to validate
  system resilience under adverse conditions.
  """

  @doc """
  Kill random providers during test execution.

  Options:
  - :kill_interval - how often to kill a provider (ms)
  - :recovery_delay - how long before provider restarts (ms)
  - :kill_probability - chance of kill on each interval (0.0-1.0)
  """
  def random_provider_chaos(chain, opts \\ []) do
    kill_interval = Keyword.get(opts, :kill_interval, 5_000)
    recovery_delay = Keyword.get(opts, :recovery_delay, 2_000)
    kill_probability = Keyword.get(opts, :kill_probability, 0.3)

    Task.async(fn ->
      chaos_loop(chain, kill_interval, recovery_delay, kill_probability)
    end)
  end

  defp chaos_loop(chain, interval, recovery, probability) do
    Process.sleep(interval)

    providers = ProviderPool.list_active_providers(chain)

    if :rand.uniform() < probability and length(providers) > 1 do
      # Kill a random provider
      target = Enum.random(providers)

      Logger.warn("🔥 CHAOS: Killing provider #{target}")
      ProviderPool.kill_provider(chain, target)

      # Schedule recovery
      Process.sleep(recovery)
      Logger.info("♻️ CHAOS: Recovering provider #{target}")
      ProviderPool.restart_provider(chain, target)
    end

    chaos_loop(chain, interval, recovery, probability)
  end

  @doc """
  Inject network latency jitter.

  Simulates network conditions by adding variable latency to requests.
  """
  def network_jitter(base_latency_ms \\ 50, jitter_ms \\ 100) do
    fn request_fun ->
      latency = base_latency_ms + :rand.uniform(jitter_ms)
      Process.sleep(latency)
      request_fun.()
    end
  end

  @doc """
  Simulate memory pressure.

  Allocates memory to trigger GC pressure during test execution.
  """
  def memory_pressure(target_mb \\ 100, interval_ms \\ 1000) do
    Task.async(fn ->
      memory_pressure_loop(target_mb, interval_ms)
    end)
  end

  defp memory_pressure_loop(target_mb, interval) do
    # Allocate large binary
    size = target_mb * 1024 * 1024
    _blob = :binary.copy(<<0>>, size)

    Process.sleep(interval)
    # Binary gets GC'd, repeat
    memory_pressure_loop(target_mb, interval)
  end
end
```

### 3.3 Battle Test: Production Resilience Validation

**Example: End-to-end production scenario**

```elixir
defmodule Lasso.Battle.ProductionResilienceTest do
  use ExUnit.Case, async: false

  @moduletag :battle
  @moduletag :slow
  @moduletag timeout: 300_000  # 5 min

  alias Lasso.Battle.{Workload, Chaos, FailureScenarios, Metrics}

  test "maintains SLOs during realistic production chaos" do
    chain = "production_chaos_test"

    # Setup: 3 providers with different failure patterns
    SetupHelper.setup_providers(chain, [
      %{
        id: "primary",
        behavior: FailureScenarios.cascading_failure(
          healthy_duration: 30_000,
          degraded_duration: 60_000,
          recovery_duration: 30_000
        )
      },
      %{
        id: "backup",
        behavior: FailureScenarios.rate_limit_with_backoff(100, 10_000)
      },
      %{
        id: "fallback",
        behavior: FailureScenarios.node_out_of_sync(5, 45_000)
      }
    ])

    # Start chaos agents
    _chaos_task = Chaos.random_provider_chaos(chain,
      kill_interval: 10_000,
      recovery_delay: 5_000,
      kill_probability: 0.2
    )

    _memory_task = Chaos.memory_pressure(50, 5_000)

    # Run sustained workload
    result = Workload.new("production_resilience")
      |> Workload.set_duration(180_000)  # 3 minutes
      |> Workload.set_rps(10)  # 10 req/sec
      |> Workload.with_methods([
          {"eth_blockNumber", [], weight: 50},
          {"eth_call", [%{"to" => "0x123", "data" => "0x"}], weight: 30},
          {"eth_getBalance", ["0xaddr", "latest"], weight: 20}
        ])
      |> Workload.run(chain)
      |> Metrics.analyze()

    # Assert SLOs
    assert result.success_rate >= 0.99,
      "Success rate #{result.success_rate} below 99% SLO"

    assert result.p95_latency_ms <= 500,
      "P95 latency #{result.p95_latency_ms}ms exceeds 500ms SLO"

    assert result.max_gap_size == 0,
      "Gap detected during chaos: #{result.max_gap_size} blocks"

    # Verify failover occurred correctly
    assert result.providers_used >= 2,
      "Expected failover to multiple providers"

    assert result.circuit_breaker_opens > 0,
      "Expected circuit breakers to open during chaos"

    # Verify recovery
    assert result.final_health_state == :all_healthy,
      "Providers did not recover: #{inspect result.final_health_state}"
  end

  test "detects and handles provider node sync issues" do
    # Scenario: One provider falls behind, Lasso detects via gap detection
    # and switches to synced provider

    chain = "sync_detection_test"

    SetupHelper.setup_providers(chain, [
      %{id: "synced", behavior: :healthy},
      %{id: "lagging", behavior: FailureScenarios.node_out_of_sync(20, 60_000)}
    ])

    # Seed benchmarks to prefer lagging provider initially
    SetupHelper.seed_benchmarks(chain, "eth_blockNumber", [
      {"lagging", 50},
      {"synced", 200}
    ])

    result = Workload.new("sync_detection")
      |> Workload.set_duration(90_000)
      |> Workload.set_rps(5)
      |> Workload.with_subscription(:newHeads)
      |> Workload.run(chain)
      |> Metrics.analyze()

    # Assert gap detection triggered provider switch
    assert result.gap_detections > 0,
      "Expected gap detection to identify lagging provider"

    assert result.provider_switches > 0,
      "Expected switch from lagging to synced provider"

    # Verify final provider preference shifted
    final_provider = result.most_used_provider
    assert final_provider == "synced",
      "Expected to end on synced provider, got #{final_provider}"
  end
end
```

### 3.4 Statistical Analysis for Battle Tests

**Problem**: Battle tests produce lots of data, need rigorous analysis.

```elixir
defmodule Lasso.Battle.Metrics do
  @moduledoc """
  Statistical analysis for battle test results.
  """

  def analyze(workload_results) do
    %{
      # Basic metrics
      total_requests: length(workload_results.requests),
      successful_requests: count_successful(workload_results.requests),
      failed_requests: count_failed(workload_results.requests),
      success_rate: calculate_success_rate(workload_results.requests),

      # Latency analysis
      mean_latency_ms: Statistics.mean(workload_results.latencies),
      p50_latency_ms: Statistics.percentile(workload_results.latencies, 50),
      p95_latency_ms: Statistics.percentile(workload_results.latencies, 95),
      p99_latency_ms: Statistics.percentile(workload_results.latencies, 99),

      # Gap analysis (for subscriptions)
      gaps_detected: analyze_gaps(workload_results.subscription_events),
      max_gap_size: max_gap_size(workload_results.subscription_events),

      # Provider usage
      providers_used: unique_providers(workload_results.requests),
      provider_distribution: provider_usage_distribution(workload_results.requests),
      most_used_provider: most_used_provider(workload_results.requests),

      # Circuit breaker activity
      circuit_breaker_opens: count_cb_opens(workload_results.events),
      circuit_breaker_half_opens: count_cb_half_opens(workload_results.events),

      # Failover analysis
      failover_count: count_failovers(workload_results.requests),
      failover_success_rate: failover_success_rate(workload_results.requests),

      # Health state
      final_health_state: analyze_final_health(workload_results.providers)
    }
  end

  @doc """
  Compare two battle test runs for regression detection.
  """
  def compare(baseline_results, current_results) do
    %{
      success_rate_delta: current_results.success_rate - baseline_results.success_rate,
      p95_latency_delta: current_results.p95_latency_ms - baseline_results.p95_latency_ms,

      regressions: detect_regressions(baseline_results, current_results),
      improvements: detect_improvements(baseline_results, current_results)
    }
  end

  defp detect_regressions(baseline, current) do
    []
    |> check_regression(:success_rate, baseline, current, -0.01)  # 1% drop is regression
    |> check_regression(:p95_latency_ms, baseline, current, 100)  # 100ms increase is regression
    |> check_regression(:max_gap_size, baseline, current, 0)      # Any gap is regression
  end

  defp check_regression(regressions, metric, baseline, current, threshold) do
    baseline_value = Map.get(baseline, metric)
    current_value = Map.get(current, metric)
    delta = current_value - baseline_value

    if delta > threshold do
      [{metric, baseline_value, current_value, delta} | regressions]
    else
      regressions
    end
  end
end
```

---

## Phase 4: Advanced Real-World Simulation Options

### Option A: Provider Behavior Recording and Replay

**Concept**: Record real provider behavior in production, replay in tests.

```elixir
defmodule Lasso.Battle.ProviderRecorder do
  @moduledoc """
  Records real provider interactions for replay in tests.

  Usage:
  1. Enable recording in production (sample %)
  2. Export recording to test fixtures
  3. Replay in battle tests for realistic behavior
  """

  def record_provider_interaction(provider_id, method, params, response, metadata) do
    interaction = %{
      provider_id: provider_id,
      method: method,
      params: params,
      response: response,
      latency_ms: metadata.duration_ms,
      timestamp: System.system_time(:millisecond),
      error?: match?({:error, _}, response)
    }

    # Write to recording buffer (ETS or file)
    :ets.insert(:provider_recordings, {provider_id, interaction})
  end

  def export_recording(provider_id, output_path) do
    interactions = :ets.lookup(:provider_recordings, provider_id)
    File.write!(output_path, :erlang.term_to_binary(interactions))
  end

  def replay_from_recording(recording_path) do
    interactions = File.read!(recording_path) |> :erlang.binary_to_term()

    fn method, params ->
      # Find matching interaction from recording
      case find_interaction(interactions, method, params) do
        %{response: response, latency_ms: latency} ->
          Process.sleep(latency)
          response

        nil ->
          # Fallback if no match
          {:error, :no_recording_match}
      end
    end
  end
end

# Usage in test:
test "replays production provider behavior" do
  behavior = ProviderRecorder.replay_from_recording(
    "test/fixtures/infura_production_recording.etf"
  )

  {:ok, [provider]} = setup_test_chain_with_providers(
    chain,
    [%{id: "infura_replay", behavior: behavior}]
  )

  # Test executes with realistic production patterns
  # (latencies, error rates, response formats)
end
```

**Pros**:
- Extremely realistic (actual production data)
- Catches edge cases that might not be anticipated
- Can regression test against production baselines

**Cons**:
- Privacy concerns (production data in tests)
- Recordings can become stale
- Large recordings hard to manage

### Option B: Fuzz Testing for RPC Methods

**Concept**: Generate random valid/invalid params to discover edge cases.

```elixir
defmodule Lasso.Battle.RPCFuzzer do
  @moduledoc """
  Fuzzing framework for RPC methods.

  Generates random parameters and validates system behavior.
  """

  def fuzz_method(chain, method, generator_opts \\ []) do
    iterations = Keyword.get(generator_opts, :iterations, 1000)

    results = for _i <- 1..iterations do
      params = generate_params_for_method(method, generator_opts)

      result = RequestPipeline.execute_via_channels(
        chain,
        method,
        params,
        timeout: 5_000
      )

      %{
        params: params,
        result: result,
        category: categorize_result(result)
      }
    end

    analyze_fuzz_results(results)
  end

  defp generate_params_for_method("eth_call", opts) do
    [
      %{
        "to" => generate_address(opts),
        "data" => generate_hex_data(opts),
        "from" => generate_optional_address(opts),
        "gas" => generate_optional_quantity(opts)
      },
      generate_block_param(opts)
    ]
  end

  defp generate_address(_opts) do
    # Valid: 20-byte hex
    # Invalid: wrong length, no 0x prefix, bad chars
    case :rand.uniform(10) do
      n when n <= 7 -> "0x" <> random_hex(40)  # Valid
      8 -> "0x" <> random_hex(38)  # Too short
      9 -> random_hex(40)  # Missing 0x
      10 -> "0x" <> random_string(40)  # Invalid chars
    end
  end

  defp analyze_fuzz_results(results) do
    %{
      total: length(results),
      successes: count_by_category(results, :success),
      user_errors: count_by_category(results, :user_error),
      provider_errors: count_by_category(results, :provider_error),
      crashes: count_by_category(results, :crash),

      # Flag concerning patterns
      unexpected_successes: find_unexpected_successes(results),
      unexpected_errors: find_unexpected_errors(results),
      crashes_on_valid_input: find_crashes_on_valid_input(results)
    }
  end
end

# Battle test usage:
test "fuzzing reveals no crashes on malformed params" do
  chain = setup_test_chain()

  results = RPCFuzzer.fuzz_method(chain, "eth_call", iterations: 10_000)

  # System should never crash, even on garbage input
  assert results.crashes == 0,
    "System crashed on fuzzing: #{inspect results.crashes_on_valid_input}"

  # Invalid input should return user errors, not provider errors
  assert results.user_errors > results.provider_errors,
    "Too many provider errors on invalid input (should be user errors)"
end
```

### Option C: Load Testing with Realistic Traffic Patterns

**Concept**: Simulate production traffic distribution.

```elixir
defmodule Lasso.Battle.TrafficPattern do
  @moduledoc """
  Realistic traffic pattern simulation based on production data.
  """

  @doc """
  Simulate typical DeFi application traffic pattern.

  Characteristics:
  - eth_call (50% - contract reads)
  - eth_getBalance (20% - wallet balances)
  - eth_blockNumber (15% - polling)
  - eth_getLogs (10% - event monitoring)
  - Other methods (5%)

  Request rate varies: base RPS with 3x spikes every 2 minutes (block updates)
  """
  def defi_app_pattern(base_rps \\ 10) do
    %{
      method_distribution: [
        {"eth_call", 0.50},
        {"eth_getBalance", 0.20},
        {"eth_blockNumber", 0.15},
        {"eth_getLogs", 0.10},
        {"eth_getTransactionReceipt", 0.05}
      ],

      rps_pattern: fn elapsed_ms ->
        # Spike every 2 minutes (120_000 ms)
        cycle_position = rem(elapsed_ms, 120_000)

        if cycle_position < 5_000 do
          # Spike: 3x base RPS for 5 seconds
          base_rps * 3
        else
          base_rps
        end
      end,

      param_generators: %{
        "eth_call" => fn -> generate_realistic_contract_call() end,
        "eth_getBalance" => fn -> [generate_realistic_address(), "latest"] end,
        # ...
      }
    }
  end

  @doc """
  Simulate NFT marketplace traffic pattern.

  Characteristics:
  - Heavy getLogs usage (event monitoring)
  - Burst traffic during mints
  - Subscription-heavy (newHeads, logs)
  """
  def nft_marketplace_pattern(base_rps \\ 15) do
    # Different pattern...
  end
end

# Battle test:
test "handles DeFi app traffic pattern under load" do
  chain = setup_real_providers("ethereum")

  result = Workload.new("defi_load_test")
    |> Workload.with_traffic_pattern(TrafficPattern.defi_app_pattern(50))
    |> Workload.set_duration(600_000)  # 10 minutes
    |> Workload.run(chain)
    |> Metrics.analyze()

  # Assert maintains SLOs under realistic load
  assert result.success_rate >= 0.995
  assert result.p99_latency_ms <= 1000
end
```

---

## Implementation Roadmap

### Week 1: Infrastructure Foundation
- [ ] Implement `TelemetrySync` helper (replace `Process.sleep`)
- [ ] Implement `CircuitBreakerHelper` with lifecycle management
- [ ] Enhance `IntegrationHelper` with synchronization
- [ ] Create `LassoIntegrationCase` base test case
- [ ] Document testing patterns and best practices

**Deliverable**: Integration tests are deterministic and reliable

### Week 2: RequestPipeline Pilot
- [ ] Implement behavior-based `MockProvider`
- [ ] Write 6 focused RequestPipeline integration tests
- [ ] Validate infrastructure improvements (no flakes in 100 runs)
- [ ] Fix any issues discovered

**Deliverable**: RequestPipeline has comprehensive integration coverage

### Week 3: Battle Test Expansion
- [ ] Implement `FailureScenarios` catalog
- [ ] Implement `Chaos` engineering framework
- [ ] Create production resilience battle test
- [ ] Implement statistical analysis (`Metrics` module)

**Deliverable**: Battle tests validate real-world resilience

### Week 4: Advanced Simulation (Choose 1-2)
- [ ] Option A: Provider behavior recording/replay
- [ ] Option B: RPC fuzzing framework
- [ ] Option C: Realistic traffic pattern simulation

**Deliverable**: Advanced scenarios uncover edge cases

### Week 5: Continuous Validation
- [ ] Set up battle test suite in CI (nightly runs)
- [ ] Create regression detection pipeline
- [ ] Document findings and bug fixes
- [ ] Production readiness report

**Deliverable**: Automated validation for production confidence

---

## Success Criteria

**Infrastructure Quality**:
- ✅ Integration tests pass 100/100 runs (no flakes)
- ✅ Average test execution time <500ms per integration test
- ✅ Zero `Process.sleep` calls in integration test assertions
- ✅ Circuit breaker state properly isolated between tests

**Test Coverage**:
- ✅ RequestPipeline has 6+ integration tests covering critical paths
- ✅ 3+ battle tests validating real-world scenarios
- ✅ 1+ chaos engineering scenario running continuously

**Bug Discovery**:
- ✅ Identify and fix 5+ production-likely bugs through testing
- ✅ Document failure patterns and mitigations
- ✅ Regression suite prevents reintroduction

**Production Readiness**:
- ✅ 99%+ success rate under chaos conditions
- ✅ P95 latency <500ms under realistic load
- ✅ Zero gaps during provider failover
- ✅ Graceful degradation when providers unavailable

---

## Risk Mitigation

**Risk**: Test infrastructure changes break existing tests
- **Mitigation**: Implement incrementally, keep old patterns until new ones proven
- **Rollback**: `LassoIntegrationCase` is opt-in, can revert

**Risk**: Battle tests too slow for regular CI
- **Mitigation**: Separate fast integration tests (CI) from slow battle tests (nightly)
- **Gate**: Only promote to CI if <2min execution time

**Risk**: Mock behaviors don't reflect reality
- **Mitigation**: Use Option A (recording/replay) to validate against production
- **Validation**: Compare mock test results to battle test results with real providers

**Risk**: Chaos testing reveals critical unfixable issues
- **Mitigation**: Document as known limitations, implement mitigations
- **Escalation**: Reassess production readiness timeline

---

## Appendix: Quick Reference

### Test Type Decision Tree

```
Is this testing a single module's logic?
├─ YES → Unit test (existing framework)
└─ NO
    └─ Is this testing integration between 2-3 modules?
        ├─ YES → Integration test (LassoIntegrationCase)
        └─ NO
            └─ Is this validating end-to-end system behavior?
                ├─ YES → Battle test (real or mock providers)
                └─ UNSURE → Start with integration, escalate if needed
```

### Command Cheat Sheet

```bash
# Run integration tests only (fast, CI-friendly)
mix test --only integration

# Run battle tests (slow, comprehensive)
mix test --only battle --exclude real_providers

# Run battle tests with real providers (very slow, pre-prod validation)
mix test --only battle --only real_providers

# Run specific test file with detailed output
mix test test/integration/request_pipeline_integration_test.exs --trace

# Run battle test with metrics export
MIX_ENV=test mix test --only battle --export-metrics results.json
```

### Helper Usage Examples

```elixir
# Clean integration test setup
defmodule MyIntegrationTest do
  use LassoIntegrationCase

  test "my scenario", %{chain: chain} do
    # Chain is unique, CBs are clean, cleanup automatic
    {:ok, [p1, p2]} = IntegrationHelper.setup_test_chain_with_providers(
      chain,
      [%{id: "p1", ...}, %{id: "p2", ...}]
    )

    # Deterministic waiting
    {:ok, _} = TelemetrySync.wait_for_circuit_breaker_open(p1, :http)

    # Assertions...
  end
end

# Battle test with chaos
test "chaos scenario", %{chain: chain} do
  SetupHelper.setup_providers(chain, [...])

  _chaos = Chaos.random_provider_chaos(chain, kill_interval: 5_000)

  result = Workload.new("test")
    |> Workload.set_duration(60_000)
    |> Workload.run(chain)
    |> Metrics.analyze()

  assert result.success_rate >= 0.99
end
```

---

**Next Steps**:
1. Review and approve this spec
2. Begin Week 1 implementation (infrastructure foundation)
3. Use RequestPipeline as pilot to validate approach
4. Iterate based on findings
