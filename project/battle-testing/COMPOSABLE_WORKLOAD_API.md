# Composable Workload API

**Version:** 2.0
**Date:** October 2, 2025
**Status:** Implemented and Production-Ready

---

## Overview

The Composable Workload API provides a flexible, functional approach to battle testing that separates **what to execute** (request primitives) from **how to execute it** (load patterns).

This design enables:
- **Fair performance comparisons** - Test identical code paths with different transports
- **Maximum flexibility** - Compose primitives to create custom test scenarios
- **Clear intent** - Tests read like specifications
- **Backward compatibility** - Legacy API still supported

---

## Architecture: Three Composable Layers

### Layer 1: Request Primitives (What to Execute)

```elixir
# HTTP client → Phoenix endpoint → RequestPipeline → Provider
Workload.http(chain, method, params, opts)

# Direct internal call → RequestPipeline → Provider (bypasses HTTP layer)
Workload.direct(chain, method, params, opts)

# Custom function - do anything
Workload.custom(fn -> ... end)
```

### Layer 2: Load Patterns (How to Execute)

```elixir
# Constant rate
Workload.constant(request_fn, rate: 10, duration: 30_000)

# Poisson distribution (realistic arrival pattern)
Workload.poisson(request_fn, lambda: 100, duration: 60_000)

# Burst pattern (spike testing)
Workload.burst(request_fn, burst_size: 50, interval: 5000, count: 10)

# Ramp up (load testing)
Workload.ramp(request_fn, from: 10, to: 100, duration: 60_000)
```

### Layer 3: Composition

Combine primitives with patterns to create sophisticated test scenarios.

---

## Request Primitives

### `Workload.http/4` - HTTP Client to Phoenix

Tests the **full stack**: HTTP client → Phoenix → RequestPipeline → Provider

```elixir
# Basic usage
{:ok, result} = Workload.http("ethereum", "eth_blockNumber")

# With parameters and options
{:ok, balance} = Workload.http(
  "ethereum",
  "eth_getBalance",
  ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb", "latest"],
  strategy: :fastest,
  timeout: 10_000
)
```

**Options:**
- `:endpoint` - Full URL (default: `"http://localhost:4002/rpc/{chain}"`)
- `:timeout` - Request timeout in ms (default: 5000)
- `:strategy` - Routing strategy (default: nil, uses chain default)

**Returns:**
- `{:ok, result}` on success
- `{:error, reason}` on failure

**Use when:** Testing end-to-end HTTP stack, load testing Phoenix endpoint

---

### `Workload.direct/4` - Direct RequestPipeline Call

Tests **upstream routing** only: RequestPipeline → Provider selection → Upstream transport

**This is the preferred way to compare HTTP vs WebSocket upstream performance.**

```elixir
# Test HTTP upstream routing
{:ok, result} = Workload.direct("ethereum", "eth_blockNumber", [], transport: :http)

# Test WebSocket upstream routing
{:ok, result} = Workload.direct("ethereum", "eth_blockNumber", [], transport: :ws)

# Test both transports (default)
{:ok, result} = Workload.direct("ethereum", "eth_blockNumber", [], transport: :both)

# Test provider failover
{:ok, result} = Workload.direct(
  "ethereum",
  "eth_blockNumber",
  [],
  provider_override: "flaky_provider",
  failover_on_override: true
)
```

**Options:**
- `:transport` - Force transport type: `:http`, `:ws`, or `:both` (default: `:both`)
- `:strategy` - Routing strategy (default: `:round_robin`)
- `:provider_override` - Force specific provider
- `:failover_on_override` - Allow failover when override fails (default: false)
- `:timeout` - Request timeout in ms (default: 30_000)

**Returns:**
- `{:ok, result}` on success
- `{:error, reason}` on failure

**Use when:**
- Comparing HTTP vs WebSocket upstream performance
- Testing routing logic
- Testing provider failover
- Avoiding HTTP client/Phoenix overhead in measurements

---

### `Workload.custom/1` - Custom Function

Maximum flexibility - execute any function as a workload.

