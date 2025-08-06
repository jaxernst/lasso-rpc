# Full JSON-RPC Compliance Implementation Plan

## Overview

This document outlines the technical implementation plan to expand ChainPulse from its current live events focus to full JSON-RPC compliance with load balancing and provider benchmarking capabilities.

## Current Implementation Analysis

### ✅ Existing Infrastructure Ready for Extension

**OTP Supervision Architecture**
- `Livechain.RPC.ChainManager` - Chain lifecycle management
- `Livechain.RPC.ChainSupervisor` - Per-chain process supervision
- `Livechain.RPC.WSSupervisor` - WebSocket connection management
- `Livechain.RPC.ProcessRegistry` - Centralized process management

**Fault Tolerance Systems**
- `Livechain.RPC.CircuitBreaker` - Provider failure isolation
- `Livechain.RPC.MessageAggregator` - Event deduplication with bounded cache
- Health monitoring and automatic recovery

**Real-Time Infrastructure**
- Phoenix Channels for WebSocket communication
- `Livechain.Telemetry` - Comprehensive metrics collection
- LiveView dashboard with real-time monitoring

**Provider Management**
- Multi-chain configuration (15+ chains configured)
- Provider pool management per chain
- Mock provider system for development/testing

### 🔍 Implementation Gaps for Full RPC Compliance

**JSON-RPC API Layer**
- No HTTP POST endpoint for standard RPC calls
- No WebSocket JSON-RPC subscription handling
- Missing standard method implementations (eth_getLogs, eth_getBlockByNumber, etc.)

**Real Provider Integration**
- Currently only mock providers - no actual RPC connections
- No API key management for real providers
- Missing real-world failover testing

**Provider Intelligence**
- No performance benchmarking system
- No load balancing based on provider performance
- No cost tracking or optimization logic

**Analytics Infrastructure**
- No historical request data collection
- No provider performance analysis
- No cost optimization insights

## Implementation Strategy

### Phase 1: JSON-RPC API Foundation

**Implementation Components:**
```elixir
# New modules to implement
lib/livechain_web/controllers/rpc_controller.ex
lib/livechain/rpc/json_rpc_handler.ex
lib/livechain_web/channels/rpc_channel.ex
lib/livechain/rpc/subscription_manager.ex
```

**Integration with Existing System:**
- Use existing `ChainManager` for provider routing
- Leverage existing `ProcessRegistry` for subscription management
- Integrate with existing telemetry for request metrics
- Utilize existing circuit breaker for fault tolerance

**Standard JSON-RPC Methods to Implement:**
- `eth_subscribe` / `eth_unsubscribe` (subscriptions)
- `eth_getLogs` (historical log queries)
- `eth_getBlockByNumber` / `eth_getBlockByHash`
- `eth_getTransactionReceipt`
- `eth_call` (contract calls)
- `eth_getBalance`
- `eth_getTransactionCount`

### Phase 2: Real Provider Integration

**Implementation Components:**
```elixir
# Enhance existing modules
lib/livechain/rpc/real_endpoints.ex (enhance existing)
lib/livechain/rpc/ws_connection.ex (add real connections)
lib/livechain/rpc/provider_config.ex (API key management)
```

**Configuration Enhancement:**
- Add real provider URLs and API keys to `config/chains.yml`
- Environment variable substitution for sensitive data
- Provider availability detection and filtering

**Integration Points:**
- Replace mock provider calls with real HTTP/WebSocket connections
- Integrate with existing circuit breaker for real failure scenarios
- Use existing health monitoring for real provider status

### Phase 3: Provider Benchmarking System

**Implementation Components:**
```elixir
# New benchmarking infrastructure
lib/livechain/benchmarking/provider_benchmarker.ex
lib/livechain/benchmarking/performance_metrics.ex
lib/livechain/benchmarking/latency_tracker.ex
```

**Benchmarking Strategy:**
- Continuous latency measurement for all providers
- Success rate tracking over time windows
- Request volume capacity testing
- Geographic performance variation detection

**Integration with Existing Systems:**
- Use existing telemetry infrastructure for metrics collection
- Store performance data in existing ETS cache system
- Integrate with existing health monitoring dashboard

**Performance Metrics to Track:**
- Average response latency (50th, 95th, 99th percentiles)
- Success rate percentage
- Connection establishment time
- Request timeout frequency
- Rate limiting occurrences

### Phase 4: Intelligent Load Balancing

