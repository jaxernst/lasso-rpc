# BEAM VM Profiling Guide for Lasso RPC Clustering

## Overview

This guide provides BEAM-specific profiling techniques to diagnose mailbox, scheduler, and GC issues in the Lasso RPC clustering architecture.

## Quick Diagnostics

### 1. Process Mailbox Sizes

**Get mailbox size for specific process:**
```elixir
# From IEx on running node
alias LassoWeb.Dashboard.ClusterEventAggregator

# Get aggregator PID
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

# Check mailbox length
{:message_queue_len, len} = Process.info(pid, :message_queue_len)
IO.puts("Aggregator mailbox: #{len} messages")
```

**Monitor mailbox growth over time:**
```elixir
defmodule MailboxMonitor do
  def watch(pid, interval_ms \\ 1000) do
    spawn(fn -> loop(pid, interval_ms) end)
  end

  defp loop(pid, interval_ms) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} ->
        IO.puts("[#{DateTime.utc_now()}] Mailbox: #{len}")
        Process.sleep(interval_ms)
        loop(pid, interval_ms)

      nil ->
        IO.puts("Process died")
    end
  end
end

# Usage
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
MailboxMonitor.watch(pid, 500)
```

**Get all LiveView mailbox sizes:**
```elixir
# This requires access to Phoenix.LiveView internals
# Alternative: track LiveView PIDs manually

# If you have LiveView PIDs stored:
liveview_pids = [pid1, pid2, pid3]  # Your tracked PIDs

liveview_pids
|> Enum.map(fn pid ->
  case Process.info(pid, :message_queue_len) do
    {:message_queue_len, len} -> {pid, len}
    nil -> {pid, :dead}
  end
end)
|> Enum.each(fn {pid, len} ->
  IO.puts("LiveView #{inspect(pid)}: #{len}")
end)
```

### 2. Process Heap Size

**Check memory usage:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

# Get heap size in words
{:heap_size, heap_words} = Process.info(pid, :heap_size)
word_size = :erlang.system_info(:wordsize)
heap_bytes = heap_words * word_size

IO.puts("Heap size: #{heap_words} words = #{heap_bytes} bytes = #{Float.round(heap_bytes / 1024 / 1024, 2)} MB")

# Get total memory (heap + stack + mailbox + etc)
{:memory, total_bytes} = Process.info(pid, :memory)
IO.puts("Total memory: #{Float.round(total_bytes / 1024 / 1024, 2)} MB")
```

**Detailed memory breakdown:**
```elixir
defmodule ProcessMemory do
  def analyze(pid) do
    info = Process.info(pid, [
      :memory,
      :heap_size,
      :stack_size,
      :message_queue_len,
      :total_heap_size,
      :garbage_collection
    ])

    case info do
      nil ->
        IO.puts("Process not found")

      details ->
        word_size = :erlang.system_info(:wordsize)

        IO.puts("=== Process Memory Analysis ===")
        IO.puts("Total memory: #{bytes_to_mb(details[:memory])} MB")
        IO.puts("Heap size: #{words_to_mb(details[:heap_size], word_size)} MB")
        IO.puts("Stack size: #{words_to_mb(details[:stack_size], word_size)} MB")
        IO.puts("Total heap: #{words_to_mb(details[:total_heap_size], word_size)} MB")
        IO.puts("Messages: #{details[:message_queue_len]}")

        gc = details[:garbage_collection]
        IO.puts("\nGarbage Collection:")
        IO.puts("  Minor GCs: #{gc[:minor_gcs]}")
        IO.puts("  Fullsweep after: #{gc[:fullsweep_after]}")
        IO.puts("  Max heap size: #{gc[:max_heap_size]}")
    end
  end

  defp bytes_to_mb(bytes), do: Float.round(bytes / 1024 / 1024, 2)
  defp words_to_mb(words, word_size), do: Float.round(words * word_size / 1024 / 1024, 2)
end

# Usage
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
ProcessMemory.analyze(pid)
```

### 3. Garbage Collection Stats

**Monitor GC activity:**
```elixir
defmodule GCMonitor do
  def watch(pid, interval_ms \\ 5000) do
    spawn(fn -> loop(pid, interval_ms, nil) end)
  end

  defp loop(pid, interval_ms, prev_stats) do
    case Process.info(pid, :garbage_collection) do
      {:garbage_collection, gc} ->
        minor_gcs = gc[:minor_gcs]

        if prev_stats do
          prev_minor = prev_stats[:minor_gcs]
          delta = minor_gcs - prev_minor
          rate = delta / (interval_ms / 1000)

          IO.puts("[#{DateTime.utc_now()}] Minor GCs: #{minor_gcs} (+#{delta}), Rate: #{Float.round(rate, 2)}/sec")
        else
          IO.puts("[#{DateTime.utc_now()}] Minor GCs: #{minor_gcs}")
        end

        Process.sleep(interval_ms)
        loop(pid, interval_ms, gc)

      nil ->
        IO.puts("Process died")
    end
  end
