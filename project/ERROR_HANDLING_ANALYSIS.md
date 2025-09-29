# Error Handling & Failover Architecture Analysis

## Executive Summary

Your error handling system is **fundamentally sound** but has some **semantic gaps** and **integration inconsistencies** that could prevent it from achieving your stated goals. The `retriable?` flag is a good start, but the system needs clearer error semantics and tighter integration between components.

**Overall Grade: B+ (Solid foundation with room for optimization)**

---

## Core Goals Assessment

### Goal 1: Fast Failover on Transient Errors ✅ **ACHIEVED**

- **Status**: Working as designed
- **Evidence**: `RequestPipeline` checks `retriable?` flag and immediately tries next provider
- **Latency**: Single network roundtrip + selection overhead (~50-200ms typical)

### Goal 2: Support Both HTTP & WebSocket ⚠️ **PARTIALLY ACHIEVED**

- **HTTP**: Fully supported with circuit breakers and failover
- **WebSocket**: Circuit breakers work, but failover **NOT** integrated
- **Gap**: WS subscriptions don't failover automatically; reconnection is manual

### Goal 3: Strong Request Fulfillment Guarantees ⚠️ **NEEDS IMPROVEMENT**

- **Issue**: Max failover attempts configurable per-method, but no circuit to guarantee request completion
- **Missing**: Timeout budget management across failover attempts
- **Edge Case**: All providers down → user gets error (correct), but no retry hints

---

## Detailed Component Analysis

### 1. Error Classification (`retriable?` flag)

#### ✅ **What Works Well**

```elixir
# From JError.assess_retriability/1
# Properly non-retriable (client errors):
- @invalid_request (-32600)
- @method_not_found (-32601)
- @invalid_params (-32602)
- @user_rejected (4001)
- @unauthorized (4100)

# Properly retriable (transient):
- Server errors (-32000 to -32099)
- Rate limits (429)
- Network errors
- HTTP 5xx errors
```

#### ⚠️ **Semantic Issues**

**Problem 1: Parse Errors Are Retriable**

```elixir
# Current:
@parse_error (-32700) → retriable?: true

# Reality: Parse errors indicate:
# - Provider sent malformed JSON (retriable)
# - OR client sent bad request (non-retriable)
#
# Without context, you can't tell!
```

**Recommendation**: Add `direction` field to JError:

