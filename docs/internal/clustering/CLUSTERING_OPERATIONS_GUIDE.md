# Lasso RPC - Clustering Operations Guide

**Version**: 1.0
**Last Updated**: 2026-01-24
**Audience**: DevOps, SRE, Platform Engineers
**Related**: [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md)

---

## Purpose

This guide provides operational procedures, runbooks, and monitoring requirements for running Lasso RPC in a clustered, geo-distributed deployment. It complements the implementation specs with operational knowledge.

**Note**: This guide includes platform-specific examples and commands. While many examples reference a specific cloud platform, the underlying concepts (DNS discovery, cookie management, node naming) apply broadly. Adapt commands for your deployment platform.

**Environment Variable Mapping**:
| Generic Variable | Purpose | Example Value |
|-----------------|---------|---------------|
| `CLUSTER_DNS_QUERY` | DNS hostname for node discovery | `myapp.internal` |
| `CLUSTER_NODE_BASENAME` | Common prefix for all nodes | `lasso-rpc` |
| `CLUSTER_NODE_IP` | This node's cluster-reachable IP | `10.0.0.5` |
| `CLUSTER_REGION` | Region identifier for metrics | `us-east` |

**What's in this guide:**
- Cluster formation requirements (libcluster, cookies, node naming)
- Failure mode analysis and recovery procedures
- Observability setup (health endpoints, telemetry, alerting)
- Staging validation procedures
- Troubleshooting runbooks

**Prerequisites**: You should have read [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md) for architecture context.

---

## 1. Current Infrastructure Assessment

### 1.1 What Exists

✅ **Release Configuration** (`/Users/jacksonernst/Documents/GitHub/lasso-cloud/rel/env.sh.eex`)
- IPv6 distribution enabled (`-proto_dist inet6_tcp`)
- Node naming configured for Fly.io 6PN
- Uses `RELEASE_NODE="${CLUSTER_NODE_BASENAME}-${FLY_IMAGE_REF##*-}@${FLY_PRIVATE_IP}"`
- Distribution mode set to `name` (long names)

✅ **Phoenix.PubSub Configured** (`/Users/jacksonernst/Documents/GitHub/lasso-cloud/lib/lasso/application.ex:39`)
- Single PubSub server named `Lasso.PubSub`
- Uses default PG2 adapter (cluster-aware)
- Will automatically distribute events once nodes connect

✅ **Fly.io Production Deployment** (`fly.prod.toml`)
- Multi-region capable (currently 2 nodes: `iad`, `sjc`)
- Auto-scaling configured (min 2 machines)
- IPv6 networking ready

### 1.2 Critical Gaps

❌ **No libcluster Dependency or Configuration**
- `mix.exs` does not include `{:libcluster, "~> 3.3"}`
- No topology configuration in `config/runtime.exs`
- Nodes cannot discover each other automatically

❌ **No Erlang Cookie Configured**
- `RELEASE_COOKIE` not set in Fly secrets (confirmed via `fly secrets list`)
- Without shared cookie, nodes will refuse to connect
- Security vulnerability if default cookie is used

❌ **No vm.args.eex File**
- Missing Erlang VM tuning parameters
- No `net_ticktime` configuration (uses default 60s)
- No `kernel` parameter customization

❌ **No Cluster Health Monitoring**
- Health endpoint (`/Users/jacksonernst/Documents/GitHub/lasso-cloud/lib/lasso_web/controllers/health_controller.ex`) doesn't report cluster state
- No telemetry events for node connections/disconnections
- No alerting on partition scenarios

❌ **Profile-Scoped Events Not Implemented**
- Routing events broadcast to global topic `"routing:decisions"` (line 339 of `observability.ex`)
- Missing `profile` field in event payload
- Dashboard subscribes to global topic (line 138 of `dashboard.ex`)
- Cross-tenant data leakage risk in SaaS deployment

---

## 2. Cluster Discovery Configuration

### 2.1 DNS-Based Discovery

Most deployment platforms provide internal DNS that resolves to all node IPs. Set `CLUSTER_DNS_QUERY` to your platform's internal DNS name.

**Required libcluster Configuration**:

```elixir
# config/runtime.exs
# Clustering is optional - only configure if DNS query is set
if dns_query = System.get_env("CLUSTER_DNS_QUERY") do
  config :libcluster,
    topologies: [
      dns: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 5_000,  # 5 seconds
          query: dns_query,
          node_basename: System.fetch_env!("CLUSTER_NODE_BASENAME")
        ]
      ]
    ]
end
```

