# WebSocket Connection Thrashing Investigation

**Date:** 2026-01-26
**Branch:** `fix/ws-circuit-breaker-disconnect-tracking`
**Issue:** Rapid WebSocket subscription recreation loop with dRPC provider
**Status:** Fixed with identified design concerns

---

## Executive Summary

Investigation revealed multiple interconnected issues causing WebSocket connection thrashing with dRPC's "accept-then-drop" connection pattern:

1. **Race condition** in `UpstreamSubscriptionManager` where `ws_connected` events invalidated subscriptions from previous connections
2. **Missing circuit breaker penalty** for connections dropped before stability window (5s)
3. **Async circuit breaker updates** causing reconnect decisions before failure state was processed
4. **Missing :EXIT handling** - Connection GenServer didn't trap exits from linked WebSockex, causing disconnects to be missed when WebSockex crashed
5. **HealthProbe interference** - Successful WS probes called `signal_recovery`, resetting failure counts during thrashing (guarded to only signal when connection_stable)

All issues have been fixed, but the investigation exposed several design concerns that may warrant architectural review.

---

## Initial Symptoms

### Observed Behavior

```
[info] [arbitrum] Created upstream subscription => connection_id=conn_ff1fbf28ef11241c
[debug] [arbitrum] WS subscription active (first block received) => height=425587913
[info] [arbitrum] Detected stale subscription, recreating => current_conn_id=conn_ed715d718cade77a stale_conn_id=conn_ff1fbf28ef11241c
[info] [arbitrum] Created upstream subscription => connection_id=conn_ed715d718cade77a
[info] [arbitrum] Detected stale subscription, recreating => current_conn_id=conn_a16b666d2530ee91...
```

**Pattern:** Rapid subscription recreation loop with changing connection IDs, no disconnect logs visible, blocks being received successfully.

### User Report

- Running with only Arbitrum chain configured
- dRPC provider experiencing rapid connection cycling
- Circuit breaker showing 0/5 failures despite multiple disconnects
- No "WebSocket closed" warning logs appearing

---

## Investigation Timeline

### Phase 1: Stale Subscription Detection (Issue #1)

#### Finding
The "Detected stale subscription" logs indicated `UpstreamSubscriptionManager.ensure_subscription` was comparing subscription's `connection_id` against current connection state and finding mismatches.

#### Root Cause
In `UpstreamSubscriptionManager.handle_info({:ws_connected, ...})`:
```elixir
def handle_info({:ws_connected, provider_id, connection_id}, state) do
  conn_state = %{
    connection_id: connection_id,
    status: :connected,
    connected_at: System.monotonic_time(:millisecond)
  }

  new_connection_states = Map.put(state.connection_states, provider_id, conn_state)
  {:noreply, %{state | connection_states: new_connection_states}}
end
```

**Problem:** Updates `connection_states` with new `connection_id` but does NOT clean up existing subscriptions with old `connection_id`.

**Race Condition:**
1. Connection A establishes (`conn_ff1fbf28ef11241c`)
2. Subscription created with `connection_id: conn_ff1fbf28ef11241c`
3. Connection drops, reconnect happens quickly
4. `ws_connected` with new ID (`conn_ed715d718cade77a`) arrives BEFORE `ws_disconnected`
5. `connection_states` now has new ID, but subscription still has old ID
6. Next `ensure_subscription` call detects mismatch → "stale detected"

**Multiple Consumers:** Three processes call `ensure_subscription` for same `{provider_id, :newHeads}`:
- BlockSync.Worker via WsStrategy
- UpstreamSubscriptionPool for client streaming
- UpstreamSubscriptionPool on manager restart

This amplified the race window - each consumer calling `ensure_subscription` at slightly different times relative to the `ws_connected` event.

#### Fix Applied
Modified `handle_info({:ws_connected, ...})` to atomically:
1. Find subscriptions with stale `connection_id` (different from new one)
2. Cancel their staleness timers
3. Dispatch `{:upstream_subscription_invalidated, ..., :connection_replaced}`
4. Remove from `active_subscriptions` and `upstream_index`
5. Then update `connection_states`

