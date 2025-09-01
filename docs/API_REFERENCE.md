# Livechain API Reference

## Health & Status Endpoints

### **Health Check**

```
GET /api/health
```

Returns basic service health status.

**Response:**

```json
{
  "status": "ok",
  "timestamp": "2024-01-01T00:00:00Z"
}
```

### **System Status**

```
GET /api/status
```

Returns detailed system and provider status.

**Response:**

```json
{
  "chains": {
    "ethereum": {
      "providers": ["infura_ethereum", "alchemy_ethereum"],
      "healthy_providers": 2,
      "total_providers": 2
    }
  },
  "connections": 8,
  "uptime": 3600
}
```

---

## JSON-RPC Endpoints

### **Ethereum Mainnet**

```
POST /rpc/ethereum
WebSocket: ws://localhost:4000/rpc/ethereum
```

### **HTTP vs WebSocket Behavior**

- **HTTP (POST /rpc/:chain)**: Read-only JSON-RPC methods are forwarded to upstream providers via the orchestration layer. Subscriptions are not supported over HTTP.
- **WebSocket (ws://.../rpc/:chain)**: Supports both real-time JSON-RPC subscriptions (`eth_subscribe`, `eth_unsubscribe`) and generic forwarding of read-only JSON-RPC methods using the same provider selection and failover logic as HTTP.

If a WS-only method is called over HTTP, the service returns a JSON-RPC error with a hint to use the WebSocket endpoint.

### **Supported Methods (HTTP & WS)**

Currently implemented and forwarded JSON-RPC methods include but are not limited to:

#### **Block Queries**

```bash
# Get latest block number
curl -X POST http://localhost:4000/rpc/ethereum \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Get block by number
curl -X POST http://localhost:4000/rpc/ethereum \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}'
```

#### **Account Queries**

```bash
# Get account balance
curl -X POST http://localhost:4000/rpc/ethereum \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x...","latest"],"id":1}'
```

#### **Log Queries**

```bash
# Get logs with filter
curl -X POST http://localhost:4000/rpc/ethereum \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"eth_getLogs",
    "params":[{
      "fromBlock":"latest",
      "toBlock":"latest",
      "address":"0xA0b86991c6218B36C1d19D4a2e9Eb0cE3606eB48"
    }],
    "id":1
  }'
```

### **WebSocket Subscriptions (WS)**

```javascript
// WebSocket connection
const ws = new WebSocket("ws://localhost:4000/rpc/ethereum");

// Subscribe to new blocks
ws.send(
  JSON.stringify({
    jsonrpc: "2.0",
    method: "eth_subscribe",
    params: ["newHeads"],
    id: 1,
  })
);

// Subscribe to logs
ws.send(
  JSON.stringify({
    jsonrpc: "2.0",
    method: "eth_subscribe",
    params: [
      "logs",
      {
        address: "0xA0b86991c6218B36C1d19D4a2e9Eb0cE3606eB48",
      },
    ],
    id: 2,
  })
);
```

---

## Provider Selection Strategy

The orchestrator uses a pluggable provider selection strategy when forwarding JSON-RPC calls over both HTTP and WebSocket.

- **Default**: `:fastest` (performance-based routing)
- **Alternatives**: `:cheapest` (prefers free providers), `:priority` (static config), `:round_robin` (load balanced)

Configuration:

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :fastest
# :cheapest, :priority or :round_robin can be used instead
```

---

## Phoenix Channels (Internal)

### **Blockchain Events**

```
WS /socket/websocket
Topic: "blockchain:ethereum"
```

Connect to real-time blockchain event streams:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", {});
socket.connect();

const channel = socket.channel("blockchain:ethereum", {});
channel.join();

channel.on("new_block", (payload) => {
  console.log("New block:", payload);
});
```

---

## Error Handling

### **Standard JSON-RPC Errors**

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32601,
    "message": "Method not found"
  },
  "id": 1
}
```

### **Provider Errors**

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32000,
    "message": "Provider unavailable",
    "data": {
      "provider": "infura_ethereum",
      "reason": "circuit_open"
    }
  },
  "id": 1
}
```

---

## Rate Limits & Performance

### **Current Limitations**

- **Provider dependent**: Rate limits inherited from upstream providers
- **Racing overhead**: ~5ms additional latency for benchmarking
- **Memory bounds**: 24-hour metric retention per chain

### **Performance Characteristics**

- **Throughput**: 1000+ requests/second per chain
- **Latency**: Provider latency + 5ms racing overhead
- **Availability**: 99%+ (with multi-provider failover)

---

## Configuration

### **Provider Configuration**

Providers are configured per chain in the application configuration:

```elixir
config :livechain,
  chains: %{
    "ethereum" => %{
      providers: [
        %{id: "infura", url: "wss://mainnet.infura.io/ws/v3/#{api_key}"},
        %{id: "alchemy", url: "wss://eth-mainnet.alchemyapi.io/v2/#{api_key}"}
      ]
    }
  }
```

### **Circuit Breaker Settings**

```elixir
config :livechain, :circuit_breaker,
  failure_threshold: 5,      # failures before opening
  recovery_timeout: 60_000,  # ms before attempting recovery
  success_threshold: 2       # successes before closing
```

---

**Note**: This API is currently in development. Method coverage and endpoint stability may change. The benchmarking API is designed for internal use and monitoring dashboards.
