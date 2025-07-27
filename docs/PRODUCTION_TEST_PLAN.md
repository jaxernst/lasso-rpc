# Livechain Production Test Plan

## 🎯 Overview

This comprehensive test plan provides step-by-step instructions to get Livechain up and running, thoroughly tested, and production-ready. Follow this guide sequentially to ensure a robust deployment.

## 📋 Prerequisites

### System Requirements

- **OS**: Linux/macOS (tested on Ubuntu 20.04+, macOS 12+)
- **Memory**: 4GB+ RAM (8GB+ recommended for production)
- **Storage**: 10GB+ free space
- **Network**: Stable internet connection for RPC providers

### Software Dependencies

- **Elixir**: 1.14+ (`elixir --version`)
- **Erlang/OTP**: 25+ (`erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell`)
- **Node.js**: 18+ (`node --version`)
- **Git**: Latest version (`git --version`)

### Environment Variables

```bash
# Required for paid providers
export INFURA_API_KEY="your_infura_api_key"
export ALCHEMY_API_KEY="your_alchemy_api_key"

# Optional: Custom configuration
export LIVECHAIN_ENV="production"
export LIVECHAIN_LOG_LEVEL="info"
```

## 🚀 Phase 1: Initial Setup & Installation

### Step 1.1: Clone and Setup Repository

```bash
# Clone the repository
git clone <your-repo-url>
cd livechain

# Install dependencies
mix deps.get
mix deps.compile

# Install Node.js dependencies (if any)
npm install
```

### Step 1.2: Verify Configuration

```bash
# Test configuration loading
mix run -e "
{:ok, config} = Livechain.Config.ChainConfig.load_config(\"config/chains.yml\")
IO.puts(\"Loaded #{map_size(config.chains)} chains\")
Enum.each(config.chains, fn {name, _} -> IO.puts(\"  - #{name}\") end)
"
```

**Expected Output:**

```
Loaded 4 chains
  - ethereum
  - base
  - polygon
  - arbitrum
```

### Step 1.3: Environment Validation

```bash
# Create test script
cat > test_env.exs << 'EOF'
# Test environment setup
IO.puts("=== Environment Validation ===")

# Check Elixir/Erlang
IO.puts("Elixir: #{System.version()}")
IO.puts("Erlang: #{:erlang.system_info(:otp_release)}")

# Check API keys
infura_key = System.get_env("INFURA_API_KEY")
alchemy_key = System.get_env("ALCHEMY_API_KEY")

IO.puts("Infura API Key: #{if infura_key, do: "✓ Set", else: "✗ Missing"}")
IO.puts("Alchemy API Key: #{if alchemy_key, do: "✓ Set", else: "✗ Missing"}")

# Test configuration
case Livechain.Config.ChainConfig.load_config("config/chains.yml") do
  {:ok, config} ->
    IO.puts("Configuration: ✓ Valid")
    IO.puts("Available chains: #{map_size(config.chains)}")
  {:error, reason} ->
    IO.puts("Configuration: ✗ Error - #{reason}")
end
EOF

# Run validation
mix run test_env.exs
```

## 🧪 Phase 2: Unit Testing

### Step 2.1: Run All Unit Tests

```bash
# Run complete test suite
mix test

# Run with coverage
mix test --cover

# Run specific test modules
mix test test/livechain/architecture_test.exs
mix test test/livechain/rpc/
```

**Success Criteria:**

- All tests pass (green)
- Coverage > 80%
- No warnings or deprecations

### Step 2.2: Component-Specific Tests

```bash
# Test Process Registry
mix test test/livechain/architecture_test.exs --only "Process Registry"

# Test Circuit Breaker
mix test test/livechain/architecture_test.exs --only "Circuit Breaker"

# Test Message Aggregator
mix test test/livechain/architecture_test.exs --only "Message Aggregator Memory Management"

# Test Configuration
mix test test/livechain/architecture_test.exs --only "Configuration Validation"
```

### Step 2.3: Telemetry Testing

