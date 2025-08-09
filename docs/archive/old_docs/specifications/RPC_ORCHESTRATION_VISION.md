# ChainPulse: Live-First Blockchain Event Streaming

## Overview

ChainPulse is a lightweight, Elixir-based middleware for **real-time blockchain event streaming** with robust RPC failover. It delivers curated, low-latency event feeds (e.g., token transfers, NFT mints) across multiple chains (Ethereum, Arbitrum, Solana) via a hybrid API approach, tailored for Viem/Wagmi-based consumer applications.

## Problem Statement

Crypto engineers at our studio waste time wrestling with:

- **Unreliable RPC providers** causing app downtime
- **Building custom event listeners** for each consumer app
- **Fragile data pipelines** that break on provider failures
- **Cross-chain complexity** when building multi-network features

This leads to development delays and unreliable user experiences in consumer apps like Farcaster and Coinbase-style dApps.

## Core Vision

### 🎯 Primary Goals

1. **Sub-Second Latency**: Real-time event delivery for consumer applications
2. **RPC Failover**: Seamless switching between providers (Infura, Alchemy, etc.)
3. **Curated Event Feeds**: Pre-processed, structured events (USDC transfers, NFT mints)
4. **Multi-Chain Support**: Unified API across EVM and non-EVM chains
5. **Viem Integration**: Drop-in compatibility with existing Viem/Wagmi frontends

### 🏗️ Architecture Principles

- **Live-First Design**: Events over RPC calls, streaming over polling
- **Fault Isolation**: Individual connection failures don't affect others
- **Event Curation**: Transform raw logs into structured, actionable events
- **Hybrid API**: Standard JSON-RPC compatibility + enhanced streaming layer
- **Developer Experience**: Minimal integration effort, maximum value

## Technical Architecture

### Hybrid API Design

ChainPulse provides **two complementary layers**:

#### **Layer 1: Standard JSON-RPC** (Viem Compatible)

```
/rpc/ethereum     # Drop-in replacement for Infura/Alchemy
/rpc/arbitrum     # Standard eth_getLogs, eth_subscribe, etc.
```

#### **Layer 2: Enhanced Event Streaming** (ChainPulse Value)

```
/stream/events    # Curated, cross-chain event feeds
/stream/tokens    # ERC-20 transfer streams with USD values
/stream/nfts      # NFT mint/transfer streams with metadata
```

### Core Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     ChainPulse Service                     │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │ Standard    │  │  Enhanced   │  │   Viem SDK  │      │
│  │ JSON-RPC    │  │  Streaming  │  │Integration  │      │
│  │   Layer     │  │    Layer    │  │    Layer    │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │  Broadway   │  │   Event     │  │    ETS      │      │
│  │ Pipelines   │  │ Processing  │  │   Cache     │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │ Ethereum    │  │  Arbitrum   │  │   Solana    │      │
│  │RPC Failover │  │RPC Failover │  │RPC Failover │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │   Infura    │  │   Alchemy   │  │   Public    │      │
│  │ Connection  │  │ Connection  │  │ Connection  │      │
│  │    Pool     │  │    Pool     │  │    Pool     │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

### Key Features

#### 1. **RPC Failover** (Foundation Layer)

- **Multi-Provider Support**: Elixir supervisors manage Infura, Alchemy, public RPC pools
- **Automatic Failover**: Seamless switching on provider failure for uninterrupted data
- **Health Monitoring**: Real-time connection health checks and circuit breakers
- **Load Balancing**: Distribute requests across healthy connections

#### 2. **Real-Time Event Streaming** (Value Layer)

- **Phoenix Channels**: Handle thousands of concurrent WebSocket subscriptions
- **Sub-Second Delivery**: Structured events (e.g., USDC Transfer) delivered in <1 second
- **Broadway Pipelines**: Normalize events across EVM and non-EVM chains
- **Event Curation**: Transform raw logs into actionable, structured data