end

# Usage
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
GCMonitor.watch(pid, 5000)
```

**Detailed GC analysis:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
{:garbage_collection, gc} = Process.info(pid, :garbage_collection)

IO.puts("=== Garbage Collection Stats ===")
IO.puts("Minor GCs: #{gc[:minor_gcs]}")
IO.puts("Fullsweep after: #{gc[:fullsweep_after]} minor GCs trigger fullsweep")
IO.puts("Max heap size: #{gc[:max_heap_size]} words")
IO.puts("Min bin vheap size: #{gc[:min_bin_vheap_size]} words")
IO.puts("Min heap size: #{gc[:min_heap_size]} words")
```

### 4. Scheduler Utilization

**Check scheduler run queue lengths:**
```elixir
# Get run queue length for all schedulers
run_queues = :erlang.statistics(:run_queue_lengths_all)

IO.puts("=== Scheduler Run Queues ===")
run_queues
|> Enum.with_index()
|> Enum.each(fn {len, idx} ->
  status = cond do
    len == 0 -> "✅ idle"
    len < 5 -> "✅ light"
    len < 20 -> "⚠️ busy"
    true -> "🔴 overloaded"
  end

  IO.puts("Scheduler #{idx}: #{len} processes #{status}")
end)

total = Enum.sum(run_queues)
IO.puts("\nTotal run queue: #{total} processes")
```

**Monitor scheduler utilization over time:**
```elixir
defmodule SchedulerMonitor do
  def watch(interval_ms \\ 1000) do
    spawn(fn -> loop(interval_ms) end)
  end

  defp loop(interval_ms) do
    run_queues = :erlang.statistics(:run_queue_lengths_all)
    total = Enum.sum(run_queues)
    max_queue = Enum.max(run_queues)
    avg_queue = total / length(run_queues)

    IO.puts("[#{DateTime.utc_now()}] Total: #{total}, Max: #{max_queue}, Avg: #{Float.round(avg_queue, 1)}")

    Process.sleep(interval_ms)
    loop(interval_ms)
  end
end

# Usage
SchedulerMonitor.watch(1000)
```

**Get scheduler info:**
```elixir
IO.puts("=== Scheduler Info ===")
IO.puts("Schedulers online: #{:erlang.system_info(:schedulers_online)}")
IO.puts("Schedulers available: #{:erlang.system_info(:schedulers)}")
IO.puts("Dirty CPU schedulers: #{:erlang.system_info(:dirty_cpu_schedulers)}")
IO.puts("Dirty IO schedulers: #{:erlang.system_info(:dirty_io_schedulers)}")
```

### 5. Message Queue Data Location

**Check if mailbox is on-heap or off-heap:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
{:message_queue_data, location} = Process.info(pid, :message_queue_data)

case location do
  :on_heap -> IO.puts("⚠️ Mailbox is ON-HEAP (GC scans messages)")
  :off_heap -> IO.puts("✅ Mailbox is OFF-HEAP (GC skips messages)")
end
```

## Advanced Profiling

### 1. Observer

Observer provides real-time visual monitoring of processes, schedulers, and memory.

```elixir
# Start Observer
:observer.start()
```

**What to look for:**

1. **Applications tab**: See all running applications and their supervision trees
2. **Processes tab**:
   - Sort by "Memory" to find memory-heavy processes
   - Sort by "Message Queue Len" to find mailbox bottlenecks
   - Sort by "Reductions" to find CPU-intensive processes
3. **Load Charts tab**: Real-time CPU, memory, and process count
4. **Memory Allocators tab**: See where memory is going

**Finding the aggregator in Observer:**
1. Click "Processes" tab
2. Click "Memory" column to sort
3. Look for `Elixir.LassoWeb.Dashboard.ClusterEventAggregator`
4. Double-click to see detailed process info

**Finding LiveView processes:**
1. Sort by "Current Function"
2. Look for `Phoenix.LiveView` processes

### 2. Recon (Production Profiling)

Install recon: Add to `mix.exs`:
```elixir
{:recon, "~> 2.5"}
```

**Find processes with large mailboxes:**
```elixir
# Top 10 processes by mailbox size
:recon.proc_count(:message_queue_len, 10)
```

**Find processes using most memory:**
```elixir
# Top 10 processes by memory
:recon.proc_count(:memory, 10)
```

**Find processes with most reductions (CPU):**
```elixir
# Top 10 processes by CPU work
:recon.proc_count(:reductions, 10)
```

**Get process info by PID:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

# Detailed process info
:recon.info(pid)
```

