# Clustering Implementation Status

**Version**: 2.0
**Last Updated**: January 2026
**Architecture**: [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md)

---

## Overview

This document tracks the implementation status of clustering for both OSS (lasso-rpc) and Cloud (lasso-cloud) repositories. The OSS phases are complete; Cloud phases are documented for implementation after copying these docs to the cloud repo.

### Repository Relationship

```
lasso-rpc (OSS)                    lasso-cloud (Proprietary)
─────────────────                  ──────────────────────────
Phases 1-5: ✅ Complete      ───►  Inherits all OSS work
Profile-scoped clustering          + Phases 6-7 (Cloud-only)
No account concepts                + Account/billing integration
Self-hosted operators              + Multi-tenant isolation
```

**Workflow**: Once OSS clustering is stable, copy `docs/internal/clustering/` to lasso-cloud and continue with Cloud phases.

---

## OSS Phases (lasso-rpc) - ✅ COMPLETE

### Architecture Summary

| Module | Status | Purpose |
|--------|--------|---------|
| `Lasso.Cluster.Topology` | ✅ Implemented | Single source of truth for cluster membership |
| `LassoWeb.Dashboard.EventStream` | ✅ Implemented | Batched event streaming to LiveViews |
| `LassoWeb.Dashboard.MetricsStore` | ✅ Implemented | RPC-based metrics caching |

### Modules Removed (Consolidated into V2)

| Old Module | Replacement |
|------------|-------------|
| `Lasso.ClusterMonitor` | `Lasso.Cluster.Topology` |
| `LassoWeb.Dashboard.ClusterEventAggregator` | `LassoWeb.Dashboard.EventStream` |
| `LassoWeb.Dashboard.ClusterMetricsCache` | `LassoWeb.Dashboard.MetricsStore` |
| `LassoWeb.Dashboard.EventBuffer` | `LassoWeb.Dashboard.EventStream` |
| `LassoWeb.Dashboard.EventDedup` | `LassoWeb.Dashboard.EventStream` |

### Phase 1: Core Infrastructure ✅

- [x] libcluster dependency and configuration
- [x] Erlang cookie configuration
- [x] Node naming in releases
- [x] VM args configuration

### Phase 2: Topology Module ✅

- [x] `Lasso.Cluster.Topology` GenServer
- [x] Node state machine (connected → discovering → responding → ready)
- [x] Async region discovery via Task.Supervisor
- [x] Periodic health checks via RPC multicall
- [x] PubSub broadcast on topology changes

### Phase 3: EventStream Module ✅

- [x] `LassoWeb.Dashboard.EventStream` GenServer
- [x] Subscribe to `cluster:topology` for node changes
- [x] Subscribe to `routing:decisions:{profile}`
- [x] Batched event delivery (500ms intervals)
- [x] Event deduplication by request_id
- [x] Rate limiting per subscriber

### Phase 4: MetricsStore Module ✅

- [x] `LassoWeb.Dashboard.MetricsStore` GenServer
- [x] RPC-based historical metrics aggregation
- [x] Stale-while-revalidate caching pattern
- [x] Uses Topology for node list (no direct Node.list())
- [x] Subscribes to topology for cache invalidation

### Phase 5: Dashboard Integration ✅

- [x] Dashboard subscribes only to EventStream
- [x] Removed direct PubSub subscriptions for routing events
- [x] Handle batched events and metrics updates
- [x] Coverage indicators using Topology data

---

## Cloud Phases (lasso-cloud) - ⏳ PENDING

> **Note for AI Agent**: These phases should be implemented in the lasso-cloud repository after the OSS clustering docs have been copied over. The OSS work provides the foundation; Cloud phases add multi-tenant isolation.

### Prerequisites

Before starting Cloud phases, verify OSS completeness:

```bash
# In lasso-rpc repo - should return NO results
grep -r "account_id\|api_key_id\|current_account" lib/ --include="*.ex" | grep -v "_test.ex"
```

