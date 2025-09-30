# Lasso RPC: North Star Objectives Assessment

**Date:** September 29, 2025
**Assessment Type:** Pre-Demo Gap Analysis
**Focus Areas:** WebSocket Subscriptions, Failover, Provider Coverage, Integration Testing

---

## Executive Summary

Lasso RPC has achieved **~70% of its core north star objectives**, with strong fundamentals in place for HTTP RPC aggregation, intelligent routing, and fault tolerance. However, **WebSocket subscriptions** and real-time stream reliability represent a significant gap that must be addressed before client-facing demos.

### Assessment Score: 7/10 🟡

**Strengths:**
- ✅ Multi-provider HTTP RPC aggregation working
- ✅ 4 routing strategies implemented (fastest, cheapest, priority, round-robin)
- ✅ Circuit breaker and failover infrastructure in place
- ✅ Comprehensive OTP architecture for supervision and fault isolation
- ✅ Battle testing framework (Phase 1 & 2) complete

**Critical Gaps:**
- ❌ WebSocket subscriptions broken in production (1011 disconnect errors)
- ❌ No working integration tests for WebSocket failover
- ❌ Provider configuration too minimal (only 3-4 providers per chain)
- ❌ Stream backfilling untested in real scenarios
- ❌ Missing Jason.Encoder implementations causing API crashes

---

## 1. North Star Objectives Review

### From @PRODUCT_VISION.md and @README.md:

| Objective | Status | Evidence | Gap |
|-----------|--------|----------|-----|
| **Multi-provider orchestration** | ✅ 85% | HTTP working, WS broken | WebSocket provider failover not validated |
| **Full JSON-RPC compatibility** | 🟡 75% | HTTP endpoints working, WS unstable | eth_subscribe crashes with 1011 error |
| **Intelligent routing** | ✅ 90% | 4 strategies, method-specific benchmarking | Need more providers for true "intelligent" selection |
| **Method failover with circuit breakers** | 🟡 70% | Circuit breakers working, failover logic present | No integration tests proving it works end-to-end |
| **Live dashboard** | ✅ 80% | Dashboard accessible | Status endpoint crashes (Jason.Encoder missing) |
| **Reliability guarantees** | ❌ 40% | Infrastructure present, not validated | Cannot prove 99%+ uptime without working WS + tests |

---

## 2. WebSocket Subscription Deep Dive

### Architecture Assessment ✅

**Excellent Design:**
The WebSocket subscription architecture is sophisticated and well-thought-out:

```
┌─────────────────┐
│  RPCChannel     │  ← Phoenix WebSocket endpoint
│  (per-client)   │
└────────┬────────┘
         │
         ↓
┌─────────────────────────┐
│ SubscriptionRouter      │  ← Thin routing facade
└────────┬────────────────┘
         │
         ↓
┌──────────────────────────────┐
│ UpstreamSubscriptionPool     │  ← Multiplexes client subscriptions
│ (per-chain GenServer)        │     to minimal upstream connections
└────────┬─────────────────────┘
         │
         ↓
┌──────────────────────────────┐
│ StreamCoordinator            │  ← Owns continuity: markers, dedupe,
│ (per-key GenServer)          │     backfill orchestration
└────────┬─────────────────────┘
         │
         ↓
┌──────────────────────────────┐
│ GapFiller + ContinuityPolicy │  ← HTTP backfill logic
└──────────────────────────────┘
```

**Key Features:**
- **Subscription multiplexing**: Multiple clients subscribe to same upstream subscription (efficiency)
- **Per-key coordinators**: Each subscription type (newHeads, logs with filter) gets own coordinator
- **Failover + backfilling**: When provider dies, coordinator computes gap and backfills via HTTP
- **Dedupe + ordering**: StreamState ensures events are delivered once and in-order
- **Capability discovery**: UpstreamSubscriptionPool tracks which providers support which subscription types

**Files:**
- `lib/livechain/rpc/subscription_router.ex` (30 lines, clean facade)
- `lib/livechain/rpc/upstream_subscription_pool.ex` (443 lines, complex multiplexing logic)
- `lib/livechain/rpc/stream_coordinator.ex` (214 lines, backfill orchestration)
- `lib/livechain/rpc/client_subscription_registry.ex` (148 lines, fan-out to clients)
- `lib/livechain_web/channels/rpc_channel.ex` (216 lines, Phoenix integration)

### Implementation Issues ❌

**Critical Bug 1: WebSocket Channel Protocol Mismatch**

**Problem:** The `RPCChannel` expects messages in Phoenix Channel format (`handle_in("rpc_call", ...)`), but WebSocket clients are sending raw JSON-RPC:

```elixir
# Client sends:
{"jsonrpc":"2.0", "method":"eth_subscribe", "params":["newHeads"], "id":1}

# But RPCChannel expects:
# Phoenix sends this as a "push" on a specific event name
# The channel should handle raw WebSocket frames instead
```

