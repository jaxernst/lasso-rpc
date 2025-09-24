# Priority Action Plan for Test Cleanup

## Immediate Actions (Do Now)

### 1. DELETE Dead Weight Tests
These provide no value and waste time:

```bash
# Delete these files entirely:
rm test/livechain_web/controllers/health_controller_test.exs
rm test/livechain_web/controllers/status_controller_test.exs
rm test/livechain/config/chain_config_test.exs
```

**Reasoning**: These only test module existence or trivial endpoints. Manual testing is sufficient.

### 2. KEEP & READY TO USE (High Value, Working)
- ✅ `test/livechain/rpc/circuit_breaker_test.exs` - **Working well, keep as-is**
- ✅ `test/livechain/error_scenarios_test.exs` - **Good circuit breaker testing, keep**

### 3. FIX IMMEDIATELY (High Value, Mostly Working)

**Priority 1: `test/livechain/rpc/provider_pool_test.exs`**
- Status: Core functionality working
- Issues: Complex setup but tests critical provider selection
- Action: Run tests, fix any failures, keep as-is

**Priority 2: `test/livechain/rpc/selection_test.exs`**
- Status: Tests critical provider selection strategies
- Issues: May have config dependencies
- Action: Run tests, fix config-related failures

## Short Term (Next 2 Weeks)

### 4. SCRAP & REWRITE (Good Intent, Bad Implementation)

**Priority 3: `test/livechain_web/controllers/rpc_controller_test.exs`**
- Current: Empty placeholder testing module existence
- Action: Delete current content, rewrite as HTTP integration tests
- New focus: Test full HTTP request lifecycle

**Priority 4: `test/livechain/rpc/chain_supervisor_test.exs`**
- Current: Comprehensive but mostly integration testing
- Issues: Heavy mocking, some empty test blocks
- Action: Keep structure, fill in missing implementations, reduce mocking

**Priority 5: `test/integration/failover_test.exs`**
- Current: Good failover testing structure
- Issues: Many empty test blocks, heavy mocking
- Action: Implement missing test bodies, test real failover scenarios

### 5. EXAMINE & DECIDE (Unknown Quality)

**`test/livechain/rpc/endpoint_test.exs`**
- Status: Comprehensive validation testing
- Assessment: **SCRAP** - Tests a validation module that may not exist or be relevant
- Action: Delete if `Livechain.RPC.Endpoint` module doesn't exist in current codebase

**`test/livechain/rpc/ws_connection_test.exs`**
- Status: Unknown - need to examine
- Assessment: Likely outdated due to new subscription architecture
- Action: Examine, likely scrap and rewrite for new WS architecture

## Medium Term (Weeks 3-4)

### 6. DEFER UNTIL ARCHITECTURE STABLE

**`test/livechain/rpc/live_stream_test.exs`**
- Status: Empty placeholder with `:skip` tag
- Action: Leave as placeholder until subscription multiplexing is stable
- Future: Rewrite as comprehensive WebSocket subscription tests

## Immediate Command Sequence

Run these commands to start cleanup:

```bash
# 1. Delete dead weight
rm test/livechain_web/controllers/health_controller_test.exs
rm test/livechain_web/controllers/status_controller_test.exs
rm test/livechain/config/chain_config_test.exs

# 2. Check if Endpoint module exists
mix compile && iex -S mix
# In IEx: Code.ensure_loaded?(Livechain.RPC.Endpoint)
# If false, delete: rm test/livechain/rpc/endpoint_test.exs

# 3. Run working tests to verify they pass
mix test test/livechain/rpc/circuit_breaker_test.exs
mix test test/livechain/error_scenarios_test.exs

# 4. Test and fix core tests
mix test test/livechain/rpc/provider_pool_test.exs
mix test test/livechain/rpc/selection_test.exs

# 5. If any fail, fix them one by one
```

## Success Metrics

**Week 1 Success**:
- [ ] Dead weight tests deleted
- [ ] Circuit breaker tests passing
- [ ] Provider pool tests passing
- [ ] Selection tests passing
- [ ] Test compilation warnings eliminated

**Week 2 Success**:
- [ ] RPC controller rewritten as HTTP integration tests
- [ ] Chain supervisor tests cleaned up and working
- [ ] Failover tests implemented and passing

**Overall Goal**: Get from "broken test suite with warnings" to "core tests passing and covering critical functionality"

## What NOT to Do

1. **Don't fix every test** - Some should be deleted
2. **Don't over-engineer** - Focus on tests that validate your core value proposition
3. **Don't test libraries** - Skip testing YAML parsing, HTTP clients, etc.
4. **Don't write subscription tests yet** - Architecture is still evolving

## Focus Areas

1. **Provider selection strategies** (fastest, cheapest, priority, round-robin)
2. **Circuit breaker and failover behavior**
3. **HTTP JSON-RPC request handling**
4. **Provider health monitoring**

These are your core differentiators and need solid test coverage.