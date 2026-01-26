# Cloud Clustering: Account-Scoped Multi-Tenancy

**Version**: 1.0
**Last Updated**: January 2026
**Repository**: lasso-cloud
**Depends On**: [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md) (OSS foundation)

---

## Overview

This document specifies the Cloud-specific clustering work that adds multi-tenant isolation on top of the OSS clustering foundation. The OSS work (Phases 1-5) provides profile-scoped clustering; this document covers account-scoped isolation (Phases 6-7).

### Prerequisites

Before implementing Cloud phases, ensure:
1. OSS clustering is stable and merged to lasso-rpc main
2. lasso-cloud has synced with latest lasso-rpc
3. OSS clustering docs copied to lasso-cloud

### Problem Statement

In a multi-tenant Cloud deployment:
- Multiple accounts use the same shared profile (e.g., "free", "premium")
- OSS clustering broadcasts events to profile-scoped topics
- **Gap**: All accounts on a profile see each other's events (privacy/security issue)

### Solution

Add account-scoped topics for activity/traffic events while keeping profile-scoped topics for infrastructure health.

```
OSS Topics (Profile-Scoped):                Cloud Addition (Account-Scoped):
├── routing:decisions:{profile}        →    routing:decisions:{profile}:account:{account_id}
├── circuit:events:{profile}:{chain}        (stays profile-scoped - shared infrastructure)
├── provider_pool:events:{profile}:{chain}  (stays profile-scoped - shared infrastructure)
└── block_sync:{profile}:{chain}            (stays profile-scoped - shared infrastructure)
```

---

## Current lasso-cloud Architecture

### Account Threading (Already Exists ✅)

Account ID flows through the request lifecycle:

```
HTTP Request → APIKeyAuthPlug → conn.assigns[:current_account] → RequestContext
WebSocket    → RPCSocket.connect → socket.state.account_id → SubscriptionRouter
```

**Key Files:**
- `lib/lasso_cloud/auth/plugs/api_key_auth_plug.ex` - Validates API key, sets account_id
- `lib/lasso_web/sockets/rpc_socket.ex:88` - Stores account_id in socket state
- `lib/lasso/core/request/request_pipeline.ex` - Creates RequestContext with account_id

### Rate Limiting & CU Metering (Already Account-Aware ✅)

- Rate limit key: `"account:{account_id}:profile:{profile_slug}"`
- CU accumulator: Records by subscription_id (tied to account)
- No changes needed for clustering

### Dashboard (Needs Account-Scoped Topics)

**Current** (`lib/lasso_web/dashboard/dashboard.ex`):
```elixir
# Line 125-128 - subscribes to profile-scoped topics
Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{profile}:#{chain}")
```

**Problem**: All accounts on a profile receive all events.

### Event Publishing (Needs Account Enrichment)

**Current** (`lib/lasso/core/events/provider.ex:22`):
```elixir
def topic(chain), do: "provider_pool:events:#{chain}"
```

**Problem**: Events published without account context.

---

## Phase 6: Account Attribution

### 6.1 Add Account-Scoped Event Publishing

**File**: `lib/lasso_cloud/observability/account_events.ex` (create new)

```elixir
defmodule LassoCloud.Observability.AccountEvents do
  @moduledoc """
  Enriches OSS events with account attribution for Cloud multi-tenancy.

  Publishes to both:
  - Profile-scoped topic (for operators/infrastructure visibility)
  - Account-scoped topic (for user's own traffic)
  """

  alias Lasso.Events.RoutingDecision

  @doc """
  Publish a routing decision with account scoping.

  Called from the request pipeline after RPC execution completes.
  """
  def publish_routing_decision(%RoutingDecision{} = event, account_id) when is_binary(account_id) do
    profile = event.profile

    # OSS behavior: profile-scoped topic (for operators)
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      RoutingDecision.topic(profile),
      event
    )

    # Cloud addition: account-scoped topic (for user's dashboard)
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      account_topic(profile, account_id),
      event
    )
  end

  def publish_routing_decision(%RoutingDecision{} = event, nil) do
    # No account context (internal/system request) - profile-scoped only
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      RoutingDecision.topic(event.profile),
      event
    )
  end

  @doc "Account-scoped topic for routing decisions."
  def account_topic(profile, account_id) do
    "routing:decisions:#{profile}:account:#{account_id}"
  end
end
```

### 6.2 Thread Account ID to Event Publishing

**File**: `lib/lasso/core/request/request_pipeline/observability.ex`

The RequestContext already has account_id. Ensure it's passed to event publishing:

```elixir
# In the observability module that publishes RoutingDecision events
def publish_request_complete(context, result, duration_ms) do
  event = %RoutingDecision{
    profile: context.profile,
    chain: context.chain,
    method: context.method,
    provider_id: context.provider_id,
    result: result,
    duration_ms: duration_ms,
    # ... other fields
  }

  # Cloud: use account-aware publishing
  LassoCloud.Observability.AccountEvents.publish_routing_decision(
    event,
    context.account_id
  )
end
```

