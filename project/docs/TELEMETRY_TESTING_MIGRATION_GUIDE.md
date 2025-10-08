# Telemetry Testing Migration Guide

## Problem Statement

The current `Lasso.Test.TelemetrySync.wait_for_event/2` implementation attaches handlers **inside** the wait function. This creates a race condition where:

1. Test executes request (synchronously)
2. Request emits telemetry event
3. Event fires and is immediately discarded (no handlers attached)
4. Test calls `wait_for_event/2`
5. Handler is attached (too late!)
6. Test times out waiting for an event that already fired

## The Fix: Pre-Attachment Pattern

The solution is to separate handler attachment from event waiting:

### Old API (Broken)

```elixir
# BROKEN: Handler attached AFTER event fires
{:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

# This will timeout!
{:ok, measurements, metadata} = TelemetrySync.wait_for_event(
  [:lasso, :request, :completed],
  match: %{method: "eth_blockNumber"}
)
```

### New API (Fixed)

```elixir
# CORRECT: Attach handler FIRST
{:ok, collector} = TelemetrySync.attach_collector([:lasso, :request, :completed])

# THEN execute request
{:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

# Now wait for collected event
{:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
```

## Migration Steps

### Step 1: Replace wait_for_event with attach_collector + await_event

**Before:**
```elixir
test "request completes", %{chain: chain} do
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  {:ok, measurements, metadata} = TelemetrySync.wait_for_event(
    [:lasso, :request, :completed],
    match: %{method: "eth_blockNumber"},
    timeout: 1000
  )

  assert measurements.duration > 0
end
```

**After:**
```elixir
test "request completes", %{chain: chain} do
  # Attach BEFORE executing
  {:ok, collector} = TelemetrySync.attach_collector(
    [:lasso, :request, :completed],
    match: %{method: "eth_blockNumber"}
  )

  # Execute request
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Wait for collected event
  {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

  assert measurements.duration > 0
end
```

### Step 2: Replace convenience helpers

**Before:**
```elixir
test "request completes", %{chain: chain} do
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  {:ok, measurements} = TelemetrySync.wait_for_request_completed(
    method: "eth_blockNumber",
    timeout: 1000
  )
end
```

**After:**
```elixir
test "request completes", %{chain: chain} do
  # Use new attach helper
  {:ok, collector} = TelemetrySync.attach_request_collector(
    method: "eth_blockNumber"
  )

  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
end
```

### Step 3: Use collect_event for simple cases

**Before:**
```elixir
test "request completes", %{chain: chain} do
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  {:ok, measurements} = TelemetrySync.wait_for_request_completed(
    method: "eth_blockNumber"
  )
end
```

