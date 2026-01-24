# Clustering Test Guide

**Version**: 1.0
**Last Updated**: January 2026
**Related**: [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md), [IMPLEMENTATION_CHECKLIST.md](./IMPLEMENTATION_CHECKLIST.md)

---

## Overview

This guide covers how to test Lasso RPC clustering functionality from local development through production deployment. It focuses on pragmatic verification that catches real bugs without excessive ceremony.

### Testing Philosophy

1. **Test behavior, not implementation** - Care about outcomes, not how the code achieves them
2. **Integration over unit** - Clustering is inherently about multiple nodes working together
3. **Realistic failure modes** - Test what actually breaks in production (timeouts, crashes, net splits)
4. **Manual testing is valid** - Some things (like UI coverage indicators) are faster to verify by eye
5. **Load testing catches surprises** - Cache behavior under 100 viewers is different from under 1 viewer

### What This Guide Covers

- Local multi-node testing with LocalCluster
- Staging environment validation checklist
- Load testing for performance validation
- Monitoring and observability setup
- Production smoke tests and rollback triggers

---

## Local Testing

### Setup: LocalCluster for Multi-Node Tests

LocalCluster spawns multiple BEAM nodes in a single OS process, enabling realistic distributed testing without infrastructure overhead.

#### Add Dependency

```elixir
# mix.exs
defp deps do
  [
    {:local_cluster, "~> 1.2", only: [:test]},
    # ... existing deps
  ]
end
```

#### Test Module Pattern

```elixir
defmodule Lasso.ClusteringIntegrationTest do
  use ExUnit.Case

  # Do NOT use async: true for clustering tests
  # Multiple tests spawning nodes will conflict

  setup do
    # Start nodes with unique names per test
    test_name = String.replace("#{__MODULE__}.#{Enum.random(1000..9999)}", ".", "_")
    nodes = LocalCluster.start_nodes(test_name, 2)

    on_exit(fn ->
      LocalCluster.stop_nodes(nodes)
    end)

    {:ok, nodes: nodes}
  end

  test "nodes discover each other", %{nodes: nodes} do
    # Each node should see the other
    for node <- nodes do
      discovered = :rpc.call(node, Node, :list, [])
      other_nodes = nodes -- [node]

      assert length(discovered) == length(other_nodes)
      assert Enum.all?(other_nodes, &(&1 in discovered))
    end
  end
end
```

### Key Scenarios to Test Locally

#### 1. Cluster Formation

**What to verify**: Nodes automatically discover each other without manual intervention.

```elixir
test "libcluster connects nodes automatically", %{nodes: nodes} do
  # Wait for libcluster to do discovery (DNS poll interval + join time)
  Process.sleep(6_000)

  for node <- nodes do
    connected = :rpc.call(node, Node, :list, [])
    # Should see N-1 other nodes
    assert length(connected) == length(nodes) - 1
  end
end
```

**Why this matters**: If nodes can't discover each other, nothing else works.

#### 2. ClusterMetricsCache Aggregation

**What to verify**: Metrics from multiple nodes aggregate correctly with proper weighted averages.

```elixir
test "aggregates provider metrics across nodes", %{nodes: [node1, node2]} do
  # Record different metrics on each node
  :rpc.call(node1, Lasso.Benchmarking.BenchmarkStore, :record_success, [
    "default", "ethereum", "alchemy", 100, 1000  # 100ms latency, 1000 calls
  ])

  :rpc.call(node2, Lasso.Benchmarking.BenchmarkStore, :record_success, [
    "default", "ethereum", "alchemy", 200, 100   # 200ms latency, 100 calls
  ])

  # Fetch aggregated metrics from either node
  {:ok, metrics, _freshness} = :rpc.call(
    node1,
    LassoWeb.Dashboard.ClusterMetricsCache,
    :get_cluster_metrics,
    ["default", "ethereum"]
  )

  alchemy = Enum.find(metrics.providers, &(&1.provider_id == "alchemy"))

  # Should have summed calls
  assert alchemy.total_calls == 1100

  # Should have weighted average latency: (100*1000 + 200*100) / 1100 = 109.09ms
  assert_in_delta alchemy.avg_latency_ms, 109, 1

  # Should report both nodes
  assert metrics.responding_nodes == 2
  assert metrics.total_nodes == 2
end
```