**File:** `lib/lasso/core/streaming/upstream_subscription_manager.ex:373-429`

---

### Phase 2: Missing Disconnect Logs (Issue #2)

#### Finding
After fixing Phase 1, logs showed:
```
[debug] [arbitrum] Invalidating stale subscriptions on new connection => stale_count=1
[info] [arbitrum] Created upstream subscription => connection_id=conn_711e9eb9d6a99f2c
[debug] [arbitrum] WS subscription invalidated => reason=:connection_replaced
```

Still no "WebSocket closed" warnings, circuit breaker still at 0/5.

#### Investigation
Added debug logging to trace disconnect flow:
- `WebSockex.Handler.handle_disconnect` - confirm WebSockex detects disconnect
- `Connection.handle_info({:ws_disconnect, ...})` - confirm message reaches Connection

**Discovery:** Logs revealed:
```
[debug] WebSockex handle_disconnect called => reason={:remote, :closed}
[debug] Connection received ws_disconnect error => reason={:remote_closed, "TCP connection closed abruptly"}
```

Disconnect WAS being detected, but the warning log never appeared.

#### Root Cause
The original circuit breaker penalty logic:
```elixir
should_penalize = had_pending or not is_graceful
```

**Problem:** dRPC sends graceful close (code 1000) immediately after accepting connection, before any requests are pending. Both conditions false → no penalty → no warning log.

This is the "accept-then-drop" pattern - provider accepts WebSocket connection, then immediately closes it (likely due to connection limits/rate limiting).

#### Design Intent from Commit 814d112
The commit message explicitly stated:
> "Add connection stability timer (5s) before signaling recovery"
> "This prevents thrashing when providers drop connections immediately after connect"

But the penalty logic didn't account for pre-stability disconnects.

#### Fix Applied
1. Added `connection_stable: boolean` to state (tracks if connection survived 5s window)
2. Updated penalty logic:
   ```elixir
   should_penalize = not was_stable or had_pending or not is_graceful
   ```
3. Set `connection_stable: true` only when stability timer fires
4. Reset to `false` on disconnect

**Result:** Connections dropped before proving stable are ALWAYS penalized, regardless of close code.

**Files:**
- `lib/lasso/core/transport/websocket/connection.ex:134,466-557,724-743`

---

### Phase 3: Circuit Breaker Not Opening (Issue #3)

#### Finding
After Phase 2 fix, logs showed:
```
[warning] WebSocket disconnected unexpectedly: {:remote_closed, ...}, was_stable=false...
[debug] Recording circuit breaker failure => breaker_penalty=true
[warning] Circuit breaker arbitrum_drpc (ws) failure 2/3: -32000 (network_error)
```

Failures being recorded, but circuit never opened. After third disconnect, no "failure 3/3" log appeared.

#### Root Cause
Circuit breaker uses async updates:
```elixir
def record_failure(id, reason) do
  GenServer.cast(via_name(id), {:report_external, {:error, reason}})
  :ok
end
```