**OSS Completeness Criteria:**
- [x] Self-hosted operator can deploy multi-node cluster
- [x] Dashboard shows merged activity feed from all nodes
- [x] Dashboard shows aggregated metrics with coverage indicators
- [x] Profile-scoped event isolation works
- [x] Event sampling reduces load under high traffic
- [x] Zero references to account_id in OSS code paths

### Phase 6: Account Attribution (Cloud) ⏳

**Purpose**: Add multi-tenant isolation so Cloud users only see their own traffic.

- [ ] **Add account_id to Cloud's RequestOptions**
  - File: `lib/lasso/core/request/request_options.ex` (Cloud fork)
  - Add fields: `account_id: nil`, `api_key_id: nil`
  - These fields exist ONLY in Cloud fork, not in OSS

- [ ] **Thread account_id from auth plug**
  - File: `lib/lasso_cloud/rpc/request_options_builder.ex`
  - Extract from `conn.assigns[:current_account][:id]`
  - Pass through RequestOptions → RequestContext

- [ ] **Create Cloud event publishing wrapper**
  - File: `lib/lasso_cloud/observability/account_events.ex` (create new)
  - Wraps OSS event publishing
  - Adds account-scoped topic publication

  ```elixir
  defmodule LassoCloud.Observability.AccountEvents do
    @moduledoc "Enriches OSS events with account attribution for Cloud."

    def publish_with_account(event, account_id) do
      # Call OSS publisher (profile-scoped)
      Lasso.Observability.publish_routing_decision(event)

      # Cloud addition: also publish to account topic
      enriched = Map.put(event, :account_id, account_id)
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "routing:decisions:#{event.profile}:account:#{account_id}",
        enriched
      )
    end
  end
  ```

- [ ] **Replace EventSubscription with account-aware version**
  - File: `lib/lasso_web/dashboard/event_subscription.ex` (replace OSS version)
  - Default to account-scoped topics
  - Add admin toggle for profile-scoped view

  ```elixir
  defmodule LassoWeb.Dashboard.EventSubscription do
    @moduledoc "Account-aware event subscription for Cloud."

    def subscribe(socket, profile) do
      if show_all_events?(socket) do
        "routing:decisions:#{profile}"
      else
        account_id = socket.assigns.current_account.id
        "routing:decisions:#{profile}:account:#{account_id}"
      end
    end

    defp show_all_events?(socket) do
      socket.assigns[:show_all_events] == true and
        is_admin?(socket.assigns[:current_account])
    end
  end
  ```

**Exit Criteria:**
- [ ] Account-scoped events publish to `routing:decisions:{profile}:account:{account_id}`
- [ ] Profile-scoped events still publish to `routing:decisions:{profile}` (for operators)
- [ ] Dashboard defaults to account-scoped subscription
- [ ] Cloud users only see their own account's events
- [ ] OSS event structs unchanged - account_id added only at publish time

### Phase 7: Multi-Tenant Dashboard UX (Cloud) ⏳

**Purpose**: Provide appropriate default views for Cloud users vs operators.

- [ ] **Implement "My App" default view**
  - Default view for logged-in Cloud users
  - Shows only account's requests in activity feed
  - Account-scoped metrics (my RPS, my success rate)

- [ ] **Implement "Profile Benchmark" toggle**
  - Admin-only toggle to see profile-wide data
  - Label clearly as "Shared profile benchmark"
  - Shows aggregate metrics across all accounts using profile

- [ ] **Add toggle UI in dashboard**
  - File: `lib/lasso_web/live/dashboard/dashboard.ex` (Cloud fork)
  - Add "My App" / "Profile Benchmark" toggle
  - Persist preference (URL param or session)

- [ ] **Update dashboard to handle view switching**
  - Resubscribe to appropriate topics on toggle
  - Clear and reload events on switch
  - Show appropriate metrics based on view

- [ ] **Implement per-profile sample rates**
  - File: `config/runtime.exs` (Cloud)
  - Allow different sample rates per profile
  - Higher rates for BYOK (low traffic), lower for shared free (high traffic)