**Evidence:** Log shows `Phoenix.Socket.InvalidMessageError` and connection closes with code 1011.

**Impact:** **WebSocket subscriptions completely non-functional** for standard JSON-RPC clients (Viem, Wagmi, wscat).

**Fix Required:** Implement raw WebSocket handler in `lib/livechain_web/channels/rpc_socket.ex` or use `Phoenix.Socket.Transport` behavior for standard JSON-RPC format.

---

**Critical Bug 2: Jason.Encoder Missing**

**Problem:** `Livechain.RPC.HealthPolicy` struct is not encodable to JSON:

```
Protocol.UndefinedError: protocol Jason.Encoder not implemented
for type Livechain.RPC.HealthPolicy (a struct)
```

**Impact:** `/api/status` endpoint crashes, making system monitoring impossible.

**Fix Required:**
```elixir
# In lib/livechain/rpc/health_policy.ex
@derive {Jason.Encoder, only: [:availability, :consecutive_failures]}
defstruct [...]
```

---

**Gap 3: No Real Provider Connections**

**Problem:** Only 3-4 providers configured per chain, and 2/3 are failing to connect:

```
[error] Failed to connect to Ankr Public (WebSocket): Not Found (code=-32600)
[error] Failed to connect to PublicNode zkSync (WebSocket): Not Found (code=-32600)
[debug] Connected to WebSocket: LlamaRPC
```

**Evidence:** Only ethereum_llamarpc WS connects successfully. This means:
- No real failover testing possible
- "Fastest" routing degenerates to single-provider
- Cannot demonstrate reliability guarantees

**Impact:** **Cannot prove value proposition** without multiple working providers.

**Fix Required:** Expand `config/chains.yml`:
- Ethereum: Add 5-7 providers with WS (Alchemy, Infura, QuickNode, Chainstack)
- Enable more chains: Base, Polygon, Arbitrum, Optimism
- Test each provider's WS endpoint manually before adding

---

## 3. Provider Configuration Coverage

### Current State:

**Ethereum:**
- ✅ ethereum_ankr (Ankr Public) - HTTP ✅, WS ❌
- ✅ ethereum_llamarpc (LlamaRPC) - HTTP ✅, WS ✅
- ✅ ethereum_cloudflare - HTTP only
- 🔴 All others commented out

**zkSync:**
- ✅ zksync_publicnode - HTTP ✅, WS ❌

**Other chains:** All commented out (Polygon, Base, Arbitrum, Optimism, etc.)

### Recommended Configuration (MVP):

**Ethereum (Priority 1):**
1. **Alchemy** (premium, reliable WS)
2. **Infura** (premium, reliable WS)
3. **Ankr** (public, good WS support)
4. **LlamaRPC** (public, decent WS)
5. **QuickNode** (premium option)
6. **Chainstack** (public/premium hybrid)

**Base (Priority 2 - Coinbase ecosystem):**
1. **Base Public RPC** (official)
2. **Ankr Base**
3. **PublicNode Base**
4. **BlastAPI Base**

**Polygon (Priority 3):**
1. **Polygon Official**
2. **Ankr Polygon**
3. **QuickNode Polygon**

### Why This Matters:

- **"Fastest" routing requires >= 3 providers** to be meaningful
- **Failover requires >= 2 working providers** per subscription type
- **Load balancing** (round-robin) needs multiple providers to spread rate limits
- **Demos** are more impressive with 5-7 provider logos on dashboard

---

## 4. Testing & Validation Gaps

### Battle Testing Framework: ✅ Strong Foundation

**Phase 1 Complete:**
- `lib/livechain/battle/scenario.ex` - Fluent API for orchestration
- `lib/livechain/battle/workload.ex` - HTTP workload generation
- `lib/livechain/battle/collector.ex` - Telemetry collection
- `lib/livechain/battle/analyzer.ex` - Percentile calculation, SLO verification
- `lib/livechain/battle/reporter.ex` - JSON + Markdown reports
- 4 passing tests in `test/battle/basic_test.exs`

**Phase 2 Complete:**
- `lib/livechain/battle/chaos.ex` - Kill, flap, degrade providers
- `lib/livechain/battle/test_helper.ex` - Integration test utilities
- Failover detection (>2x avg latency = failover)
- 5 passing chaos tests in `test/battle/chaos_test.exs`

**What's Missing:**
- ❌ No WebSocket workload generation in battle framework
- ❌ No integration tests for `test/battle/failover_test.exs` (330 lines of skeletons)
- ❌ No real provider testing (all use mock providers)
- ❌ No stream backfilling validation

### Integration Test Coverage: 🔴 Poor