```elixir
# Custom failover timing
custom_fn = fn ->
  start = System.monotonic_time(:microsecond)

  result = Workload.direct("ethereum", "eth_blockNumber",
    provider_override: "flaky",
    failover_on_override: true
  )

  duration = System.monotonic_time(:microsecond) - start

  # Emit custom telemetry
  :telemetry.execute([:battle, :failover_time],
    %{duration_us: duration},
    %{success: match?({:ok, _}, result)}
  )

  result
end

Workload.custom(custom_fn)
```

**Use when:**
- Custom measurement logic
- Complex scenarios requiring multi-step operations
- Emitting custom telemetry events

---

## Load Patterns

### `Workload.constant/2` - Fixed Rate Execution

Executes requests at a constant rate (X requests per second).

```elixir
http_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :http) end

Workload.constant(http_fn,
  rate: 10,              # 10 requests per second
  duration: 30_000,      # for 30 seconds
  on_error: fn error -> Logger.error("Failed: #{inspect(error)}") end
)
```

**Options:**
- `:rate` - Requests per second (required)
- `:duration` - Duration in milliseconds (required)
- `:on_result` - Callback for each successful result
- `:on_error` - Callback for each error

**Returns:** `:ok` when complete

---

### `Workload.poisson/2` - Realistic Arrival Pattern

Executes requests with Poisson-distributed arrival times (more realistic than constant rate).

```elixir
mixed_fn = fn ->
  method = Enum.random(["eth_blockNumber", "eth_chainId", "eth_gasPrice"])
  Workload.direct("ethereum", method, transport: :ws)
end

Workload.poisson(mixed_fn,
  lambda: 100,      # Average 100 req/s
  duration: 60_000  # for 60 seconds
)
```

**Options:**
- `:lambda` - Average requests per second (required)
- `:duration` - Duration in milliseconds (required)

**Returns:** `:ok` when complete

---

### `Workload.burst/2` - Spike Testing

Executes bursts of requests at intervals.

```elixir
ws_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :ws) end

Workload.burst(ws_fn,
  burst_size: 50,    # 50 requests per burst
  interval: 5000,    # Every 5 seconds
  count: 10          # 10 total bursts
)
```

**Options:**
- `:burst_size` - Number of requests per burst (required)
- `:interval` - Time between bursts in ms (required)
- `:count` - Number of bursts (required)

**Returns:** `:ok` when complete

---

### `Workload.ramp/2` - Gradual Load Increase

Gradually increases request rate to find breaking points.

```elixir
http_endpoint_fn = fn -> Workload.http("ethereum", "eth_blockNumber") end

Workload.ramp(http_endpoint_fn,
  from: 10,          # Start at 10 req/s
  to: 100,           # Ramp to 100 req/s
  duration: 60_000,  # Over 60 seconds
  steps: 10          # In 10 increments
)
```

**Options:**
- `:from` - Starting rate (req/s, required)
- `:to` - Ending rate (req/s, required)
- `:duration` - Ramp duration in ms (required)
- `:steps` - Number of rate increments (default: 10)

**Returns:** `:ok` when complete

---

## Composition Examples

### Example 1: Compare HTTP vs WebSocket Upstream Performance

```elixir
test "upstream transport comparison" do
  result =
    Scenario.new("Upstream Transport: HTTP vs WebSocket")
    |> Scenario.setup(fn ->
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
        {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"}
      ])
      {:ok, %{}}
    end)
    |> Scenario.workload(fn ->
      # Define workload functions
      http_upstream = fn ->
        Workload.direct("ethereum", "eth_blockNumber", [], transport: :http)
      end

      ws_upstream = fn ->
        Workload.direct("ethereum", "eth_blockNumber", [], transport: :ws)
      end

      # Run both in parallel at same rate for fair comparison
      tasks = [
        Task.async(fn -> Workload.constant(http_upstream, rate: 10, duration: 30_000) end),
        Task.async(fn -> Workload.constant(ws_upstream, rate: 10, duration: 30_000) end)
      ]

      Task.await_many(tasks, :infinity)
      :ok
    end)
    |> Scenario.collect([:requests, :system])
    |> Scenario.slo(success_rate: 0.95, p95_latency_ms: 1000)
    |> Scenario.run()

  # Report will show transport-specific breakdown:
  # HTTP Transport: P50=129.7ms, P95=625.3ms
  # WebSocket Transport: P50=0.14ms, P95=0.30ms
  # Comparison: WebSocket is 129.57ms faster at P50

  assert result.passed?
end
```

