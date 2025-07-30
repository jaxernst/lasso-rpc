# Livechain - Real-Time Blockchain Event Streaming System

## 🎯 System Overview

Livechain is a **live-first blockchain event streaming middleware** built with Elixir/Phoenix that provides:

- **Sub-second latency** real-time blockchain events
- **RPC failover** across multiple providers (Infura, Alchemy, public RPCs)
- **Unified event feeds** for token transfers, NFT events, DeFi activities
- **Viem/Wagmi compatibility** as a drop-in replacement for existing dApps

## 🏗️ Core Architecture

```
Client Apps → Web Interface → Orchestration → Connection → Blockchain Networks
     ↓              ↓              ↓            ↓              ↓
  Viem/Wagmi   HTTP/WebSocket   ChainManager  WSConnection   Ethereum/Base
  dApps        Channels         ProviderPool  CircuitBreaker Polygon/Arbitrum
```

## 📁 Key Directories & Files

### Core Application (`lib/livechain/`)

- `application.ex` - OTP supervision tree startup
- `rpc/` - RPC orchestration and connection management
- `config/` - Chain configuration and validation
- `telemetry.ex` - System monitoring and metrics

### Web Interface (`lib/livechain_web/`)

- `controllers/` - HTTP API endpoints
- `channels/` - WebSocket real-time streaming
- `router.ex` - API routing configuration

### Configuration (`config/`)

- `chains.yml` - Multi-chain provider configurations
- `dev.exs` / `prod.exs` - Environment-specific settings

### Testing (`test/`)

- `livechain/` - Core system tests
- `livechain_web/` - Web interface tests

## 🔧 Core Patterns

### OTP Supervision Tree

- **Application** → **ChainManager** → **ChainSupervisor** → **WSConnection**
- Each level provides fault tolerance and process management
- Automatic restart and recovery on failures

### GenServer Pattern

- Stateful processes with message handling
- `handle_call/3` for synchronous operations
- `handle_info/2` for asynchronous messages

### Phoenix Channels

- Real-time WebSocket communication
- PubSub for broadcasting events
- Channel lifecycle: join → subscribe → leave

### Circuit Breaker Pattern

- Prevents cascade failures
- Automatic failover between providers
- Health monitoring and recovery

## 🎯 Primary Goals

1. **Reliability**: Zero provider-related outages
2. **Performance**: Sub-1 second event delivery
3. **Scalability**: 1000+ concurrent WebSocket connections
4. **Developer Experience**: Drop-in Viem compatibility
5. **Multi-Chain**: Unified API across EVM chains

## 🚀 Quick Start

```bash
# Start the application
mix run --no-halt

# Test health endpoint
curl http://localhost:4000/api/health

# Connect WebSocket
wscat -c "ws://localhost:4000/socket/websocket"
```

## 📚 Specialized Guides

- [`.llm/architecture.md`](architecture.md) - Detailed architecture patterns
- [`.llm/patterns.md`](patterns.md) - Elixir/OTP patterns used
- [`.llm/api.md`](api.md) - API endpoints and WebSocket channels
- [`.llm/testing.md`](testing.md) - Testing strategies and mock providers
- [`.llm/deployment.md`](deployment.md) - Production deployment considerations

## 🔍 Key Concepts

- **Live-First Design**: Events over RPC calls, streaming over polling
- **Fault Isolation**: Individual failures don't cascade
- **Event Curation**: Transform raw logs into structured events
- **Hybrid API**: Standard JSON-RPC + enhanced streaming layer
- **Provider Pool**: Multi-provider redundancy with automatic failover
