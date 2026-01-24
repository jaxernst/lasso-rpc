# Internal Documentation: BEAM VM Analysis

This directory contains comprehensive BEAM VM-level analysis of the Lasso RPC dashboard clustering architecture.

## Quick Start

**If you need the executive summary**: Read `BEAM_ANALYSIS_SUMMARY.md`

**If you want to understand the problem**: Read `message_flow_analysis.md`

**If you need detailed BEAM internals**: Read `beam_analysis_clustering.md`

**If you want to profile/debug**: Read `beam_profiling_guide.md`

## Problem Statement

The dashboard clustering architecture suffers from mailbox saturation and system failure at high event rates due to redundant message delivery. LiveView processes receive routing events through two paths simultaneously, causing exponential message growth.

## Documents

### 1. BEAM_ANALYSIS_SUMMARY.md
**Executive summary for decision-makers**

- Key findings and metrics
- Optimization recommendations with priority
- Implementation phases
- Performance projections

**Read this if**: You need to understand the problem and solution quickly

**Time to read**: 10 minutes

### 2. message_flow_analysis.md
**Visual analysis of message flow**

- Current vs optimized architecture diagrams
- Mailbox growth analysis at each load level
- Numerical comparisons (current vs optimized)
- Exact code changes with line numbers

**Read this if**: You need to implement the fixes

**Time to read**: 15 minutes

### 3. beam_analysis_clustering.md
**Deep dive into BEAM VM behavior**

- BEAM memory characteristics (struct sizes, binary reference counting)
- Load scenario analysis (Easy, Medium, Worst)
- Specific bottlenecks with BEAM-level explanations
- Scheduler utilization analysis
- GC pressure calculations
- Detailed optimization recommendations

**Read this if**: You need to understand WHY the system fails

**Time to read**: 30 minutes

### 4. beam_profiling_guide.md
**Hands-on profiling and debugging**

- Process mailbox monitoring
- GC statistics analysis
- Scheduler utilization tracking
- Observer usage guide
- Load testing scripts
- Production monitoring setup

**Read this if**: You need to diagnose issues or validate fixes

**Time to read**: 45 minutes (plus hands-on time)

## Quick Reference

### The Problem

```
Each RoutingDecision event is delivered TWICE to every LiveView:
1. Direct from PubSub (subscribe to "routing:decisions:default")
2. Indirect via ClusterEventAggregator metrics

At 3,000 events/sec × 7 nodes = 21,000 events/sec to each LiveView
Result: Mailbox overflow → GC death spiral → Process crash
```

### The Solution

**Four code changes** (total ~20 lines):

1. **Remove direct PubSub subscription** (dashboard.ex line 173)
   - DELETE: `Phoenix.PubSub.subscribe(Lasso.PubSub, RoutingDecision.topic(profile))`
   - Impact: 10,500× reduction in messages to LiveViews

2. **Enable off-heap mailbox** (cluster_event_aggregator.ex line 206)
   - ADD: `Process.flag(:message_queue_data, :off_heap)`
   - Impact: 10× faster GC

3. **Cap pending events** (cluster_event_aggregator.ex line 235)
   - CHANGE: `pending = [event | state.pending_events] |> Enum.take(500)`
   - Impact: Prevents OOM

4. **MapSet deduplication** (cluster_event_aggregator.ex line 228-243)
   - See `message_flow_analysis.md` for full implementation
   - Impact: O(n) → O(1) duplicate check

### Performance Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| LiveView msgs/sec | 21,002 | 2 | 10,500× |
| Cluster traffic | 204 MB/sec | 663 KB/sec | 308× |
| Aggregator GC time | 50ms | 5ms | 10× |
| Failure threshold | 3,000 events/sec | 50,000 events/sec | 17× |

## Analysis Scripts

### analyze_beam_characteristics.exs
**Run**: `elixir scripts/analyze_beam_characteristics.exs`

Calculates:
- Struct memory sizes
- Message copying overhead
- Mailbox growth rates
- GC pressure
- Cluster-wide traffic

Output: Numerical analysis for each load scenario

### load_test_aggregator.exs (in beam_profiling_guide.md)
**Run**: From IEx: `LoadTest.run(events_per_sec, duration_sec)`

Simulates event load for testing.

Example:
```elixir
LoadTest.run(100, 30)   # 100 events/sec for 30 seconds
LoadTest.run(400, 60)   # Medium scenario
LoadTest.run(3000, 30)  # Worst scenario (be careful!)
```

### monitor_aggregator.exs (in beam_profiling_guide.md)
**Run**: From IEx: `AggregatorMonitor.watch("default", 1000)`

Real-time monitoring:
- Mailbox size
- Memory usage
- Heap size
- GC rate

## Key BEAM Concepts Explained

### Mailbox (Message Queue)
- Each process has its own mailbox
- Messages are copied from sender to receiver (no shared state)
- Mailboxes can be on-heap (default) or off-heap
- On-heap mailboxes are scanned during GC (slow!)
- Off-heap mailboxes skip GC scanning (fast!)

### Binary Reference Counting
- Binaries >64 bytes are stored in shared binary heap
- Only a reference is copied during `send()`
- Binaries <64 bytes are copied entirely (heap binaries)
- Most RoutingDecision fields are <64 bytes, so they ARE copied