### Example 2: End-to-End HTTP Stack Load Test

```elixir
test "http endpoint capacity" do
  result =
    Scenario.new("HTTP Endpoint Load Test")
    |> Scenario.setup(fn ->
      SetupHelper.setup_providers("ethereum", @providers)
      {:ok, %{}}
    end)
    |> Scenario.workload(fn ->
      http_endpoint = fn ->
        Workload.http("ethereum", "eth_blockNumber")
      end

      # Ramp up to find capacity limits
      Workload.ramp(http_endpoint, from: 10, to: 200, duration: 120_000)
    end)
    |> Scenario.collect([:requests, :system])
    |> Scenario.slo(success_rate: 0.99, p99_latency_ms: 2000)
    |> Scenario.run()

  assert result.passed?
end
```

### Example 3: Custom Failover Measurement

```elixir
test "failover performance under load" do
  result =
    Scenario.new("Failover Performance")
    |> Scenario.setup(fn ->
      SetupHelper.setup_providers("ethereum", [
        {:mock, "flaky", latency: 50, reliability: 0.5},
        {:real, "backup", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])
      {:ok, %{}}
    end)
    |> Scenario.workload(fn ->
      # Custom workload to measure failover timing
      failover_test = fn ->
        start = System.monotonic_time(:microsecond)

        result = Workload.direct("ethereum", "eth_blockNumber",
          provider_override: "flaky",
          failover_on_override: true,
          strategy: :round_robin
        )

        duration_us = System.monotonic_time(:microsecond) - start

        # Emit custom telemetry
        :telemetry.execute([:battle, :failover_time],
          %{duration_us: duration_us},
          %{success: match?({:ok, _}, result)}
        )

        result
      end

      Workload.constant(failover_test, rate: 5, duration: 60_000)
    end)
    |> Scenario.collect([:requests])
    |> Scenario.slo(success_rate: 0.95)
    |> Scenario.run()

  assert result.passed?
end
```

### Example 4: Mixed Method Distribution

```elixir
test "realistic mixed workload" do
  result =
    Scenario.new("Mixed Method Workload")
    |> Scenario.setup(fn ->
      SetupHelper.setup_providers("ethereum", @providers)
      {:ok, %{}}
    end)
    |> Scenario.workload(fn ->
      # Simulate realistic traffic with method distribution
      mixed_methods = fn ->
        case :rand.uniform(100) do
          n when n <= 40 ->
            # 40% - Simple queries
            Workload.direct("ethereum", "eth_blockNumber", transport: :ws)
          n when n <= 70 ->
            # 30% - Balance checks
            addr = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb"
            Workload.direct("ethereum", "eth_getBalance", [addr, "latest"], transport: :ws)
          _ ->
            # 30% - Gas price
            Workload.direct("ethereum", "eth_gasPrice", transport: :ws)
        end
      end

      # Poisson arrival pattern more realistic than constant
      Workload.poisson(mixed_methods, lambda: 50, duration: 120_000)
    end)
    |> Scenario.collect([:requests, :system])
    |> Scenario.slo(success_rate: 0.99, p95_latency_ms: 500)
    |> Scenario.run()

  assert result.passed?
end
```

---

## Migration from Legacy API

### Before (Legacy API)

```elixir
Workload.http_constant(
  chain: "ethereum",
  method: "eth_blockNumber",
  rate: 10,
  duration: 30_000
)

Workload.ws_constant(
  chain: "ethereum",
  method: "eth_blockNumber",
  rate: 10,
  duration: 30_000
)
```

### After (Composable API)