**Implementation Components:**
```elixir
# Load balancing logic
lib/livechain/load_balancing/request_router.ex
lib/livechain/load_balancing/provider_selector.ex
lib/livechain/load_balancing/routing_strategy.ex
```

**Load Balancing Strategies:**
1. **Performance-based**: Route to fastest responding providers
2. **Cost-optimized**: Prefer providers with lower costs per request
3. **Balanced**: Optimize for both performance and cost
4. **Failover-priority**: Primary/secondary provider hierarchies

**Integration Points:**
- Enhance existing provider pool selection in `ChainSupervisor`
- Use benchmarking data for routing decisions
- Maintain existing circuit breaker behavior for failed providers
- Integrate with existing telemetry for routing metrics

### Phase 5: Analytics and Cost Optimization

**Implementation Components:**
```elixir
# Analytics system
lib/livechain/analytics/request_logger.ex
lib/livechain/analytics/cost_calculator.ex
lib/livechain/analytics/usage_analyzer.ex
lib/livechain_web/controllers/analytics_controller.ex
```

**Analytics Features:**
- Request volume tracking by method, chain, and provider
- Cost calculation based on provider pricing models
- Usage pattern analysis for optimization recommendations
- Historical performance trend analysis

**Integration with Existing Infrastructure:**
- Extend existing telemetry system for detailed request logging
- Use existing ETS cache for recent analytics data
- Integrate with existing LiveView dashboard for analytics display
- Leverage existing health monitoring for provider cost tracking

## Technical Implementation Details

### JSON-RPC Request Flow
```
HTTP/WebSocket Request
├── RPCController.handle_request()
├── JSONRPCHandler.parse_and_validate()
├── RequestRouter.select_provider() (uses benchmarking data)
├── ChainManager.execute_request() (existing)
├── WSConnection.send_request() (existing, enhanced for real providers)
└── Response processing and return
```

### Provider Benchmarking Flow
```
Scheduled Benchmark Task
├── ProviderBenchmarker.run_benchmark()
├── LatencyTracker.measure_response_time()
├── PerformanceMetrics.update_statistics()
├── ETS Cache storage (existing cache system)
└── Telemetry event emission (existing telemetry)
```

### Load Balancing Decision Flow
```
Request Routing Decision
├── RequestRouter.select_provider()
├── ProviderSelector.get_available_providers() (existing health check)
├── BenchmarkingData.get_performance_scores()
├── RoutingStrategy.calculate_optimal_provider()
└── Provider selection with fallback (existing circuit breaker)
```

## Integration with Existing Systems

### Leveraging Current OTP Architecture
- **ChainManager**: Add JSON-RPC request routing
- **ChainSupervisor**: Enhance provider selection logic
- **ProcessRegistry**: Use for subscription management
- **CircuitBreaker**: Extend for real provider failures
- **MessageAggregator**: Adapt for JSON-RPC response deduplication

### Enhancing Existing Telemetry
- Add request-level metrics (method, latency, provider used)
- Track cost-related metrics (provider pricing, usage patterns)
- Monitor load balancing effectiveness
- Measure benchmarking system performance

### Extending LiveView Dashboard
- Real-time JSON-RPC request monitoring
- Provider performance comparison charts
- Cost optimization recommendations
- Load balancing effectiveness visualization

## Overlap with Live Events Functionality

### Shared Infrastructure
- **Provider Connections**: Both systems use the same provider pools
- **Circuit Breakers**: Same fault tolerance for both request types
- **Health Monitoring**: Unified provider health across use cases
- **Telemetry**: Combined metrics for comprehensive monitoring

### Differentiated Features
- **Request Types**: JSON-RPC calls vs. event subscriptions
- **Response Patterns**: Synchronous responses vs. streaming events
- **Optimization Goals**: Request latency vs. event delivery speed
- **Client Interfaces**: Standard JSON-RPC vs. enhanced event streaming

## Success Metrics

### Technical Performance
- JSON-RPC request latency under 100ms for 95% of requests
- Provider failover time under 5 seconds
- Load balancing effectiveness (improved average latency)
- Cost optimization (reduced provider costs through smart routing)

### Compatibility
- 100% compatibility with standard Ethereum JSON-RPC spec
- Drop-in replacement capability for existing Viem/Wagmi applications
- Support for all major RPC methods and subscription types

### System Reliability
- Maintain existing high availability with multi-provider failover
- Graceful degradation when providers fail
- Consistent performance under high request volumes
- Effective circuit breaker protection against cascade failures

This implementation plan leverages ChainPulse's existing strengths while systematically adding the components needed for full JSON-RPC compliance with intelligent provider management.