From `@TEST_PLAN.md`:
- Circuit breaker tests: ✅ Working
- Provider pool tests: ✅ Working
- Selection tests: ✅ Working
- **Failover tests: ❌ Empty skeletons**
- **WS subscription tests: ❌ Disabled/outdated**
- **Stream tests: ❌ Deferred**

### Recommended Testing Priorities:

**Week 1 (Immediate):**
1. Fix WebSocket channel protocol (make subscriptions work)
2. Add working providers to `chains.yml`
3. Write 1 end-to-end WebSocket test:
   ```bash
   wscat -c ws://localhost:4000/rpc/ethereum
   > {"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
   < {"jsonrpc":"2.0","id":1,"result":"0xabc123"}
   < {"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xabc123","result":{...}}}
   ```

**Week 2 (Validation):**
1. Implement `test/battle/failover_test.exs` scenarios
2. Test WS failover: Kill primary provider, verify backfill + switch
3. Validate SLOs: 95%+ success rate, <500ms P95 latency during failover

**Week 3 (Polish):**
1. Fix `/api/status` (Jason.Encoder)
2. Add WebSocket workload to battle framework
3. Run 10min soak test with chaos (kill providers randomly)

---

## 5. Stream Backfilling Assessment

### Design: ✅ Excellent

`StreamCoordinator.do_backfill_and_switch/3` logic is sophisticated:

```elixir
# 1. Determine last seen block
last = StreamState.last_block_num(state.state)

# 2. Fetch current head from new provider
head = fetch_head(state.chain, new_provider)

# 3. Compute gap with policy (max 32 blocks)
{:range, from_n, to_n} <- ContinuityPolicy.needed_block_range(
  last, head, state.max_backfill_blocks, :best_effort
)

# 4. HTTP backfill via GapFiller
{:ok, blocks} <- GapFiller.ensure_blocks(...)

# 5. Inject backfilled blocks into stream
Enum.each(blocks, fn b ->
  GenServer.cast(self(), {:upstream_event, new_provider, nil, b, timestamp})
end)
```

**Features:**
- Bounded backfill (default 32 blocks)
- Timeout protection (30s default)
- Works for both `newHeads` and `logs`
- Falls back gracefully if gap exceeds limit

### Reality Check: ❌ Untested

**Problem:** Zero integration tests validate this flow works.

**Risks:**
- Does `GapFiller.ensure_blocks` handle rate limits?
- Does dedupe work correctly for backfilled blocks?
- What happens if backfill takes >30s?
- Does client see duplicate events during switch?

**Test Needed:**
```elixir
# Scenario: Provider dies mid-stream, backfill 10 blocks
test "newHeads failover with backfill" do
  # 1. Subscribe to newHeads
  # 2. Receive blocks 100-110
  # 3. Kill provider at block 110
  # 4. Wait 5 seconds (blocks 111-115 missed)
  # 5. Expect: Receive blocks 111-115 (backfilled) + 116 (live)
  # 6. Assert: No duplicates, no gaps
end
```

---

## 6. Gap Analysis: North Star vs Reality

### ✅ What's Working (70%):

| Feature | Status | Evidence |
|---------|--------|----------|
| HTTP RPC aggregation | ✅ Excellent | `curl POST /rpc/ethereum` works |
| Routing strategies | ✅ Excellent | 4 strategies implemented + tested |
| Circuit breakers | ✅ Good | Opens after 5 failures, recovers |
| Method-specific benchmarking | ✅ Good | Passive latency measurement per-method |
| Provider health monitoring | ✅ Good | Telemetry events + PubSub propagation |
| Battle testing framework | ✅ Excellent | Phase 1 & 2 complete, 9 tests passing |
| OTP supervision | ✅ Excellent | Per-chain supervisors, fault isolation |

### ❌ What's Broken/Missing (30%):

| Gap | Severity | Impact | ETA to Fix |
|-----|----------|--------|------------|
| **WebSocket subscriptions** | 🔴 Critical | Cannot do live demos | 3-5 days |
| **Stream backfilling (untested)** | 🔴 Critical | Cannot prove reliability | 5-7 days |
| **Provider coverage** | 🟡 High | Degrades to single-provider routing | 1-2 days |
| **Integration tests** | 🟡 High | Cannot validate failover claims | 7-10 days |
| **Jason.Encoder bugs** | 🟡 Medium | API endpoints crash | 1 hour |
| **Dashboard telemetry** | 🟢 Low | Metrics work, display issues | 2-3 days |

---

## 7. Recommendations

### Immediate Actions (This Week):

1. **Fix WebSocket Channel Protocol** (2-3 days)
   - Implement raw JSON-RPC WebSocket handler
   - Test with wscat: `eth_subscribe` → subscription_id → events
   - Validate with Viem client