#### 3. **Viem Integration** (Developer Experience)

- **Standard JSON-RPC**: Drop-in replacement for existing Viem/Wagmi apps
- **Enhanced Streaming**: chainpulse-viem SDK for curated event subscriptions
- **Minimal Integration**: eth_subscribe, eth_getLogs compatibility
- **Progressive Enhancement**: Start with standard RPC, upgrade to enhanced features

#### 4. **Fault Tolerance** (Production Ready)

- **OTP Supervisors**: Individual connection failures don't cascade
- **ETS Caching**: Handle reorgs and temporary network issues
- **Reorg Safety**: Event deduplication and ordering guarantees
- **Circuit Breakers**: Prevent cascade failures across provider networks

## API Design

### Hybrid API Structure

#### **Standard JSON-RPC Layer** (Viem Compatible)

```bash
# Standard Ethereum JSON-RPC (drop-in replacement)
WS /rpc/ethereum              # Standard WebSocket RPC
WS /rpc/arbitrum              # Per-chain standard endpoints
POST /rpc/ethereum            # HTTP RPC for simple calls
```

**Standard Methods Supported:**

- `eth_subscribe` / `eth_unsubscribe`
- `eth_getLogs` with filtering
- `eth_getBlockByNumber` / `eth_getBlockByHash`
- `eth_getTransactionReceipt`
- `eth_newFilter` / `eth_getFilterLogs`

#### **Enhanced Streaming Layer** (ChainPulse Value)

```bash
# Curated event streams
WS /stream/events             # Multi-chain curated events
WS /stream/tokens             # ERC-20 transfers with USD values
WS /stream/nfts               # NFT events with metadata
WS /stream/defi               # DeFi protocol events

# Management API
GET /api/health               # Service health
GET /api/chains               # Supported chains/providers
GET /api/events/types         # Available curated event types
```

### Standard JSON-RPC Events

```json
{
  "jsonrpc": "2.0",
  "method": "eth_subscription",
  "params": {
    "subscription": "0x123...",
    "result": {
      "address": "0xa0b86a33e6441...",
      "topics": [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
      ],
      "data": "0x000000000000000000000000000000000000000000000000016345785d8a0000",
      "blockNumber": "0x12345",
      "transactionHash": "0xabc..."
    }
  }
}
```

### Enhanced ChainPulse Events

```json
{
  "type": "USDC_TRANSFER",
  "chain": "ethereum",
  "blockNumber": 18500000,
  "timestamp": 1703001234,
  "data": {
    "from": "0x123...",
    "to": "0x456...",
    "amount": "1000000000",
    "amountUSD": "1000.00",
    "txHash": "0xabc...",
    "gasUsed": 65000
  }
}
```

## Implementation Roadmap

### Phase 1: Foundation ✅ **COMPLETED**

- ✅ **Phoenix Channels Infrastructure**: Real-time WebSocket streaming
- ✅ **OTP Supervision Trees**: Fault-tolerant GenServer architecture
- ✅ **Multi-Chain Support**: Ethereum, Polygon, Arbitrum, BSC ready
- ✅ **Mock Provider System**: Comprehensive development/testing environment
- ✅ **HTTP API**: Health, status, and chain management endpoints

### Phase 2: Practical Dashboard & Core Features 🔄 **IN PROGRESS**

#### Dashboard Redesign (Weeks 1-4)

- 🔄 **Live System Tab**: Real-time monitoring, network topology, event feed
- 🔄 **Live Test Tab**: Interactive end-to-end testing platform
- 🔄 **Provider Management**: Enhanced visualization of all configured providers
- 🔄 **System Metrics**: Performance monitoring and health dashboards

#### Standard JSON-RPC Layer (Weeks 5-7)

