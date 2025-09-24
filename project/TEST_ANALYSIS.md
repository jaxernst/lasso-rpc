# Test Analysis & Categorization

## Test Files Status Analysis

### ✅ KEEP & FIX - Good intent, fixable implementation

**1. `test/livechain/rpc/circuit_breaker_test.exs`**
- **Status**: Good implementation, working logic
- **Issues**: None major - tests circuit breaker behavior correctly
- **Action**: Keep as-is, maybe add more edge cases

**2. `test/livechain/rpc/provider_pool_test.exs`**
- **Status**: Good intent, mostly working
- **Issues**: Complex setup but tests core provider selection logic
- **Action**: Keep & refine - tests EMA updates, strategy selection

**3. `test/livechain/rpc/selection_test.exs`**
- **Status**: Good intent, some working tests
- **Issues**: Some tests may fail due to config dependencies
- **Action**: Keep & fix - tests core provider selection strategies

**4. `test/integration/failover_test.exs`**
- **Status**: Good intent, comprehensive failover testing
- **Issues**: Heavy mocking, some empty test blocks
- **Action**: Keep structure, implement missing tests, reduce mocking

**5. `test/livechain/error_scenarios_test.exs`**
- **Status**: Good intent, tests circuit breaker properly
- **Issues**: Missing real error scenario tests
- **Action**: Keep & expand - add more realistic error scenarios

### 🔧 SCRAP IMPLEMENTATION, KEEP INTENT

**6. `test/livechain_web/controllers/rpc_controller_test.exs`**
- **Status**: Mostly empty placeholder
- **Issues**: Only tests controller existence, no real HTTP testing
- **Action**: Scrap current, rewrite as proper HTTP integration tests
- **Intent**: Test HTTP JSON-RPC request handling

**7. `test/livechain/rpc/live_stream_test.exs`**
- **Status**: Empty placeholder with good structure
- **Issues**: Marked as `:skip`, no implementation
- **Action**: Scrap current, rewrite when subscription system is stable
- **Intent**: Test live WebSocket subscription streaming

**8. `test/livechain/rpc/endpoint_test.exs`**
- **Status**: Unknown (need to examine)
- **Issues**: Likely placeholder
- **Action**: Examine and likely scrap/rewrite

**9. `test/livechain/rpc/chain_supervisor_test.exs`**
- **Status**: Unknown (need to examine)
- **Issues**: Likely has outdated module references
- **Action**: Examine and likely scrap/rewrite

**10. `test/livechain/rpc/ws_connection_test.exs`**
- **Status**: Unknown (need to examine)
- **Issues**: Likely outdated WebSocket testing
- **Action**: Examine and likely scrap/rewrite for new WS architecture

### 🗑️ SCRAP ENTIRELY

**11. `test/livechain_web/controllers/health_controller_test.exs`**
- **Status**: Likely only tests endpoint existence
- **Issues**: Health endpoints are trivial
- **Action**: Scrap - health endpoints can be tested manually
- **Reasoning**: Not worth maintaining tests for simple status endpoints

**12. `test/livechain_web/controllers/status_controller_test.exs`**
- **Status**: Likely only tests endpoint existence
- **Issues**: Status endpoints are trivial
- **Action**: Scrap - status can be tested manually
- **Reasoning**: Not worth maintaining tests for simple status endpoints

**13. `test/livechain/config/chain_config_test.exs`**
- **Status**: Likely tests YAML parsing
- **Issues**: Configuration testing is low value
- **Action**: Scrap - config validation happens at runtime
- **Reasoning**: YAML parsing is handled by library, validation tested elsewhere

## Priority Action Plan

### Immediate (Week 1)
1. ✅ Fix compilation issues (DONE)
2. Keep `circuit_breaker_test.exs` - already working
3. Examine and fix `provider_pool_test.exs`
4. Examine and fix `selection_test.exs`

### Week 2
1. Scrap placeholder controllers tests entirely
2. Rewrite `rpc_controller_test.exs` as proper HTTP integration tests
3. Fix `failover_test.exs` implementation gaps

### Week 3
1. Examine chain_supervisor, ws_connection, endpoint tests
2. Scrap what's broken beyond repair
3. Rewrite critical missing tests

### Week 4+
1. Implement new subscription system tests
2. Live stream testing (once subscription architecture is stable)
3. Performance and load testing

## Test Coverage Gaps

### Critical Missing Tests
1. **HTTP Request Lifecycle**: Request → Strategy → Provider → Response
2. **WebSocket Subscription Lifecycle**: Connect → Subscribe → Failover → Continuity
3. **Provider Health Monitoring**: Real provider failure detection
4. **JSON-RPC Compliance**: Full eth_* method support validation
5. **Multi-chain Behavior**: Different chains operating independently

### Lower Priority Missing Tests
1. Configuration validation
2. Dashboard functionality
3. Telemetry and metrics collection
4. Performance benchmarking
5. Memory leak detection

## Recommendations

1. **Start with working tests** - Fix `provider_pool_test.exs` and `selection_test.exs` first
2. **Delete dead weight** - Remove placeholder controller tests immediately
3. **Focus on integration** - Build HTTP and WebSocket flow tests
4. **Test real behavior** - Less mocking, more actual provider interaction
5. **Defer complex tests** - Subscription multiplexing tests wait until architecture stabilizes