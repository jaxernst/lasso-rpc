# Telemetry Testing Quick Reference

## TL;DR

**NEVER do this:**
```elixir
{:ok, result} = execute_request()
{:ok, m, meta} = TelemetrySync.wait_for_event([:event])  # ❌ TOO LATE!
```

**ALWAYS do this:**
```elixir
{:ok, collector} = TelemetrySync.attach_collector([:event])  # ✅ Attach FIRST
{:ok, result} = execute_request()                           # ✅ Execute
{:ok, m, meta} = TelemetrySync.await_event(collector)       # ✅ Wait
```

## Why?

Telemetry handlers execute **synchronously** when events fire. If you attach AFTER the event, you missed it forever.

## Common Patterns

### Pattern 1: Single Event

```elixir
test "request completes", %{chain: chain} do
  # 1. Attach
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  # 2. Execute
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # 3. Wait
  {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

  # 4. Assert
  assert measurements.duration > 0
  assert metadata.method == "eth_blockNumber"
end
```

### Pattern 2: Multiple Events (Retries)

```elixir
test "collects retry attempts", %{chain: chain} do
  # Attach with count
  {:ok, collector} = TelemetrySync.attach_request_collector(
    method: "eth_blockNumber",
    count: 3
  )

  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Returns list if multiple events
  case TelemetrySync.await_event(collector, timeout: 5000) do
    {:ok, events} when is_list(events) ->
      assert length(events) <= 3

    {:error, :timeout} ->
      :ok  # Only one attempt
  end
end
```

### Pattern 3: Convenience Wrapper

```elixir
test "request completes", %{chain: chain} do
  {:ok, measurements, metadata} = TelemetrySync.collect_event(
    [:lasso, :request, :completed],
    fn -> RequestPipeline.execute_via_channels(chain, "eth_blockNumber", []) end,
    match: %{method: "eth_blockNumber"},
    timeout: 1000
  )

  assert measurements.duration > 0
end
```

### Pattern 4: Setup Collectors

```elixir
describe "requests" do
  setup do
    # Pre-attach for all tests
    {:ok, collector} = TelemetrySync.attach_request_collector()
    {:ok, collector: collector}
  end

  test "test 1", %{collector: collector, chain: chain} do
    {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
    {:ok, m, meta} = TelemetrySync.await_event(collector)
    assert m.duration > 0
  end

  test "test 2", %{collector: collector, chain: chain} do
    {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_getBalance", ["0x...", "latest"])
    {:ok, m, meta} = TelemetrySync.await_event(collector)
    assert m.duration > 0
  end
end
```

## API Reference

### attach_collector/2

Attaches a telemetry handler before the action.

```elixir
{:ok, collector} = TelemetrySync.attach_collector(
  [:lasso, :request, :completed],
  match: %{method: "eth_blockNumber"},  # Filter by metadata
  count: 3                               # Expect N events
)
```

**Options:**
- `:match` - Map or predicate function to filter events
- `:count` - Number of events to collect (default: 1)

**Returns:** `{:ok, collector}`

### await_event/2

Waits for collected events.

```elixir
# Single event
{:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

# Multiple events
{:ok, events} = TelemetrySync.await_event(collector, timeout: 5000)
# events is list of {measurements, metadata} tuples
```

**Options:**
- `:timeout` - Maximum wait time in milliseconds (default: 5000)

**Returns:**
- `{:ok, measurements, metadata}` - Single event
- `{:ok, events}` - Multiple events if count > 1
- `{:error, :timeout}` - No matching events

### collect_event/3

Convenience wrapper for simple cases.

```elixir
{:ok, measurements, metadata} = TelemetrySync.collect_event(
  [:event, :name],
  fn -> execute_action() end,
  match: %{key: "value"},
  timeout: 1000
)
```

**Parameters:**
1. Event name
2. Action function (0-arity)
3. Options (same as attach_collector + timeout)

### attach_request_collector/1

Helper for request completion events.

```elixir
{:ok, collector} = TelemetrySync.attach_request_collector(
  method: "eth_blockNumber",  # Optional filter
  chain: "ethereum",          # Optional filter
  count: 1                    # Optional count
)
```

## Filtering Events

### By Metadata Map

```elixir
{:ok, collector} = TelemetrySync.attach_collector(
  [:event],
  match: %{method: "eth_blockNumber", status: :ok}
)
```

### By Predicate Function

```elixir
{:ok, collector} = TelemetrySync.attach_collector(
  [:event],
  match: fn measurements, metadata ->
    measurements.duration > 100 and metadata.method in ["eth_blockNumber", "eth_getBalance"]
  end
)
```

## Anti-Patterns

### ❌ Attaching After Action

```elixir
# WRONG - Event already fired
{:ok, result} = execute_request()
{:ok, collector} = TelemetrySync.attach_collector([:event])
{:ok, m, meta} = TelemetrySync.await_event(collector)  # Times out!
```

