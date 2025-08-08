# ChainPulse: Blockchain RPC Orchestration Platform

## What is ChainPulse?

ChainPulse is a blockchain RPC orchestration platform built with Elixir/Phoenix that provides JSON-RPC compatibility with enhanced real-time event streaming capabilities. It manages connections to multiple RPC providers with automatic failover and load balancing.

## Current State

### ✅ **Implemented Foundation**
- **OTP Supervision Trees**: ChainManager, ChainSupervisor, WSSupervisor
- **Multi-Chain Configuration**: 15+ chains with provider pools configured
- **Circuit Breakers**: Automatic failover with health monitoring
- **Phoenix Channels**: Real-time WebSocket infrastructure
- **Process Registry**: Centralized process management
- **Message Aggregation**: Event deduplication and routing with bounded cache
- **Telemetry**: Performance monitoring and metrics collection
- **Mock Provider System**: Full development and testing environment
- **Basic LiveView Dashboard**: Initial orchestration monitoring interface

### 🔄 **In Development: Practical Dashboard & Testing**
- **Live System Dashboard**: Real-time monitoring, network topology, system health
- **Interactive Testing Platform**: End-to-end testing with configurable load scenarios
- **Provider Management Interface**: Visualization and management of all RPC providers
- **Performance Analytics**: Real-time metrics and historical trend analysis

### 🔄 **Planned for Full JSON-RPC Compliance**
- **JSON-RPC API Endpoints**: Standard HTTP/WebSocket JSON-RPC handlers
- **Real Provider Connections**: Actual connections to Infura, Alchemy, etc.
- **Provider Benchmarking**: Latency and reliability measurement system
- **Load Balancing**: Request routing based on provider performance
- **Stream Processing**: Enhanced event curation and multi-chain aggregation

## Expansion to Full JSON-RPC Compliance

The existing live events infrastructure provides the foundation for full JSON-RPC compliance. The expansion involves:

### Standard JSON-RPC Layer
- HTTP POST endpoints for standard RPC calls
- WebSocket endpoints for subscriptions (eth_subscribe, eth_unsubscribe)
- Support for all standard Ethereum JSON-RPC methods
- Drop-in replacement for existing RPC providers

### Provider Management Enhancement
- Real connections to multiple RPC providers per chain
- Performance benchmarking to measure latency and success rates
- Load balancing requests across healthy providers
- Cost tracking and optimization

### Analytics and Monitoring
- Historical request data collection
- Provider performance analysis
- Cost optimization insights
- Usage pattern analysis

## Technical Architecture

### Current Architecture
```
Phoenix Application
├── ChainManager (supervises chains)
├── ChainSupervisor (per-chain supervision)
│   ├── WSConnection (WebSocket connections)
│   ├── MessageAggregator (event deduplication)
│   └── ProviderPool (manages providers)
├── ProcessRegistry (centralized process management)
├── CircuitBreaker (fault tolerance)
└── Telemetry (monitoring)
```

### Enhanced Architecture for Full JSON-RPC
```
Phoenix Application
├── JSON-RPC Controller (HTTP endpoints)
├── JSON-RPC WebSocket Handler (subscription management)
├── Provider Benchmarker (performance measurement)
├── Load Balancer (request routing)
├── Analytics Engine (data collection & analysis)
└── [Existing Infrastructure]
```

## API Design

### Standard JSON-RPC Endpoints
```
POST /rpc/ethereum          # Standard JSON-RPC over HTTP
WS   /rpc/ethereum          # JSON-RPC subscriptions over WebSocket
POST /rpc/{chain_name}      # Any configured blockchain
```

### Enhanced Event Streaming (existing)
```
WS /channels/events         # Real-time event streams
WS /channels/chain/{name}   # Chain-specific events
```

### Analytics API (new)
```
GET /api/providers          # Provider status and performance
GET /api/analytics/requests # Request volume and patterns
GET /api/analytics/costs    # Cost analysis and optimization
```

## Implementation Dependencies

### Step 1: JSON-RPC API Layer
**Depends on**: Existing Phoenix router, ChainManager, ProcessRegistry
- Add JSON-RPC controller with method dispatching
- Implement WebSocket JSON-RPC handler using existing Phoenix Channels
- Route requests through existing provider pool management

### Step 2: Real Provider Integration
**Depends on**: Step 1, existing WSConnection and circuit breaker system
- Replace mock providers with actual RPC connections
- Add API key configuration
- Integrate with existing health monitoring

### Step 3: Provider Benchmarking
**Depends on**: Step 2, existing telemetry infrastructure
- Add latency measurement to connection pools
- Implement performance scoring system
- Store metrics using existing ETS cache system

### Step 4: Load Balancing
**Depends on**: Step 3, existing provider pool selection
- Enhance provider selection logic with performance data
- Add request routing algorithms
- Integrate with existing circuit breaker failover

### Step 5: Analytics System
**Depends on**: All previous steps, existing telemetry
- Add request logging and historical data collection
- Create analytics API endpoints
- Build analytics dashboard using existing LiveView

## Key Technical Challenges

### Load Balancing Strategy
- Determine optimal provider selection algorithm
- Balance between performance, cost, and reliability
- Handle different request types (read vs. subscription)

### Provider Benchmarking
- Implement fair performance measurement
- Account for geographic and network variations
- Handle different provider rate limits and pricing

### Cost Optimization
- Track usage patterns across providers
- Implement cost-aware routing decisions
- Provide insights for cost optimization

## Benefits of Full JSON-RPC Compliance

### For Developers
- Drop-in replacement for existing RPC providers
- No code changes required for Viem/Wagmi applications
- Enhanced reliability through multi-provider failover
- Real-time event streaming capabilities

### For Infrastructure
- Reduced single-point-of-failure risk
- Cost optimization through intelligent routing
- Performance optimization through provider benchmarking
- Comprehensive monitoring and analytics

## Existing Strengths to Leverage

- **Proven OTP Architecture**: Fault-tolerant supervision trees
- **Circuit Breaker System**: Automatic failure handling
- **Real-time Capabilities**: Phoenix Channels for WebSocket connections
- **Process Management**: Centralized registry with health monitoring
- **Telemetry Integration**: Comprehensive metrics collection
- **Mock System**: Complete testing and development environment

The foundation is solid for expanding into full JSON-RPC compliance while maintaining the existing live events capabilities.