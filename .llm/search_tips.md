# ChainPulse Search & Navigation Tips

## Efficient File Discovery

### Key Module Locations
- **RPC Connection Logic**: Search `lib/livechain/rpc/` - contains ws_supervisor.ex, mock_provider.ex
- **Web Interface**: Search `lib/livechain_web/` - contains LiveView components and routing
- **Core Application**: Search `lib/livechain/` - contains main application modules
- **Configuration**: Search `config/` - dev.exs, prod.exs, config.exs
- **Tests**: Search `test/` - follows lib/ structure pattern

### Common Search Patterns
- **GenServer implementations**: Look for `use GenServer` and `def handle_*` patterns
- **Phoenix LiveView**: Search for `use ChainPulseWeb, :live_view` and `def mount`
- **Supervision trees**: Search for `Supervisor.start_link` and `child_spec`
- **Telemetry events**: Search for `:telemetry.execute` calls
- **Configuration**: Search for `Application.get_env` or `config :livechain`

### Function/Module Discovery
- **Connection management**: `WSSupervisor` module
- **Provider health**: `CircuitBreaker` module  
- **Event processing**: `MessageAggregator` module
- **Dashboard**: `OrchestrationLive` module
- **Process registry**: `ProcessRegistry` module

### Important Constants & Configs
- **Chain names**: Usually atoms like `:ethereum`, `:polygon`, `:arbitrum`
- **Provider types**: `:infura`, `:alchemy`, `:public`
- **Event types**: Look for string constants like `"Transfer"`, `"Approval"`

### Testing Patterns
- **Mock providers**: All in `mock_provider.ex` and related test files
- **Test helpers**: Look for `test/support/` directory
- **Integration tests**: Usually in `test/integration/` or similar

### Development History Key Points
- **Phase 1**: Foundation with Phoenix + OTP (COMPLETED)
- **Recent improvements**: Circuit breakers, telemetry, memory management
- **Current focus**: JSON-RPC compatibility and Broadway pipelines
- **Next phase**: Analytics intelligence and enhanced dashboard

### When Debugging
- Check supervisor states with `Livechain.RPC.WSSupervisor.list_connections()`
- Telemetry data available through the telemetry system
- LiveView dashboard shows real-time system state
- Mock providers have configurable failure modes for testing

### Architecture Understanding
- Each blockchain has its own supervisor tree
- RPC providers are individual GenServer processes
- Circuit breakers prevent cascade failures
- Message aggregation handles deduplication
- Phoenix PubSub enables real-time updates across the system