**Race Condition:**
1. `handle_info({:ws_disconnect, :error, ...})` calls `CircuitBreaker.record_failure` (async cast)
2. `schedule_reconnect_with_circuit_check(state)` immediately checks circuit state
3. Circuit state still `:closed` (cast hasn't been processed yet)
4. Reconnect scheduled immediately
5. Circuit breaker processes cast, opens circuit - too late!

**Additional Issue:** HealthProbe.Worker calls `CircuitBreaker.signal_recovery` on successful WS probes, which can reset the failure count even while connections are thrashing.

#### Fix Applied
1. Added synchronous `record_failure_sync/3` to CircuitBreaker
2. Updated disconnect handlers to use sync version and capture circuit state
3. Added logging to trace circuit state after each disconnect

**Files:**
- `lib/lasso/core/support/circuit_breaker.ex:476-485,1089-1109`
- `lib/lasso/core/transport/websocket/connection.ex:612-634,522-545`

---

### Phase 4: Missing Disconnect Messages (Issue #4)

#### Finding
After Phase 3 fixes, testing showed circuit breaker eventually opening, but only after ~14 rapid disconnects that weren't being logged or penalized. Early disconnects showed:
```
[debug] WebSockex handle_disconnect called => reason={:remote, :closed} provider_id=arbitrum_drpc
[debug] [arbitrum] Invalidating stale subscriptions on new connection => ...
```

But NO "Connection received ws_disconnect error" log between them. The Handler was sending the disconnect message, but the Connection GenServer wasn't processing it.

#### Root Cause
The Connection GenServer starts WebSockex using `start_link`, creating a process link. However, it doesn't trap exits.

**Missing Link Handling:**
1. WebSockex uses `start_link` which creates a bidirectional link
2. Connection GenServer doesn't call `Process.flag(:trap_exit, true)`
3. If WebSockex crashes (vs exiting normally), the exit propagates to Connection
4. Connection crashes and restarts via supervisor (`restart: :permanent`)
5. On restart, `init` is called which starts a NEW WebSockex connection
6. The `:ws_disconnect` message from the old WebSockex was sent to the old Connection PID (now dead)
7. Message is lost, disconnect is never processed or penalized

**Why It Eventually Worked:**
After multiple rapid cycles, the HealthProbe crashed trying to send a request to the WebSocket, which triggered a circuit breaker failure through a different path. This gave the circuit breaker time to accumulate failures.

#### Fix Applied
1. Added `Process.flag(:trap_exit, true)` in Connection's `init/1`
2. Added `handle_info({:EXIT, pid, reason}, state)` handlers to:
   - Detect when the linked WebSockex process exits
   - Process the disconnect even if `:ws_disconnect` message was lost
   - Record circuit breaker failure and schedule reconnect

**Files:**
- `lib/lasso/core/transport/websocket/connection.ex:121` (trap_exit flag)
- `lib/lasso/core/transport/websocket/connection.ex:797-895` (EXIT handlers)
- `lib/lasso/core/support/error_normalizer.ex:488-499` (new ws_exit error type)

---

## Summary of Changes

### 1. UpstreamSubscriptionManager - Race Condition Fix
**Problem:** `ws_connected` didn't invalidate subscriptions with stale connection IDs
**Solution:** Atomically clean up stale subscriptions before updating connection state
**File:** `lib/lasso/core/streaming/upstream_subscription_manager.ex:373-429`

### 2. Connection - Stability Tracking
**Problem:** Connections dropped before stability window weren't penalized
**Solution:** Added explicit `connection_stable` boolean, penalize all pre-stability disconnects
**Files:**
- `lib/lasso/core/transport/websocket/connection.ex:134` (state field)
- `lib/lasso/core/transport/websocket/connection.ex:466-557` (close frame handler)
- `lib/lasso/core/transport/websocket/connection.ex:560-639` (error disconnect handler)
- `lib/lasso/core/transport/websocket/connection.ex:724-743` (stability timer handler)

### 3. CircuitBreaker - Synchronous Failure Recording
**Problem:** Async failure recording caused reconnect decisions before circuit state updated
**Solution:** Added `record_failure_sync/3` for critical disconnect paths
**Files:**
- `lib/lasso/core/support/circuit_breaker.ex:482-485` (handle_call clause)
- `lib/lasso/core/support/circuit_breaker.ex:1089-1109` (public API)
- `lib/lasso/core/transport/websocket/connection.ex` (usage in handlers)

### 4. Connection - EXIT Signal Handling
**Problem:** WebSockex linked to Connection, but Connection doesn't trap exits. When WebSockex crashes, Connection also crashes, losing the disconnect message.
**Solution:** Added `trap_exit: true` and `:EXIT` handlers to catch WebSockex termination
**Files:**
- `lib/lasso/core/transport/websocket/connection.ex:121` (trap_exit flag)
- `lib/lasso/core/transport/websocket/connection.ex:797-895` (EXIT handlers)
- `lib/lasso/core/support/error_normalizer.ex:488-499` (ws_exit error type)

### 5. HealthProbe - Guard Recovery Signal
**Problem:** HealthProbe called `signal_recovery` on every successful WS probe, even during thrashing. This reset failure counts before circuit could open.
**Context:** The original intent was to help circuits recover from half-open state when stuck too long. The fix preserves this while preventing interference during thrashing.
**Solution:** Only call `signal_recovery` when `connection_stable: true`
**Files:**
- `lib/lasso/core/health_probe/worker.ex:340-361` (guarded signal_recovery)
- `lib/lasso/core/transport/websocket/connection.ex:376-385` (exposed connection_stable in status)

### 6. Connection - Supervisor Shutdown Handlers
**Problem:** With trap_exit enabled, supervisor shutdown signals go through catch-all handler (non-idiomatic).
**Solution:** Added explicit handlers for `:shutdown` and `{:shutdown, reason}` EXIT signals
**Files:**
- `lib/lasso/core/transport/websocket/connection.ex:892-899` (shutdown handlers)

### 7. Debug Logging (Temporary)
Added extensive debug logging to trace message flow - should be removed or reduced after verification.

---

## Design Concerns Identified

### 1. Multiple Consumers for Same Subscription Key

**Issue:** Three independent processes call `ensure_subscription` for `{provider_id, :newHeads}`:
- `BlockSync.Worker` (via `WsStrategy.start` and `WsStrategy.resubscribe`)
- `UpstreamSubscriptionPool` (for client streaming)
- Various places on manager restart

**Problem:** This creates:
- Race windows where different processes see different connection states
- Redundant subscription attempts
- Complex coordination requirements

**Question:** Should there be a single "subscription coordinator" per `{provider_id, key}` that manages the lifecycle, rather than multiple consumers racing?

### 2. Message Ordering Dependencies

**Issue:** System correctness depends on specific PubSub message ordering:
- `ws_disconnected` must arrive before `ws_connected` (not guaranteed)
- Circuit breaker state must update before reconnect decision
- Subscription invalidation must complete before new subscription

**Current Mitigation:**
- Phase 1 fix handles out-of-order `ws_connected`
- Phase 3 fix uses synchronous updates for critical paths

**Concern:** Are we fighting PubSub's inherent async nature? Should coordination be different?

### 3. HealthProbe Interference with Circuit Breaker

**Issue:** `HealthProbe.Worker.handle_ws_probe_success` calls `CircuitBreaker.signal_recovery` on every successful probe (line 344).

**Problem:** During connection thrashing:
1. Connection establishes
2. HealthProbe sends request, gets response → calls `signal_recovery`
3. Connection drops → circuit breaker records failure
4. Repeat

The successful probes can reset/reduce the failure count, preventing circuit from opening.

**Question:** Should HealthProbe WS success affect the circuit breaker at all during active connection thrashing? Or should circuit breaker only respond to Connection lifecycle events?

### 4. Dual Circuit Breaker State Management

**Issue:** Both Connection and HealthProbe interact with the same circuit breaker:
- Connection records failures on disconnect
- HealthProbe signals recovery on successful probes
- Both check circuit state for different purposes

**Concern:** No clear "owner" of circuit breaker state. Who has authority to open/close?

**Related:** The `signal_recovery` at line 344 only fires when circuit is `:open` or `:half_open`, but this check happens BEFORE the probe result is known. Design seems unclear.

### 5. Connection Stability vs Circuit Breaker State

**Issue:** Two separate mechanisms track connection health:
- `connection_stable` boolean (5s timer in Connection)
- Circuit breaker failure count and state machine

**Overlap:**
- Connection won't signal `recovery` to circuit breaker until stable
- But circuit breaker also tracks failures/successes independently
- Connection penalty logic uses `was_stable`
- Circuit breaker has its own category-based thresholds

**Question:** Should these be unified? Is there one source of truth for "connection is healthy"?

### 6. Synchronous Operations in GenServer Handlers

**Issue:** Phase 3 fix uses synchronous `GenServer.call` from within another GenServer's message handler.

**Risk:**
- Potential for deadlocks if circular dependencies exist
- Timeout cascades if circuit breaker is slow
- Performance impact of synchronous calls in hot path

**Mitigation:** Currently using 5s timeout, but this is a temporary fix.

**Question:** Should circuit breaker state be local (in Connection) rather than remote (separate GenServer)?

### 7. Implicit Message Flow Contracts

**Issue:** Correctness depends on understanding implicit contracts:
- `ws_connected` must be followed eventually by `ws_disconnected` or `ws_closed`
- Subscription invalidation messages must be processed before new subscriptions
- Circuit breaker casts must complete before reconnect checks

**Problem:** These contracts aren't enforced or validated, making it easy to introduce subtle bugs.

**Example:** We only discovered Issue #3 after fixing Issues #1 and #2. The async nature was always there, but only became visible when other issues were resolved.

---

## dRPC-Specific Behavior

### "Accept-Then-Drop" Pattern

dRPC appears to:
1. Accept WebSocket connections immediately
2. Send a graceful close (code 1000) within milliseconds
3. No error indication in the close reason

**Hypothesis:** Connection limits or rate limiting implemented as "accept then immediately close."

**Why This Is Hard:**
- No distinguishable error code (1000 = normal closure)
- No pending requests at disconnect time (connection too short)
- Without stability tracking, appears as "graceful voluntary disconnect"

### Impact on Circuit Breaker Thresholds

With default threshold of 5 failures:
- First 4 rapid disconnects → circuit stays closed
- 5th disconnect → circuit opens
- But if ANY successful operation occurs between disconnects, count resets

With HealthProbe interference, this becomes even more difficult.

---

## Test Coverage Gaps

The following scenarios were not covered by existing tests:

1. **Rapid reconnect with out-of-order messages**
   - `ws_connected` arrives before previous `ws_disconnected`
   - Multiple consumers calling `ensure_subscription` concurrently

2. **Pre-stability disconnects**
   - Connection drops within 5s stability window
   - Graceful close codes (1000) before stability

3. **Circuit breaker async timing**
   - Reconnect decision made before failure state processes
   - HealthProbe success racing with Connection failure

4. **Subscription lifecycle during thrashing**
   - Subscription invalidation while new subscription being created
   - Multiple invalidation reasons arriving simultaneously

**Recommendation:** Add integration tests that explicitly test these timing-sensitive scenarios.

---

## Open Questions for Design Review

### Architecture

1. Should subscription lifecycle be managed by a single coordinator per `{provider, key}` rather than multiple consumers?

2. Should circuit breaker state be local to Connection rather than a separate GenServer?

3. Should message flow use synchronous protocols (like DynamicSupervisor's sync start) rather than PubSub for critical state transitions?

### Semantics

4. What is the single source of truth for "connection is healthy"?
   - Connection.connection_stable?
   - CircuitBreaker.state == :closed?
   - Both?

5. Who owns circuit breaker state?
   - Connection (disconnect/connect events)?
   - HealthProbe (probe results)?
   - Both? If both, what's the coordination protocol?

6. Should HealthProbe interact with circuit breaker during active connection thrashing?

### Implementation

7. Are synchronous GenServer calls in disconnect handlers acceptable, or do we need a different approach?

8. Should we add explicit ordering guarantees (like sequence numbers) to critical messages?

9. Is the current `ensure_subscription` API (returns `:new` or `:existing`) sufficient, or should it return more detailed state?

### Testing

10. How do we reliably test timing-sensitive concurrent scenarios?

11. Should we add property-based tests for subscription lifecycle state transitions?

---

## Recommendations

### Immediate (Keep Current Fixes)

1. ✅ Keep Phase 1 fix (stale subscription cleanup)
2. ✅ Keep Phase 2 fix (stability tracking)
3. ✅ Keep Phase 3 fix (synchronous circuit breaker updates)
4. ⚠️ Monitor for performance impact of synchronous calls
5. ⚠️ Remove/reduce debug logging after verification

### Short Term (Next Sprint)

1. **Review HealthProbe → CircuitBreaker interaction**
   - Consider removing `signal_recovery` call on WS probe success
   - Or only call it when circuit is `:open` AND connection is stable

2. **Add integration tests** for identified gaps

3. **Document message flow contracts**
   - Create sequence diagrams for normal and error flows
   - Document ordering assumptions and guarantees

### Medium Term (Design Review)

1. **Evaluate subscription coordinator pattern**
   - Single process per `{provider, key}` managing lifecycle
   - Consumers register interest, coordinator handles WebSocket state

2. **Consider circuit breaker ownership model**
   - Should Connection own circuit breaker state locally?
   - Or should there be explicit handoff protocol?

3. **Assess PubSub vs synchronous protocols**
   - For critical state transitions, is PubSub the right primitive?
   - Could gen_statem or explicit FSM provide better guarantees?

### Long Term (If Issues Persist)

1. **Redesign WebSocket connection management**
   - Unified state machine for connection + subscription + circuit breaker
   - Explicit state transitions with validation
   - Single source of truth

2. **Consider provider-level abstractions**
   - Abstract "reliable provider connection" that handles thrashing internally
   - Expose stable interface to consumers

---

## Related Issues and PRs

- Initial circuit breaker work: commit `814d112` (2026-01-26)
- Dashboard subscription explosion fix: commit `b1a665d` (2026-01-26)
- This investigation: branch `fix/ws-circuit-breaker-disconnect-tracking`

---

## Appendix: Key Code Locations

### Subscription Management
- `lib/lasso/core/streaming/upstream_subscription_manager.ex`
  - Line 120: `ensure_subscription/4` - Entry point for subscription requests
  - Line 196: `handle_call({:ensure_subscription, ...})` - Subscription creation
  - Line 373: `handle_info({:ws_connected, ...})` - Connection established (FIXED)
  - Line 424: `handle_disconnect/2` - Connection lost cleanup

### WebSocket Connection
- `lib/lasso/core/transport/websocket/connection.ex`
  - Line 76: `@connection_stability_ms 5_000` - Stability threshold
  - Line 134: `connection_stable: false` - Stability state (ADDED)
  - Line 169: `handle_continue(:connect)` - Connection attempt
  - Line 378: `handle_info({:ws_connected})` - Connection established
  - Line 466: `handle_info({:ws_disconnect, :close_frame, ...})` - Graceful close (FIXED)
  - Line 560: `handle_info({:ws_disconnect, :error, ...})` - Error disconnect (FIXED)
  - Line 724: `handle_info({:connection_stable})` - Stability timer fired (FIXED)

### Circuit Breaker
- `lib/lasso/core/support/circuit_breaker.ex`
  - Line 1078: `record_failure/2` - Async failure recording
  - Line 1089: `record_failure_sync/3` - Sync failure recording (ADDED)
  - Line 482: `handle_call({:report_external_sync, ...})` - Sync handler (ADDED)
  - Line 811: `handle_failure/2` - Process failure and update state

### HealthProbe
- `lib/lasso/core/health_probe/worker.ex`
  - Line 344: `CircuitBreaker.signal_recovery` - WS probe success (CONCERN)

---

## Contributors

- Investigation and fixes: Claude Sonnet 4.5 & Jackson Ernst
- Original circuit breaker changes (814d112): Claude Opus 4.5 & Jackson Ernst

---

**Last Updated:** 2026-01-26
**Document Version:** 1.0