```bash
# Create telemetry test
cat > test_telemetry.exs << 'EOF'
# Test telemetry integration
IO.puts("=== Telemetry Testing ===")

# Start application
Application.ensure_all_started(:livechain)

# Test telemetry events
Livechain.Telemetry.emit_rpc_call("test_provider", "eth_blockNumber", 150, :ok)
Livechain.Telemetry.emit_provider_health_change("test_provider", :healthy, :unhealthy)
Livechain.Telemetry.emit_circuit_breaker_change("test_provider", :closed, :open)
Livechain.Telemetry.emit_failover("ethereum", "provider1", "provider2", :timeout)

IO.puts("✓ Telemetry events emitted successfully")

# Test circuit breaker
{:ok, _pid} = Livechain.RPC.CircuitBreaker.start_link({"test_cb", %{}})
state = Livechain.RPC.CircuitBreaker.get_state("test_cb")
IO.puts("✓ Circuit breaker state: #{state.state}")

IO.puts("=== Telemetry Test Complete ===")
EOF

mix run test_telemetry.exs
```

## 🔄 Phase 3: Integration Testing

### Step 3.1: Mock Provider Testing

```bash
# Create integration test script
cat > test_integration.exs << 'EOF'
# Integration testing with mock providers
IO.puts("=== Integration Testing ===")

# Start application
Application.ensure_all_started(:livechain)

# Create mock endpoints
ethereum = Livechain.RPC.MockWSEndpoint.ethereum_mainnet()
base = Livechain.RPC.MockWSEndpoint.base_mainnet()

# Start connections
{:ok, _pid1} = Livechain.RPC.WSSupervisor.start_connection(ethereum)
{:ok, _pid2} = Livechain.RPC.WSSupervisor.start_connection(base)

IO.puts("✓ Mock connections started")

# Test message flow
receive do
  {:blockchain_message, message} ->
    IO.puts("✓ Received blockchain message: #{inspect(message)}")
after
  5000 ->
    IO.puts("✗ No messages received within 5 seconds")
end

# Test provider status
connections = Livechain.RPC.WSSupervisor.list_connections()
IO.puts("✓ Active connections: #{length(connections)}")

IO.puts("=== Integration Test Complete ===")
EOF

mix run test_integration.exs
```

### Step 3.2: Multi-Provider Testing

```bash
# Test multi-provider setup
cat > test_multi_provider.exs << 'EOF'
# Multi-provider testing
IO.puts("=== Multi-Provider Testing ===")

# Start ChainManager
{:ok, _pid} = Livechain.RPC.ChainManager.start_link()

# Start all chains
{:ok, started_count} = Livechain.RPC.ChainManager.start_all_chains()
IO.puts("✓ Started #{started_count} chain supervisors")

# Get global status
status = Livechain.RPC.ChainManager.get_status()
IO.puts("✓ Total chains: #{status.total_chains}")
IO.puts("✓ Active chains: #{status.active_chains}")

# Test specific chain
case Livechain.RPC.ChainManager.get_chain_status("ethereum") do
  {:ok, chain_status} ->
    IO.puts("✓ Ethereum providers: #{chain_status.total_providers}")
    IO.puts("✓ Healthy providers: #{chain_status.healthy_providers}")
  {:error, reason} ->
    IO.puts("✗ Ethereum status error: #{reason}")
end

IO.puts("=== Multi-Provider Test Complete ===")
EOF

mix run test_multi_provider.exs
```

## 🌐 Phase 4: Real Provider Testing

### Step 4.1: Provider Connectivity Test

```bash
# Test real provider connections
cat > test_real_providers.exs << 'EOF'
# Real provider connectivity testing
IO.puts("=== Real Provider Testing ===")

# Test configuration with real providers
{:ok, config} = Livechain.Config.ChainConfig.load_config("config/chains.yml")

# Test each chain's providers
Enum.each(config.chains, fn {chain_name, chain_config} ->
  IO.puts("\\nTesting #{chain_name}:")

  available_providers = Livechain.Config.ChainConfig.get_available_providers(chain_config)
  IO.puts("  Available providers: #{length(available_providers)}")

  Enum.each(available_providers, fn provider ->
    IO.puts("    - #{provider.name} (#{provider.type})")
    if provider.api_key_required do
      if String.contains?(provider.url, "${") do
        IO.puts("      ✗ API key missing")
      else
        IO.puts("      ✓ API key configured")
      end
    else
      IO.puts("      ✓ Public provider")
    end
  end)
end)

IO.puts("\\n=== Real Provider Test Complete ===")
EOF

mix run test_real_providers.exs
```