**Why this matters**: Wrong aggregation math means wrong dashboards, and the error is invisible.

#### 3. Event Deduplication

**What to verify**: Same event arriving from multiple nodes only appears once in dashboard.

```elixir
test "deduplicates routing events across nodes", %{nodes: [node1, node2]} do
  # Simulate same event broadcast from both nodes (same request_id)
  event = %Lasso.Events.RoutingDecision{
    request_id: "req-test-123",
    profile: "default",
    chain: "ethereum",
    result: :success,
    source_node: node1,
    timestamp: System.system_time(:millisecond)
  }

  # Subscribe to event buffer
  Phoenix.PubSub.subscribe(Lasso.PubSub, "dashboard:events")

  # Publish from both nodes
  :rpc.call(node1, Phoenix.PubSub, :broadcast, [
    Lasso.PubSub,
    "routing:decisions:default",
    event
  ])

  :rpc.call(node2, Phoenix.PubSub, :broadcast, [
    Lasso.PubSub,
    "routing:decisions:default",
    %{event | source_node: node2}  # Different node, same request_id
  ])

  # Should receive event only once
  assert_receive {:new_event, ^event}, 1000
  refute_receive {:new_event, _}, 500
end
```

**Why this matters**: Duplicate events spam the activity feed and confuse users.

#### 4. Partial Node Failure

**What to verify**: Dashboard degrades gracefully when some nodes are unreachable.

```elixir
test "handles partial node failure gracefully", %{nodes: [node1, node2, node3]} do
  # Record data on all nodes
  for node <- [node1, node2, node3] do
    :rpc.call(node, BenchmarkStore, :record_success, [
      "default", "ethereum", "alchemy", 100, 100
    ])
  end

  # Stop one node
  LocalCluster.stop_nodes([node3])

  # Should still get partial results
  {:ok, metrics, _} = :rpc.call(
    node1,
    ClusterMetricsCache,
    :get_cluster_metrics,
    ["default", "ethereum"]
  )

  # Partial coverage (2 of 3 nodes, or 2 of 2 if node3 already removed from cluster)
  assert metrics.responding_nodes >= 2
  assert metrics.responding_nodes < metrics.total_nodes or metrics.total_nodes == 2

  # Should still have data
  assert length(metrics.providers) > 0
end
```

**Why this matters**: Nodes will fail in production. Cluster should keep working with reduced data.

#### 5. Cache Correctness Under Load

**What to verify**: Concurrent cache requests don't cause duplicate RPC calls or crashes.

```elixir
test "cache handles concurrent requests without duplicate RPC", %{nodes: [node1, _node2]} do
  # Start cache on node1
  cache_pid = :rpc.call(node1, Process, :whereis, [ClusterMetricsCache])

  # Spawn 50 concurrent callers requesting same cache key
  tasks = for _i <- 1..50 do
    Task.async(fn ->
      :rpc.call(node1, ClusterMetricsCache, :get_cluster_metrics, ["default", "ethereum"])
    end)
  end

  results = Enum.map(tasks, &Task.await/1)

  # All should succeed
  assert Enum.all?(results, &match?({:ok, _, _}, &1))

  # Check cache stats - should have had only 1 pending refresh despite 50 callers
  stats = :rpc.call(node1, ClusterMetricsCache, :stats, [])
  assert stats.cache_entries >= 1
  # If we caught it during refresh, max 1 pending
  assert stats.pending_refreshes <= 1
end
```

**Why this matters**: Cache state machine is complex. Races can cause duplicate expensive RPC calls.

### Running Local Tests

