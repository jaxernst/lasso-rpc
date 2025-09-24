# Lasso RPC Testing Strategy

## Current State Assessment

### Issues Found
- Missing `SubscriptionManager` module referenced in tests
- Most tests are empty placeholders or only check function existence
- Heavy mock usage with limited real integration testing
- Outdated references to modules that may not exist
- No end-to-end request lifecycle validation

### Working Components
- Core HTTP routing (`rpc_controller.ex:58-548`)
- Provider selection strategies (`selection.ex:35-166`)
- Circuit breaker implementation (`circuit_breaker_test.exs:46-95`)
- Configuration management (`chains.yml:4-334`)

## Phase 1: Manual Testing & Immediate Validation

### Manual Testing Checklist

Start with these manual tests to validate core functionality:

```bash
# 1. Basic HTTP RPC endpoints
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 2. Test all routing strategies
curl -X POST http://localhost:4000/rpc/fastest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl -X POST http://localhost:4000/rpc/cheapest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl -X POST http://localhost:4000/rpc/priority/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

curl -X POST http://localhost:4000/rpc/round-robin/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 3. Test provider override
curl -X POST http://localhost:4000/rpc/ethereum_ankr/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 4. Test batch requests
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2}
  ]'

# 5. Test WebSocket subscriptions
wscat -c ws://localhost:4000/rpc/ethereum
> {"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}

# 6. Test health endpoints
curl http://localhost:4000/api/health
curl http://localhost:4000/api/status
curl http://localhost:4000/api/metrics/ethereum

# 7. Test error conditions
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_sendTransaction","params":[],"id":1}'
```

### Manual Failover Testing

```bash
# Test provider failover by temporarily blocking a provider
# 1. Get current provider status
curl http://localhost:4000/api/status

# 2. Make requests and observe provider switching
for i in {1..10}; do
  curl -X POST http://localhost:4000/rpc/fastest/ethereum \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":'$i'}' \
    && echo " - Request $i"
done
```

## Phase 2: Fix Broken Tests & Core Unit Tests

### Priority Fixes
1. **Remove SubscriptionManager references** from `test_helper.exs:70-73`
2. **Fix compilation warnings** in live stream tests
3. **Complete placeholder tests** in `rpc_controller_test.exs:23`

### Critical Unit Tests to Write
```bash
# Focus on these modules first:
test/livechain/rpc/strategy/fastest_test.exs
test/livechain/rpc/strategy/cheapest_test.exs
test/livechain/rpc/strategy/priority_test.exs
test/livechain/rpc/strategy/round_robin_test.exs
test/livechain/rpc/failover_test.exs
test/livechain/rpc/provider_health_monitor_test.exs
test/livechain/config/config_store_test.exs
```

## Phase 3: Integration Tests

### HTTP Request Lifecycle Testing
```elixir
# test/integration/http_request_flow_test.exs
defmodule Integration.HttpRequestFlowTest do
  use LivechainWeb.ConnCase, async: false

  test "full HTTP request flow with real providers" do
    # Test: Request -> Strategy -> Provider -> Response -> Metrics
  end

  test "strategy switching works under different conditions" do
    # Test all 4 strategies with same request
  end

  test "provider failover during request" do
    # Simulate provider failure mid-request
  end
end
```

### WebSocket Integration Testing
```elixir
# test/integration/websocket_flow_test.exs
defmodule Integration.WebSocketFlowTest do
  test "subscription lifecycle with multiple providers" do
    # Test: Connect -> Subscribe -> Provider failover -> Data continuity
  end

  test "multiplexed subscription failover" do
    # Multiple clients, provider fails, all maintain subscriptions
  end
end
```

## Phase 4: End-to-End Tests

### JSON-RPC Compliance Testing
```elixir
# test/e2e/json_rpc_compliance_test.exs
defmodule E2E.JsonRpcComplianceTest do
  # Test against https://ethereum.github.io/execution-apis/api-documentation/

  test "supports all eth_* read methods" do
    methods = [
      "eth_blockNumber", "eth_getBalance", "eth_getBlockByNumber",
      "eth_getBlockByHash", "eth_getTransactionCount", "eth_getCode",
      "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_getLogs"
    ]
    # Test each method with multiple providers
  end

  test "rejects write methods properly" do
    # Ensure eth_sendTransaction, etc. are blocked
  end

  test "handles malformed requests according to JSON-RPC spec" do
    # Invalid JSON, missing fields, wrong version, etc.
  end
end
```

### Multi-Chain Testing
```bash
# Enable polygon, base chains in chains.yml for testing
mix test --only multi_chain
```

## Phase 5: Performance & Load Testing

### Latency & Throughput Testing
```elixir
# test/load/performance_test.exs
defmodule Load.PerformanceTest do
  test "concurrent request handling" do
    # 1000 concurrent eth_blockNumber requests
    # Measure: latency, throughput, error rate
  end

  test "strategy performance under load" do
    # Compare all 4 strategies under identical load
  end

  test "provider health monitoring accuracy" do
    # Inject controlled failures, verify detection
  end
end
```

### Memory & Resource Testing
```bash
# Long-running tests for memory leaks
mix test --only long_running --timeout 600000
```

## Phase 6: Chaos & Reliability Testing

### Failure Simulation
```elixir
# test/chaos/provider_failure_test.exs
defmodule Chaos.ProviderFailureTest do
  test "all providers fail simultaneously" do
    # Verify graceful degradation
  end

  test "network partitions and recovery" do
    # Simulate network splits
  end

  test "rapid provider state changes" do
    # Providers flapping between healthy/unhealthy
  end
end
```

## Implementation Priority

1. **Week 1**: Manual testing + fix broken tests
2. **Week 2**: Core unit tests for strategies and failover
3. **Week 3**: HTTP/WebSocket integration tests
4. **Week 4**: JSON-RPC compliance + multi-chain testing
5. **Week 5**: Performance testing + optimization
6. **Week 6**: Chaos testing + reliability validation

## Testing Infrastructure Needs

```bash
# Add to mix.exs test dependencies:
{:stream_data, "~> 0.5", only: :test}     # Property-based testing
{:benchee, "~> 1.0", only: :test}         # Performance benchmarking
{:wallaby, "~> 0.30", only: :test}        # Browser testing for dashboard
{:bypass, "~> 2.1", only: :test}          # Mock HTTP server for provider simulation
```

## Recommended Test Commands

```bash
# Run specific test phases
mix test --only unit
mix test --only integration
mix test --only e2e
mix test --only load
mix test --only chaos

# CI/CD pipeline tests
mix test --include integration --exclude load --exclude chaos
```

## Key Recommendations

1. **Start with manual testing** to validate basic functionality immediately
2. **Fix existing broken tests** before writing new ones
3. **Focus on integration tests** over heavy unit testing - your system's value is in provider orchestration
4. **Test real provider interactions** rather than just mocking everything
5. **Include chaos testing** early - resilience is your core value proposition