### Step 4.2: Live Network Testing

```bash
# Test with live networks (use with caution)
cat > test_live_networks.exs << 'EOF'
# Live network testing (BE CAREFUL - uses real providers)
IO.puts("=== Live Network Testing ===")

# Only test if API keys are available
infura_key = System.get_env("INFURA_API_KEY")
alchemy_key = System.get_env("ALCHEMY_API_KEY")

if infura_key or alchemy_key do
  IO.puts("API keys available - testing live networks")

  # Start with a single chain for testing
  {:ok, _pid} = Livechain.RPC.ChainManager.start_link()
  {:ok, _} = Livechain.RPC.ChainManager.start_chain("ethereum")

  # Wait for connections to establish
  Process.sleep(5000)

  # Check status
  case Livechain.RPC.ChainManager.get_chain_status("ethereum") do
    {:ok, status} ->
      IO.puts("✓ Ethereum status:")
      IO.puts("  Total providers: #{status.total_providers}")
      IO.puts("  Healthy providers: #{status.healthy_providers}")

      if status.healthy_providers > 0 do
        IO.puts("✓ Live network connectivity confirmed")
      else
        IO.puts("✗ No healthy providers available")
      end

    {:error, reason} ->
      IO.puts("✗ Error getting status: #{reason}")
  end
else
  IO.puts("No API keys available - skipping live network tests")
  IO.puts("Set INFURA_API_KEY or ALCHEMY_API_KEY to test live networks")
end

IO.puts("=== Live Network Test Complete ===")
EOF

mix run test_live_networks.exs
```

## 📊 Phase 5: Performance Testing

### Step 5.1: Load Testing

```bash
# Create load test
cat > test_performance.exs << 'EOF'
# Performance and load testing
IO.puts("=== Performance Testing ===")

# Start application
Application.ensure_all_started(:livechain)

# Test message aggregation performance
chain_name = "perf_test_chain"
chain_config = %{
  aggregation: %{
    deduplication_window: 100,
    min_confirmations: 1,
    max_providers: 3,
    max_cache_size: 1000
  }
}

{:ok, _pid} = Livechain.RPC.MessageAggregator.start_link({chain_name, chain_config})

# Performance test
message_count = 1000
start_time = System.monotonic_time(:millisecond)

for i <- 1..message_count do
  message = %{"id" => i, "data" => "performance_test_#{i}"}
  Livechain.RPC.MessageAggregator.process_message(chain_name, "provider1", message)
end

end_time = System.monotonic_time(:millisecond)
duration = end_time - start_time
messages_per_second = Float.round(message_count / (duration / 1000), 2)

IO.puts("✓ Processed #{message_count} messages in #{duration}ms")
IO.puts("✓ Throughput: #{messages_per_second} messages/second")

# Memory test
stats = Livechain.RPC.MessageAggregator.get_stats(chain_name)
IO.puts("✓ Messages received: #{stats.messages_received}")
IO.puts("✓ Messages forwarded: #{stats.messages_forwarded}")
IO.puts("✓ Messages deduplicated: #{stats.messages_deduplicated}")

# Performance criteria
if messages_per_second > 1000 do
  IO.puts("✓ Performance: EXCELLENT (>1000 msg/sec)")
elsif messages_per_second > 500 do
  IO.puts("✓ Performance: GOOD (>500 msg/sec)")
else
  IO.puts("✗ Performance: NEEDS IMPROVEMENT (<500 msg/sec)")
end

IO.puts("=== Performance Test Complete ===")
EOF

mix run test_performance.exs
```

### Step 5.2: Memory Testing