### 3. Tracing Message Flow

**Trace messages sent to aggregator:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

# Trace all messages sent to aggregator
:erlang.trace(pid, true, [:receive, :timestamp])

# Set up receiver
flush() # Clear existing messages

# Now messages will appear in IEx shell
# Format: {trace_ts, Pid, :receive, Message, Timestamp}

# Stop tracing
:erlang.trace(pid, false, [:receive])
```

**Count message types:**
```elixir
defmodule MessageCounter do
  def count_types(pid, duration_ms) do
    # Enable tracing
    :erlang.trace(pid, true, [:receive])

    # Collect messages
    Process.sleep(duration_ms)

    # Disable tracing
    :erlang.trace(pid, false, [:receive])

    # Count message types
    collect_traces(%{})
  end

  defp collect_traces(counts) do
    receive do
      {:trace, _pid, :receive, msg} ->
        type = message_type(msg)
        new_counts = Map.update(counts, type, 1, &(&1 + 1))
        collect_traces(new_counts)
    after
      100 ->
        # No more messages
        counts
    end
  end

  defp message_type(%{__struct__: struct}), do: struct
  defp message_type({atom, _}) when is_atom(atom), do: atom
  defp message_type(atom) when is_atom(atom), do: atom
  defp message_type(_), do: :other
end

# Usage
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
counts = MessageCounter.count_types(pid, 5000)

IO.puts("=== Message Types (5 second sample) ===")
counts
|> Enum.sort_by(fn {_type, count} -> -count end)
|> Enum.each(fn {type, count} ->
  IO.puts("#{inspect(type)}: #{count}")
end)
```

### 4. Benchmarking Message Passing

**Measure message send latency:**
```elixir
defmodule MessageBench do
  def measure_latency(pid, num_messages) do
    parent = self()

    # Send messages and measure round-trip time
    start = System.monotonic_time(:microsecond)

    for i <- 1..num_messages do
      send(pid, {:ping, i, parent})
    end

    # Wait for responses (assumes process echoes back)
    for _ <- 1..num_messages do
      receive do
        {:pong, _} -> :ok
      after
        5000 -> :timeout
      end
    end

    elapsed = System.monotonic_time(:microsecond) - start
    avg_latency = elapsed / num_messages / 2  # Divide by 2 for one-way latency

    IO.puts("Average message latency: #{Float.round(avg_latency, 2)} μs")
  end
end
```

**Measure throughput:**
```elixir
defmodule ThroughputBench do
  def measure(pid, num_messages) do
    start = System.monotonic_time(:millisecond)

    for i <- 1..num_messages do
      send(pid, {:test_message, i})
    end

    elapsed = System.monotonic_time(:millisecond) - start
    throughput = num_messages / (elapsed / 1000)

    IO.puts("Sent #{num_messages} messages in #{elapsed}ms")
    IO.puts("Throughput: #{Float.round(throughput, 0)} messages/sec")
  end
end

# Usage (be careful not to overload production!)
# {:ok, pid} = ClusterEventAggregator.ensure_started("default")
# ThroughputBench.measure(pid, 10_000)
```

## Load Testing

### 1. Simulate Event Load

**Create test script:**

File: `scripts/load_test_aggregator.exs`

```elixir
defmodule LoadTest do
  alias Lasso.Events.RoutingDecision

  def run(events_per_sec, duration_sec) do
    IO.puts("Starting load test: #{events_per_sec} events/sec for #{duration_sec} seconds")

    profile = "default"
    topic = RoutingDecision.topic(profile)

    # Calculate interval between events
    interval_ms = 1000 / events_per_sec

    # Start time
    start = System.monotonic_time(:millisecond)
    end_time = start + (duration_sec * 1000)

    # Generate events
    send_events(topic, interval_ms, end_time, 0)

    IO.puts("Load test complete")
  end

  defp send_events(topic, interval_ms, end_time, count) do
    now = System.monotonic_time(:millisecond)

    if now < end_time do
      # Create event
      event = RoutingDecision.new(
        request_id: "load_test_#{count}",
        profile: "default",
        chain: "ethereum_mainnet",
        method: "eth_getBlockByNumber",
        strategy: "fastest_responder",
        provider_id: "test_provider",
        transport: :http,
        duration_ms: :rand.uniform(100),
        result: if(:rand.uniform() > 0.05, do: :success, else: :error)
      )

      # Broadcast
      Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)

      # Sleep
      Process.sleep(round(interval_ms))

      send_events(topic, interval_ms, end_time, count + 1)
    else
      IO.puts("Sent #{count} events")
    end
  end
