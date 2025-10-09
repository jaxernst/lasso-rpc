# ProviderPool Performance Profiling Guide

This guide walks through diagnosing performance bottlenecks in the ProviderPool GenServer.

## Quick Diagnosis Steps

### 1. Check Mailbox Depth

Start monitoring the ProviderPool process during load:

```elixir
# In IEx connected to production
Lasso.Diagnostic.ProviderPoolDiagnostics.start_monitoring("ethereum",
  interval_ms: 100,
  duration_ms: 10_000,
  log_threshold: 5
)
```

**What to look for:**
- **Mailbox > 10**: GenServer is processing slower than requests arrive
- **Mailbox = 0-2**: Not a GenServer bottleneck, look elsewhere
- **Mailbox growing continuously**: Definite serialization bottleneck

### 2. Measure Request Latency

```elixir
# Measure under normal load
Lasso.Diagnostic.ProviderPoolDiagnostics.measure_list_candidates("ethereum", %{}, 100)
```

**Expected results:**
- **< 100 microseconds**: Normal for in-memory operations
- **> 1 millisecond**: Something is wrong (heavy computation or blocking)

### 3. Simulate the Exact Load Pattern

```elixir
# Reproduce your 10 req/s burst load
Lasso.Diagnostic.ProviderPoolDiagnostics.simulate_load("ethereum",
  concurrency: 20,
  requests_per_process: 10
)
```

**Look at the results:**
- `latency_p95_us` and `latency_p99_us` - if these are >> median, you have queueing
- `throughput_per_sec` - should be > 1000 req/s for this simple operation

### 4. Profile with eprof (Low Overhead)

```elixir
Lasso.Diagnostic.Profiler.eprof_list_candidates("ethereum", iterations: 100)
```

This will show you:
- Which functions consume the most time
- Hot paths in your code

**Red flags:**
- High time in `Lasso.RPC.HealthPolicy.availability/1`
- High time in `Enum.filter` or `Enum.map`
- Unexpected Registry/GenServer lookups in hot path

### 5. Deep Profile with fprof (High Overhead)

Only use this with lower load:

```elixir
Lasso.Diagnostic.Profiler.fprof_list_candidates("ethereum", iterations: 10)
# Results written to fprof_analysis.txt
```

Check the output file for:
- Accumulative time per function
- Call counts
- Unexpected expensive operations

### 6. Isolate GenServer Overhead

```elixir
Lasso.Diagnostic.Profiler.profile_handle_call_directly("ethereum", iterations: 1000)
```

Compare this to the `measure_list_candidates` result:
- **If both are fast (< 100us)**: The bottleneck is NOT the processing logic
- **If handle_call is slow**: The filter logic itself is expensive
- **If GenServer.call is slow but handle_call is fast**: Mailbox queueing

## Interpreting Results

### Scenario A: Mailbox Grows, GenServer.call Slow, handle_call Fast
**Diagnosis**: Classic GenServer serialization bottleneck

**Solutions**:
1. Move to ETS for read-heavy operations
2. Use `:persistent_term` for rarely-changing data
3. Shard the GenServer (multiple pools with consistent hashing)

### Scenario B: Mailbox Empty, Both GenServer.call and handle_call Slow
**Diagnosis**: The filtering/mapping logic is expensive

**Possible causes**:
- `ws_connection_pid` doing Registry lookup for each provider (line 722)
- `HealthPolicy.availability/1` or `cooldown?/2` doing expensive checks
- Large provider maps being copied

**Solutions**:
1. Cache `ws_connection_pid` lookups
2. Optimize HealthPolicy operations
3. Reduce data copying in filter pipeline

### Scenario C: Mailbox Empty, GenServer.call Fast
**Diagnosis**: Bottleneck is NOT in ProviderPool

**Look elsewhere**:
- Upstream HTTP client pool saturation
- Circuit breaker contention
- Database/network calls
- Phoenix endpoint/router overhead

## Common Culprits in Your Code

### 1. Registry Lookup Per Provider (Line 722)

```elixir
defp ws_connection_pid(provider_id) when is_binary(provider_id) do
  GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, provider_id}}})
end
```

This is called for EVERY provider when `protocol: :ws`. Registry lookups are fast but not free.

**Fix**: Cache WS pids in ProviderPool state when they connect.

### 2. HealthPolicy Checks in Hot Path

Lines 749-753 call `HealthPolicy.cooldown?/2` for each candidate. If this function is doing expensive work (time comparisons should be fast), it could add up.