```bash
# Run all clustering tests
mix test test/lasso/clustering_integration_test.exs

# Run specific test
mix test test/lasso/clustering_integration_test.exs:42

# Verbose output for debugging
mix test test/lasso/clustering_integration_test.exs --trace
```

### Common Local Testing Issues

| Issue | Symptom | Solution |
|-------|---------|----------|
| **Nodes don't connect** | `Node.list()` returns `[]` | LocalCluster doesn't use libcluster. Nodes auto-connect via distributed erlang. |
| **RPC timeout** | `:badrpc, {:timeout, ...}` | Increase RPC timeout. BenchmarkStore might not be started on test nodes. |
| **Port conflicts** | `eaddrinuse` | Use unique node names per test. Don't use `async: true`. |
| **Flaky dedup tests** | Sometimes passes, sometimes fails | PubSub delivery timing. Use `assert_receive` with timeout, not exact counts. |

---

## Staging Environment Testing

### Prerequisites

- Staging environment deployed with 2+ nodes
- SSH access via `fly ssh console -a lasso-staging`
- Monitoring/telemetry configured

### Manual Validation Checklist

Run through this checklist before promoting clustering to production:

#### Cluster Formation

- [ ] **Nodes discover each other**
  ```bash
  fly ssh console -a lasso-staging
  > app/bin/lasso remote
  iex> Node.list()
  # Should return 1+ other nodes within 30 seconds of deploy
  ```

- [ ] **Health endpoint includes cluster state**
  ```bash
  curl https://lasso-staging.fly.dev/health | jq '.cluster'
  # Should show: {"enabled": true, "nodes_connected": 2, "nodes_total": 2}
  ```

- [ ] **ClusterMonitor logs node events**
  ```bash
  fly logs -a lasso-staging | grep -i "cluster"
  # Should see: "Cluster node joined: lasso@..." on startup
  ```

#### Dashboard Aggregation

- [ ] **Coverage indicators visible**
  - Open dashboard in browser
  - Navigate to Metrics tab
  - Verify header shows "Coverage: 2/2 nodes" (or similar)

- [ ] **Activity feed shows merged events**
  - Generate test traffic (curl some RPC endpoints)
  - Activity feed should show events from different `source_node` values
  - No obvious duplicates (same request_id appearing twice)

- [ ] **Metrics refresh without UI blocking**
  - Dashboard should update every 15 seconds
  - No freezing or "Loading..." stuck states
  - Check browser console for errors

#### Failure Modes

- [ ] **Single node failure degrades gracefully**
  ```bash
  # Stop one machine
  fly machine list -a lasso-staging
  fly machine stop <machine-id>

  # Check dashboard
  # - Should show "Coverage: 1/2 nodes" with yellow warning
  # - Data still visible (partial)
  # - No hard errors or blank screens

  # Restart machine
  fly machine start <machine-id>

  # Verify rejoin
  # - Within 60 seconds, coverage returns to "2/2 nodes"
  # - Dashboard updates with full data
  ```

- [ ] **Network partition recovery**
  ```bash
  # Use fly machine restart to simulate brief partition
  fly machine restart <machine-id> --force

  # Monitor logs for reconnection
  fly logs -a lasso-staging --region <region>
  # Should see "Cluster node joined" within 60s
  ```

#### Performance Under Load

- [ ] **Dashboard with 10 concurrent viewers**
  - Open dashboard in 10 browser tabs
  - All tabs should refresh without errors
  - Check cache hit rate in telemetry (target >80%)

- [ ] **RPC latency acceptable**
  ```elixir
  # In remote console
  :timer.tc(fn ->
    LassoWeb.Dashboard.ClusterMetricsCache.get_cluster_metrics("default", "ethereum")
  end)
  # Should return in <500ms (p95 target)
  ```

- [ ] **No memory leaks during extended viewing**
  - Leave dashboard open for 30 minutes
  - Check BEAM memory usage doesn't climb steadily
  - Verify via `fly ssh console` → `:observer.start()`

#### Event Sampling