### 6.3 Update Dashboard Event Subscription

**File**: `lib/lasso_web/dashboard/event_subscription.ex` (replace OSS version)

```elixir
defmodule LassoWeb.Dashboard.EventSubscription do
  @moduledoc """
  Account-aware event subscription for Cloud dashboard.

  Default: Account-scoped topics (user sees only their traffic)
  Admin toggle: Profile-scoped topics (operator sees all traffic)
  """

  alias LassoCloud.Observability.AccountEvents

  @doc """
  Subscribe to routing events for the given profile.

  Returns the topic name for later unsubscription.
  """
  def subscribe_routing_events(socket, profile) do
    topic = routing_topic(socket, profile)
    Phoenix.PubSub.subscribe(Lasso.PubSub, topic)
    topic
  end

  def unsubscribe_routing_events(topic) do
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, topic)
  end

  @doc """
  Determine the appropriate routing topic based on view mode.
  """
  def routing_topic(socket, profile) do
    if show_all_events?(socket) do
      # Operator view: profile-scoped (all traffic)
      Lasso.Events.RoutingDecision.topic(profile)
    else
      # User view: account-scoped (own traffic only)
      account_id = socket.assigns.current_account.id
      AccountEvents.account_topic(profile, account_id)
    end
  end

  defp show_all_events?(socket) do
    socket.assigns[:show_all_events] == true and
      is_operator?(socket.assigns[:current_account])
  end

  defp is_operator?(account) do
    # Define operator criteria (e.g., admin role, specific account IDs)
    Map.get(account, :is_operator, false)
  end
end
```

### 6.4 Update Dashboard Mount

**File**: `lib/lasso_web/dashboard/dashboard.ex`

```elixir
def mount(params, session, socket) do
  # ... existing setup ...

  if connected?(socket) do
    profile = socket.assigns.selected_profile

    # Subscribe to EventStream (OSS clustering - batched events)
    LassoWeb.Dashboard.EventStream.subscribe(profile)

    # Subscribe to account-scoped routing events (Cloud addition)
    topic = EventSubscription.subscribe_routing_events(socket, profile)
    socket = assign(socket, :routing_topic, topic)

    # ... rest of mount ...
  end
end

def handle_event("toggle_view_mode", _params, socket) do
  # Resubscribe when toggling between "My App" and "Profile Benchmark"
  old_topic = socket.assigns.routing_topic
  EventSubscription.unsubscribe_routing_events(old_topic)

  socket = update(socket, :show_all_events, &(!&1))

  new_topic = EventSubscription.subscribe_routing_events(socket, socket.assigns.selected_profile)
  socket = assign(socket, :routing_topic, new_topic)

  # Clear events and reload
  socket = assign(socket, :routing_events, [])

  {:noreply, socket}
end
```

### 6.5 Exit Criteria

- [ ] `LassoCloud.Observability.AccountEvents` module created
- [ ] Request pipeline publishes to both profile and account topics
- [ ] Dashboard subscribes to account-scoped topic by default
- [ ] Events only appear for the logged-in account
- [ ] Operators can toggle to profile-scoped view
- [ ] No cross-account data leakage (test with 2 accounts on same profile)

---

## Phase 7: Multi-Tenant Dashboard UX

### 7.1 View Mode Toggle UI

**File**: `lib/lasso_web/dashboard/dashboard.ex`

Add toggle in dashboard header (only for operators):

```elixir
def render(assigns) do
  ~H"""
  <div class="dashboard-header">
    <!-- Existing header content -->

    <%= if is_operator?(@current_account) do %>
      <div class="view-mode-toggle">
        <button
          phx-click="toggle_view_mode"
          class={if @show_all_events, do: "active", else: ""}
        >
          <%= if @show_all_events do %>
            📊 Profile Benchmark
          <% else %>
            🏠 My App
          <% end %>
        </button>
      </div>
    <% end %>
  </div>
  """
end
```

### 7.2 Activity Feed Scoping

Activity feed should reflect the current view mode:

| View Mode | Activity Feed Shows | Metrics Show |
|-----------|---------------------|--------------|
| My App (default) | Only this account's requests | Account's RPS, success rate |
| Profile Benchmark | All requests on profile | Aggregate RPS, success rate |

### 7.3 BYOK Profile Handling

For BYOK (Bring Your Own Key) profiles where profile = account:

```elixir
defp is_byok_profile?(socket) do
  profile = socket.assigns.selected_profile
  account_id = socket.assigns.current_account.id

  # BYOK profiles are named after account or have dedicated flag
  Lasso.Config.ConfigStore.get_profile(profile)
  |> Map.get(:is_byok, false)
end

# In mount - hide toggle for BYOK
def mount(params, session, socket) do
  # ...
  socket = assign(socket, :hide_view_toggle, is_byok_profile?(socket))
  # ...
end
```