end

# Run test
LoadTest.run(100, 30)  # 100 events/sec for 30 seconds
```

**Run from IEx:**
```elixir
Code.eval_file("scripts/load_test_aggregator.exs")
LoadTest.run(100, 30)
```

### 2. Monitor During Load Test

**Create monitoring script:**

File: `scripts/monitor_aggregator.exs`

```elixir
defmodule AggregatorMonitor do
  alias LassoWeb.Dashboard.ClusterEventAggregator

  def watch(profile, interval_ms \\ 1000) do
    {:ok, pid} = ClusterEventAggregator.ensure_started(profile)

    IO.puts("Monitoring aggregator for profile: #{profile}")
    IO.puts("PID: #{inspect(pid)}")
    IO.puts("")

    spawn(fn -> loop(pid, interval_ms, nil) end)
  end

  defp loop(pid, interval_ms, prev_stats) do
    Process.sleep(interval_ms)

    case Process.info(pid, [:message_queue_len, :memory, :heap_size, :garbage_collection]) do
      nil ->
        IO.puts("Process died!")

      info ->
        mailbox = info[:message_queue_len]
        memory_mb = Float.round(info[:memory] / 1024 / 1024, 2)
        heap_mb = Float.round(info[:heap_size] * 8 / 1024 / 1024, 2)
        gc = info[:garbage_collection]
        minor_gcs = gc[:minor_gcs]

        # Calculate GC rate
        gc_rate = if prev_stats do
          prev_gc = prev_stats[:garbage_collection][:minor_gcs]
          (minor_gcs - prev_gc) / (interval_ms / 1000)
        else
          0
        end

        status = cond do
          mailbox > 1000 -> "🔴"
          mailbox > 100 -> "⚠️"
          true -> "✅"
        end

        IO.puts("[#{DateTime.utc_now() |> DateTime.to_time()}] #{status} Mailbox: #{mailbox}, Mem: #{memory_mb}MB, Heap: #{heap_mb}MB, GC: #{Float.round(gc_rate, 1)}/sec")

        loop(pid, interval_ms, info)
    end
  end
end

# Usage
AggregatorMonitor.watch("default", 1000)
```

### 3. Combined Load Test + Monitor

**Run in separate IEx sessions:**

Session 1:
```elixir
# Start monitoring
Code.eval_file("scripts/monitor_aggregator.exs")
AggregatorMonitor.watch("default", 500)
```

Session 2:
```elixir
# Run load test
Code.eval_file("scripts/load_test_aggregator.exs")

# Easy scenario
LoadTest.run(50, 60)

# Medium scenario
LoadTest.run(400, 60)

# Worst scenario (be careful!)
LoadTest.run(3000, 30)
```

## Debugging Techniques

### 1. Find Stuck Processes

**Check if process is alive and responsive:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

# Try to call it
case GenServer.call(pid, :get_known_regions, 5000) do
  {:ok, regions} ->
    IO.puts("Process responsive: #{inspect(regions)}")

  {:error, reason} ->
    IO.puts("Process error: #{inspect(reason)}")
end
```

**Check current function:**
```elixir
{:current_function, {mod, fun, arity}} = Process.info(pid, :current_function)
IO.puts("Currently executing: #{mod}.#{fun}/#{arity}")
```

**Check if process is in GC:**
```elixir
{:current_stacktrace, stacktrace} = Process.info(pid, :current_stacktrace)

if Enum.any?(stacktrace, fn {mod, _fun, _arity, _loc} ->
  mod == :erts_internal or mod == :erlang
end) do
  IO.puts("⚠️ Process may be in GC")
else
  IO.puts("Process not in GC")
end
```

### 2. Dump Process State

**Get full process info:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

# Get ALL process info
info = Process.info(pid)

# Pretty print
info
|> Enum.each(fn {key, value} ->
  IO.puts("#{key}: #{inspect(value, limit: 5)}")
end)
```

**Dump to file for analysis:**
```elixir
{:ok, pid} = ClusterEventAggregator.ensure_started("default")