- [ ] **High traffic doesn't overwhelm PubSub**
  - Generate sustained load (100+ req/s)
  - Dashboard activity feed should show sampled events (not all 100/s)
  - No errors about mailbox overflow in logs

### Staging Smoke Test Script

```bash
#!/bin/bash
# staging_clustering_smoke_test.sh

set -e

APP="lasso-staging"
HEALTH_URL="https://lasso-staging.fly.dev/health"

echo "=== Clustering Smoke Test ==="

# 1. Check cluster health
echo "1. Checking cluster health..."
HEALTH=$(curl -s $HEALTH_URL)
NODES_CONNECTED=$(echo $HEALTH | jq -r '.cluster.nodes_connected')
NODES_TOTAL=$(echo $HEALTH | jq -r '.cluster.nodes_total')

if [ "$NODES_CONNECTED" -lt "$NODES_TOTAL" ]; then
  echo "❌ Cluster degraded: $NODES_CONNECTED/$NODES_TOTAL nodes"
  exit 1
fi
echo "✓ Cluster healthy: $NODES_CONNECTED/$NODES_TOTAL nodes"

# 2. Generate test traffic
echo "2. Generating test traffic..."
for i in {1..20}; do
  curl -s -X POST $HEALTH_URL/../rpc/default/ethereum \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    > /dev/null &
done
wait

echo "✓ Traffic generated"

# 3. Check dashboard accessibility
echo "3. Checking dashboard..."
DASHBOARD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://lasso-staging.fly.dev/dashboard)
if [ "$DASHBOARD_STATUS" != "200" ]; then
  echo "❌ Dashboard returned $DASHBOARD_STATUS"
  exit 1
fi
echo "✓ Dashboard accessible"

echo "=== All smoke tests passed ==="
```

### Monitoring During Staging Tests

Key metrics to watch:

```
# Cache performance
lasso_web.dashboard.cache.count{result="hit"}  # Target >80%
lasso_web.dashboard.cache.count{result="miss"}

# RPC performance
lasso_web.dashboard.cluster_rpc.duration_ms (p95)  # Target <500ms
lasso_web.dashboard.cluster_rpc.success_rate       # Target 100%

# Event rate
lasso_web.dashboard.events.rate{sampled="true"}    # Should be <100/s sustained

# Cluster stability
lasso.cluster.node_up.count
lasso.cluster.node_down.count  # Should be rare
```

---

## Load Testing

### Purpose

Load testing validates that caching, aggregation, and event handling work correctly at realistic scale. Unit tests and manual testing won't catch cache stampedes or mailbox overflow.

### Test Scenarios

#### Scenario 1: Concurrent Dashboard Viewers

**Goal**: Verify cache hit rate >80% with many concurrent viewers.

```javascript
// k6 script: dashboard_load.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 100,  // 100 concurrent users
  duration: '5m',
};

export default function () {
  const res = http.get('https://lasso-staging.fly.dev/dashboard');

  check(res, {
    'status is 200': (r) => r.status === 200,
    'page loads under 2s': (r) => r.timings.duration < 2000,
  });

  sleep(15);  // Simulate user viewing for 15s (one refresh cycle)
}
```

**Run test**:
```bash
k6 run dashboard_load.js
```

**Success criteria**:
- p95 response time <2s
- Zero errors
- Cache hit rate >80% (check telemetry)

#### Scenario 2: High RPC Traffic with Events

**Goal**: Verify event sampling prevents PubSub bottleneck.

```javascript
// k6 script: rpc_load.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 50,
  duration: '2m',
};

export default function () {
  const payload = JSON.stringify({
    jsonrpc: '2.0',
    method: 'eth_blockNumber',
    params: [],
    id: 1
  });

  const res = http.post(
    'https://lasso-staging.fly.dev/rpc/default/ethereum',
    payload,
    { headers: { 'Content-Type': 'application/json' } }
  );

  check(res, {
    'status is 200': (r) => r.status === 200,
  });
}
```

