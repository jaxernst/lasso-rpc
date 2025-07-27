# Changelog

## [0.2.0] - 2024-Present

### ✨ Major Features Added

#### Phoenix Channels Integration
- **Real-time WebSocket streaming** for client applications
- **Multi-client broadcasting** - thousands of concurrent connections
- **Channel-based subscriptions** to specific blockchain networks
- **Scalable architecture** using Phoenix PubSub

#### Enhanced Architecture
- **Two-tier design**: GenServers for blockchain connections, Phoenix Channels for clients
- **Fault isolation** between blockchain and client connections
- **Phoenix PubSub** message broadcasting system
- **HTTP API** for system health and status monitoring

#### Production Features
- **Real blockchain endpoint support** (Infura, Alchemy, public RPC)
- **Comprehensive error handling** and automatic reconnection
- **Configuration system** for production deployment
- **Docker deployment** support

### 🔧 Improvements

#### Mock Provider System
- **Fixed function arity issues** for convenience methods
- **Enhanced block generation** with realistic data structures
- **Improved error simulation** and testing capabilities
- **Better statistics tracking** and monitoring

#### Documentation
- **Complete README overhaul** with architecture diagrams
- **Updated Quick Start guide** with Phoenix Channels examples
- **WebSocket client examples** in JavaScript and Elixir
- **Production deployment guides**

#### Code Quality
- **Fixed type safety issues** and compiler warnings
- **Improved module organization** and naming conventions
- **Enhanced error handling** throughout the system
- **Better logging** and debugging capabilities

### 🐛 Bug Fixes

- Fixed MockWSEndpoint function arity for ethereum_mainnet(), polygon(), etc.
- Resolved module alias issues throughout codebase
- Fixed type safety violations in state management
- Corrected WebSocket connection status handling
- Improved error handling in connection supervision

### 📚 Documentation Updates

- **README.md**: Complete rewrite with modern features and examples
- **QUICK_START.md**: Updated with Phoenix Channels and multi-client testing
- **Added example applications**: JavaScript WebSocket client, Elixir GenServer client
- **Production deployment guides**: Docker, environment configuration

## [0.1.0] - Initial Release

### 🎯 Core Features

#### Mock Provider System
- **Realistic blockchain simulation** for development and testing
- **Multi-chain support**: Ethereum, Polygon, Arbitrum, BSC
- **Configurable parameters**: block time, failure rates, latency
- **WebSocket connection management** with automatic reconnection

#### GenServer Architecture  
- **Individual processes** per blockchain connection
- **Fault tolerance** with supervision trees
- **Automatic reconnection** and error recovery
- **Message queuing** during disconnections

#### Basic Testing
- **Mock RPC calls** for common Ethereum methods
- **Event streaming simulation** 
- **Connection monitoring** and status reporting
- **Basic subscription management**

---

## Migration Guide

### From 0.1.0 to 0.2.0

#### New Dependencies
Add to your `mix.exs`:
```elixir
{:phoenix, "~> 1.7"},
{:phoenix_pubsub, "~> 2.1"},
{:websockex, "~> 0.4"}
```

#### Updated API Usage

**Old (0.1.0):**
```elixir
# Direct mock provider usage only
MockProvider.subscribe(provider, "newHeads")
```

**New (0.2.0):**
```elixir
# Phoenix Channels for client connections
wscat -c "ws://localhost:4000/socket/websocket"
{"topic":"blockchain:ethereum","event":"phx_join","payload":{},"ref":"1"}

# Or direct GenServer usage still supported
Livechain.RPC.MockProvider.subscribe(provider, "newHeads")
```

#### Configuration Changes

**Production configuration now supported:**
```elixir
# config/prod.exs
config :livechain,
  infura_api_key: System.get_env("INFURA_API_KEY"),
  alchemy_api_key: System.get_env("ALCHEMY_API_KEY")
```