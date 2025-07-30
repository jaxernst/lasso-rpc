# WebSocket Connection Simulator

## Quick Start

**The simulator automatically starts with Phoenix in dev/test environments:**

```bash
mix phx.server
```

Then open http://localhost:4000 to see real-time WebSocket connections appearing and disappearing!

## Live Controls

### Option 1: Start with IEx Console

```bash
iex -S mix phx.server
```

### Option 2: Connect to Running Phoenix Server

If Phoenix is already running with `mix phx.server`, connect from a new terminal:

```bash
iex --sname debug --remsh livechain@localhost
```

### Simulator Commands

Once in IEx, control the simulator:

```elixir
# View current statistics
Livechain.Simulator.get_stats()

# Switch simulation modes  
Livechain.Simulator.switch_mode("intense")  # Rapid connections, high failure rates
Livechain.Simulator.switch_mode("calm")     # Stable, long-lived connections
Livechain.Simulator.switch_mode("normal")   # Balanced connections (default)

# Stop/start simulation
Livechain.Simulator.stop_simulation()
Livechain.Simulator.start_simulation()
```

## What You'll See

The simulator creates realistic blockchain WebSocket connections that:

- **Spawn dynamically** across multiple chains (Ethereum, Polygon, Arbitrum, BSC)
- **Live and die** with realistic timing patterns
- **Fail and reconnect** to simulate network issues
- **Update in real-time** on the dashboard without any polling

Perfect for demonstrating the real-time observability capabilities of your WebSocket orchestration system.

## Architecture

- **Application Integration**: `lib/livechain/application.ex` - Auto-starts simulator in dev/test environments
- **Simulator**: `lib/livechain/simulator.ex` - Core simulation logic and connection lifecycle management
- **Mock Connections**: `lib/livechain/rpc/mock_ws_connection.ex` - Simulated WebSocket connections with real heartbeats
- **Event Generator**: `lib/livechain/simulator/event_generator.ex` - Blockchain event simulation  
- **Dashboard**: `lib/livechain_web/live/orchestration_live.ex` - Real-time LiveView interface with live timestamps
- **PubSub Integration**: Real-time updates via Phoenix.PubSub without polling

## Features

- **Real-time Updates**: Live connection status, timestamps, and metrics via PubSub
- **Realistic Simulation**: Authentic connection lifecycles with failures and reconnections  
- **Multiple Blockchains**: Ethereum, Polygon, Arbitrum, BSC with different characteristics
- **Live Timestamps**: Actual last-seen times that update as connections send heartbeats
- **Environment Aware**: Only runs in dev/test environments, disabled in production