# ChainPulse Project Context

## Project Overview
ChainPulse is a real-time blockchain event streaming middleware built in Elixir/Phoenix. It provides reliable RPC failover, structured event feeds, and real-time analytics for crypto applications.

## Current Architecture
- **Phoenix Channels**: Real-time WebSocket streaming infrastructure
- **OTP Supervisors**: Fault-tolerant GenServer architecture for RPC connections
- **Multi-Chain Support**: Ethereum, Polygon, Arbitrum, BSC ready
- **Mock Provider System**: Comprehensive testing environment
- **Circuit Breakers**: Fault isolation and automatic recovery
- **Telemetry Integration**: Comprehensive observability

## Development Status
- ✅ **Phase 1 Complete**: Foundation with Phoenix + OTP architecture
- 🔄 **Phase 2 In Progress**: Hybrid API Layer (JSON-RPC + Enhanced Streaming)
- 🔄 **Phase 3 Planned**: Production features and performance optimization
- 🔄 **Phase 4 Planned**: Analytics intelligence and dashboard

## Key Files and Structure
```
lib/
├── livechain/
│   ├── rpc/                      # RPC connection management
│   │   ├── ws_supervisor.ex      # WebSocket connection supervisor
│   │   ├── mock_provider.ex      # Mock provider for testing
│   │   ├── circuit_breaker.ex    # Fault tolerance
│   │   └── process_registry.ex   # Centralized process management
│   ├── telemetry.ex              # Observability and metrics
│   └── application.ex            # Application startup
├── livechain_web/
│   ├── live/
│   │   └── orchestration_live.ex # Real-time dashboard
│   └── router.ex                 # Web routing
docs/
├── RPC_ORCHESTRATION_VISION.md   # Technical architecture
├── ARCHITECTURE_IMPROVEMENTS.md  # Recent improvements
├── LIVEVIEW_ORCHESTRATION_DASHBOARD_PLAN.md # Dashboard design
└── HACKATHON_VISION_PLAN.md      # 4-week development plan
```

## Technology Stack
- **Backend**: Elixir/OTP with Phoenix Framework
- **Real-time**: Phoenix Channels (WebSocket)
- **Event Processing**: Broadway (planned)
- **Database**: TimescaleDB (planned for analytics)
- **Monitoring**: Telemetry + Prometheus
- **Frontend**: Phoenix LiveView + TailwindCSS

## Current Capabilities
- Multi-provider RPC failover (Infura, Alchemy, public nodes)
- Real-time WebSocket streaming
- Mock provider system for development/testing
- Circuit breaker fault tolerance
- Comprehensive telemetry and monitoring
- LiveView dashboard proof-of-concept

## Next Development Phase (Week 1)
1. **JSON-RPC Compatibility**: Drop-in replacement for Viem/Wagmi apps
2. **Broadway Pipeline**: Structured event processing (ERC-20, NFT events)
3. **Provider Failover**: Multi-provider redundancy per chain
4. **Performance Optimization**: Sub-second event delivery

## Testing Strategy
- Unit tests for individual components
- Integration tests for end-to-end workflows
- Chaos engineering for failure scenarios
- Load testing for concurrent connections
- Mock providers for reliable testing

## Deployment Context
- Internal studio tool for crypto development projects
- Potential SaaS evolution for external developers
- Demonstration piece for technical capabilities
- Foundation for future blockchain infrastructure