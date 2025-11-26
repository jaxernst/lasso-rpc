# Upstream Subscription Management Architecture

## Overview

This document describes the architecture for managing upstream WebSocket subscriptions in Lasso RPC. The system uses a centralized Manager that owns all upstream subscriptions and multiplexes events to multiple consumers via a Registry.

## Problem Statement

Previously, multiple components (BlockHeightMonitor, UpstreamSubscriptionPool) created their own upstream WebSocket subscriptions, leading to:

1. **Duplicate subscriptions** - Same `{provider_id, subscription_key}` subscribed multiple times
2. **Warning spam** - "No key found for subscription event" when events arrived for subscriptions owned by other components
3. **Resource waste** - Multiple upstream connections for the same data
4. **Complex lifecycle management** - Each component managed its own subscription state

## Solution Architecture

### Component Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                         Per-Chain Components                            │
└────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                    UpstreamSubscriptionRegistry                          │
│                    (Global - started by Application)                     │
│                                                                          │
│  Registry with :duplicate keys for tracking consumers per subscription   │
│  Key: {chain, provider_id, sub_key}                                     │
│  Automatic cleanup on consumer process death                             │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                        Used by Manager for dispatch
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    UpstreamSubscriptionManager                           │
│                    (Per-chain GenServer)                                 │
│                                                                          │
│  - Owns all upstream subscriptions for the chain                        │
│  - Subscribes to PubSub "ws:subs:{chain}" for subscription events       │
│  - Dispatches events to consumers via Registry                          │
│  - Manages subscription lifecycle with 60s grace period teardown        │
│  - Broadcasts restart event so consumers can re-register                │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                        Dispatches to consumers
                                    │
            ┌───────────────────────┴───────────────────────┐
            │                                               │
            ▼                                               ▼
┌───────────────────────────┐               ┌───────────────────────────┐
│   UpstreamSubscriptionPool │               │    BlockHeightMonitor     │
│                            │               │                           │
│  - Manages client subs     │               │  - Tracks block heights   │
│  - Failover orchestration  │               │  - Updates BlockCache     │
│  - Deduplication           │               │  - Provider sync status   │
└───────────────────────────┘               └───────────────────────────┘
```

### Data Flow

#### 1. Consumer Registration Flow

```
Consumer                    Registry                    Manager
   │                           │                           │
   │ ensure_subscription(chain, provider_id, key)         │
   ├───────────────────────────────────────────────────────►
   │                           │                           │
   │                           │◄──register_consumer───────┤
   │                           │                           │
   │                           │  (if first consumer)      │
   │                           │                           │
   │                           │  create upstream sub ─────►
   │                           │                           │
   │◄──────────────────{:ok, :new | :existing}─────────────┤
```

#### 2. Event Dispatch Flow

```
WSConnection          PubSub              Manager              Registry           Consumers
    │                    │                   │                    │                  │
    │ {:subscription_event, ...}             │                    │                  │
    ├────────────────────►                   │                    │                  │
    │                    │                   │                    │                  │
    │                    ├───────────────────►                    │                  │
    │                    │                   │                    │                  │
    │                    │                   │ dispatch(...)      │                  │
    │                    │                   ├────────────────────►                  │
    │                    │                   │                    │                  │
    │                    │                   │                    │ send to each     │
    │                    │                   │                    ├──────────────────►
    │                    │                   │                    │                  │
```

#### 3. Manager Restart Recovery Flow

```
Manager (restarted)       PubSub                  Pool              BlockHeightMonitor
       │                     │                      │                       │
       │ broadcast(:upstream_sub_manager_restarted) │                       │
       ├─────────────────────►                      │                       │
       │                     │                      │                       │
       │                     ├──────────────────────►                       │
       │                     │                      │                       │
       │                     │  re-establish        │                       │
       │                     │  subscriptions       │                       │
       │◄───────────────────────ensure_subscription─┤                       │
       │                     │                      │                       │
       │                     ├──────────────────────┼───────────────────────►
       │                     │                      │                       │
       │                     │                      │  re-establish subs    │
       │◄─────────────────────────────────────────────ensure_subscription───┤