- 🔄 **JSON-RPC WebSocket Handler**: Standard eth_subscribe, eth_getLogs
- 🔄 **Viem Compatibility**: Drop-in replacement for Infura/Alchemy
- 🔄 **HTTP RPC Endpoint**: POST /rpc/ethereum for simple calls
- 🔄 **Provider Failover**: Multi-provider redundancy per chain

### Phase 3: Enhanced Features (Weeks 8-10)

#### Advanced Testing Capabilities

- 🔄 **Load Testing Suite**: Configurable multi-connection stress tests
- 🔄 **Failover Simulation**: Automated provider failure testing
- 🔄 **Performance Benchmarking**: Provider comparison and optimization
- 🔄 **Test Automation**: Scheduled and continuous testing scenarios

#### Stream Processing (Stretch Goal)

- 🔄 **Stream Builder**: Interactive event stream configuration (requires scoping)
- 🔄 **Event Schema**: USDC_TRANSFER, NFT_MINT, etc. structured events
- 🔄 **Cross-Chain Events**: Unified event format across EVM chains
- 🔄 **USD Value Integration**: Real-time price feeds for token amounts

### Phase 4: Production Features (Weeks 11-12)

- 🔄 **ETS Caching**: Reorg handling and event deduplication
- 🔄 **Circuit Breakers**: Provider failure protection
- 🔄 **Performance Optimization**: Sub-second event delivery
- 🔄 **Production Config**: Environment-based provider management

### Phase 5: MVP Deployment (Week 13)

- 🔄 **Monitoring**: Metrics, alerting, observability
- 🔄 **Documentation**: API docs and integration guides
- 🔄 **Load Testing**: Validate performance targets
- 🔄 **Demo Preparation**: Finalize presentation and showcase materials

## Mock Provider Features

The current mock provider system provides:

### ✅ Implemented Features

- **Realistic Data Generation**: Authentic blockchain data structures
- **Configurable Latency**: Simulate network delays (50-200ms)
- **Failure Simulation**: Configurable failure rates (0-100%)
- **Event Streaming**: WebSocket-like subscription events
- **Multiple Networks**: Support for different blockchain networks
- **Statistics Tracking**: Request counts, success rates, event counts

### 🔄 Planned Enhancements

- **Advanced Failure Modes**: Network partitions, timeouts, malformed data
- **Load Testing**: Simulate high-traffic scenarios
- **Data Consistency**: Ensure realistic blockchain state progression
- **Performance Metrics**: Latency histograms, throughput measurements

## Usage Examples

### Basic Setup

```elixir
# Start the service
Application.ensure_all_started(:livechain)

# Create mock endpoints
ethereum = Livechain.RPC.MockWSEndpoint.ethereum_mainnet()
polygon = Livechain.RPC.MockWSEndpoint.polygon()

# Start connections
{:ok, _pid} = Livechain.RPC.WSSupervisor.start_connection(ethereum)
{:ok, _pid} = Livechain.RPC.WSSupervisor.start_connection(polygon)
```

### RPC Calls

```elixir
# Get latest block
{:ok, block} = Livechain.RPC.MockProvider.call(provider, "eth_getBlockByNumber", ["latest", false])

# Get balance
{:ok, balance} = Livechain.RPC.MockProvider.call(provider, "eth_getBalance", ["0x...", "latest"])

# Subscribe to events
Livechain.RPC.MockProvider.subscribe(provider, "newHeads")
```

### Monitoring

```elixir
# Get connection status
connections = Livechain.RPC.WSSupervisor.list_connections()

# Get provider statistics
{:ok, stats} = Livechain.RPC.MockProvider.status(provider)
```

## Testing Strategy

### Unit Tests

- Individual component testing
- Mock provider validation
- Connection lifecycle testing

### Integration Tests

- End-to-end workflow testing
- Multi-provider scenarios
- Failure mode testing

### Load Tests

- High-concurrency scenarios
- Performance benchmarking
- Memory and CPU profiling

### Chaos Engineering

