# Mock Provider Testing Guide

**Quick, deterministic testing for Lasso's RPC routing and provider management.**

## Overview

`Lasso.Testing.MockProvider` provides lightweight HTTP mock servers that integrate with Lasso's real provider infrastructure. Unlike process-level mocks, these are real HTTP servers running on localhost that work with the full routing stack.

## Key Benefits

✅ **Fast & deterministic** - No network latency, predictable responses
✅ **Real integration** - Tests actual HTTP transport, circuit breakers, routing
✅ **Zero maintenance** - No API keys, no rate limits, no external dependencies
✅ **Easy setup** - One-liner to start multiple mocks
✅ **Automatic cleanup** - Mocks stop when test process exits

## Quick Start

### Basic Usage

```elixir
test "provider routing" do
  alias Lasso.Testing.MockProvider
  alias Lasso.RPC.RequestPipeline

  # Start a mock provider
  {:ok, "mock_1"} = MockProvider.start_mock("ethereum", %{
    id: "mock_1",
    latency: 10,
    reliability: 1.0,
    block_number: 0x1000
  })

  # Use it in requests
  {:ok, result} = RequestPipeline.execute_via_channels(
    "ethereum",
    "eth_blockNumber",
    [],
    provider_override: "mock_1"
  )

  assert result == "0x1000"
end
```

### Using Test Helpers

```elixir
test "fast mock helper" do
  alias Lasso.Test.MockHelper

  # Create a fast, reliable mock (10ms latency, 100% reliability)
  {:ok, provider_id} = MockHelper.create_fast_mock("ethereum")

  # Provider is ready to use immediately
end
```

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:id` | string | *required* | Provider identifier |
| `:latency` | integer | `0` | Response delay in milliseconds |
| `:reliability` | float | `1.0` | Success probability (0.0-1.0) |
| `:block_number` | integer | `0x1000` | Fixed block number to return |
| `:port` | integer | *auto* | HTTP port (auto-assigned if not specified) |
| `:priority` | integer | `100` | Provider priority for routing |
| `:response_fn` | function | *nil* | Custom response generator |

## Common Patterns

### Testing Failover Behavior

```elixir
test "failover to backup provider" do
  # Create unreliable primary
  {:ok, _} = MockProvider.start_mock("ethereum", %{
    id: "unreliable",
    reliability: 0.0,  # Always fails
    priority: 10
  })

  # Create reliable backup
  {:ok, _} = MockProvider.start_mock("ethereum", %{
    id: "backup",
    reliability: 1.0,
    priority: 20
  })

  # Request should failover to backup
  {:ok, _result} = RequestPipeline.execute_via_channels(
    "ethereum",
    "eth_blockNumber",
    [],
    strategy: :priority
  )
end
```

### Testing Load Balancing

```elixir
test "round robin across providers" do
  # Create pool of 3 providers
  {:ok, providers} = MockHelper.create_provider_pool("ethereum", 3)

  # Make multiple requests
  results = Enum.map(1..10, fn _ ->
    RequestPipeline.execute_via_channels(
      "ethereum",
      "eth_blockNumber",
      [],
      strategy: :round_robin
    )
  end)

  # All should succeed
  assert Enum.all?(results, fn r -> match?({:ok, _}, r) end)
end
```

### Testing Dynamic Provider Addition

```elixir
test "dynamically add provider mid-test" do
  # Start with one provider
  {:ok, _} = MockHelper.create_fast_mock("ethereum", id: "initial")

  # Make initial request
  {:ok, result1} = RequestPipeline.execute_via_channels(
    "ethereum", "eth_blockNumber", []
  )

  # Add another provider dynamically
  {:ok, _} = MockProvider.start_mock("ethereum", %{
    id: "dynamic",
    block_number: 0x5000,
    priority: 5  # Higher priority
  })

  Process.sleep(100)

  # New provider should be used
  {:ok, result2} = RequestPipeline.execute_via_channels(
    "ethereum",
    "eth_blockNumber",
    [],
    strategy: :priority
  )

  assert result2 == "0x5000"
end
```

### Custom Response Logic

```elixir
test "custom response function" do
  custom_response = fn request ->
    case request["method"] do
      "eth_blockNumber" ->
        %{"jsonrpc" => "2.0", "id" => 1, "result" => "0xABCD"}

      "eth_chainId" ->
        %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1"}

      _ ->
        %{"jsonrpc" => "2.0", "id" => 1, "error" => %{
          "code" => -32601,
          "message" => "Method not found"
        }}
    end
  end

  {:ok, _} = MockProvider.start_mock("ethereum", %{
    id: "custom",
    response_fn: custom_response
  })

  {:ok, result} = RequestPipeline.execute_via_channels(
    "ethereum",
    "eth_blockNumber",
    [],
    provider_override: "custom"
  )

  assert result == "0xABCD"