**After (if you don't need the result):**
```elixir
test "request completes", %{chain: chain} do
  {:ok, measurements, metadata} = TelemetrySync.collect_event(
    [:lasso, :request, :completed],
    fn -> RequestPipeline.execute_via_channels(chain, "eth_blockNumber", []) end,
    match: %{method: "eth_blockNumber"},
    timeout: 1000
  )
end
```

## Common Patterns

### Pattern 1: Multiple Events

**Before:**
```elixir
test "collects retries" do
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # This would only catch ONE event, and only if lucky with timing
  {:ok, measurements} = TelemetrySync.wait_for_request_completed(method: "eth_blockNumber")
end
```

**After:**
```elixir
test "collects retries" do
  {:ok, collector} = TelemetrySync.attach_request_collector(
    method: "eth_blockNumber",
    count: 3  # Expect up to 3 attempts
  )

  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  case TelemetrySync.await_event(collector, timeout: 5000) do
    {:ok, events} when is_list(events) ->
      # Multiple attempts occurred
      assert length(events) <= 3

    {:error, :timeout} ->
      # Only one attempt (happy path)
      :ok
  end
end
```

### Pattern 2: Async Operations

**Before:**
```elixir
test "async requests" do
  task = Task.async(fn ->
    RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
  end)

  # Race condition: might attach before or after event fires
  {:ok, measurements} = TelemetrySync.wait_for_request_completed(method: "eth_blockNumber")

  Task.await(task)
end
```

**After:**
```elixir
test "async requests" do
  # Attach BEFORE starting task
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  task = Task.async(fn ->
    RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
  end)

  Task.await(task)

  # Event was captured during task execution
  {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
end
```

### Pattern 3: Setup Collectors

**Before:**
```elixir
describe "requests" do
  test "test 1", %{chain: chain} do
    {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
    {:ok, measurements} = TelemetrySync.wait_for_request_completed(method: "eth_blockNumber")
  end

  test "test 2", %{chain: chain} do
    {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_getBalance", ["0x...", "latest"])
    {:ok, measurements} = TelemetrySync.wait_for_request_completed(method: "eth_getBalance")
  end
end
```

**After:**
```elixir
describe "requests" do
  setup do
    # Pre-attach collector for all tests in this describe block
    {:ok, request_collector} = TelemetrySync.attach_request_collector()

    {:ok, collectors: %{request: request_collector}}
  end

  test "test 1", %{chain: chain, collectors: collectors} do
    {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
    {:ok, measurements, metadata} = TelemetrySync.await_event(collectors.request, timeout: 1000)
    assert metadata.method == "eth_blockNumber"
  end

  test "test 2", %{chain: chain, collectors: collectors} do
    {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_getBalance", ["0x...", "latest"])
    {:ok, measurements, metadata} = TelemetrySync.await_event(collectors.request, timeout: 1000)
    assert metadata.method == "eth_getBalance"
  end
end
```

## API Compatibility Layer

To ease migration, we can provide a compatibility layer that warns about the old pattern:

```elixir
defmodule Lasso.Test.TelemetrySync do
  @deprecated_warning """
  WARNING: wait_for_event/2 has a fundamental timing issue.

  Old pattern (BROKEN):
    {:ok, result} = execute_request()
    {:ok, m, meta} = TelemetrySync.wait_for_event(...)

  New pattern (CORRECT):
    {:ok, collector} = TelemetrySync.attach_collector(...)
    {:ok, result} = execute_request()
    {:ok, m, meta} = TelemetrySync.await_event(collector)

  Or use:
    {:ok, m, meta} = TelemetrySync.collect_event(..., fn -> execute_request() end)
  """

  @doc deprecated: @deprecated_warning
  def wait_for_event(event_name, opts \\ []) do
    # Old implementation with warning
    IO.warn(@deprecated_warning, Macro.Env.stacktrace(__ENV__))

    # Still works for collect_events pattern where handler is attached first
    # but warn anyway to encourage migration
    # ... existing implementation ...
  end

  # New API
  def attach_collector(event_name, opts \\ []), do: # ...
  def await_event(collector, opts \\ []), do: # ...
  def collect_event(event_name, action_fn, opts \\ []), do: # ...
end
```

## Testing the Migration

### Verification Test

Create a test that demonstrates the issue and verifies the fix:

```elixir
defmodule Lasso.TelemetrySyncMigrationTest do
  use ExUnit.Case

  test "OLD API: demonstrates timing issue" do
    event_name = [:test, :old, :api]

    # Execute action (event fires)
    :telemetry.execute(event_name, %{value: 42}, %{})

    # Try to wait (will timeout)
    assert {:error, :timeout} = Lasso.Test.TelemetrySync.wait_for_event(
      event_name,
      timeout: 100
    )
  end

  test "NEW API: demonstrates correct pattern" do
    event_name = [:test, :new, :api]

    # Attach FIRST
    {:ok, collector} = Lasso.Testing.TelemetrySync.attach_collector(event_name)

    # Execute action
    :telemetry.execute(event_name, %{value: 42}, %{})

    # Wait for collected event (succeeds)
    assert {:ok, measurements, _metadata} = Lasso.Testing.TelemetrySync.await_event(
      collector,
      timeout: 100
    )
    assert measurements.value == 42
  end

  test "NEW API: collect_event convenience" do
    event_name = [:test, :convenience, :api]

    # All-in-one
    assert {:ok, measurements, _metadata} = Lasso.Testing.TelemetrySync.collect_event(
      event_name,
      fn -> :telemetry.execute(event_name, %{value: 42}, %{}) end,
      timeout: 100
    )
    assert measurements.value == 42
  end
end
```

## Deprecation Timeline

1. **Phase 1: Add new API** (Week 1)
   - Implement `attach_collector/2`, `await_event/2`, `collect_event/3`
   - Keep old API working with deprecation warnings
   - Add migration guide (this document)

2. **Phase 2: Migrate tests** (Week 2-3)
   - Update all existing tests to use new API
   - Run full test suite to verify correctness
   - Document any issues

3. **Phase 3: Remove old API** (Week 4)
   - Remove `wait_for_event/2` and convenience wrappers
   - Update documentation
   - Final test suite run

## Rollout Checklist

- [ ] Implement new `Lasso.Testing.TelemetrySync` module
- [ ] Write comprehensive tests for new API
- [ ] Add deprecation warnings to old API
- [ ] Migrate integration tests
- [ ] Migrate unit tests
- [ ] Update all documentation
- [ ] Update README examples
- [ ] Remove old API after verification

## FAQ

### Q: Why can't we just make wait_for_event work?

**A:** Telemetry handlers execute synchronously in the calling process. By the time `wait_for_event/2` is called, the event has already fired and been discarded. There's no event history or replay mechanism. The only solution is to attach handlers BEFORE events fire.

### Q: What if I'm testing async code?

**A:** Attach the collector before starting the async operation:

```elixir
{:ok, collector} = TelemetrySync.attach_collector(...)

task = Task.async(fn ->
  # This will emit telemetry
  do_async_work()
end)

Task.await(task)

# Event was captured during async execution
{:ok, m, meta} = TelemetrySync.await_event(collector)
```

### Q: Can I reuse collectors across tests?

**A:** No, each collector should be used once. Collectors automatically detach after `await_event/2` completes. For multiple tests, attach in `setup`:

```elixir
setup do
  {:ok, collector} = TelemetrySync.attach_collector(...)
  {:ok, collector: collector}
end
```

### Q: What about collect_events (duration-based)?

**A:** `collect_events/2` is fine because it attaches FIRST, then collects for a duration. This is the correct pattern:

```elixir
# Correct: Attaches, then waits for duration
events = TelemetrySync.collect_events([:event], timeout: 1000)

# During this 1 second, execute actions that emit events
# ...

# After timeout, returns all collected events
```

### Q: How do I debug timing issues?

**A:** Add logging to verify attachment order:

```elixir
test "debug timing" do
  IO.puts("1. Attaching collector")
  {:ok, collector} = TelemetrySync.attach_collector([:event])

  handlers = :telemetry.list_handlers([:event])
  IO.puts("2. Handlers attached: #{length(handlers)}")

  IO.puts("3. Executing action")
  execute_action()

  IO.puts("4. Waiting for event")
  {:ok, m, meta} = TelemetrySync.await_event(collector)

  IO.puts("5. Event received")
end
```

## Additional Resources

- [TELEMETRY_TESTING_BEAM_SEMANTICS.md](./TELEMETRY_TESTING_BEAM_SEMANTICS.md) - Deep dive into BEAM fundamentals
- [`:telemetry` documentation](https://hexdocs.pm/telemetry/)
- [`telemetry_test` library](https://hexdocs.pm/telemetry_test/) - Alternative approach