### 7.4 Per-Profile Sample Rates

**File**: `config/runtime.exs`

```elixir
config :lasso, :event_sampling,
  profiles: %{
    "free" => 0.01,      # 1% - high traffic shared profile
    "premium" => 0.05,   # 5% - medium traffic
    # BYOK profiles use default
  },
  default: 0.10  # 10% for custom/BYOK profiles
```

**File**: `lib/lasso/observability/event_sampler.ex`

```elixir
defmodule Lasso.Observability.EventSampler do
  @moduledoc "Profile-aware event sampling for dashboard."

  def should_sample?(profile, result) do
    # Always sample errors and failovers
    if result == :error, do: true, else: sample_success?(profile)
  end

  defp sample_success?(profile) do
    rate = get_sample_rate(profile)
    :rand.uniform() < rate
  end

  defp get_sample_rate(profile) do
    profiles = Application.get_env(:lasso, :event_sampling, [])[:profiles] || %{}
    default = Application.get_env(:lasso, :event_sampling, [])[:default] || 0.05
    Map.get(profiles, profile, default)
  end
end
```

### 7.5 Exit Criteria

- [ ] View toggle appears for operators only
- [ ] Toggle switches between "My App" and "Profile Benchmark"
- [ ] Activity feed reflects current view mode
- [ ] BYOK profiles don't show toggle (not needed)
- [ ] Per-profile sample rates configurable
- [ ] Sample rates load from config at runtime

---

## Topic Hierarchy (Complete)

```
Profile-Scoped Topics (OSS + Cloud operator view):
├── routing:decisions:{profile}                    # All routing events
├── circuit:events:{profile}:{chain}               # Circuit breaker transitions
├── provider_pool:events:{profile}:{chain}         # Provider health
├── block_sync:{profile}:{chain}                   # Block height updates
└── cluster:topology                               # Cluster membership

Account-Scoped Topics (Cloud user view):
└── routing:decisions:{profile}:account:{account_id}  # User's own traffic
```

**Scoping Rules:**

| Event Type | Topic Scope | Rationale |
|------------|-------------|-----------|
| Routing decisions | Account | User's own traffic |
| Circuit breakers | Profile | Shared infrastructure health |
| Provider health | Profile | Shared infrastructure health |
| Block sync | Profile | Shared infrastructure state |
| Cluster topology | Global | Operator-only |

---

## Testing Checklist

### Account Isolation Tests

```elixir
describe "account-scoped events" do
  test "account A only receives own events" do
    # Setup: Two accounts on same profile
    account_a = create_account()
    account_b = create_account()
    profile = "free"

    # Subscribe account A's dashboard
    {:ok, socket_a} = connect_dashboard(account_a, profile)

    # Publish event for account B
    event = %RoutingDecision{profile: profile, ...}
    AccountEvents.publish_routing_decision(event, account_b.id)

    # Assert: Account A doesn't receive it
    refute_receive {:routing_decision, _}, 100
  end

  test "operators see all events when toggled" do
    operator = create_operator_account()
    profile = "free"

    {:ok, socket} = connect_dashboard(operator, profile, show_all_events: true)

    # Publish events for various accounts
    Enum.each(1..5, fn i ->
      event = %RoutingDecision{profile: profile, ...}
      AccountEvents.publish_routing_decision(event, "account_#{i}")
    end)

    # Assert: Operator receives all
    assert_receive {:routing_decision, _}, 100
    # ... receive all 5
  end
end
```

### Cross-Cluster Tests

```elixir
test "events propagate across nodes with account isolation" do
  {:ok, [node1, node2]} = LocalCluster.start_nodes("lasso", 2)

  # Account subscribes on node1
  :rpc.call(node1, Dashboard, :subscribe, [account_a, "free"])

  # Event published on node2 for account_a
  :rpc.call(node2, AccountEvents, :publish_routing_decision, [event, account_a.id])

  # Assert: Received on node1
  assert_receive {:routing_decision, ^event}, 500
end
```

---

## Migration Path

### Step 1: Deploy Account Events Module
- Add `LassoCloud.Observability.AccountEvents`
- No behavior change yet (not called)

### Step 2: Wire Up Publishing
- Update request pipeline to use AccountEvents
- Events now publish to both topics

### Step 3: Update Dashboard Subscription
- Replace EventSubscription with account-aware version
- Default to account-scoped
- Add operator toggle

### Step 4: Add Sample Rate Config
- Add per-profile sample rates
- Monitor event volumes

---

## Related Documents

- [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md) - OSS foundation
- [IMPLEMENTATION_CHECKLIST.md](./IMPLEMENTATION_CHECKLIST.md) - Phase tracking
- [PUBSUB_EVENTS.md](./PUBSUB_EVENTS.md) - Event schemas