end
```

## Supported RPC Methods

Mock providers return realistic responses for all standard Ethereum methods:

| Method | Response |
|--------|----------|
| `eth_blockNumber` | Configurable hex number (default: `0x1000`) |
| `eth_chainId` | `0x1` (Ethereum mainnet) |
| `eth_getBalance` | Random balance |
| `eth_gasPrice` | Random gas price |
| `eth_call` | `0x0000...0001` |
| `eth_getLogs` | Empty array `[]` |
| Others | `0x0` |

## Integration vs Battle Testing

### When to Use Mocks

✅ **Integration tests** - Testing provider routing logic
✅ **Unit tests** - Testing isolated components
✅ **CI/CD pipelines** - Fast, reliable test runs
✅ **Local development** - Quick iteration without API keys

### When to Use Real Providers

✅ **Battle tests** - End-to-end system validation
✅ **Performance testing** - Real network conditions
✅ **Failover validation** - Actual provider failures
✅ **Pre-production testing** - Final validation before release

## Architecture Details

### How Mocks Integrate

```
┌─────────────────┐
│  Test Process   │
└────────┬────────┘
         │
         │ 1. MockProvider.start_mock()
         ▼
┌─────────────────────────────────────────┐
│  Cowboy HTTP Server (localhost:random)  │
└────────┬────────────────────────────────┘
         │
         │ 2. Providers.add_provider()
         ▼
┌─────────────────────────────────────────┐
│      ChainSupervisor                    │
│  ┌────────────────────────────────┐    │
│  │   ProviderPool (Health)        │    │
│  │   TransportRegistry (Channels) │    │
│  │   CircuitBreaker (Resilience)  │    │
│  └────────────────────────────────┘    │
└─────────────────────────────────────────┘
         │
         │ 3. RequestPipeline.execute()
         ▼
┌─────────────────────────────────────────┐
│  HTTP Request → Mock Server → Response  │
└─────────────────────────────────────────┘
```

### Automatic Cleanup

Mocks automatically clean up when the test process exits:

```elixir
test "auto cleanup demo" do
  {:ok, _} = MockProvider.start_mock("ethereum", %{id: "auto"})

  # Mock is available during test

  # No manual cleanup needed - monitor handles it
end
# Mock server stopped and provider removed automatically
```

## Troubleshooting

### Mock Not Responding

**Problem:** Requests timeout or fail
**Solution:** Ensure adequate sleep after `start_mock()`:

```elixir
{:ok, _} = MockProvider.start_mock("ethereum", %{id: "test"})
Process.sleep(300)  # Allow ChainSupervisor to initialize
```

### Port Conflicts

**Problem:** "Address already in use"
**Solution:** Let mock auto-assign ports (don't specify `:port`)

### Provider Not Found in Routing

**Problem:** `{:error, :not_found}` when requesting
**Solution:** Check provider was successfully registered:

```elixir
{:ok, provider_id} = MockProvider.start_mock("ethereum", config)
{:ok, providers} = Providers.list_providers("ethereum")
assert Enum.any?(providers, fn p -> p.id == provider_id end)
```

## Best Practices

1. **Use unique IDs** - Generate unique provider IDs per test:
   ```elixir
   id = "mock_#{:erlang.unique_integer([:positive])}"
   ```

2. **Allow initialization time** - Sleep 100-300ms after starting mocks

3. **Test deterministically** - Use fixed `block_number` for assertions:
   ```elixir
   {:ok, _} = MockProvider.start_mock("ethereum", %{
     id: "test",
     block_number: 0x2000
   })

   {:ok, result} = # ... make request
   assert result == "0x2000"
   ```

4. **Clean up explicitly for long tests** - For tests longer than a few seconds:
   ```elixir
   on_exit(fn ->
     MockProvider.stop_mock("ethereum", "my_provider")
   end)
   ```

5. **Use helpers for common patterns** - Leverage `MockHelper` for typical scenarios

## Examples in Codebase

See real examples in:

- `test/integration/dynamic_providers_test.exs` - Dynamic provider management
- `test/battle/real_provider_failover_test.exs` - Battle testing patterns
- `test/support/mock_helper.ex` - Helper utilities

## Migration from Old MockProvider

If you're using the old `Lasso.Battle.MockProvider`:

### Before (Battle.MockProvider)
```elixir
# ❌ Old approach - didn't integrate with ConfigStore
MockProvider.start_providers([
  {:provider_a, latency: 50}
])
```

### After (Testing.MockProvider)
```elixir
# ✅ New approach - full integration
MockProvider.start_mock("ethereum", %{
  id: "provider_a",
  latency: 50
})
```

Key improvements:
- Real `ChainSupervisor` integration
- Works with `Providers` API
- Automatic cleanup
- Better error handling
- Deterministic responses

---

**Ready to write fast, reliable tests!** 🚀

For questions or issues, see the main test suite or create an issue in the repository.