**During test**, monitor:
```bash
# Watch event rate
fly logs -a lasso-staging | grep "routing:decisions"

# Check mailbox sizes
fly ssh console -a lasso-staging
> :observer.start()
# Navigate to Processes tab, sort by message queue length
```

**Success criteria**:
- Event rate <150/s per node (sampling working)
- No LiveView crashes (check logs)
- No mailbox warnings in logs

### Load Test Failure Modes

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Cache hit rate <50% | TTL too short or excessive invalidation | Increase `@cache_ttl_ms` to 30s |
| Dashboard timeouts | RPC taking too long | Check network latency between nodes; consider increasing RPC timeout |
| LiveView crashes | Mailbox overflow from events | Reduce `success_sample_rate` or add backpressure |
| Memory climbing | EventDedup not expiring old entries | Verify dedup cleanup interval |

---

## Production Deployment

### Pre-Deployment Checklist

Before deploying clustering to production:

- [ ] All staging validation tests passed
- [ ] Load test completed successfully
- [ ] Monitoring/alerting configured
- [ ] Rollback plan documented
- [ ] Cookie set via `fly secrets set RELEASE_COOKIE=...`
- [ ] Expected node count set in fly.toml

### Deployment Strategy

**Recommended**: Deploy one region at a time (rolling deploy).

```bash
# Deploy to US region first
fly deploy --region iad -a lasso-production

# Wait 5 minutes, verify health
curl https://lasso-production.fly.dev/health | jq '.cluster'

# If healthy, deploy remaining regions
fly deploy -a lasso-production
```

### Post-Deployment Smoke Tests

Run within 10 minutes of deploy:

1. **Cluster formed**
   ```bash
   fly ssh console -a lasso-production
   iex> Node.list()
   # Should show all other nodes
   ```

2. **Dashboard loads with coverage**
   - Open dashboard
   - Verify "Coverage: N/N nodes" shows full coverage
   - Activity feed shows events

3. **Metrics refreshing**
   - Watch dashboard for 1 minute
   - Metrics should update every 15 seconds
   - No "updating..." stuck states

### Monitoring in Production

**Critical alerts** (should wake someone up):
- `lasso.cluster.nodes_connected < expected - 1` for >2 minutes
- `lasso_web.dashboard.cluster_rpc.duration_ms (p95) > 2000ms`
- `lasso_web.dashboard.cluster_rpc.success_rate < 0.8`

**Warning alerts** (review during business hours):
- Cache hit rate <50% for >10 minutes
- Event rate >150/s sustained for >5 minutes
- >5 node flaps (up/down cycles) in 10 minutes

**Dashboard for ops**:
```
# Grafana panels to create
- Cluster node count (gauge)
- RPC latency (p50, p95, p99 over time)
- Cache hit/miss/stale rates (stacked area)
- Event rate by profile (line chart)
- LiveView process count (line chart)
```

### Rollback Triggers

**Immediate rollback if**:
- Cluster won't form (Node.list() returns [] after 2 minutes)
- Dashboard hard errors for all users
- RPC requests start failing (cluster RPC interfering with hot path)

**Rollback procedure**:
```bash
# Get previous deployment image
fly releases -a lasso-production
# Deploy previous version
fly deploy --image <previous-image-ref> -a lasso-production

# Or use Fly's instant rollback
fly deploy --strategy immediate --image <previous-image> -a lasso-production
```

### Feature Flag Fallback

If clustering is partially broken but not critical:

```elixir
# config/runtime.exs
config :lasso, :cluster_metrics_enabled, System.get_env("ENABLE_CLUSTER_METRICS") == "true"

# In ClusterMetricsCache
def get_cluster_metrics(profile, chain) do
  if Application.get_env(:lasso, :cluster_metrics_enabled, true) do
    # Cluster aggregation path
  else
    # Fallback to local-only metrics
    local_metrics(profile, chain)
  end
end
```

**Disable clustering without redeploy**:
```bash
fly secrets set ENABLE_CLUSTER_METRICS=false -a lasso-production
# Restart to pick up new env
fly machine restart <machine-id>
```

---