### ❌ Task.async + Process.sleep

```elixir
# WRONG - Race condition
task = Task.async(fn -> TelemetrySync.wait_for_event([:event]) end)
Process.sleep(50)  # Hoping handler attaches in time
{:ok, result} = execute_request()
{:ok, m, meta} = Task.await(task)  # May timeout!
```

### ❌ Using Old API

```elixir
# WRONG - Old TelemetrySync.wait_for_event has timing issues
{:ok, result} = execute_request()
{:ok, m, meta} = Lasso.Test.TelemetrySync.wait_for_event([:event])  # Broken!
```

## Correct Order

```
1. attach_collector    ← Handler registered
2. execute_action      ← Event fires, handler sends message
3. await_event         ← Retrieve message from mailbox
```

## Debugging

### Verify Handler Attached

```elixir
{:ok, collector} = TelemetrySync.attach_collector([:event])

handlers = :telemetry.list_handlers([:event])
IO.inspect(handlers, label: "Handlers")  # Should include collector.handler_id
```

### Trace Events

```elixir
:telemetry.attach(
  :debug,
  [:event],
  fn event, measurements, metadata, _ ->
    IO.puts("Event: #{inspect(event)}")
    IO.puts("Measurements: #{inspect(measurements)}")
    IO.puts("Metadata: #{inspect(metadata)}")
  end,
  nil
)
```

### Check Mailbox

```elixir
{:ok, collector} = TelemetrySync.attach_collector([:event])
execute_request()

# Check if message arrived
Process.info(self(), :messages)
# Should see: {ref, :telemetry_event, measurements, metadata}
```

## Migration Checklist

For each test:

- [ ] Find `TelemetrySync.wait_for_event` calls
- [ ] Replace with `attach_collector` BEFORE action
- [ ] Add `await_event` AFTER action
- [ ] Remove `Task.async` wrapping telemetry calls
- [ ] Remove `Process.sleep` calls
- [ ] Update to use `Lasso.Testing.TelemetrySync` (new module)
- [ ] Run test 100 times to verify no flakiness

## Quick Fixes

### Fix 1: Single Request

**Before:**
```elixir
{:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
{:ok, m} = TelemetrySync.wait_for_request_completed(method: "eth_blockNumber")
```

**After:**
```elixir
{:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")
{:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
{:ok, m, meta} = TelemetrySync.await_event(collector)
```

### Fix 2: Task.async Pattern

**Before:**
```elixir
task = Task.async(fn -> TelemetrySync.wait_for_event([:event]) end)
Process.sleep(50)
{:ok, result} = execute_request()
{:ok, m, meta} = Task.await(task)
```

**After:**
```elixir
{:ok, collector} = TelemetrySync.attach_collector([:event])
{:ok, result} = execute_request()
{:ok, m, meta} = TelemetrySync.await_event(collector)
```

### Fix 3: Multiple Events

**Before:**
```elixir
task = Task.async(fn ->
  TelemetrySync.collect_events([:event], timeout: 2000)
end)
Process.sleep(50)
{:ok, result} = execute_request()
events = Task.await(task)
```

**After:**
```elixir
{:ok, collector} = TelemetrySync.attach_collector([:event], count: 3)
{:ok, result} = execute_request()
{:ok, events} = TelemetrySync.await_event(collector, timeout: 2000)
```

## Key Insights

1. **Telemetry is synchronous** - Handlers run immediately when event fires
2. **Events are fire-and-forget** - No queue, no replay, no history
3. **Pre-attachment is mandatory** - Handler must exist before event
4. **Message passing is async** - Handler sends message to test process
5. **Mailbox buffering works** - Message waits until you receive it

## When to Use Which Pattern

| Scenario | Pattern | Reason |
|----------|---------|--------|
| Single event | attach_collector + await_event | Clean, explicit |
| Multiple retries | attach_collector(count: N) | Collects all attempts |
| Don't need result | collect_event | Less boilerplate |
| Multiple tests | Setup collectors | DRY |
| Complex filtering | Predicate function | Maximum flexibility |

## Further Reading

- [TELEMETRY_TIMEOUT_ROOT_CAUSE_ANALYSIS.md](./TELEMETRY_TIMEOUT_ROOT_CAUSE_ANALYSIS.md) - Root cause
- [TELEMETRY_TESTING_BEAM_SEMANTICS.md](./TELEMETRY_TESTING_BEAM_SEMANTICS.md) - Deep dive
- [CONCRETE_FIX_EXAMPLES.md](./CONCRETE_FIX_EXAMPLES.md) - Real examples
- [TELEMETRY_TESTING_MIGRATION_GUIDE.md](./TELEMETRY_TESTING_MIGRATION_GUIDE.md) - Migration steps

## Files Created

- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso/testing/telemetry_sync.ex` - New implementation
- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/test/lasso/testing/telemetry_sync_test.exs` - Tests
- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/test/integration/telemetry_integration_example_test.exs` - Examples
