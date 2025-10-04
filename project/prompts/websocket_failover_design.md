# WebSocket Subscription Failover & Continuity - Design Specification

## Mission-Critical Requirement

Provide **bulletproof, gap-free WebSocket subscription streams** for blockchain data (newHeads, logs) to downstream consumers, with automatic provider failover and guaranteed continuity across provider failures.

## System Context

### Current Architecture Components

**UpstreamSubscriptionPool** (`lib/lasso/core/streaming/upstream_subscription_pool.ex`)
- Per-chain GenServer that multiplexes client subscriptions onto minimal upstream WebSocket connections
- Manages subscription lifecycle: establishes upstream eth_subscribe, routes events downstream
- Tracks: `keys` (subscription metadata), `upstream_index` (provider_id => upstream_id => key mapping)
- Subscribes to PubSub: `"ws:subs:#{chain}"` for WS events, `"provider_pool:events:#{chain}"` for health

**StreamCoordinator** (`lib/lasso/core/streaming/stream_coordinator.ex`)
- Per-subscription-key GenServer (one per {:newHeads} or {:logs, filter})
- Owns continuity guarantees: deduplication, gap detection, ordering
- Uses StreamState to track `last_block_num`, `last_log_block`, dedupe cache
- Receives upstream events from Pool, dispatches to ClientSubscriptionRegistry after validation
- **Attempts** provider failover via `provider_unhealthy` cast

**GapFiller** (`lib/lasso/core/support/gap_filler.ex`)
- Pure functional API (no GenServer) for HTTP-based backfill
- `ensure_blocks(chain, provider_id, from_n, to_n)` - fetches missed blocks via eth_getBlockByNumber
- `ensure_logs(chain, provider_id, filter, from_n, to_n)` - fetches missed logs via eth_getLogs
- Used by StreamCoordinator in failover scenarios

**ClientSubscriptionRegistry** (`lib/lasso/core/streaming/client_subscription_registry.ex`)
- Tracks downstream client PIDs and their subscription IDs
- Dispatches events to all subscribed clients

### Current Behavior Analysis

#### What Works ✅
1. **Initial subscription establishment** - Pool correctly calls `send_upstream_subscribe/3` to create WS subscriptions
2. **Event routing** - WS messages flow: Transport → Pool → Coordinator → Clients
3. **Deduplication** - StreamState prevents duplicate block/log delivery using DedupeCache
4. **Gap detection** - StreamState.last_block_num tracks stream position, can identify gaps
5. **HTTP backfill** - GapFiller can fetch missed blocks/logs via synchronous HTTP calls
6. **Basic health monitoring** - ProviderPool broadcasts provider health events

#### What's Broken ❌

**Critical Flaw #1: Incomplete Failover Message Chain**
```elixir
# StreamCoordinator.ex:188 (after backfill completes)
send(self(), {:subscribe_on, new_provider})

# StreamCoordinator.ex:193 - handler exists
def handle_info({:subscribe_on, provider_id}, state) do
  send_to_pool(state.chain, {:subscribe_on, provider_id, state.key, self()})
  {:noreply, %{state | awaiting_confirm: provider_id}}  # awaiting_confirm was unused, removed
end

# UpstreamSubscriptionPool.ex - NO HANDLER for {:subscribe_on, ...}
# Falls through to catch-all: def handle_info(_, state), do: {:noreply, state}
# Result: Message silently dropped, resubscription never happens
```

**Critical Flaw #2: Dead Confirmation Mechanism**
- `upstream_confirmed/3` function exists but never called
- No way to verify new subscription succeeded
- No retry logic if resubscription fails

**Critical Flaw #3: Async Backfill Race Condition**
```elixir
# StreamCoordinator spawns Task for backfill
Task.start(fn -> do_backfill_and_switch(state, failed_id, proposed_new_id) end)
{:noreply, state}  # Returns immediately
```
- Backfill runs async, but no state update when it completes
- Events from old provider still processed during backfill
- No mechanism to buffer/reject events until switch completes

**Critical Flaw #4: Provider Selection Mismatch**
- Pool picks provider via `Selection.pick_provider/4` at subscription time
- Coordinator receives `proposed_new_id` from health event
- No guarantee proposed provider supports required capabilities (newHeads/logs)
- No fallback if proposed provider also fails