## Debugging Production Issues

### Cluster Won't Form

**Symptom**: `Node.list()` returns `[]` after several minutes.

**Check**:
```bash
# 1. Verify DNS resolution
fly ssh console -a lasso-production
> :inet.gethostbyname('lasso-production.internal')
# Should return IP addresses of machines

# 2. Check cookie set
> Node.get_cookie()
# Should NOT be :nocookie

# 3. Check node name format
> node()
# Should be: :"lasso-production@<ipv6>"
# NOT: :"lasso-production-<image-hash>@<ipv6>"  (wrong naming pattern)

# 4. Check libcluster logs
fly logs -a lasso-production | grep -i libcluster
```

**Common causes**:
- Cookie not set or mismatched
- Node naming includes deployment-specific values (changes on deploy)
- DNS not resolving internal hostname
- Network connectivity issues between nodes

### Dashboard Shows Stale Data

**Symptom**: Coverage indicator shows "(updating...)" constantly.

**Check**:
```elixir
# In remote console
LassoWeb.Dashboard.ClusterMetricsCache.stats()
# Look for: pending_refreshes > 0 stuck, waiting_callers accumulating

# Check if RPC is timing out
:timer.tc(fn ->
  :rpc.call(List.first(Node.list()), BenchmarkStore, :get_provider_leaderboard, ["default", "ethereum"], 5000)
end)
# Should complete in <1s. If timeout, network issue between nodes.
```

**Common causes**:
- Network latency between regions (increase RPC timeout)
- BenchmarkStore not returning data (no traffic recorded yet)
- Cache task crashing repeatedly (check logs for exceptions)

### Event Duplicates in Feed

**Symptom**: Same request appearing 2-3 times in activity feed.

**Check**:
```elixir
# Verify EventDedup is working
# Subscribe to raw PubSub topic
Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:decisions:default")

# Generate test request
# Watch for multiple events with same request_id

# If dedup broken, check EventDedup state in EventBuffer
GenServer.call(LassoWeb.Dashboard.EventBuffer, :stats)  # includes dedup stats
```

**Common causes**:
- EventDedup not started (missing from supervision tree)
- Dedup window too short (events from slow nodes arrive late)
- Different nodes generating same request_id (UUID collision - extremely rare)

---

## Testing Checklist Summary

Use this checklist to verify clustering is production-ready:

### Development Phase
- [ ] Local multi-node tests pass (LocalCluster)
- [ ] Aggregation math verified with edge cases
- [ ] Event deduplication works
- [ ] Cache handles concurrent requests

### Staging Phase
- [ ] Nodes discover each other automatically
- [ ] Dashboard shows coverage indicators
- [ ] Single node failure degrades gracefully
- [ ] No memory leaks during extended use
- [ ] Load test: 100 concurrent viewers, no errors

### Production Phase
- [ ] Cluster forms within 60s of deploy
- [ ] Dashboard loads with full coverage
- [ ] Monitoring/alerts configured
- [ ] Smoke tests pass
- [ ] Rollback plan tested

### Ongoing
- [ ] Cache hit rate >80%
- [ ] RPC p95 <500ms
- [ ] No cluster flapping (stable node count)
- [ ] Event rate within budget (<150/s)

---

## When to Skip Testing

**Reality check**: Not everything needs a test. Skip testing if:

- It's trivial (e.g., formatting a timestamp)
- It's visual and subjective (e.g., coverage indicator color)
- It's testing a library, not your code (e.g., PubSub delivery)
- The cost of maintaining the test exceeds the value (e.g., brittle UI tests)

**Trust but verify**: Some things are better spot-checked in staging than formally tested:
- Telemetry emissions (check once, trust it works)
- Log messages (grep logs during staging validation)
- Health endpoint format (curl it once)

**Invest in high-value tests**:
- Aggregation math (subtle bugs, high impact)
- RPC failure handling (will happen in production)
- Cache correctness (complex state machine)
- Event deduplication (cross-node interactions)

The goal is confidence, not coverage percentage.