### Garbage Collection
- Each process has its own heap
- GC is per-process, not global
- Minor GC: Collects young generation
- Full sweep GC: Collects entire heap
- GC pauses block message processing
- Large mailboxes slow down GC (if on-heap)

### Schedulers
- BEAM has N schedulers (usually = CPU cores)
- Each scheduler runs processes in a work-stealing queue
- Process priorities: low, normal, high, max
- PubSub and LiveViews use normal priority
- High message rates can saturate schedulers

### Process Lifecycle
1. Process receives message → added to mailbox
2. Scheduler picks process from run queue
3. Process executes `handle_info`
4. If heap is full, trigger GC
5. Return to run queue (if more messages)
6. If mailbox grows faster than processing, death spiral begins

## Profiling Cheat Sheet

```elixir
# Get aggregator PID
{:ok, pid} = LassoWeb.Dashboard.ClusterEventAggregator.ensure_started("default")

# Check mailbox size
{:message_queue_len, len} = Process.info(pid, :message_queue_len)

# Check memory
{:memory, bytes} = Process.info(pid, :memory)
mb = bytes / 1024 / 1024

# Check GC stats
{:garbage_collection, gc} = Process.info(pid, :garbage_collection)

# Check if mailbox is off-heap
{:message_queue_data, location} = Process.info(pid, :message_queue_data)

# Check scheduler run queues
total = :erlang.statistics(:run_queue_lengths_all) |> Enum.sum()

# Start Observer
:observer.start()

# Find top processes by mailbox size (requires recon)
:recon.proc_count(:message_queue_len, 10)
```

## Monitoring Thresholds

**Aggregator**:
- Mailbox >100: ⚠️ Warning
- Mailbox >500: 🔴 Critical
- Memory >100 MB: ⚠️ Warning
- GC rate >10/sec: ⚠️ Warning

**LiveView**:
- Mailbox >50: ⚠️ Warning (should be near-zero after fix)
- Memory >10 MB: ⚠️ Warning

**System**:
- Total run queue >20: ⚠️ Warning
- Total run queue >50: 🔴 Critical
- Scheduler utilization >80%: ⚠️ Warning

## Implementation Checklist

### Phase 1: Critical Fix
- [ ] Read `BEAM_ANALYSIS_SUMMARY.md`
- [ ] Read `message_flow_analysis.md`
- [ ] Remove direct PubSub subscription from LiveViews
- [ ] Enable off-heap mailbox in aggregator
- [ ] Deploy to staging
- [ ] Run load test at Medium scenario (400 events/sec)
- [ ] Verify mailbox sizes <100 under load
- [ ] Deploy to production

### Phase 2: Stability
- [ ] Cap pending events list
- [ ] Implement MapSet deduplication
- [ ] Add telemetry events
- [ ] Deploy to staging
- [ ] Run load test at Worst scenario (3,000 events/sec)
- [ ] Verify system survives without crashes
- [ ] Deploy to production

### Phase 3: Monitoring
- [ ] Read `beam_profiling_guide.md`
- [ ] Add Prometheus/StatsD metrics
- [ ] Create Grafana dashboards
- [ ] Set up alerts for thresholds
- [ ] Document runbooks
- [ ] Train team on debugging

## Common Questions

**Q: Why does the system fail at 3,000 events/sec?**

A: LiveViews receive 21,000 messages/sec each, but can only process 10,000/sec. Mailbox grows exponentially, triggers GC, GC pauses slow processing, death spiral.

**Q: Why not just increase process heap size?**

A: Larger heaps make GC slower, not faster. The problem is message rate, not heap size.

**Q: Can we use multiple aggregator processes?**

A: Yes, but the main bottleneck is LiveView mailboxes, not the aggregator. Fix LiveViews first.

**Q: Will this affect real-time dashboard updates?**

A: Minimal. Updates go from "instant" to "500ms batched", which is imperceptible to users.

**Q: What if we need <500ms updates?**

A: Reduce batch interval to 100ms or use Phoenix Channels streaming instead of PubSub broadcasts.

## Related Code

**Files to review**:
- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso_web/dashboard/cluster_event_aggregator.ex`
- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso_web/dashboard/dashboard.ex`
- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso_web/dashboard/message_handlers.ex`
- `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso/events/routing_decision.ex`

**Key lines**:
- `dashboard.ex:173` - Direct PubSub subscription (DELETE THIS)
- `dashboard.ex:298-340` - RoutingDecision handler (DELETE THIS)
- `dashboard.ex:810-813` - Metrics update handler (KEEP THIS)
- `cluster_event_aggregator.ex:206` - Init (ADD off-heap flag)
- `cluster_event_aggregator.ex:228-243` - Event handler (MODIFY for dedup)

## Contributing

When adding new analysis:
1. Focus on BEAM-specific behavior (processes, mailboxes, GC, schedulers)
2. Include concrete measurements (use `:erts_debug.flat_size/1`)
3. Provide profiling commands, not just theory
4. Link to code with absolute file paths
5. Test recommendations under load

## License

Internal documentation for Lasso RPC project.