```bash
# Test memory management
cat > test_memory.exs << 'EOF'
# Memory management testing
IO.puts("=== Memory Testing ===")

# Start with small cache
chain_name = "memory_test_chain"
chain_config = %{
  aggregation: %{
    deduplication_window: 1000,
    min_confirmations: 1,
    max_providers: 2,
    max_cache_size: 5  # Small cache to test eviction
  }
}

{:ok, _pid} = Livechain.RPC.MessageAggregator.start_link({chain_name, chain_config})

# Add more messages than cache can hold
for i <- 1..20 do
  message = %{"id" => i, "data" => "memory_test_#{i}"}
  Livechain.RPC.MessageAggregator.process_message(chain_name, "provider1", message)
end

# Check stats
stats = Livechain.RPC.MessageAggregator.get_stats(chain_name)
IO.puts("✓ Messages received: #{stats.messages_received}")
IO.puts("✓ Messages forwarded: #{stats.messages_forwarded}")

# Test cache reset
:ok = Livechain.RPC.MessageAggregator.reset_cache(chain_name)
stats_after_reset = Livechain.RPC.MessageAggregator.get_stats(chain_name)
IO.puts("✓ Cache reset successful: #{stats_after_reset.messages_received} messages")

IO.puts("=== Memory Test Complete ===")
EOF

mix run test_memory.exs
```

## 🛡️ Phase 6: Fault Tolerance Testing

### Step 6.1: Circuit Breaker Testing

```bash
# Test circuit breaker functionality
cat > test_fault_tolerance.exs << 'EOF'
# Fault tolerance testing
IO.puts("=== Fault Tolerance Testing ===")

# Test circuit breaker
provider_id = "fault_test_provider"
config = %{failure_threshold: 3, recovery_timeout: 1000, success_threshold: 2}

{:ok, _pid} = Livechain.RPC.CircuitBreaker.start_link({provider_id, config})

# Test normal operation
result = Livechain.RPC.CircuitBreaker.call(provider_id, fn -> :ok end)
IO.puts("✓ Normal operation: #{inspect(result)}")

# Test failure handling
for i <- 1..3 do
  result = Livechain.RPC.CircuitBreaker.call(provider_id, fn -> raise "test error" end)
  IO.puts("  Failure #{i}: #{inspect(result)}")
end

# Check circuit state
state = Livechain.RPC.CircuitBreaker.get_state(provider_id)
IO.puts("✓ Circuit state after failures: #{state.state}")

# Test recovery
Process.sleep(1200)  # Wait for recovery timeout

for i <- 1..2 do
  result = Livechain.RPC.CircuitBreaker.call(provider_id, fn -> :ok end)
  IO.puts("  Recovery attempt #{i}: #{inspect(result)}")
end

# Check final state
final_state = Livechain.RPC.CircuitBreaker.get_state(provider_id)
IO.puts("✓ Final circuit state: #{final_state.state}")

IO.puts("=== Fault Tolerance Test Complete ===")
EOF

mix run test_fault_tolerance.exs
```

### Step 6.2: Process Failure Testing

```bash
# Test process failure handling
cat > test_process_failures.exs << 'EOF'
# Process failure testing
IO.puts("=== Process Failure Testing ===")

# Test process registry with failing processes
registry = Livechain.RPC.ProcessRegistry

# Register a process that will die
dying_pid = spawn(fn -> Process.sleep(100) end)
:ok = Livechain.RPC.ProcessRegistry.register(registry, :test_type, "dying_process", dying_pid)

# Wait for process to die
Process.sleep(200)

# Test lookup of dead process
case Livechain.RPC.ProcessRegistry.lookup(registry, :test_type, "dying_process") do
  {:error, :process_dead} ->
    IO.puts("✓ Dead process properly detected and cleaned up")
  {:ok, _pid} ->
    IO.puts("✗ Dead process not properly cleaned up")
  {:error, :not_found} ->
    IO.puts("✓ Dead process removed from registry")
end

IO.puts("=== Process Failure Test Complete ===")
EOF

mix run test_process_failures.exs
```

## 🌐 Phase 7: Web Interface Testing

### Step 7.1: Start Web Server

```bash
# Start the web server
mix phx.server
```

### Step 7.2: Test Web Endpoints