### Current Implementation Artifacts (from cleanup)

**Removed incomplete code:**
- `awaiting_confirm` state field - set but never read
- `upstream_confirmed/3` API - defined but never called
- `send_to_pool/2` helper - became unused after removing subscribe_on handler
- `provider_caps`, `failover_enabled`, `max_backfill_blocks` config in Pool - loaded but unused
- `:subscribe_on` message send - had no handler

**Implications:**
The system was **designed** for provider failover but the implementation was **never completed**. Current behavior: detects failures, attempts backfill, but never switches subscriptions.

## Requirements Specification

### Functional Requirements

**FR1: Continuous Event Delivery**
- Once subscribed, client receives ALL events (blocks/logs) in order with no gaps
- Survives provider failures, network issues, WebSocket disconnections
- Acceptable latency: events delivered within 5 seconds of on-chain confirmation

**FR2: Provider Failover**
- Detect unhealthy provider within 10 seconds (via health checks, WS disconnect, timeout)
- Switch to healthy provider automatically
- Complete failover within 30 seconds (backfill + resubscribe)

**FR3: Gap Filling**
- Identify missing blocks/logs between last received and first from new provider
- Fetch missing data via HTTP as fallback
- Deliver backfilled data in order before resuming live stream

**FR4: Duplicate Prevention**
- Never deliver same block/log twice to client
- Handle overlapping data from multiple providers during transition

**FR5: Failure Recovery**
- Retry failed resubscription attempts (exponential backoff, max 5 attempts)
- Fallback to additional providers if first failover target fails
- Alert/log if all providers exhausted

### Non-Functional Requirements

**NFR1: State Consistency**
- Stream state (last_block_num, dedupe) must be durable across failovers
- No event loss even if Coordinator crashes during failover

**NFR2: Latency**
- Normal operation: <100ms event delivery latency
- During failover: <5s for backfill + switch (for ≤32 missed blocks)

**NFR3: Resource Efficiency**
- Minimize upstream subscriptions (multiplex clients onto single upstream per key)
- Limit concurrent backfill requests (max 3 per chain)
- Clean up resources when last client unsubscribes

**NFR4: Observability**
- Emit telemetry for: failover initiated, backfill started/completed, subscription switched, gaps detected
- Log errors with context (chain, key, provider_id, gap range)

## Design Questions for AI Agent

### Architecture

**Q1: Should Pool or Coordinator own failover decisions?**
- **Option A (Current):** Coordinator receives health signals, decides to failover, tells Pool to resubscribe
- **Option B:** Pool owns all provider decisions, Coordinator just requests "ensure healthy subscription"
- **Option C:** Hybrid: Pool monitors health, Coordinator requests failover with backfill requirements

**Q2: Synchronous or Asynchronous failover?**
- **Synchronous:** Block event processing during backfill, ensure atomic switch
- **Asynchronous:** Continue processing events from old provider during backfill, merge streams
- **Hybrid:** Buffer events during critical transition window

**Q3: Where to track failover state?**
- Pool state: `{key => %{status: :active | :failing_over, target_provider: ...}}`
- Coordinator state: `%{failover_state: nil | %{target: pid, backfill_task: ref}}`
- Separate FailoverSM GenServer per key

### Message Flow

**Q4: How should resubscription work?**
```elixir
# Option A: Coordinator requests, Pool executes
Coordinator -> Pool: {:resubscribe, key, new_provider_id, coordinator_pid}
Pool -> WSTransport: send_upstream_subscribe(...)
Pool -> Coordinator: {:subscription_confirmed, upstream_id} | {:subscription_failed, reason}

# Option B: Coordinator manages directly
Coordinator -> WSTransport: send_upstream_subscribe(...)
Coordinator -> Pool: {:update_upstream, key, provider_id, upstream_id}

# Option C: Pool-driven
Pool detects failure -> Pool: select_new_provider()
Pool -> Coordinator: {:provider_switching, old_id, new_id, expected_gap}
Coordinator -> Pool: {:backfill_complete, from_n, to_n} or {:ready_for_switch}
```