```elixir
# HTTP endpoint test
http_fn = fn -> Workload.http("ethereum", "eth_blockNumber") end
Workload.constant(http_fn, rate: 10, duration: 30_000)

# WebSocket upstream test
ws_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :ws) end
Workload.constant(ws_fn, rate: 10, duration: 30_000)
```

### Benefits of Migration

1. **Clearer intent** - Separate "what" from "how"
2. **More testable** - Primitives can be unit tested independently
3. **More flexible** - Easy to compose custom scenarios
4. **Fair comparisons** - Use `direct` with different transports for apples-to-apples

---

## Transport-Specific Reporting

The Analyzer now provides transport-specific breakdowns when testing with `Workload.direct`:

```markdown
### HTTP Requests

- Total: 161
- Successes: 161
- Success Rate: 100.0%
- P50 Latency: 0.203ms

#### HTTP Transport to Upstream
- Total: 61
- P50 Latency: 129.712ms
- P95 Latency: 625.343ms
- P99 Latency: 937.621ms

#### WebSocket Transport to Upstream
- Total: 100
- P50 Latency: 0.142ms
- P95 Latency: 0.303ms
- P99 Latency: 4.002ms

#### Transport Comparison
- P50: WebSocket is 129.57ms faster than HTTP
- P95: WebSocket is 625.04ms faster than HTTP
- P99: WebSocket is 933.62ms faster than HTTP
```

---

## Best Practices

### 1. Use `direct` for Transport Comparison

❌ **Don't compare different code paths:**
```elixir
# BAD: Comparing different things
Workload.http("ethereum", "eth_blockNumber")  # Full HTTP stack
Workload.ws_constant(...)                      # Direct pipeline call
```

✅ **Do compare identical paths with different transports:**
```elixir
# GOOD: Fair comparison
Workload.direct("ethereum", "eth_blockNumber", transport: :http)
Workload.direct("ethereum", "eth_blockNumber", transport: :ws)
```

### 2. Define Functions Outside Loops

❌ **Don't create functions inside hot paths:**
```elixir
for _ <- 1..1000 do
  Task.async(fn -> Workload.direct(...) end)  # Creates 1000 anonymous functions
end
```

✅ **Do define once, reuse:**
```elixir
workload_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :ws) end
Workload.constant(workload_fn, rate: 10, duration: 30_000)
```

### 3. Use Appropriate Load Patterns

- **Constant** - Baseline performance, SLO validation
- **Poisson** - Realistic traffic simulation
- **Burst** - Spike/capacity testing
- **Ramp** - Finding breaking points

### 4. Match Test Duration to Goals

- **Quick smoke test** - 10-30 seconds
- **Steady-state validation** - 2-5 minutes
- **Soak testing** - 30+ minutes
- **Capacity planning** - Use `ramp` over 5-10 minutes

---

## Implementation Details

### Concurrency Model

- Each request executes in its own `Task`
- Load patterns control timing, not concurrency limits
- System automatically handles backpressure via BEAM scheduler

### Telemetry Integration

All primitives emit production telemetry events:
- `[:lasso, :rpc, :request, :start]`
- `[:lasso, :rpc, :request, :stop]`
- `[:lasso, :rpc, :request, :exception]`

The Battle Collector captures these automatically.

### Timing Precision

- Request timing uses `System.monotonic_time(:microsecond)`
- Captures from RequestPipeline start to response received
- Includes provider selection, upstream call, and response parsing

---

## Future Enhancements

Planned for future versions:

1. **WebSocket client primitive** - `Workload.ws()` for full Phoenix Socket testing
2. **Subscription workloads** - Specialized primitives for `eth_subscribe`
3. **Adaptive load patterns** - Auto-adjust rate based on latency/errors
4. **Distributed workloads** - Coordinate load across multiple nodes

---

## Summary

The Composable Workload API provides:

✅ **Flexibility** - Mix and match primitives with patterns
✅ **Clarity** - Tests read like specifications
✅ **Fair comparisons** - Test identical paths with different configs
✅ **Backward compatible** - Legacy API still works
✅ **Production-grade** - Uses real telemetry, real code paths

**Key takeaway:** Use `Workload.direct` with `transport: :http` vs `:ws` for fair upstream transport comparison.