- [ ] **Handle BYOK profile UX**
  - BYOK profiles: "My App" = "Profile Benchmark" (same data)
  - Hide toggle for BYOK profiles (no distinction needed)

**Exit Criteria:**
- [ ] Logged-in users see "My App" view by default
- [ ] Admin toggle switches to "Profile Benchmark" view
- [ ] View switch resubscribes to correct topics
- [ ] BYOK users don't see confusing toggle
- [ ] Per-profile sample rates configurable

---

## Cloud Extension Patterns

### How Cloud Extends OSS

Cloud extends OSS through **replacement and enrichment**, not modification:

| Component | Strategy | Notes |
|-----------|----------|-------|
| `event_subscription.ex` | **Replace** | Different subscription logic |
| `observability.ex` | **Wrap** | Add account topic, call OSS for profile topic |
| `request_options.ex` | **Extend** | Add account_id field in Cloud fork |
| `dashboard.ex` | **Extend** | Add "My App" / "Profile Benchmark" toggle |
| Event structs | **Use as-is** | Add account_id at publish time, not in struct |

### Topic Hierarchy

```
Profile-Scoped Topics (OSS + Cloud operator view):
├── routing:decisions:{profile}
├── circuit:events:{profile}:{chain}
├── provider_pool:events:{profile}:{chain}
└── block_sync:{profile}:{chain}

Account-Scoped Topics (Cloud default UX):
└── routing:decisions:{profile}:account:{account_id}
```

### Automatic Scoping Model (Cloud)

Cloud dashboards apply **automatic scoping** based on metric type:

| Metric Type | Scope | Example |
|-------------|-------|---------|
| Activity/traffic metrics | Account-scoped | Activity feed, RPS, success rate |
| Infrastructure health | Profile-scoped | Provider topology, circuit breakers |

---

## Configuration

### OSS Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `CLUSTER_DNS_QUERY` | For clustering | DNS query for node discovery |
| `CLUSTER_NODE_BASENAME` | For clustering | Node basename (must match across nodes) |
| `CLUSTER_NODE_IP` | For clustering | This node's cluster-reachable IP |
| `CLUSTER_REGION` | Optional | Region identifier for metrics |
| `RELEASE_COOKIE` | For clustering | Shared Erlang cookie |
| `EXPECTED_NODE_COUNT` | Optional | Expected cluster size (default: 1) |

### Cloud-Specific Configuration (Phase 7)

```elixir
# config/runtime.exs (Cloud)
config :lasso, :event_sampling,
  # Per-profile sample rates
  profiles: %{
    "free" => 0.01,      # 1% - high traffic shared profile
    "premium" => 0.05,   # 5% - medium traffic
    "byok" => 0.20       # 20% - low traffic, private
  },
  default: 0.05
```

---

## Testing

### OSS Tests

- [ ] Topology state machine transitions
- [ ] EventStream batching and deduplication
- [ ] MetricsStore caching and aggregation
- [ ] Integration tests with LocalCluster

### Cloud Tests (Phase 6-7)

- [ ] Account-scoped event publishing
- [ ] EventSubscription topic selection
- [ ] "My App" / "Profile Benchmark" toggle
- [ ] Per-profile sample rate application
- [ ] No cross-account data leakage

---

## Related Documents

- [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md) - Authoritative OSS architecture
- [REALTIME_METRICS_ARCHITECTURE_V2.md](./REALTIME_METRICS_ARCHITECTURE_V2.md) - Real-time metrics design
- [CLUSTERING_OPERATIONS_GUIDE.md](./CLUSTERING_OPERATIONS_GUIDE.md) - Operational runbooks
- [CLUSTERING_TEST_GUIDE.md](./CLUSTERING_TEST_GUIDE.md) - Testing procedures
- [PUBSUB_EVENTS.md](./PUBSUB_EVENTS.md) - Event schemas and topics
- [CLUSTERING_SPEC_V1.md](./CLUSTERING_SPEC_V1.md) - Historical reference (contains additional Cloud context)