**Q5: How to handle events during failover?**
- Queue events from old provider until switch completes?
- Process events from old provider, dedupe against backfill?
- Reject events from old provider after failover initiated?

### Gap Management

**Q6: Who determines gap range?**
- **Coordinator:** Knows `last_block_num`, can calculate gap when switching
- **Pool:** Could track "expected next block" per upstream, detect gaps in real-time
- **GapFiller:** Pure function, caller provides range

**Q7: How to handle backfill failures?**
- Retry same provider (transient HTTP error)
- Try different provider (provider-specific issue)
- Skip gap, mark as "best effort" (all providers failing)
- Fail subscription, notify client

**Q8: How to merge backfill with live stream?**
```elixir
# Option A: Pause upstream, backfill, resume
1. Stop processing WS events
2. Fetch blocks N to M via HTTP
3. Emit backfilled blocks
4. Resume WS event processing

# Option B: Parallel streams with deduplication
1. Continue processing WS events (new provider)
2. Async fetch blocks N to M
3. Dedupe and emit in order

# Option C: Buffering
1. Buffer WS events during backfill
2. Fetch blocks N to M
3. Merge and emit in order
```

### Error Handling

**Q9: How to handle cascading failures?**
- Provider A fails → failover to B → B also fails → try C?
- Maximum retry attempts per failover?
- Fallback strategy when all providers exhausted?

**Q10: How to handle partial gaps?**
- eth_getLogs returns 0 results for range - is it a gap or empty?
- Provider returns incomplete block (missing transactions) - retry or accept?

### State Management

**Q11: What state needs persistence?**
- `last_block_num` / `last_log_block` - critical for gap detection
- Dedupe cache - can be rebuilt (tolerate duplicates on restart)
- Failover state - ephemeral or durable?

**Q12: How to handle Coordinator crashes during failover?**
- Restart from last known state (lost backfill progress)
- Pool detects Coordinator death, re-initiates subscription
- External supervision strategy

## Implementation Constraints

### Must Preserve
1. **Deduplication in StreamState** - working correctly, keep logic
2. **GapFiller HTTP backfill** - working correctly, keep as utility
3. **ClientSubscriptionRegistry dispatch** - working correctly, keep interface
4. **Pool's upstream subscription management** - mostly working, enhance

### Must Fix
1. Add `handle_info({:resubscribe, ...})` or equivalent to Pool
2. Implement confirmation flow back to Coordinator
3. Add retry logic for failed resubscription
4. Coordinate backfill with subscription switch

### Must Add
1. State machine for failover status (idle → detecting → backfilling → switching → active)
2. Timeout supervision (failover taking too long)
3. Telemetry events for observability
4. Provider capability validation before failover

## Success Criteria

### Correctness
- [ ] Zero gaps in event stream across provider failover (verified by test)
- [ ] Zero duplicate events delivered to clients (verified by test)
- [ ] Events delivered in order (block N before block N+1)

### Resilience
- [ ] Survives single provider failure (failover completes successfully)
- [ ] Survives cascading failures (tries multiple providers)
- [ ] Survives Coordinator crash (recovers on restart)

### Performance
- [ ] Failover completes within 30s (including backfill for ≤32 blocks)
- [ ] Normal event latency <100ms (no regression)
- [ ] Memory bounded (dedupe cache cleanup, no unbounded buffers)

## Agent Task

**Given this context:**
1. Analyze the current incomplete implementation and failure modes
2. Answer the Design Questions (Q1-Q12) with engineering rationale
3. Propose a complete, production-ready design that:
   - Fixes all 4 Critical Flaws
   - Minimizes architectural changes (build on existing components)
   - Provides clear failure semantics
   - Is testable (propose test scenarios)

**Deliverable: Detailed Design Specification Document** including:
- Component responsibilities (Pool, Coordinator, GapFiller, new components if needed)
- Message flow diagrams (normal operation, failover, edge cases)
- State machine diagrams (failover lifecycle)
- API contracts (GenServer calls/casts, PubSub events)
- Error handling decision tree
- Test plan (unit, integration, chaos/failure injection)
- Implementation plan (phased rollout, rollback strategy)

**Success metric:** A specification detailed enough for a senior engineer to implement without ambiguity, with zero gaps in continuity guarantees.