2. **Add Working Providers** (1 day)
   - Manually test 5-7 Ethereum WS providers
   - Add to `chains.yml` with known-good configs
   - Verify circuit breakers work with real failures

3. **Fix Jason.Encoder** (1 hour)
   - Add `@derive {Jason.Encoder, only: [...]}` to all structs
   - Test `/api/status` endpoint

4. **Write 1 End-to-End Test** (1 day)
   - `test/integration/websocket_subscription_test.exs`
   - Connect, subscribe, receive 1 event, unsubscribe
   - Proves basic flow works

### Next Sprint (Weeks 2-3):

5. **Implement Failover Tests** (3-5 days)
   - Use battle framework to kill providers during subscriptions
   - Validate backfilling logic with real gaps
   - Measure SLOs: success rate, latency, duplicate rate

6. **Expand Chain Coverage** (2-3 days)
   - Enable Base, Polygon, Arbitrum
   - 3-5 providers per chain
   - Test multi-chain load balancing

7. **Soak Test** (2 days setup, 1 day run)
   - 10min continuous load with chaos (random provider kills)
   - Track: 99%+ success rate, <100ms failover time, 0 duplicates
   - Generate report for stakeholders

### Pre-Demo Checklist:

- [ ] WebSocket `eth_subscribe("newHeads")` works with wscat
- [ ] WebSocket `eth_subscribe("logs", {...})` works with wscat
- [ ] At least 5 providers configured per chain
- [ ] 1 end-to-end failover test passing
- [ ] Dashboard shows provider leaderboard (no crashes)
- [ ] Can demo: Kill provider → automatic failover → no dropped events

---

## 8. Strategic Insights

### What This Assessment Reveals:

**Strengths:**
- **Architecture is production-ready**: The OTP design, supervision trees, and separation of concerns are excellent. This is not a prototype—it's a serious distributed system.
- **Battle testing framework is powerful**: Phase 1 & 2 provide a strong foundation for validation and demos.
- **HTTP path is solid**: Multi-provider routing, circuit breakers, and failover work well for read-only methods.

**Weaknesses:**
- **WebSocket implementation is incomplete**: The architecture is there, but the Phoenix Channel integration is broken. This is the #1 blocker for "consumer-grade reliability" claims.
- **Provider configuration is placeholder-level**: With only 1-2 working providers per chain, you can't demonstrate intelligent routing or failover benefits.
- **Testing is aspirational**: Lots of test skeletons and TODOs, but no integration tests proving the core value proposition (reliability despite provider failures).

### What This Means for Demos:

**Current Demo Capabilities (Today):**
- ✅ "We aggregate 4 routing strategies for HTTP RPC"
- ✅ "We have circuit breakers and automatic retry"
- ✅ "Look at our real-time dashboard"

**Cannot Demo (Yet):**
- ❌ "Subscribe to live block headers via WebSocket"
- ❌ "Watch us kill a provider mid-stream—no dropped events"
- ❌ "99.9% uptime even when providers fail"

**Timeline to Full Demo:**
- **2 weeks**: Fix WS + add providers → Basic subscriptions work
- **3-4 weeks**: Failover tests + soak testing → Can prove reliability claims
- **4-6 weeks**: Polish dashboard + multi-chain → Investor-ready

---

## 9. Conclusion

Lasso RPC is **70% complete** relative to its north star objectives. The core infrastructure is excellent, but **WebSocket subscriptions and real-world validation are the critical path to demonstrating value**.

**Key Takeaway:** You have a strong foundation, but you're not ready for a client-facing demo that emphasizes "bulletproof reliability" until:
1. WebSocket subscriptions work end-to-end
2. You have 5+ working providers per chain
3. At least 1 integration test proves failover + backfilling works

**Estimated Time to Demo-Ready:** 2-3 weeks of focused work on WebSocket protocol fix, provider expansion, and basic integration testing.

**Recommendation:** Prioritize WebSocket fixes over battle testing polish. The architecture is sound—focus on making the happy path work before stress-testing edge cases.

---

## Appendix: Quick Wins

### 1-Hour Fixes:

```elixir
# Fix Jason.Encoder (lib/livechain/rpc/health_policy.ex)
@derive {Jason.Encoder, only: [:availability, :cooldown_until, :consecutive_failures]}
defstruct [...]
```

### 1-Day Wins:

- Test 10 Ethereum WS providers, add 5 known-good ones to `chains.yml`
- Write `scripts/test_websocket_subscription.sh` with wscat for manual validation
- Add `@tag :integration` to existing test skeletons, run subset in CI

### 1-Week Win:

- Fix Phoenix Channel protocol → raw JSON-RPC WebSocket handler
- 1 end-to-end test: connect → subscribe → receive event → unsubscribe
- Demo to internal team

---

**Assessment prepared by:** Claude Code
**Review recommended:** Share with team leads for prioritization