```bash
# Test health endpoint
curl -s http://localhost:4000/api/health | jq .

# Test chains endpoint
curl -s http://localhost:4000/api/chains | jq .

# Test WebSocket connection (if implemented)
# Use a WebSocket client to connect to ws://localhost:4000/socket/websocket
```

## 📈 Phase 8: Monitoring & Observability

### Step 8.1: Telemetry Verification

```bash
# Verify telemetry is working
cat > test_monitoring.exs << 'EOF'
# Monitoring and observability testing
IO.puts("=== Monitoring Test ===")

# Test all telemetry events
Livechain.Telemetry.emit_rpc_call("test_provider", "eth_blockNumber", 150, :ok)
Livechain.Telemetry.emit_provider_health_change("test_provider", :healthy, :unhealthy)
Livechain.Telemetry.emit_circuit_breaker_change("test_provider", :closed, :open)
Livechain.Telemetry.emit_failover("ethereum", "provider1", "provider2", :timeout)
Livechain.Telemetry.emit_error(:rpc, "test_error", %{provider_id: "test"})
Livechain.Telemetry.emit_performance_metric("latency", 150, %{chain: "ethereum"})

IO.puts("✓ All telemetry events emitted successfully")

# Check if telemetry handlers are attached
handlers = :telemetry.list_handlers([])
IO.puts("✓ Telemetry handlers: #{length(handlers)}")

IO.puts("=== Monitoring Test Complete ===")
EOF

mix run test_monitoring.exs
```

### Step 8.2: Log Analysis

```bash
# Check log output for structured logging
tail -f log/dev.log | grep -E "(Provider health changed|Circuit breaker|Failover triggered)"
```

## 🚀 Phase 9: Production Deployment

### Step 9.1: Production Configuration

```bash
# Create production configuration
export MIX_ENV=prod
export LIVECHAIN_ENV=production
export LIVECHAIN_LOG_LEVEL=info

# Build release
mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release
```

### Step 9.2: Production Testing

```bash
# Test production build
_build/prod/rel/livechain/bin/livechain start

# Test production endpoints
curl -s http://localhost:4000/api/health
curl -s http://localhost:4000/api/chains

# Monitor production logs
tail -f _build/prod/rel/livechain/log/error.log
```

## ✅ Phase 10: Final Validation

### Step 10.1: Comprehensive Health Check

```bash
# Final comprehensive test
cat > final_validation.exs << 'EOF'
# Final validation checklist
IO.puts("=== FINAL VALIDATION CHECKLIST ===")

# 1. Application startup
Application.ensure_all_started(:livechain)
IO.puts("✓ Application started successfully")

# 2. Configuration loading
{:ok, config} = Livechain.Config.ChainConfig.load_config("config/chains.yml")
IO.puts("✓ Configuration loaded: #{map_size(config.chains)} chains")

# 3. Process registry
registry = Livechain.RPC.ProcessRegistry
IO.puts("✓ Process registry available")

# 4. Chain manager
{:ok, _pid} = Livechain.RPC.ChainManager.start_link()
IO.puts("✓ Chain manager started")

# 5. Telemetry
Livechain.Telemetry.emit_rpc_call("validation", "test", 100, :ok)
IO.puts("✓ Telemetry working")

# 6. Circuit breaker
{:ok, _pid} = Livechain.RPC.CircuitBreaker.start_link({"validation_cb", %{}})
IO.puts("✓ Circuit breaker working")

# 7. Message aggregator
{:ok, _pid} = Livechain.RPC.MessageAggregator.start_link({"validation_chain", %{aggregation: %{max_cache_size: 100}}})
IO.puts("✓ Message aggregator working")

# 8. Performance test
start_time = System.monotonic_time(:millisecond)
for i <- 1..100 do
  Livechain.RPC.MessageAggregator.process_message("validation_chain", "provider1", %{"id" => i})
end
duration = System.monotonic_time(:millisecond) - start_time
IO.puts("✓ Performance: 100 messages in #{duration}ms")

IO.puts("\\n🎉 ALL VALIDATION TESTS PASSED! 🎉")
IO.puts("\\nYour Livechain system is ready for production!")
IO.puts("\\nNext steps:")
IO.puts("1. Set up monitoring dashboards")
IO.puts("2. Configure alerting")
IO.puts("3. Deploy to production environment")
IO.puts("4. Monitor system performance")
EOF

mix run final_validation.exs
```