- Network partition simulation
- Provider failure testing
- Recovery time measurement

## Deployment Considerations

### Infrastructure

- **Containerization**: Docker for consistent deployment
- **Orchestration**: Kubernetes for scaling and management
- **Load Balancing**: Nginx or HAProxy for traffic distribution
- **Monitoring**: Prometheus + Grafana for metrics

### Security

- **Rate Limiting**: Protect against abuse
- **Authentication**: API key management
- **Data Validation**: Input sanitization
- **Audit Logging**: Comprehensive request logging

### Scaling

- **Horizontal Scaling**: Multiple service instances
- **Database**: Redis for caching, PostgreSQL for persistence
- **Message Queues**: RabbitMQ for event processing
- **CDN**: CloudFlare for global distribution

## Success Metrics & MVP Targets

### Performance Targets (MVP)

- **Event Latency**: <1 second from blockchain to client
- **RPC Failover**: <5 seconds to switch providers
- **Concurrent Connections**: 1,000+ WebSocket clients
- **Multi-Chain Events**: Ethereum + Arbitrum unified streaming

### Developer Experience Goals

- **Drop-in Compatibility**: Existing Viem apps work without changes
- **Enhanced Value**: 50% less code for common event patterns
- **Integration Time**: <30 minutes from npm install to first events
- **Studio Adoption**: 3+ internal projects using ChainPulse feeds

## Technical Validation

### MVP Test Cases

1. **Viem Integration**: Existing dApp connects without code changes
2. **Event Curation**: USDC transfers delivered with USD values <1s
3. **Failover**: Infura outage doesn't affect app (switches to Alchemy)
4. **Multi-Chain**: Single subscription receives Ethereum + Arbitrum events
5. **Load Test**: 1000 concurrent WebSocket connections streaming events

### Success Criteria

- ✅ **Foundation Built**: Phoenix + OTP architecture proven
- 🔄 **Standard Layer**: JSON-RPC compatibility with Viem
- 🔄 **Enhanced Layer**: Curated events outperform raw log parsing
- 🔄 **Production Ready**: Handles studio traffic without issues

## Why Elixir/Phoenix for ChainPulse

**BEAM VM Advantages:**

- **Concurrency**: Handle thousands of WebSocket connections efficiently
- **Fault Tolerance**: OTP supervisors prevent cascade failures
- **Real-Time**: Phoenix Channels built for sub-second event delivery
- **Maintenance**: Less code than Node.js/Go/Rust alternatives

**Competitive Edge:**

- **Live-First Design**: Events over polling, streaming over batching
- **Multi-Chain Native**: EVM + Solana support from day one
- **Studio Integration**: Built specifically for our Viem/Wagmi stack
- **Operational Excellence**: Self-healing infrastructure with OTP

## Next Steps: Phase 2 Implementation

### Standard JSON-RPC Layer (Week 1)

1. **JSON-RPC Handler**: WebSocket endpoint at `/rpc/ethereum`
2. **Method Routing**: eth_subscribe, eth_getLogs, eth_getBlockByNumber
3. **Viem Testing**: Verify drop-in compatibility
4. **Provider Failover**: Multi-Infura/Alchemy connection pools

### Enhanced Streaming Layer (Week 2-3)

1. **Broadway Pipeline**: Event processing infrastructure
2. **ERC-20 Schema**: USDC_TRANSFER with USD values
3. **NFT Schema**: NFT_MINT/TRANSFER with metadata
4. **Multi-Chain**: Unified events across Ethereum + Arbitrum

### Production Hardening (Week 4)

1. **ETS Caching**: Reorg handling and deduplication
2. **Performance**: Sub-second latency optimization
3. **Monitoring**: Metrics, alerts, observability
4. **Studio Deployment**: Internal testing with real dApps

ChainPulse represents a paradigm shift from reactive RPC calls to proactive event streams, positioning our studio at the forefront of real-time blockchain development.
