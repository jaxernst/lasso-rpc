# Telemetry Testing: BEAM Semantics and Patterns

## Executive Summary

**Problem**: Tests that attach telemetry handlers AFTER executing actions will always timeout, because telemetry events are fire-and-forget with no history or replay mechanism.

**Solution**: Always attach handlers BEFORE triggering the action that emits telemetry. This document explains why from BEAM VM fundamentals through production patterns.

## Part 1: BEAM Fundamentals

### Telemetry Handler Execution Model

Telemetry handlers execute **synchronously** in the **calling process** when `:telemetry.execute/3` is invoked:

```elixir
# Inside your application code
def handle_request(request) do
  result = process_request(request)

  # This blocks until ALL handlers complete
  :telemetry.execute(
    [:lasso, :request, :completed],
    %{duration: 100},
    %{method: request.method}
  )

  result
end
```

Under the hood (simplified `:telemetry` implementation):

```elixir
defmodule :telemetry do
  def execute(event_name, measurements, metadata) do
    # Lookup happens in ETS (fast)
    handlers = :ets.lookup(@handler_table, event_name)

    # Each handler runs SYNCHRONOUSLY in THIS process
    # No message passing, no scheduling delay
    for handler <- handlers do
      try do
        # Direct function call - runs immediately
        handler.function.(event_name, measurements, metadata, handler.config)
      rescue
        exception ->
          # Handlers can't crash the caller
          Logger.error("Telemetry handler failed: #{inspect(exception)}")
      end
    end

    :ok
  end
end
```

### Key BEAM Semantics

1. **Synchronous Execution**: Handlers are plain function calls, not messages
2. **Same Process Context**: Handlers run in the emitting process, not handler's process
3. **Ordered Execution**: Handlers execute in attachment order
4. **No Event Queue**: Events don't go into a mailbox; they execute immediately
5. **No Replay**: Once `:telemetry.execute/3` returns, the event is gone forever

### Process Scheduling and Message Ordering

The BEAM scheduler guarantees:

```elixir
# Process A (your test)
def test_with_messages do
  send(self(), :message_1)
  send(self(), :message_2)

  # Messages arrive in order: [:message_1, :message_2]
  # But telemetry is NOT messages!
end

# Process B (application code)
def emit_telemetry do
  # This is NOT a message send
  :telemetry.execute([:event], %{}, %{})
  # Handlers already ran by the time we reach this line
end
```

**Critical difference**: Message passing is asynchronous and queued; telemetry handler invocation is synchronous and immediate.

## Part 2: Why Your Pattern Failed

### The Broken Pattern

```elixir
test "broken telemetry test" do
  # Time T1: No handlers attached
  handlers_before = :telemetry.list_handlers([:lasso, :request, :completed])
  # => []

  # Time T2: Execute request (synchronous - blocks until done)
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Inside RequestPipeline.execute_via_channels, this happened:
  #   :telemetry.execute([:lasso, :request, :completed], measurements, metadata)
  #   # No handlers attached, so event disappeared

  # Time T3: NOW attach handler (too late!)
  {:ok, collector} = TelemetrySync.attach_collector([:lasso, :request, :completed])

  # Time T4: Wait for event that already fired
  result = TelemetrySync.await_event(collector, timeout: 1000)
  # => {:error, :timeout} - Always!
end
```

### Timeline Analysis

```
Process: Test Process (PID: #PID<0.123.0>)

┌─────────────────────────────────────────────────────────────────┐
│ Time T1: Test starts                                            │
│   Telemetry handlers for [:lasso, :request, :completed]: []    │
└─────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────┐
│ Time T2: RequestPipeline.execute_via_channels() called         │
│   - Function executes synchronously in test process            │
│   - Inside the function:                                        │
│       :telemetry.execute([:lasso, :request, :completed], ...) │
│       - Looks up handlers: []                                   │
│       - No handlers, so event is ignored                        │
│       - Function returns immediately                            │
│   - Request completes, control returns to test                  │
└─────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────┐
│ Time T3: TelemetrySync.attach_collector() called               │
│   - Handler attached to [:lasso, :request, :completed]         │
│   - Handler will send message to test process when event fires │
│   - But event already fired at T2!                              │
└─────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────┐
│ Time T4: TelemetrySync.await_event() called                    │
│   - Enters receive block                                        │
│   - Waits for message: {ref, :telemetry_event, _, _}          │
│   - Message will never arrive (event fired at T2)              │
│   - Timeout after 1000ms                                        │
│   - Returns {:error, :timeout}                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why "Just After" Doesn't Work

You might think: "But I'm attaching RIGHT AFTER the request, before the BEAM scheduler runs anything else!"

This is incorrect because:

1. **No Context Switch Needed**: Telemetry doesn't involve message passing, so there's no opportunity for a context switch where you could "catch" the event
2. **Synchronous Execution**: By the time `RequestPipeline.execute_via_channels/3` returns to your test, ALL telemetry handlers have already run
3. **Function Call Semantics**: Think of telemetry like a callback list, not an event queue

```elixir
# Pseudo-code showing what actually happens
def execute_via_channels(chain, method, params) do
  # ... do work ...
  result = make_rpc_call()

  # This is essentially:
  for handler <- list_handlers([:lasso, :request, :completed]) do
    handler.function.()  # Direct call, no message passing
  end

  # By the time we return, ALL handlers ran
  result