### 3. Logger.info in GenServer.call (Line 342)

```elixir
Logger.info("ProviderPool.list_candidates for #{state.chain_name}: ...")
```

**This is likely a significant contributor.** Logger calls can be surprisingly expensive, especially if logging is synchronous or if the log message is large.

**Immediate fix**: Change to `Logger.debug` or remove entirely.

### 4. Multiple Filter Passes

Lines 680-718 do THREE separate `Enum.filter` passes:
1. Protocol filtering (680-698)
2. Circuit breaker filtering (699-711)
3. Exclude list filtering (712-718)

Then a final `Enum.map` (349-362).

**Optimization**: Combine into a single pass with `Enum.reduce` or `for` comprehension.

## Recommended Immediate Actions

### 1. Remove/Demote the Logger.info (Line 342)

```elixir
# Change this:
Logger.info("ProviderPool.list_candidates for #{state.chain_name}: ...")

# To this:
Logger.debug("ProviderPool.list_candidates for #{state.chain_name}: ...")
# Or remove entirely
```

### 2. Run Baseline Profiling

```bash
# In IEx
alias Lasso.Diagnostic.ProviderPoolDiagnostics, as: Diag

# Check current state
Diag.check_mailbox("ethereum")

# Simulate load
Diag.simulate_load("ethereum", concurrency: 20, requests_per_process: 10)

# Profile
Lasso.Diagnostic.Profiler.eprof_list_candidates("ethereum")
```

## Migration Path if GenServer IS the Bottleneck

### Option 1: ETS Table (Best for Read-Heavy)

```elixir
# On init, create ETS table
:ets.new(:provider_candidates, [:named_table, :set, :public, read_concurrency: true])

# On state changes (report_success/failure, health updates), update ETS
:ets.insert(:provider_candidates, {chain_name, candidates})

# In list_candidates, read from ETS directly (no GenServer.call)
def list_candidates(chain_name, filters) do
  case :ets.lookup(:provider_candidates, chain_name) do
    [{^chain_name, candidates}] -> apply_filters(candidates, filters)
    [] -> []
  end
end
```

**Pros**: Concurrent reads, no serialization
**Cons**: State synchronization complexity, stale reads possible

### Option 2: :persistent_term (Best for Rarely Changing)

```elixir
# Update on state changes
:persistent_term.put({:provider_candidates, chain_name}, candidates)

# Read directly
def list_candidates(chain_name, filters) do
  candidates = :persistent_term.get({:provider_candidates, chain_name}, [])
  apply_filters(candidates, filters)
end
```

**Pros**: Extremely fast reads, no copying
**Cons**: Expensive writes (triggers GC on all processes), only for rarely-changing data

### Option 3: Shard the GenServer

```elixir
# Run N ProviderPool instances per chain
defp pool_name(chain_name, shard_id) do
  {:via, Registry, {Lasso.Registry, {:provider_pool, chain_name, shard_id}}}
end

# Route requests via consistent hashing
def list_candidates(chain_name, filters) do
  shard_id = :erlang.phash2(self(), @num_shards)
  GenServer.call(pool_name(chain_name, shard_id), {:list_candidates, filters})
end
```

**Pros**: Scales linearly with shards
**Cons**: Coordination overhead, state replication complexity

### Option 4: Keep State, Make Calls Async

If callers don't need immediate results:

```elixir
# Instead of GenServer.call
def list_candidates_async(chain_name, filters) do
  Task.async(fn ->
    GenServer.call(via_name(chain_name), {:list_candidates, filters})
  end)
end
```

**Pros**: Doesn't block caller
**Cons**: Still doesn't solve GenServer serialization

## Production Monitoring

Add permanent telemetry:

```elixir
# In handle_call for :list_candidates
def handle_call({:list_candidates, filters}, _from, state) do
  start = System.monotonic_time(:microsecond)

  # ... existing logic ...

  duration_us = System.monotonic_time(:microsecond) - start

  :telemetry.execute(
    [:lasso, :provider_pool, :list_candidates],
    %{duration_us: duration_us},
    %{chain: state.chain_name}
  )

  {:reply, candidates, state}
end
```

Track in your metrics system:
- P50/P95/P99 latency
- Request rate
- Mailbox depth (sampled)
- Active provider count

## Next Steps

1. Run the diagnostics on your production system during a burst load period
2. Share the profiling results
3. Based on results, choose the appropriate optimization strategy
4. Implement and measure improvement

The diagnostic tools will definitively tell you whether this is a GenServer bottleneck or something else entirely.