- `:upstream_parse_error` → retriable (provider's fault)
- `:downstream_parse_error` → non-retriable (client's fault)

**Problem 2: Default to Non-Retriable**

```elixir
# From assess_retriability/1:
true -> false  # Default for unknown codes
```

This is **safe but pessimistic**. For a multi-provider system optimizing for availability, consider:

- Default to `true` for unknown codes
- Log unknown codes as warnings for investigation
- Let circuit breakers protect against bad defaults

---

### 2. Circuit Breaker Integration

#### ✅ **Excellent Design**

```elixir
# From CircuitBreaker.classify_and_handle_result/2:
{:error, %JError{retriable?: true}} -> handle_failure()
{:error, %JError{retriable?: false}} -> handle_non_breaker_error()
```

**This is exactly right**:

- User errors (400s, invalid params) don't trip circuit breaker
- Infrastructure errors (timeouts, 500s) increment failure counter
- Circuit opens after N consecutive retriable failures

#### ⚠️ **Edge Case: Rate Limits**

```elixir
# Rate limits (429) are currently:
retriable?: true  # ✅ Correct for failover
category: :rate_limit  # ✅ Correct semantics

# BUT in CircuitBreaker:
# Treats rate limits same as timeouts/errors
```

**Problem**: A provider hitting rate limits will trip its circuit breaker, preventing it from recovering when rate limit expires.

**Recommendation**: Add `affects_circuit_breaker?` field:

```elixir
# In JError:
%JError{
  code: 429,
  retriable?: true,              # ✅ Trigger failover
  affects_circuit_breaker?: false # ❌ Don't count as failure
}
```

Rationale: Rate limits are **capacity issues**, not **health issues**. The provider is healthy but at capacity. Circuit breakers are for health problems.

---

### 3. Failover Logic

#### ✅ **Strong Implementation**

```elixir
# From RequestPipeline.execute_with_failover/5:
1. Try primary provider through CircuitBreaker
2. On retriable error → failover
3. Select next provider (excludes failed ones)
4. Recurse until success or max attempts

# Circuit breaker check happens first:
CircuitBreaker.call({provider_id, :http}, fn -> ... end)
# If open → returns {:error, :circuit_open} → triggers failover
```

**This is beautiful**:

- Circuit-open providers are automatically skipped
- Provider selection respects circuit state
- Failed providers excluded from retry pool

#### ⚠️ **Missing: Timeout Budget Management**

```elixir
# Current:
def execute_with_failover(chain, method, params, strategy, provider_id, opts) do
  timeout = Keyword.get(opts, :timeout, 30_000)  # Fixed per attempt

  # Attempt 1: 30s timeout
  # Attempt 2: 30s timeout
  # Attempt 3: 30s timeout
  # Total: 90s possible!
end
```

**Problem**: Client might timeout before all failover attempts complete.

**Recommendation**: Implement timeout budget:

```elixir
defp try_failover_with_budget(chain, method, params, strategy, excluded, attempt, start_time, total_timeout) do
  elapsed = System.monotonic_time(:millisecond) - start_time
  remaining = total_timeout - elapsed

  if remaining < min_timeout_threshold() do
    {:error, JError.new(-32000, "Timeout budget exhausted")}
  else
    # Use remaining time for this attempt
    execute_failover_attempt(..., timeout: remaining)
  end
end
```

---

### 4. WebSocket Error Handling

#### ✅ **Excellent Error Normalization**

Your consolidation into `ErrorNormalizer` is **exactly right**:

```elixir
# All WS errors normalize to JError with proper metadata:
normalize(:not_connected, opts) →
  %JError{
    code: -32000,
    message: "WebSocket not connected",
    retriable?: true,
    transport: :ws,
    category: :network_error
  }
```

#### ⚠️ **Missing: WS Failover for Unary Requests**

```elixir
# Current (RequestPipeline):
protocol: :http  # Hard-coded!

# From try_failover_with_reporting/6:
Selection.select_provider(chain, method,
  strategy: strategy,
  protocol: :http,  # ← WebSocket never considered!
  exclude: excluded
)
```

**Problem**: Even though WS supports unary requests via `Transport.WebSocket.request/3`, the failover logic never uses WS providers.

**Your TRANSPORT_AGNOSTIC_ARCHITECTURE.md explicitly calls this out as a goal**:

> "A single request pipeline that can route any read-only JSON-RPC request to the best upstream path among HTTP and WebSocket channels"

**Recommendation**:

1. Add `preferred_protocol` to failover opts (default: `:any`)
2. On HTTP failure, try WS if available
3. Track latency separately per transport+method

---

### 5. Subscription Failover

#### ❌ **Not Implemented**

```elixir
# From UpstreamSubscriptionPool:
# Manual reconnection with exponential backoff
# No automatic failover to alternate providers
```

**This is acceptable** because:

- Subscriptions are stateful (subscription IDs)
- Seamless failover requires state synchronization
- Better to reconnect than risk message loss

**But you could improve**:

1. Add "preferred backup provider" config
2. On disconnect → try backup before reconnecting to primary
3. Use GapFiller to replay missed blocks

---

## Error Flow Analysis

### Scenario 1: Timeout on Provider A (HTTP)

```
User Request
  → RequestPipeline.execute_with_failover
    → CircuitBreaker.call({provider_a, :http}, fn -> ... end)
      → Transport.HTTP.forward_request
        → Finch.request (timeout!)
          ← {:error, :timeout}
      ← {:error, :timeout}
    ← {:error, :timeout}

  → Normalize to JError{retriable?: true}
  → Check: should_failover? YES

  → try_failover_with_reporting
    → Selection.select_provider (exclude: [provider_a])
      ← {:ok, provider_b}

    → CircuitBreaker.call({provider_b, :http}, fn -> ... end)
      → Transport.HTTP.forward_request
        ← {:ok, result}
      ← {:ok, result}
    ← {:ok, result}

  ← {:ok, result}
```

**✅ Latency: ~30s (timeout) + ~100ms (selection) + ~200ms (provider_b)**

**Total: ~30.3s** (acceptable given timeout was necessary)

---

### Scenario 2: Provider A Circuit Opens

```
User Request (5th failure in row)
  → RequestPipeline.execute_with_failover
    → CircuitBreaker.call({provider_a, :http}, fn -> ... end)
      [Circuit closed, has 4 failures]
      → Transport.HTTP.forward_request
        → Finch.request
          ← {:error, :econnrefused}
      ← {:error, :econnrefused}

      [Failure #5 → Circuit OPENS]
      ← {:error, :circuit_opening}
    ← {:error, :circuit_opening}

  → Normalize to JError{retriable?: true}
  → try_failover_with_reporting
    → Selection.select_provider (exclude: [provider_a])
      [provider_a circuit is open, automatically excluded]
      ← {:ok, provider_b}

    → SUCCESS with provider_b
  ← {:ok, result}
```

**✅ Latency: ~100ms (refused connection) + ~100ms (selection) + ~200ms (provider_b)**

**Total: ~400ms** (excellent!)

**Next Request:**

```
User Request #2
  → RequestPipeline.execute_with_failover
    → Selection.select_provider
      [provider_a circuit still open, excluded automatically]
      ← {:ok, provider_b} (selected first!)
    → SUCCESS with provider_b
  ← {:ok, result}
```

**✅ Latency: ~100ms (selection) + ~200ms (provider_b)**

**Total: ~300ms** (no wasted time on provider_a!)

---

### Scenario 3: Invalid Params (Non-Retriable)

```
User Request (bad params)
  → RequestPipeline.execute_with_failover
    → CircuitBreaker.call({provider_a, :http}, fn -> ... end)
      → Transport.HTTP.forward_request
        → Finch.request
          ← {:ok, %{"error" => %{"code" => -32602, "message" => "Invalid params"}}}
      ← {:ok, response}

      [CircuitBreaker classifies]:
      JError{code: -32602, retriable?: false}
      → handle_non_breaker_error() (doesn't count as failure!)

      ← {:ok, error_response}
    ← {:ok, error_response}

  → Normalize to JError{retriable?: false}
  → Check: should_failover? NO

  ← {:error, JError{code: -32602}}
```

**✅ No wasted failover attempts**
**✅ Circuit breaker state unchanged**
**✅ Latency: ~200ms (single roundtrip)**

---

## Gaps & Recommendations Summary

### Priority 1: Critical

1. **Timeout Budget Management**

   - Track total elapsed time across failover attempts
   - Ensure total time < client timeout
   - Prevents false positives from slow failover chains

2. **WebSocket Failover for Unary Requests**

   - Let failover try WS providers when HTTP fails
   - Honors your transport-agnostic architecture goals
   - Could reduce latency for providers with faster WS

3. **Rate Limit Handling**
   - Add `affects_circuit_breaker?` field
   - Don't penalize providers for capacity issues
   - Allows them to recover when rate limit window resets

### Priority 2: Important

4. **Parse Error Context**

   - Distinguish upstream vs downstream parse errors
   - Add `direction: :inbound | :outbound` field
   - Improves error reporting and classification

5. **Method-Specific Circuit Breakers**

   - Some methods fail more than others
   - Consider per-method failure thresholds
   - Allows fine-grained health tracking

6. **Explicit Non-Retriable Codes**
   - Document all non-retriable error codes
   - Add tests for each classification
   - Prevents silent misclassification

### Priority 3: Nice to Have

7. **Subscription Failover**

   - Automatically try backup provider on disconnect
   - Use GapFiller for seamless transitions
   - Improves subscription reliability

8. **Hedged Requests**

   - For critical methods, send parallel requests
   - Take first successful response
   - Reduces tail latency at cost of throughput

9. **Adaptive Timeouts**
   - Learn typical latency per provider+method
   - Set timeouts to p99 + buffer
   - Reduces wasted time on slow providers

---

## Code Quality Assessment

### ✅ **Strengths**

1. **Unified Error Type**: `JError` with rich metadata
2. **Clear Separation**: Transport/Circuit/Failover concerns separated
3. **Telemetry Integration**: Metrics at every decision point
4. **Circuit Breaker Design**: Proper state machine with recovery
5. **Error Normalization**: Single source of truth (`ErrorNormalizer`)

### ⚠️ **Weaknesses**

1. **Implicit Assumptions**: Some error semantics not documented
2. **Incomplete WebSocket Integration**: Missing from failover path
3. **No Timeout Budget**: Can exceed client expectations
4. **Rate Limit Treatment**: Conflates capacity with health
5. **Limited Testing**: Edge cases not fully covered

---

## Conclusion

**You're on the right track.** The `retriable?` flag is a solid foundation, and your circuit breaker integration is exemplary. The main issues are:

1. **Timeout management** - easily fixable
2. **WebSocket failover** - architectural work but straightforward
3. **Rate limit handling** - semantic refinement

The system **will** provide fast failover for transient errors. It **will** leverage circuit breakers effectively. But it **won't** fully achieve your multi-transport vision without WebSocket failover support.

**Recommendation**: Implement Priority 1 items to unlock your stated goals. The rest are optimizations that can wait for production feedback.

---

## Next Steps

1. Add timeout budget tracking to `RequestPipeline`
2. Extend failover to consider WS providers
3. Add `affects_circuit_breaker?` field for rate limits
4. Write integration tests for:
   - Multi-attempt failover with timeouts
   - HTTP → WS failover
   - Rate limit handling
   - Circuit breaker recovery