**Why DNS Polling?** ([BEAM Clustering made easy · The Phoenix Files](https://fly.io/phoenix-files/beam-clustering-made-easy/))
- Fly.io's 6PN private network makes DNS the simplest discovery mechanism
- Multicast and gossip strategies don't work well across WireGuard tunnels
- DNS updates are fast (~1-2 seconds after machine start)

### 2.2 IPv6 and 6PN Networking

✅ **Already Configured** in `rel/env.sh.eex`:
```bash
export ERL_AFLAGS="-proto_dist inet6_tcp"
export ECTO_IPV6="true"
```

This is correct. Fly.io uses IPv6 for private networking ([Private Networking · Fly Docs](https://fly.io/docs/reference/private-networking/)):
- All apps get 6PN addresses (IPv6 Private Networking)
- WireGuard mesh connects regions
- Internal DNS resolves to 6PN addresses only

### 2.3 Node Naming Strategy

Node names must have a **consistent basename** across all nodes for libcluster discovery to work. The basename is the part before the `@` symbol.

**Required Pattern**:
```bash
export RELEASE_NODE="${CLUSTER_NODE_BASENAME}@${CLUSTER_NODE_IP}"
```

This creates predictable names like `lasso-rpc@10.0.0.5` where:
- All nodes share the same basename (`lasso-rpc`)
- Each node has a unique IP suffix

**Common Mistake**: Including deployment-specific values (image refs, timestamps) in the node name. This breaks cluster formation because nodes have different basenames.

```bash
# WRONG - basenames differ per deploy
export RELEASE_NODE="${APP_NAME}-${DEPLOY_HASH}@${IP}"
# Results in: lasso-rpc-abc123@... vs lasso-rpc-xyz789@...

# CORRECT - consistent basename
export RELEASE_NODE="${APP_NAME}@${IP}"
# Results in: lasso-rpc@10.0.0.5 vs lasso-rpc@10.0.0.6
```

---

## 3. Erlang Distribution Configuration

### 3.1 Cookie Security (CRITICAL)

**Current State**: No `RELEASE_COOKIE` secret configured.

**Risk**:
- Erlang defaults to `~/.erlang.cookie` file (not present in Docker)
- May fall back to insecure default or random per-machine cookie
- Nodes will fail to connect with authentication errors

**Required Action**:
```bash
# Generate cryptographically secure cookie
fly secrets set RELEASE_COOKIE="$(openssl rand -base64 32)" -a lasso-rpc
fly secrets set RELEASE_COOKIE="$(openssl rand -base64 32)" -a lasso-staging
```

**Critical Security Note**: This cookie is equivalent to a root password for the cluster. Anyone with this cookie can:
- Connect rogue nodes to your cluster
- Execute arbitrary code via `:rpc.call/4`
- Read all application state
- Crash the cluster

Treat it as sensitive as database credentials.

### 3.2 Network Tick Time

**Current State**: No `vm.args.eex` file exists.

**Default Behavior**: Erlang uses `net_ticktime = 60` seconds:
- Nodes exchange heartbeats every 15 seconds (60/4)
- Node is considered down after 60 seconds of silence
- Detection range: 45-75 seconds due to ±25% jitter ([Net Tick Time | RabbitMQ](https://www.rabbitmq.com/nettick.html))

**Is Default Acceptable?**

For Fly.io: **YES, with caveats**
- Fly's 6PN network is stable (WireGuard tunnels)
- 60s detection is reasonable for geo-distributed deployment
- Shorter ticktime increases heartbeat overhead across regions

**However**: Create `rel/vm.args.eex` for future tuning:

```erl
## Erlang Distribution Configuration

# Network tick time (heartbeat interval between nodes)
# Default: 60 seconds. Decrease for faster partition detection.
# Increase for flaky networks to avoid spurious disconnects.
-kernel net_ticktime 60

# Prevent overlapping partitions (OTP 25+)
# Ensures proper cluster state during network flaps
-kernel prevent_overlapping_partitions true

# Connection timeout for distributed Erlang
# Default: 60 seconds
-kernel dist_auto_connect once

# Enable distribution optimizations
-kernel inet_dist_listen_min 9100
-kernel inet_dist_listen_max 9155
```

**Why `dist_auto_connect once`?** ([Distributed Erlang — Erlang System Documentation](https://www.erlang.org/doc/system/distributed.html))
- Default `once` means nodes try to reconnect once on disconnect
- Alternative `false` disables auto-reconnect (requires manual intervention)
- libcluster handles reconnection logic, so `once` is safe

### 3.3 Recommended Tuning for Fly.io

**Do NOT change these initially**. Use defaults and measure before tuning:

| Parameter | Default | When to Tune | Why |
|-----------|---------|--------------|-----|
| `net_ticktime` | 60s | If seeing spurious disconnects | Fly's network is stable; 60s is fine |
| `inet_dist_listen_min/max` | Ephemeral | If firewall rules needed | Fly handles this via 6PN |
| `dist_buffer_size` | 1MB | If high traffic between nodes | Dashboard multicall is low volume |

**Measurement-Driven Approach**:
1. Deploy with defaults
2. Monitor node connection events (see Section 5)
3. If partition rate > 1 per week, investigate network vs tuning

---

## 4. Cluster Failure Modes & Handling

### 4.1 Failure Mode Table

| Scenario | Detection Time | Impact | Auto-Recovery | Mitigation |
|----------|---------------|--------|---------------|------------|
| **Single node crash** | Instant (supervisor) | 50% capacity loss (2→1 node) | Fly auto-restart (~30s) | Graceful degradation in dashboard (show 1/2 nodes) |
| **Network partition** | 45-75s (net_ticktime) | Cluster splits into islands | libcluster rejoins on heal | Show partial data warning in UI |
| **DNS resolution failure** | 5s (polling_interval) | New nodes can't join | Retry on next poll | Alert if node count drops |
| **Region-wide outage** | 0-60s (depends on failure) | Lose 1 region's capacity | Fly routes to healthy region | Regional circuit breakers prevent cascading failure |
| **Split-brain (partition with writes)** | N/A (no distributed writes) | Non-issue for Lasso | N/A | Node-local state prevents conflict |
| **Cookie mismatch** | Instant (connection refused) | Nodes can't join cluster | Manual fix required | Alert on zero connected nodes |
| **libcluster misconfiguration** | Never (silent failure) | Nodes never discover each other | Manual fix required | Health check exposes `Node.list() == []` |

### 4.2 Split-Brain Analysis

**Good News**: Lasso's architecture is **naturally split-brain safe** because:

✅ **No Distributed Writes in Hot Path**
- Circuit breakers are node-local (spec Section 3.2)
- Provider pool state is node-local
- ETS tables are node-local
- No CRDTs or Mnesia

✅ **Dashboard is Read-Only Aggregation**
- `:rpc.multicall` for metrics aggregation (spec Section 5.5)
- Failures return partial results (graceful degradation)
- No state synchronization required

✅ **Billing Metering is Node-Aware**
- CU Accumulator must be fixed per spec Section 4.3
- Each node reports independently to database
- Database aggregation is authoritative

**Only Risk**: Dashboard showing stale/partial data during partition
- **Not a correctness issue** (RPC routing unaffected)
- **UX issue** (users see incomplete metrics)
- **Mitigation**: Show coverage indicator (spec Section 5.1)

### 4.3 Partition Handling Strategy

**Erlang's Built-In Behavior** ([Distributed Erlang — Erlang System Documentation](https://www.erlang.org/doc/system/distributed.html)):
- Partitioned nodes trigger `:nodedown` messages
- PubSub stops forwarding to unreachable nodes
- `:rpc.multicall` excludes disconnected nodes from results
- On heal, nodes automatically reconnect (libcluster + `dist_auto_connect`)

**Application-Level Handling Required**:

1. **Health Endpoint Must Report Cluster State** (see Section 5.1)
2. **Dashboard Must Show Coverage** (spec Section 5.1)
   ```
   Requests/sec: 1,234  (2/3 nodes)  ← Partial coverage warning
   ```
3. **Alert on Sustained Partitions** (not transient flaps)

**Do NOT Implement**:
- ❌ Custom partition detection (Erlang handles this)
- ❌ Quorum-based decision making (not needed for read-only aggregation)
- ❌ Automatic node ejection (let Fly handle machine health)

---

## 5. Observability Requirements

### 5.1 Cluster Health Endpoint

**Current State**: `/health` endpoint returns only local node status:
```elixir
%{
  status: "healthy",
  timestamp: DateTime.utc_now(),
  uptime_seconds: uptime_seconds,
  version: Application.spec(:lasso, :vsn) |> to_string()
}
```

**Required Enhancement**:
```elixir
defmodule LassoWeb.HealthController do
  def health(conn, _params) do
    uptime_ms = System.monotonic_time(:millisecond) -
                Application.get_env(:lasso, :start_time)

    # Cluster state
    connected_nodes = Node.list()
    node_count = length(connected_nodes) + 1  # +1 for self

    # Group by region (requires CLUSTER_REGION env var from each node)
    regions = get_cluster_regions()

    health_status = %{
      status: determine_status(node_count),
      timestamp: DateTime.utc_now(),
      uptime_seconds: div(uptime_ms, 1000),
      version: Application.spec(:lasso, :vsn) |> to_string(),
      node: %{
        name: node(),
        region: System.get_env("CLUSTER_REGION", "unknown")
      },
      cluster: %{
        enabled: cluster_enabled?(),
        nodes_connected: length(connected_nodes),
        nodes_total: node_count,
        regions: regions,
        nodes: connected_nodes
      }
    }

    json(conn, health_status)
  end

  defp determine_status(node_count) do
    cond do
      node_count >= expected_node_count() -> "healthy"
      node_count >= div(expected_node_count(), 2) -> "degraded"
      true -> "critical"
    end
  end

  defp cluster_enabled? do
    Application.get_env(:libcluster, :topologies, []) != []
  end

  defp get_cluster_regions do
    # Query each node for its CLUSTER_REGION
    [node() | Node.list()]
    |> Enum.map(fn node ->
      case :rpc.call(node, System, :get_env, ["CLUSTER_REGION"]) do
        region when is_binary(region) -> region
        _ -> "unknown"
      end
    end)
    |> Enum.uniq()
  end

  defp expected_node_count do
    # Could be config or env var
    String.to_integer(System.get_env("EXPECTED_NODE_COUNT", "2"))
  end
end
```

**Why This Matters**:
- Fly.io health checks can detect cluster degradation
- Ops team can see cluster state without SSH
- Alerts can trigger on `node_count < expected`

### 5.2 Telemetry Events for Distribution

**Currently Missing**: No events for node connections/disconnections.

**Required Events**:

```elixir
# In application.ex or new cluster monitor module
defmodule Lasso.ClusterMonitor do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Subscribe to node events
    :net_kernel.monitor_nodes(true, node_type: :visible)

    Logger.info("Cluster monitor started on node #{node()}")
    {:ok, %{}}
  end

  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node connected: #{node}")

    :telemetry.execute(
      [:lasso, :cluster, :node, :connected],
      %{node_count: length(Node.list()) + 1},
      %{node: node, region: get_node_region(node)}
    )

    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("Node disconnected: #{node}")

    :telemetry.execute(
      [:lasso, :cluster, :node, :disconnected],
      %{node_count: length(Node.list()) + 1},
      %{node: node}
    )

    {:noreply, state}
  end

  defp get_node_region(node) do
    case :rpc.call(node, System, :get_env, ["CLUSTER_REGION"], 1000) do
      region when is_binary(region) -> region
      _ -> "unknown"
    end
  end
end
```

**Add to Telemetry Metrics** (`lib/lasso/observability/telemetry.ex`):

```elixir
# In Lasso.Telemetry.metrics/0
counter("lasso.cluster.node.connected.count",
  event_name: [:lasso, :cluster, :node, :connected],
  description: "Cluster nodes connected",
  tags: [:node, :region]
),
counter("lasso.cluster.node.disconnected.count",
  event_name: [:lasso, :cluster, :node, :disconnected],
  description: "Cluster nodes disconnected",
  tags: [:node]
),
last_value("lasso.cluster.node.count",
  event_name: [:lasso, :cluster, :node, :connected],
  measurement: :node_count,
  description: "Current cluster node count"
)
```

### 5.3 Phoenix.PubSub Monitoring

**Current State**: PubSub is configured but not monitored.

**Recommendation**: Use Phoenix.PubSub's built-in instrumentation:

```elixir
# These events are emitted automatically by Phoenix.PubSub 2.1+
:telemetry.attach_many(
  "lasso-pubsub-metrics",
  [
    [:phoenix, :pubsub, :broadcast, :start],
    [:phoenix, :pubsub, :broadcast, :stop],
    [:phoenix, :pubsub, :broadcast, :exception]
  ],
  &handle_pubsub_event/4,
  nil
)

defp handle_pubsub_event(event, measurements, metadata, _config) do
  # Log slow broadcasts or failures
  if measurements[:duration] > 1_000_000 do  # 1ms in native units
    Logger.warning("Slow PubSub broadcast",
      topic: metadata.topic,
      duration_us: div(measurements[:duration], 1000)
    )
  end
end
```

**Why This Matters**:
- Detect slow cross-region broadcasts
- Identify PubSub bottlenecks
- Catch silent message delivery failures

### 5.4 Dashboard Coverage Indicators

**Spec Section 5.1 Requirement**: Show coverage metadata in all aggregated views.

**Example Implementation** (in dashboard LiveView):

```elixir
defmodule LassoWeb.Dashboard.ClusterMetrics do
  def get_cluster_provider_metrics(profile, chain) do
    nodes = [node() | Node.list()]

    {results, bad_nodes} = :rpc.multicall(
      nodes,
      Lasso.Benchmarking.BenchmarkStore,
      :get_provider_leaderboard,
      [profile, chain],
      5_000  # 5 second timeout
    )

    if bad_nodes != [] do
      Logger.warning("Cluster metrics: unreachable nodes",
        bad_nodes: bad_nodes,
        responding: length(nodes) - length(bad_nodes)
      )
    end

    aggregated = aggregate_provider_metrics(results)
    responding = length(nodes) - length(bad_nodes)

    {aggregated, responding, length(nodes)}
  end
end
```

**UI Component**:
```heex
<div class="metrics-header">
  <h2>Provider Leaderboard</h2>
  <span class={coverage_class(@coverage)}>
    <%= @coverage.responding %>/<%= @coverage.total %> nodes
  </span>
</div>
```

---

## 6. Phoenix.PubSub Behavior in Clustered Mode

### 6.1 Message Ordering Guarantees

**Critical Understanding** ([Does Phoenix PubSub respect order of messages](https://elixirforum.com/t/does-phoenix-pubsub-respect-the-order-of-messages-received/30789)):

Phoenix.PubSub provides **NO ordering guarantees** across distributed nodes:

- ✅ **Local delivery**: Messages from same node arrive in order
- ❌ **Remote delivery**: Messages from different nodes can arrive out of order

**Example Scenario**:
```
Node A (iad) publishes event at 12:00:00.000
Node B (sjc) publishes event at 12:00:00.001

Subscriber on Node C may receive:
  - B's event (12:00:00.001)  ← arrives first
  - A's event (12:00:00.000)  ← arrives second (delayed by network)
```

**Impact on Lasso**:
- Recent Activity feed may show events out of timestamp order
- Transient UX glitch (events reorder after ~100ms)
- **Not a correctness issue** (events have timestamps for client-side sorting)

**Spec Section 5.3 Already Handles This**:
```elixir
# Dashboard sorts by timestamp on arrival
routing_events
|> Enum.sort_by(& &1.ts, :desc)
|> Enum.take(100)
```

**No Action Required** beyond what's in spec.

### 6.2 Message Delivery Guarantees

Phoenix.PubSub provides **at-most-once delivery**:
- If subscriber process crashes during message handling, message is lost
- If network partition occurs mid-broadcast, some nodes may not receive message
- No retry or acknowledgment mechanism

**Impact on Lasso**:
- Dashboard might miss some events during network flaps
- **Acceptable**: Events are ephemeral (next event fills the gap)
- **Not acceptable for**: Billing events (use database writes instead)

**CU Metering Events**: Spec Section 4.3 correctly uses database writes, not PubSub.

### 6.3 Distributed PubSub Overhead

**Broadcast to N subscribers across M nodes**:
- Local node: Single Erlang message copy
- Remote nodes: One message per remote node (not per subscriber)

**Example**: 10 subscribers across 3 nodes
- 1 broadcast = 3 messages sent (one per node)
- Each node fans out locally to its subscribers

**Fly.io Implications**:
- Cross-region broadcasts traverse WireGuard tunnels (add ~10-50ms latency)
- High-frequency broadcasts (>100/sec) may saturate inter-node links
- Monitor with telemetry (Section 5.3)

**Spec Section 5.4 Mitigation**: Dashboard event buffer prevents per-viewer broadcasts.

---

## 7. Configuration Checklist (Ops Readiness)

### 7.1 Phase 0: Cluster Foundation (MUST DO BEFORE MULTI-NODE)

- [ ] Add libcluster dependency to `mix.exs`
  ```elixir
  {:libcluster, "~> 3.3"}
  ```

- [ ] Configure libcluster topology in `config/runtime.exs`
  ```elixir
  if config_env() == :prod and System.get_env("CLUSTER_NODE_BASENAME") do
    config :libcluster,
      topologies: [
        fly6pn: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            polling_interval: 5_000,
            query: "#{System.get_env("CLUSTER_NODE_BASENAME")}.internal",
            node_basename: System.get_env("CLUSTER_NODE_BASENAME")
          ]
        ]
      ]
  end
  ```

- [ ] Add libcluster supervisor to `application.ex`
  ```elixir
  # After PubSub, before EventBuffer
  {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: Lasso.ClusterSupervisor]]},
  ```

- [ ] Set Erlang cookie in Fly secrets
  ```bash
  fly secrets set RELEASE_COOKIE="$(openssl rand -base64 32)" -a lasso-rpc
  fly secrets set RELEASE_COOKIE="$(openssl rand -base64 32)" -a lasso-staging
  ```

- [ ] Create `rel/vm.args.eex` with distribution settings
  ```erl
  -kernel net_ticktime 60
  -kernel prevent_overlapping_partitions true
  -kernel dist_auto_connect once
  ```

- [ ] Fix node naming in `rel/env.sh.eex`
  ```bash
  # Replace FLY_IMAGE_REF with simpler pattern
  ip=$(grep fly-local-6pn /etc/hosts | cut -f 1)
  export RELEASE_NODE="${CLUSTER_NODE_BASENAME}@${ip}"
  ```

- [ ] Add ClusterMonitor to supervision tree (Section 5.2)

- [ ] Enhance health endpoint with cluster state (Section 5.1)

- [ ] Add cluster telemetry metrics (Section 5.2)

- [ ] Deploy to staging and verify `Node.list()` returns other nodes

### 7.2 Phase 1: Profile-Scoped Events (CRITICAL FOR SAAS)

- [ ] Add `profile` field to routing decision events
  ```elixir
  # In observability.ex:publish_routing_decision
  Phoenix.PubSub.broadcast(
    Lasso.PubSub,
    "routing:decisions:#{profile}",  # ← Scoped topic
    %{
      ts: System.system_time(:millisecond),
      profile: profile,  # ← Include in payload
      source_node: node(),
      source_region: System.get_env("CLUSTER_REGION", "unknown"),
      # ... rest
    }
  )
  ```

- [ ] Update dashboard subscription
  ```elixir
  # In dashboard.ex:subscribe_global_topics
  Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:decisions:#{profile}")
  ```

- [ ] Add `source_node` and `source_region` to all PubSub events

- [ ] Update dashboard event handlers to handle source metadata

### 7.3 Phase 2: Dashboard Aggregation (SPEC PHASE 3)

- [ ] Implement `ClusterMetrics` module (spec Section 5.5)

- [ ] Add `ClusterMetricsCache` with 15s TTL (spec Section 5.5)

- [ ] Add async RPC pattern to LiveView (spec Section 5.5)

- [ ] Add coverage indicators to all aggregate views (spec Section 5.1)

- [ ] Implement graceful degradation for partial node failures

### 7.4 Phase 3: Validation & Monitoring

- [ ] Add staging test plan (Section 8)

- [ ] Configure alerts for cluster health (Section 9)

- [ ] Document runbook for partition recovery (Section 10)

- [ ] Load test multi-node setup (Section 8.4)

---

## 8. Staging Test Plan

### 8.1 Cluster Formation Validation

**Objective**: Verify nodes discover each other and form cluster.

**Test Steps**:
1. Deploy to staging with 2 nodes minimum
2. SSH into first node: `fly ssh console -a lasso-staging`
3. Start IEx: `app/bin/lasso remote`
4. Check cluster: `Node.list()`
   - **Expected**: `[:"lasso-staging@fdaa:...", ...]` (1+ nodes)
   - **Failure**: `[]` → DNS issue or cookie mismatch

5. Check from health endpoint:
   ```bash
   curl https://lasso-staging.fly.dev/health | jq '.cluster'
   ```
   - **Expected**:
     ```json
     {
       "enabled": true,
       "nodes_connected": 1,
       "nodes_total": 2,
       "regions": ["sjc", "iad"]
     }
     ```

6. Check PubSub connection:
   ```elixir
   Phoenix.PubSub.node_name(Lasso.PubSub)
   # => :"lasso-staging@fdaa:..."
   ```

### 8.2 Event Propagation Test

**Objective**: Verify PubSub broadcasts reach all nodes.

**Test Steps**:
1. Connect to Node A via SSH
2. Subscribe to test topic:
   ```elixir
   Phoenix.PubSub.subscribe(Lasso.PubSub, "test:clustering")
   ```
3. From Node B (separate SSH session):
   ```elixir
   Phoenix.PubSub.broadcast(Lasso.PubSub, "test:clustering", {:hello, node()})
   ```
4. Verify Node A receives message:
   ```elixir
   flush()
   # => {:hello, :"lasso-staging@fdaa:..."}
   ```

### 8.3 Partition Simulation

**Objective**: Test behavior during network partition.

**Test Steps**:
1. Deploy 2-node cluster to staging
2. From Node A, forcibly disconnect Node B:
   ```elixir
   Node.disconnect(:"lasso-staging@fdaa:...")
   ```
3. Verify `:nodedown` event logged
4. Check health endpoint shows degraded state:
   ```json
   {"status": "degraded", "cluster": {"nodes_total": 1}}
   ```
5. Wait for libcluster to reconnect (~5s)
6. Verify Node B rejoins: `Node.list()`
7. Check logs for `"Node connected"` message

**Expected Behavior**:
- Dashboard shows "1/2 nodes" coverage warning
- RPC routing continues on each node independently
- No errors or crashes
- Auto-reconnect within 10 seconds

### 8.4 Load Test Multi-Node

**Objective**: Verify cluster stability under production load.

**Test Steps**:
1. Deploy 2-node staging cluster
2. Run load test script against both regions:
   ```bash
   # From scripts/rpc_load_test.mjs
   node scripts/rpc_load_test.mjs \
     --url https://lasso-staging.fly.dev/rpc \
     --rate 100 \
     --duration 300
   ```
3. Monitor metrics:
   - Node count stays at 2 (no spurious disconnects)
   - PubSub broadcast latency < 100ms p99
   - No `:nodedown` events during test
4. Check dashboard updates reflect both nodes' traffic
5. Verify no memory leaks (run for 1 hour)

---

## 9. Monitoring & Alerting Recommendations

### 9.1 Critical Alerts (Page Ops)

| Alert | Condition | Why Critical | Action |
|-------|-----------|--------------|--------|
| **Cluster Split** | `nodes_connected < expected_nodes - 1` for >2 min | Sustained partition indicates network issue | Check Fly.io status, investigate logs |
| **Zero Nodes Connected** | `nodes_connected == 0` for >1 min | Total cluster failure or config error | Check cookie, DNS, deploy logs |
| **Cookie Mismatch** | Log pattern: `authentication failed` | Nodes can't join cluster | Verify RELEASE_COOKIE secret |
| **Repeated Flaps** | >5 nodedown/nodeup cycles in 10 min | Network instability | Check Fly.io network, tune net_ticktime |

### 9.2 Warning Alerts (Investigate)

| Alert | Condition | Investigation |
|-------|-----------|---------------|
| **Degraded Cluster** | `nodes_connected < expected_nodes` for >5 min | Check which node is down, review Fly logs |
| **Slow PubSub** | PubSub broadcast p99 > 500ms | Cross-region latency spike, check Fly network |
| **RPC Timeout** | `:rpc.multicall` timeout rate > 1% | Overloaded node or network congestion |

### 9.3 Metrics to Track

**Infrastructure Metrics** (Fly.io + Prometheus):
- `lasso_cluster_node_count` (gauge)
- `lasso_cluster_node_connected_total` (counter)
- `lasso_cluster_node_disconnected_total` (counter)
- `phoenix_pubsub_broadcast_duration_microseconds` (histogram)
- `rpc_multicall_duration_milliseconds` (histogram)
- `rpc_multicall_bad_nodes` (gauge)

**Application Metrics** (Telemetry):
- Dashboard event buffer size
- LiveView socket count per node
- ETS table sizes (to detect memory leaks)

### 9.4 Logs to Watch

**Normal Operations**:
```
[info] Cluster monitor started on node lasso-rpc@fdaa:...
[info] Node connected: lasso-rpc@fdaa:... (region: iad)
```

**Warnings**:
```
[warning] Node disconnected: lasso-rpc@fdaa:...
[warning] Cluster metrics: unreachable nodes: [:"lasso-rpc@fdaa:..."]
```

**Errors** (require investigation):
```
[error] PubSub broadcast failed: {:nodedown, :"lasso-rpc@fdaa:..."}
[error] :rpc.multicall timeout: [:"lasso-rpc@fdaa:..."]
[error] ** Node authentication failed: {:"lasso-rpc@fdaa:...", :cookie_mismatch}
```

---

## 10. Operational Runbook

### 10.1 Node Not Joining Cluster

**Symptoms**: New deployment can't see existing nodes, `Node.list() == []`.

**Diagnosis**:
1. Check node name: `node()`
   - Should be: `:"lasso-rpc@fdaa:..."`
   - Invalid: `:"nonode@nohost"` (distribution not enabled)

2. Check DNS resolution:
   ```bash
   nslookup lasso-rpc.internal
   # Should return 2+ IPv6 addresses
   ```

3. Check cookie:
   ```elixir
   Node.get_cookie()
   # Should be same 32-char string on all nodes
   ```

4. Check libcluster logs:
   ```bash
   fly logs -a lasso-rpc | grep -i "cluster\|libcluster"
   ```

**Resolution**:
- Cookie mismatch: Re-set secret and redeploy all nodes
- DNS issue: Check CLUSTER_NODE_BASENAME env var
- Node naming: Fix `rel/env.sh.eex` and redeploy

### 10.2 Partition Recovery

**Symptoms**: Nodes were connected, now `Node.list()` returns fewer nodes.

**Automatic Recovery**: libcluster polls DNS every 5s and attempts reconnection.

**Manual Recovery** (if auto-recovery fails):
1. Check Fly.io status:
   ```bash
   fly status -a lasso-rpc
   # Verify all machines are "started"
   ```

2. Check logs for network errors:
   ```bash
   fly logs -a lasso-rpc | grep -i "nodedown\|timeout\|connection"
   ```

3. If persistent (>5 min), restart affected machine:
   ```bash
   fly machine restart <machine-id> -a lasso-rpc
   ```

4. Verify cluster reforms:
   ```bash
   curl https://lasso-rpc.fly.dev/health | jq '.cluster.nodes_total'
   ```

**Escalation**: If restart doesn't fix, check Fly.io status page for network incidents.

### 10.3 Rolling Deployment

**Best Practices**:
1. Deploy one region at a time:
   ```bash
   fly deploy --region sjc --strategy immediate
   # Wait for health check to pass
   fly deploy --region iad --strategy immediate
   ```

2. During deploy, expect temporary `(1/2 nodes)` state

3. Monitor cluster reformation:
   ```bash
   watch -n 5 'curl -s https://lasso-rpc.fly.dev/health | jq .cluster'
   ```

4. If new node doesn't join after 60s, rollback:
   ```bash
   fly deploy --image <previous-image>
   ```

### 10.4 Emergency: Total Cluster Failure

**Symptoms**: All nodes disconnected, dashboard shows `(0/0 nodes)`.

**Immediate Actions**:
1. Check Fly.io dashboard for machine health
2. Verify SECRET_KEY_BASE and RELEASE_COOKIE secrets exist
3. Check recent deployments for breaking changes
4. Review error logs:
   ```bash
   fly logs -a lasso-rpc --region sjc | tail -100
   ```

**Recovery**:
1. Rollback to last known-good deployment:
   ```bash
   fly releases -a lasso-rpc
   fly deploy --image <previous-version>
   ```

2. If rollback fails, restart all machines:
   ```bash
   fly machine list -a lasso-rpc
   fly machine restart <machine-id> --force
   ```

3. If still failing, check for infrastructure issues:
   - Fly.io status page
   - Database connectivity
   - DNS resolution

---

## 11. Spec Corrections & Additions

### 11.1 Spec Section 5.2 - Node Naming Correction

**Current Spec Recommendation** (line 569-577):
```bash
ip=$(grep fly-local-6pn /etc/hosts | cut -f 1)
export RELEASE_NODE="${CLUSTER_NODE_BASENAME}@${ip}"
```

**Issue**: Spec recommends `node_basename: app_name` in libcluster config, which expects nodes to have a common basename. The current `rel/env.sh.eex` uses `${FLY_IMAGE_REF##*-}` which changes on every deploy.

**Correction**: Use the simpler pattern consistently:
```bash
ip=$(grep fly-local-6pn /etc/hosts | cut -f 1)
if [ -z "$ip" ]; then
  echo "ERROR: Could not determine Fly.io 6PN IP"
  exit 1
fi
export RELEASE_NODE="${CLUSTER_NODE_BASENAME}@${ip}"
```

**Rationale**: This creates stable node names like `lasso-rpc@fdaa:0:1da:a7b::3` that survive deploys and work correctly with libcluster's DNS polling.

### 11.2 Spec Section 5.2 - Add vm.args.eex

**Gap**: Spec mentions network tuning (line 592-598) but doesn't provide complete `vm.args.eex` file.

**Addition**: Create `rel/vm.args.eex` with:
```erl
## Erlang Distribution Configuration
-kernel net_ticktime 60
-kernel prevent_overlapping_partitions true
-kernel dist_auto_connect once

## Set cookie from environment (RELEASE_COOKIE)
## Note: This is handled automatically by Mix releases if RELEASE_COOKIE is set
```

**Location**: `/Users/jacksonernst/Documents/GitHub/lasso-cloud/rel/vm.args.eex`

### 11.3 Spec Section 4.1 - Rolling Deploy Migration Simplification

**Current Spec** (lines 354-367): Recommends dual-write migration strategy for profile-scoped events.

**Operational Simplification**: For Fly.io with blue-green deploys, use immediate strategy:

1. **Single PR**: Change both publisher and subscriber in same commit
2. **Deploy**: Use `fly deploy --strategy immediate` (all machines update at once)
3. **Verify**: Check health endpoint shows all nodes connected

**Why Simpler**:
- Fly's immediate strategy = full restart (all nodes on new code)
- No mixed-version period to handle
- No cleanup phase needed

**Trade-off**: ~30s downtime during deploy (acceptable for staging/small deployments).

**Keep Dual-Write Approach If**:
- Production requires zero-downtime deploys
- High traffic can't tolerate restart
- Multi-tenant SaaS with strict SLAs

### 11.4 Spec Section 5.5 - Critical RPC Bug

**Spec Code** (lines 786-790):
```elixir
# CRITICAL: Filter out {:badrpc, reason} tuples from failed nodes
|> Enum.reject(&match?({:badrpc, _}, &1))
```

**Issue**: This is correct, but spec doesn't explain **why** this is critical.

**Explanation to Add**:
> `:rpc.multicall` returns `{results, bad_nodes}` where `results` is a list that **includes** `{:badrpc, reason}` tuples for failed calls. You MUST filter these out before processing, or they will:
> - Crash pattern matches expecting maps/lists
> - Pollute aggregation calculations
> - Cause `FunctionClauseError` in downstream functions
>
> Example failure without filtering:
> ```elixir
> results = [%{provider_id: "alchemy"}, {:badrpc, :timeout}]
> Enum.group_by(results, & &1.provider_id)  # CRASH: no provider_id on tuple
> ```

### 11.5 New Section: Cookie Rotation Procedure

**Missing from Spec**: How to rotate RELEASE_COOKIE without downtime.

**Add to Appendices**:

**Cookie Rotation Procedure**:

Erlang distribution requires all nodes to share the same cookie. Rotating it requires coordination:

1. **Generate new cookie**:
   ```bash
   NEW_COOKIE=$(openssl rand -base64 32)
   ```

2. **Set as secondary secret** (if supported by release config):
   ```bash
   fly secrets set RELEASE_COOKIE_OLD="<current-cookie>" -a lasso-rpc
   fly secrets set RELEASE_COOKIE="$NEW_COOKIE" -a lasso-rpc
   ```

3. **Deploy with dual-cookie support** (requires custom `rel/env.sh.eex`):
   ```bash
   # Not standard Elixir release feature - requires custom net_kernel setup
   ```

4. **Simpler approach**: Accept downtime:
   ```bash
   # Stop all machines
   fly scale count 0 -a lasso-rpc

   # Update secret
   fly secrets set RELEASE_COOKIE="$NEW_COOKIE" -a lasso-rpc

   # Restart
   fly scale count 2 -a lasso-rpc
   ```

**Recommendation**: Rotate cookie annually or after suspected compromise. Schedule maintenance window.

---

## 12. Key Takeaways & Risk Summary

### 12.1 Critical Path to Production

**Must Have** (blocking for multi-node):
1. ✅ Install and configure libcluster
2. ✅ Set RELEASE_COOKIE secret
3. ✅ Add cluster health monitoring
4. ✅ Implement profile-scoped events (SaaS security)

**Should Have** (for operational safety):
5. ⚠️ Add ClusterMonitor telemetry
6. ⚠️ Create vm.args.eex with tuning params
7. ⚠️ Implement dashboard coverage indicators
8. ⚠️ Test partition scenarios in staging

**Nice to Have** (can defer to v2):
9. 🔵 Advanced partition detection
10. 🔵 Per-region dashboard filtering
11. 🔵 Distributed tracing across nodes

### 12.2 Operational Confidence Assessment

| Area | Confidence | Gaps |
|------|------------|------|
| **Node Discovery** | 🔴 None | libcluster not installed |
| **Security** | 🔴 None | No cookie configured |
| **Health Monitoring** | 🟡 Partial | Basic endpoint exists, needs cluster state |
| **Event Distribution** | 🟢 High | PubSub ready, needs profile scoping |
| **Partition Handling** | 🟡 Partial | Erlang built-ins ok, needs app-level observability |
| **Dashboard Aggregation** | 🟡 Partial | Code structure supports it, needs implementation |

**Overall Readiness**: 🔴 **Not Ready** - Critical gaps must be addressed before multi-node deploy.

### 12.3 Timeline Estimate

| Phase | Duration | Dependencies | Can Parallelize? |
|-------|----------|--------------|------------------|
| **0: Cluster Foundation** | 1-2 days | None | No (blocking) |
| **1: Profile Scoping** | 1 day | Phase 0 | No (SaaS critical) |
| **2: Dashboard Aggregation** | 2-3 days | Phase 0, 1 | Partially (spec work) |
| **3: Testing & Validation** | 1-2 days | Phase 0, 1 | Yes (can test early) |
| **Total** | **5-8 days** | | |

**Fast Track** (accepting some technical debt): 3-4 days by:
- Skipping vm.args.eex initially (use defaults)
- Deferring full telemetry (add after validation)
- Using immediate deploy strategy (skip dual-write complexity)

### 12.4 Post-Deployment Monitoring Plan

**Week 1**:
- Monitor cluster node count every 5 minutes
- Alert on any `:nodedown` events
- Check PubSub broadcast latency p99
- Verify dashboard shows correct node counts

**Week 2-4**:
- Measure partition frequency (target: <1/week)
- Tune net_ticktime if spurious disconnects occur
- Validate cross-region RPC latency
- Check for memory leaks from distributed PubSub

**Ongoing**:
- Quarterly cookie rotation
- Monthly libcluster version updates
- Annual review of clustering strategy

---

## 13. References & Further Reading

### 13.1 Fly.io Documentation

- [BEAM Clustering made easy · The Phoenix Files](https://fly.io/phoenix-files/beam-clustering-made-easy/)
- [Clustering Your Application · Fly Docs](https://fly.io/docs/elixir/the-basics/clustering/)
- [Private Networking · Fly Docs](https://fly.io/docs/reference/private-networking/)
- [Incoming! 6PN Private Networks · The Fly Blog](https://fly.io/blog/incoming-6pn-private-networks/)

### 13.2 Erlang Distribution

- [Distributed Erlang — Erlang System Documentation](https://www.erlang.org/doc/system/distributed.html)
- [net_kernel — kernel v10.5](https://www.erlang.org/doc/apps/kernel/net_kernel.html)
- [Net Tick Time (Inter-node Communication Heartbeats) | RabbitMQ](https://www.rabbitmq.com/nettick.html)

### 13.3 libcluster

- [Cluster.Strategy.DNSPoll — libcluster v3.5.0](https://hexdocs.pm/libcluster/Cluster.Strategy.DNSPoll.html)
- [libcluster/lib/strategy/dns_poll.ex at master · bitwalker/libcluster](https://github.com/bitwalker/libcluster/blob/master/lib/strategy/dns_poll.ex)

### 13.4 Phoenix.PubSub

- [Phoenix.PubSub — Phoenix.PubSub v2.2.0](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html)
- [Does Phoenix PubSub respect order of messages](https://elixirforum.com/t/does-phoenix-pubsub-respect-the-order-of-messages-received/30789)
- [Using Phoenix.PubSub as a message-bus for Elixir cluster - DEV Community](https://dev.to/manhvanvu/simple-using-phoenixpubsub-as-a-message-bus-for-elixir-cluster-l3c)

---

## 14. Appendix: Quick Start Checklist

For operators who want to "just make it work", follow this abbreviated checklist:

```bash
# 1. Add libcluster to mix.exs
# Add {:libcluster, "~> 3.3"} to deps

# 2. Configure runtime.exs
# (See Section 7.1 for full config)

# 3. Set cookie
fly secrets set RELEASE_COOKIE="$(openssl rand -base64 32)" -a lasso-rpc

# 4. Create rel/vm.args.eex
# (See Section 11.2 for content)

# 5. Fix node naming in rel/env.sh.eex
# Change to: export RELEASE_NODE="${CLUSTER_NODE_BASENAME}@${ip}"

# 6. Deploy
fly deploy -a lasso-rpc

# 7. Verify
fly ssh console -a lasso-rpc -C "app/bin/lasso remote -e 'Node.list()'"
# Should show other nodes

# 8. Check health
curl https://lasso-rpc.fly.dev/health | jq .cluster
# Should show nodes_total: 2
```

**If it doesn't work**: See Section 10.1 for troubleshooting.

---

**Document Version**: 1.0
**Last Updated**: 2026-01-22
**Next Review**: After Phase 0 implementation
**Owned By**: Engineering + Operations