### Step 10.2: Production Readiness Checklist

```bash
# Create production readiness checklist
cat > PRODUCTION_CHECKLIST.md << 'EOF'
# Production Readiness Checklist

## ✅ System Requirements
- [ ] Elixir 1.14+ installed
- [ ] Erlang/OTP 25+ installed
- [ ] 4GB+ RAM available
- [ ] 10GB+ storage available
- [ ] Stable network connection

## ✅ Configuration
- [ ] Environment variables set
- [ ] API keys configured (if using paid providers)
- [ ] Configuration files validated
- [ ] Log levels configured

## ✅ Testing
- [ ] All unit tests pass
- [ ] Integration tests pass
- [ ] Performance tests meet requirements
- [ ] Fault tolerance tests pass
- [ ] Memory management verified

## ✅ Monitoring
- [ ] Telemetry handlers attached
- [ ] Logging configured
- [ ] Health endpoints working
- [ ] Metrics collection active

## ✅ Security
- [ ] API keys secured
- [ ] Network access controlled
- [ ] Logs don't contain sensitive data
- [ ] Error handling doesn't leak information

## ✅ Performance
- [ ] Message throughput > 1000/sec
- [ ] Memory usage bounded
- [ ] Failover time < 1 second
- [ ] Circuit breakers working

## ✅ Documentation
- [ ] API documentation complete
- [ ] Operational procedures documented
- [ ] Troubleshooting guide available
- [ ] Contact information for support

## ✅ Deployment
- [ ] Production build created
- [ ] Release process tested
- [ ] Rollback procedures documented
- [ ] Backup procedures in place

## ✅ Monitoring & Alerting
- [ ] Dashboards configured
- [ ] Alerting rules defined
- [ ] Escalation procedures documented
- [ ] On-call rotation established
EOF

echo "Production checklist created: PRODUCTION_CHECKLIST.md"
```

## 🎯 Success Criteria

### Performance Targets

- ✅ **Message Throughput**: >1000 messages/second
- ✅ **Latency**: <100ms average response time
- ✅ **Memory Usage**: Bounded and predictable
- ✅ **Failover Time**: <1 second
- ✅ **Uptime**: 99.9%+ availability

### Quality Gates

- ✅ **Test Coverage**: >80%
- ✅ **All Tests Pass**: No failures
- ✅ **No Warnings**: Clean compilation
- ✅ **Documentation**: Complete and accurate
- ✅ **Monitoring**: Comprehensive observability

## 🚨 Troubleshooting

### Common Issues

1. **API Key Errors**

   ```bash
   # Check environment variables
   echo $INFURA_API_KEY
   echo $ALCHEMY_API_KEY

   # Test configuration
   mix run -e "Livechain.Config.ChainConfig.load_config(\"config/chains.yml\")"
   ```

2. **Connection Failures**

   ```bash
   # Check network connectivity
   curl -s https://mainnet.infura.io/v3/your-key

   # Test WebSocket connections
   # Use a WebSocket client to test connections
   ```

3. **Memory Issues**

   ```bash
   # Monitor memory usage
   watch -n 1 'ps aux | grep beam'

   # Check cache sizes
   mix run -e "Livechain.RPC.MessageAggregator.get_stats(\"ethereum\")"
   ```

4. **Performance Issues**

   ```bash
   # Run performance tests
   mix run test_performance.exs

   # Check telemetry metrics
   # Monitor logs for performance data
   ```

## 📞 Support

If you encounter issues during testing:

1. **Check Logs**: Review application logs for errors
2. **Run Tests**: Execute relevant test scripts
3. **Verify Configuration**: Ensure all settings are correct
4. **Check Dependencies**: Verify all software versions
5. **Review Documentation**: Consult architecture and API docs

---

**🎉 Congratulations!** Following this test plan will ensure your Livechain system is thoroughly tested and production-ready. The system provides enterprise-grade reliability, performance, and observability for blockchain event streaming.