end

# Back in your test
result = execute_via_channels(...)  # <-- Handlers already ran
attach_handler(...)                  # <-- Too late
```

## Part 3: The Correct Pattern

### Pre-Attachment Pattern

```elixir
test "correct telemetry test" do
  # Time T1: Attach handler FIRST
  {:ok, collector} = TelemetrySync.attach_collector([:lasso, :request, :completed])

  # Collector contains:
  #   - Handler ID registered with :telemetry
  #   - Reference for message matching
  #   - Test process PID

  # Time T2: Execute action that generates telemetry
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Inside RequestPipeline.execute_via_channels, this happens:
  #   :telemetry.execute([:lasso, :request, :completed], measurements, metadata)
  #   # Handler IS attached, so it executes:
  #   #   send(test_pid, {ref, :telemetry_event, measurements, metadata})
  #   # Message is now in test process mailbox

  # Time T3: Wait for event (message already in mailbox!)
  {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
  # => Success! Message was already delivered at T2

  # Verify telemetry
  assert measurements.duration > 0
  assert metadata.method == "eth_blockNumber"
end
```

### Timeline Analysis (Correct Pattern)

```
Process: Test Process (PID: #PID<0.123.0>)

┌─────────────────────────────────────────────────────────────────┐
│ Time T1: Attach collector                                       │
│   - Handler registered with :telemetry                          │
│   - Handler function:                                            │
│       fn event, measurements, metadata, config ->               │
│         send(test_pid, {ref, :telemetry_event, measurements, metadata}) │
│       end                                                        │
└─────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────┐
│ Time T2: RequestPipeline.execute_via_channels() called         │
│   - Function executes synchronously                             │
│   - Inside the function:                                        │
│       :telemetry.execute([:lasso, :request, :completed], ...) │
│       - Looks up handlers: [our_handler]                        │
│       - Calls our_handler function                              │
│       - Handler sends message to test_pid                       │
│       - Message arrives in test process mailbox                 │
│   - Request completes, control returns to test                  │
│                                                                  │
│   Test process mailbox now contains:                            │
│     [{ref, :telemetry_event, measurements, metadata}]          │
└─────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────┐
│ Time T3: TelemetrySync.await_event() called                    │
│   - Enters receive block                                        │
│   - Message ALREADY in mailbox                                  │
│   - Receive matches immediately                                 │
│   - Returns {:ok, measurements, metadata}                       │
│   - Detaches handler                                            │
└─────────────────────────────────────────────────────────────────┘
```

### Why This Works

1. **Handler Pre-Registration**: Handler exists before event fires
2. **Synchronous Message Send**: When event fires, handler sends message immediately
3. **Message Mailbox**: Message waits in mailbox until we're ready to receive it
4. **Order Guaranteed**: BEAM guarantees messages from one process to another arrive in order

## Part 4: Production Patterns

### Pattern A: Telemetry Test (What We Built)

Best for: Integration tests, E2E tests

```elixir
test "verify request completes with telemetry" do
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  {:ok, measurements, metadata} = TelemetrySync.await_event(collector)

  assert measurements.duration > 0
  assert metadata.status == :ok
end
```

### Pattern B: Telemetry Test Collector (Elixir Community Standard)

The `telemetry_test` library provides similar functionality:

```elixir
# Using https://hexdocs.pm/telemetry_test/
test "with telemetry_test library" do
  # Attach collector
  :telemetry_test.attach_event_handlers(self(), [[:lasso, :request, :completed]])

  # Execute
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Assert event
  assert_receive {[:lasso, :request, :completed], %{duration: _}, %{method: "eth_blockNumber"}}, 1000
end
```

### Pattern C: Global Test Listener

Best for: Collecting metrics across entire test suite

```elixir
# In test_helper.exs
defmodule TelemetryTestListener do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    events = [
      [:lasso, :request, :completed],
      [:lasso, :request, :failed],
      [:lasso, :circuit_breaker, :state_change]
    ]

    # Attach handlers for all events
    for event <- events do
      :telemetry.attach(
        {__MODULE__, event},
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end

    {:ok, %{events: []}}
  end

  def handle_event(event_name, measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:event, event_name, measurements, metadata})
  end

  def handle_cast({:event, event_name, measurements, metadata}, state) do
    # Store or log for later analysis
    {:noreply, state}
  end
end

# Start in test_helper.exs
TelemetryTestListener.start_link([])
```

### Pattern D: Shared Collector in Case Template

Best for: Consistent telemetry testing across test suite

```elixir
defmodule MyApp.IntegrationCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Lasso.Testing.TelemetrySync

      setup do
        # Pre-attach collectors for common events
        collectors = %{
          request: attach_request_collector!(),
          circuit_breaker: attach_collector!([:lasso, :circuit_breaker, :state_change])
        }

        {:ok, collectors: collectors}
      end
    end
  end
end

# In tests
test "request completes", %{collectors: collectors} do
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Collector was already attached in setup
  {:ok, measurements, _} = await_event(collectors.request)
  assert measurements.duration > 0
end
```

## Part 5: Advanced Patterns

### Handling Multiple Events

```elixir
test "collect multiple retry attempts" do
  # Expect up to 3 attempts
  {:ok, collector} = TelemetrySync.attach_request_collector(
    method: "eth_blockNumber",
    count: 3
  )

  # Trigger retries (via chaos engineering, etc.)
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Get all attempts
  case TelemetrySync.await_event(collector, timeout: 5000) do
    {:ok, events} when is_list(events) ->
      # Multiple attempts occurred
      assert length(events) <= 3

    {:error, :timeout} ->
      # Only one attempt, no retries needed
      :ok
  end
end
```

### Conditional Event Collection

```elixir
test "collect only failed requests" do
  {:ok, collector} = TelemetrySync.attach_collector(
    [:lasso, :request, :completed],
    match: fn _measurements, metadata ->
      metadata.status == :error
    end
  )

  # Execute request
  result = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  case result do
    {:ok, _} ->
      # Request succeeded, collector won't match
      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 500)

    {:error, _} ->
      # Request failed, collector should match
      {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
      assert metadata.status == :error
  end
end
```

### Testing Event Ordering

```elixir
test "verify event sequence: start -> progress -> complete" do
  events = [:start, :progress, :complete]

  collectors = for event <- events do
    {:ok, collector} = TelemetrySync.attach_collector([:lasso, :request, event])
    {event, collector}
  end

  # Execute request
  {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Verify order
  for {event, collector} <- collectors do
    {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
    assert metadata.stage == event
  end
end
```

## Part 6: Common Pitfalls

### Pitfall 1: Attaching After Async Operations

```elixir
# WRONG
test "async request" do
  task = Task.async(fn ->
    RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
  end)

  # Handler attached AFTER task started
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  Task.await(task)

  # This MIGHT work or MIGHT timeout depending on timing
  TelemetrySync.await_event(collector, timeout: 1000)
end

# CORRECT
test "async request" do
  # Attach BEFORE starting task
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  task = Task.async(fn ->
    RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
  end)

  Task.await(task)

  # Handler was attached before task started, so event was captured
  {:ok, _, _} = TelemetrySync.await_event(collector, timeout: 1000)
end
```

### Pitfall 2: Forgetting to Detach

```elixir
# WRONG - Handler leaks
test "leaky handler" do
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  {:ok, _} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Forgot to call await_event, so handler never detaches
  # Handler remains attached and can interfere with other tests
end

# CORRECT - Always detach
test "proper cleanup" do
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  try do
    {:ok, _} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
    {:ok, _, _} = TelemetrySync.await_event(collector, timeout: 1000)
  after
    # await_event automatically detaches, but if test fails before that:
    :telemetry.detach(collector.handler_id)
  end
end
```

### Pitfall 3: Handler Exceptions

```elixir
# Telemetry handlers that raise don't crash the caller
test "handler exception doesn't crash request" do
  bad_handler = fn _event, _measurements, _metadata, _config ->
    raise "Handler crashed!"
  end

  :telemetry.attach(:bad_handler, [:lasso, :request, :completed], bad_handler, nil)

  # Request still succeeds even though handler raised
  {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
  assert is_binary(result)

  :telemetry.detach(:bad_handler)
end
```

## Part 7: Performance Considerations

### Handler Execution Cost

Since handlers run synchronously in the calling process:

```elixir
# BAD - Slow handler blocks request
:telemetry.attach(
  :slow_handler,
  [:lasso, :request, :completed],
  fn _event, measurements, _metadata, _config ->
    # Don't do expensive work in handlers!
    :timer.sleep(1000)  # Blocks request for 1 second

    # Don't do I/O in handlers!
    File.write("/tmp/metrics.log", "#{measurements.duration}\n")
  end,
  nil
)

# GOOD - Fast handler sends message to dedicated process
:telemetry.attach(
  :async_handler,
  [:lasso, :request, :completed],
  fn event, measurements, metadata, metrics_pid ->
    # Fast message send (non-blocking)
    send(metrics_pid, {:event, event, measurements, metadata})
  end,
  metrics_collector_pid
)
```

### Test Performance

Pre-attaching handlers in `setup` can slow down tests if you're not careful:

```elixir
# Less optimal - Attaches/detaches for every test
setup do
  {:ok, collector} = TelemetrySync.attach_request_collector()
  on_exit(fn -> :telemetry.detach(collector.handler_id) end)
  {:ok, collector: collector}
end

# Better - Only attach when needed
setup do
  # Don't attach by default
  :ok
end

test "specific test needs telemetry", %{} do
  # Only attach for this test
  {:ok, collector} = TelemetrySync.attach_request_collector()
  # ... test ...
end
```

## Part 8: Debugging Telemetry Issues

### Check Handler Attachment

```elixir
# List all handlers for an event
handlers = :telemetry.list_handlers([:lasso, :request, :completed])
IO.inspect(handlers, label: "Attached handlers")

# In tests
test "verify handler is attached" do
  {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

  handlers = :telemetry.list_handlers([:lasso, :request, :completed])
  assert length(handlers) > 0

  # Cleanup
  TelemetrySync.await_event(collector, timeout: 100)
end
```

### Trace Event Emission

```elixir
# Add a debugging handler that logs all events
:telemetry.attach(
  :debug_handler,
  [:lasso, :request, :completed],
  fn event, measurements, metadata, _ ->
    IO.puts("Event: #{inspect(event)}")
    IO.puts("Measurements: #{inspect(measurements)}")
    IO.puts("Metadata: #{inspect(metadata)}")
    IO.puts("Calling process: #{inspect(self())}")
  end,
  nil
)
```

### Verify Event Emission

```elixir
test "verify event is actually emitted" do
  test_pid = self()
  ref = make_ref()

  # Attach simple handler
  :telemetry.attach(
    :verification_handler,
    [:lasso, :request, :completed],
    fn _event, measurements, metadata, {pid, ref} ->
      send(pid, {ref, :event_fired, measurements, metadata})
    end,
    {test_pid, ref}
  )

  # Execute
  {:ok, _} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

  # Verify message arrived
  assert_receive {^ref, :event_fired, measurements, metadata}, 1000

  IO.puts("✓ Event was emitted")
  IO.puts("  Measurements: #{inspect(measurements)}")
  IO.puts("  Metadata: #{inspect(metadata)}")

  :telemetry.detach(:verification_handler)
end
```

## Conclusion

### Key Takeaways

1. **Telemetry handlers execute synchronously** in the calling process
2. **Events are fire-and-forget** with no replay mechanism
3. **Always attach handlers BEFORE** triggering the action
4. **Use message passing** to bridge synchronous handlers to async tests
5. **Pre-attachment is the only reliable pattern** for telemetry testing

### Decision Matrix

| Scenario | Pattern | Reason |
|----------|---------|--------|
| Single event per test | `attach_collector` + `await_event` | Clean, explicit |
| Multiple events per test | `attach_collector(count: N)` | Collects all attempts |
| Shared across tests | Setup in case template | Reduces duplication |
| Complex matching | Predicate function | Maximum flexibility |
| Simple assertion | `telemetry_test` library | Less boilerplate |
| Production monitoring | Dedicated GenServer | Proper async handling |

### Further Reading

- [`:telemetry` documentation](https://hexdocs.pm/telemetry/)
- [`telemetry_test` library](https://hexdocs.pm/telemetry_test/)
- [BEAM Scheduler Documentation](https://www.erlang.org/doc/efficiency_guide/processes.html)
- [Erlang Message Passing Guarantees](https://www.erlang.org/doc/getting_started/conc_prog.html#message-passing)