```

## Key Components

### UpstreamSubscriptionRegistry

**Location:** `lib/lasso/core/streaming/upstream_subscription_registry.ex`

A thin wrapper around Elixir's Registry with `:duplicate` keys. Provides:

- `register_consumer/3` - Register a consumer for `{chain, provider_id, sub_key}`
- `unregister_consumer/3` - Remove registration
- `dispatch/4` - Send message to all consumers for a key
- `count_consumers/3` - Count active consumers
- `has_consumers?/3` - Check if any consumers exist

**Automatic Cleanup:** When a consumer process dies, Registry automatically removes its registration.

### UpstreamSubscriptionManager

**Location:** `lib/lasso/core/streaming/upstream_subscription_manager.ex`

Per-chain GenServer that owns upstream subscription lifecycle. Key responsibilities:

1. **Subscription Creation:** Creates upstream WebSocket subscription when first consumer registers
2. **Subscription Reuse:** Returns `:existing` when subsequent consumers register for same subscription
3. **Event Dispatch:** Receives events from PubSub and dispatches to all consumers via Registry
4. **Grace Period Teardown:** Marks subscriptions for teardown when last consumer leaves, waits 60 seconds before actual teardown (allows brief disconnects without thrashing)
5. **Restart Recovery:** Broadcasts `{:upstream_sub_manager_restarted, chain}` on init so consumers can re-register

**State Structure:**
```elixir
%UpstreamSubscriptionManager{
  chain: "ethereum",
  active_subscriptions: %{
    {"provider_1", {:newHeads}} => %{
      upstream_id: "0xabc123",
      created_at: 1234567890,
      marked_for_teardown_at: nil,
      consumer_count: 2
    }
  },
  upstream_index: %{
    "0xabc123" => {"provider_1", {:newHeads}}
  }
}
```

### UpstreamSubscriptionPool (Modified)

**Location:** `lib/lasso/core/streaming/upstream_subscription_pool.ex`

Now delegates upstream subscription management to Manager. Key changes:

1. **Removed:** `upstream_index` tracking (now in Manager)
2. **Removed:** Direct `send_upstream_subscribe` calls (now via Manager)
3. **Added:** `transitioning_from` field for tracking old provider during failover
4. **Added:** Handler for Manager restart event to re-establish subscriptions

**New State Structure:**
```elixir
%{
  chain: "ethereum",
  keys: %{
    {:newHeads} => %{
      refcount: 2,
      primary_provider_id: "provider_1",
      status: :active,
      transitioning_from: nil,  # Set during failover
      markers: %{...},
      dedupe: %{...}
    }
  }
}
```

### BlockHeightMonitor (Modified)

**Location:** `lib/lasso/core/streaming/block_height_monitor.ex`

Now uses Manager instead of direct eth_subscribe. Key changes:

1. **Uses:** `UpstreamSubscriptionManager.ensure_subscription/3`
2. **Receives:** `{:upstream_subscription_event, provider_id, {:newHeads}, payload, received_at}`
3. **Added:** Handler for Manager restart event

## Race Condition Handling

### Race #1: Events During Provider Transition

**Problem:** During failover, events might arrive from both old and new providers.

**Solution:** Pool tracks `transitioning_from` field and forwards events from both primary and transitioning providers:

```elixir
def handle_info({:upstream_subscription_event, provider_id, key, payload, received_at}, state) do
  case Map.get(state.keys, key) do
    %{primary_provider_id: ^provider_id, status: :active} ->
      # Normal case - event from primary provider
      forward_event(...)

    %{transitioning_from: ^provider_id, status: :active} ->
      # Event from old provider during transition - forward for deduplication
      forward_event(...)

    _ ->
      {:noreply, state}
  end
end
```

After 5 seconds, deferred release cleans up the `transitioning_from` tracking.

### Race #4: Buffer Preservation During Cascade

**Problem:** When a failover fails and cascades to another provider, buffered events could be lost.

**Solution:** StreamCoordinator preserves event buffer when cascading:

```elixir
defp handle_resubscribe_failure(state, reason) do
  # Preserve buffer when cascading
  preserved_buffer = state.failover_context.event_buffer
  initiate_failover_with_buffer(reset_state, old_provider, next_provider, preserved_buffer)
end
```

### Manager Crash Recovery

**Problem:** If Manager crashes and restarts, it has empty state but consumers are still running.

**Solution:** Manager broadcasts restart event, consumers re-register:

```elixir
# Manager init
def init(chain) do
  # ... setup ...

  # Notify consumers to re-register
  Phoenix.PubSub.broadcast(
    Lasso.PubSub,
    "upstream_sub_manager:#{chain}",
    {:upstream_sub_manager_restarted, chain}
  )

  {:ok, %__MODULE__{chain: chain}}
end

# Pool handler
def handle_info({:upstream_sub_manager_restarted, _chain}, state) do
  # Re-establish all active subscriptions
  for {key, %{primary_provider_id: provider_id, status: :active}} <- state.keys do
    UpstreamSubscriptionManager.ensure_subscription(state.chain, provider_id, key)
  end
  {:noreply, state}
end
```

## PubSub Topics

| Topic | Publisher | Subscribers | Message Format |
|-------|-----------|-------------|----------------|
| `ws:subs:{chain}` | WSConnection | Manager | `{:subscription_event, provider_id, upstream_id, payload, received_at}` |
| `upstream_sub_manager:{chain}` | Manager | Pool, BlockHeightMonitor | `{:upstream_sub_manager_restarted, chain}` |
| `provider_pool:events:{chain}` | ProviderPool | Manager, Pool, BlockHeightMonitor | `{:provider_event, %{type: atom, provider_id: string}}` |

## Configuration

```elixir
# In UpstreamSubscriptionManager
@teardown_grace_period_ms 60_000  # Wait 60s before tearing down unused subscription
@cleanup_interval_ms 30_000       # Check for teardowns every 30s

# In UpstreamSubscriptionPool
@deferred_release_delay_ms 5_000  # Wait 5s before releasing old provider during transition
```

## Testing

### Unit Tests

- `test/lasso/core/streaming/upstream_subscription_manager_test.exs` - Manager lifecycle, dispatch, concurrent access
- `test/lasso/core/streaming/upstream_subscription_registry_test.exs` - Registry functions, automatic cleanup

### Integration Tests

- `test/lasso/rpc/upstream_subscription_pool_test.exs` - Pool state management, race conditions
- `test/integration/upstream_subscription_pool_integration_test.exs` - Full flow with MockWSProvider

## Migration Notes

### Breaking Changes

None - the refactor is internal. The public API (`UpstreamSubscriptionPool.subscribe_client/3`) remains unchanged.

### Behavioral Changes

1. **Single upstream subscription per key:** Previously, multiple components could create duplicate subscriptions. Now only one exists per `{provider_id, sub_key}`.

2. **Grace period teardown:** Subscriptions aren't immediately torn down when last consumer leaves. This prevents thrashing during brief disconnects.

3. **Automatic recovery:** If Manager crashes, consumers automatically re-register on restart broadcast.

## Future Considerations

1. **State persistence:** Consider persisting subscription state to ETS for faster recovery
2. **Metrics:** Add telemetry for subscription count, consumer count, teardown frequency
3. **Load shedding:** Consider max consumers per subscription to prevent overload