info = Process.info(pid)
timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
filename = "process_dump_#{timestamp}.txt"

File.write!(filename, inspect(info, limit: :infinity, printable_limit: :infinity))

IO.puts("Dumped to #{filename}")
```

### 3. Detect Memory Leaks

**Monitor memory growth over time:**
```elixir
defmodule MemoryLeakDetector do
  def watch(pid, interval_ms \\ 5000, samples \\ 20) do
    IO.puts("Watching for memory leaks...")

    measurements = for _ <- 1..samples do
      {:memory, mem} = Process.info(pid, :memory)
      Process.sleep(interval_ms)
      mem
    end

    # Calculate trend
    first_half = measurements |> Enum.take(div(samples, 2)) |> Enum.sum()
    second_half = measurements |> Enum.drop(div(samples, 2)) |> Enum.sum()

    avg_first = first_half / div(samples, 2)
    avg_second = second_half / div(samples, 2)
    growth = ((avg_second - avg_first) / avg_first) * 100

    IO.puts("\n=== Memory Leak Detection ===")
    IO.puts("First half average: #{Float.round(avg_first / 1024 / 1024, 2)} MB")
    IO.puts("Second half average: #{Float.round(avg_second / 1024 / 1024, 2)} MB")
    IO.puts("Growth: #{Float.round(growth, 1)}%")

    if growth > 20 do
      IO.puts("🔴 POSSIBLE MEMORY LEAK")
    elsif growth > 10 do
      IO.puts("⚠️ Memory growing")
    else
      IO.puts("✅ Memory stable")
    end
  end
end

# Usage
{:ok, pid} = ClusterEventAggregator.ensure_started("default")
MemoryLeakDetector.watch(pid, 5000, 20)  # Watch for 100 seconds
```

## Production Monitoring

### 1. Telemetry Integration

**Add telemetry events for monitoring:**

File: `lib/lasso_web/dashboard/cluster_event_aggregator.ex`

Add to `handle_info(%RoutingDecision{}, state)`:

```elixir
def handle_info(%RoutingDecision{} = event, state) do
  # Emit telemetry
  :telemetry.execute(
    [:lasso, :aggregator, :event_received],
    %{count: 1},
    %{profile: state.profile}
  )

  # ... rest of function
end
```

Add to `process_event_batch/1`:

```elixir
defp process_event_batch(state) do
  batch_size = length(state.pending_events)

  :telemetry.execute(
    [:lasso, :aggregator, :batch_processed],
    %{batch_size: batch_size},
    %{profile: state.profile}
  )

  # ... rest of function
end
```

**Attach telemetry handlers:**

```elixir
:telemetry.attach_many(
  "aggregator-metrics",
  [
    [:lasso, :aggregator, :event_received],
    [:lasso, :aggregator, :batch_processed]
  ],
  &handle_aggregator_event/4,
  nil
)

def handle_aggregator_event(event_name, measurements, metadata, _config) do
  IO.inspect({event_name, measurements, metadata})
end
```

### 2. Metrics Collection

**Periodically report metrics:**

```elixir
defmodule AggregatorMetrics do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_report()
    {:ok, state}
  end

  def handle_info(:report, state) do
    report_metrics()
    schedule_report()
    {:noreply, state}
  end

  defp schedule_report do
    Process.send_after(self(), :report, 60_000)  # Every minute
  end

  defp report_metrics do
    case LassoWeb.Dashboard.ClusterEventAggregator.ensure_started("default") do
      {:ok, pid} ->
        info = Process.info(pid, [:message_queue_len, :memory, :heap_size])

        if info do
          mailbox = info[:message_queue_len]
          memory_mb = info[:memory] / 1024 / 1024

          # Log to your monitoring system
          Logger.info("[AggregatorMetrics] mailbox=#{mailbox} memory_mb=#{Float.round(memory_mb, 2)}")

          # Could send to StatsD, Prometheus, etc.
        end

      _ ->
        :ok
    end
  end
end
```

## Summary

This guide provides comprehensive BEAM-level profiling for the Lasso RPC clustering architecture. Key takeaways:

1. **Mailbox monitoring** is critical - use `Process.info(pid, :message_queue_len)`
2. **GC stats** reveal performance issues - monitor minor GC frequency
3. **Scheduler run queues** show system-wide contention
4. **Observer** is your best friend for real-time debugging
5. **Recon** is production-safe profiling
6. **Off-heap mailboxes** reduce GC pressure significantly
7. **Telemetry** enables production monitoring

Use these techniques to diagnose issues at each load level and verify optimizations.
