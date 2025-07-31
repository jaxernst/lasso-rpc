# ChainPulse LLM Context

## Project Overview
ChainPulse is a real-time blockchain event streaming middleware built in Elixir/Phoenix for internal studio use and potential SaaS evolution.

## Key Development Context

### Package Management & Build System
- **Package Manager**: Mix (Elixir's built-in package manager)
- **Dependencies**: Defined in `mix.exs`
- **Commands**: `mix deps.get`, `mix compile`, `mix test`, `mix phx.server`

### Architecture Patterns
- **OTP Supervision Trees**: Core pattern for fault tolerance
- **GenServers**: Used for RPC connection management
- **Phoenix Channels**: Real-time WebSocket streaming
- **Broadway**: Event processing pipelines (planned)
- **Circuit Breakers**: Fault isolation pattern implemented

### Current Development Status (Phase 1 ✅ Complete)
- Phoenix Channels infrastructure working
- OTP supervision trees implemented
- Multi-chain support (Ethereum, Polygon, Arbitrum, BSC)
- Mock provider system for testing
- Circuit breakers and telemetry integration
- LiveView dashboard proof-of-concept

### Key File Locations
- **RPC Management**: `lib/livechain/rpc/`
- **Web Interface**: `lib/livechain_web/`
- **Configuration**: `config/`
- **Tests**: `test/`
- **Documentation**: `docs/`

### Testing Strategy
- Uses ExUnit (Elixir's built-in testing framework)
- Mock providers in `lib/livechain/rpc/mock_provider.ex`
- Integration tests for end-to-end workflows
- Chaos engineering approach for failure scenarios

### Important Implementation Details
- **Process Registry**: Custom implementation to avoid global registry conflicts
- **Memory Management**: Bounded cache with LRU eviction in MessageAggregator
- **Telemetry**: Comprehensive event emission for observability
- **Configuration**: Environment variable substitution supported

### Development Workflow
1. Start with `iex -S mix phx.server` for interactive development
2. LiveView dashboard available at `http://localhost:4000/orchestration`
3. Tests run with `mix test`
4. Mock providers simulate real blockchain connections

### Common Patterns to Follow
- GenServer for stateful connections
- Supervisor trees for fault tolerance
- Phoenix PubSub for real-time updates
- Telemetry events for all major operations
- Environment-based configuration

### Performance Targets
- Sub-second event delivery
- 1,000+ concurrent WebSocket connections
- <100ms LiveView update latency
- Automatic failover in <5 seconds