# API Reference

Complete reference for Lasso's HTTP and WebSocket JSON-RPC endpoints.

## HTTP Endpoints

All HTTP RPC endpoints accept `POST` requests with `Content-Type: application/json`.

### Base Endpoint

```
POST /rpc/:chain
```

Routes using the default strategy (configurable, defaults to `:round_robin`).

**Example:**

```bash
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Strategy Endpoints

```
POST /rpc/fastest/:chain
POST /rpc/round-robin/:chain
POST /rpc/latency-weighted/:chain
```

### Provider Override

```
POST /rpc/provider/:provider_id/:chain
POST /rpc/:chain/:provider_id
```

Route directly to a specific provider, bypassing strategy selection.

### Profile-Scoped Endpoints

All routes above are available under a profile namespace:

```
POST /rpc/profile/:profile/:chain
POST /rpc/profile/:profile/fastest/:chain
POST /rpc/profile/:profile/round-robin/:chain
POST /rpc/profile/:profile/latency-weighted/:chain
POST /rpc/profile/:profile/provider/:provider_id/:chain
```

Without an explicit profile, requests use the `"default"` profile.

### Chain Identifier

The `:chain` parameter accepts either:
- **Chain name** (string): `ethereum`, `base`, `arbitrum`
- **Chain ID** (numeric): `1`, `8453`, `42161`

---

## WebSocket Endpoints

WebSocket endpoints use raw JSON-RPC protocol (not Phoenix Channels). Connect via standard WebSocket clients.

### Connection URLs

```
ws://host/ws/rpc/:chain
ws://host/ws/rpc/:strategy/:chain
ws://host/ws/rpc/provider/:provider_id/:chain
ws://host/ws/rpc/:chain/:provider_id
```

### Profile-Scoped

```
ws://host/ws/rpc/profile/:profile/:chain
ws://host/ws/rpc/profile/:profile/:strategy/:chain
ws://host/ws/rpc/profile/:profile/provider/:provider_id/:chain
```

### WebSocket Protocol

**Client sends:**

```json
{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
```

**Server responds:**

```json
{"jsonrpc":"2.0","id":1,"result":"0xabc123..."}
```

**Server pushes (subscription events):**

```json
{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xabc123...","result":{...}}}
```

### Supported Subscription Types

| Type | Params | Description |
|------|--------|-------------|
| `newHeads` | `["newHeads"]` | New block headers |
| `logs` | `["logs", {"address":"0x...", "topics":["0x..."]}]` | Log events matching filter |

### Unsubscribe

```json
{"jsonrpc":"2.0","method":"eth_unsubscribe","params":["0xabc123..."],"id":2}
```

### Connection Lifecycle

- **Heartbeat**: Server sends ping every 30 seconds
- **Timeout**: Pong must be received within 5 seconds
- **Max missed**: Connection closed after 2 missed heartbeats
- **Session timeout**: 2 hours maximum connection duration

---

## Authentication

All RPC endpoints require an API key. Provide it via any of these methods:

| Method | Example |
|--------|---------|
| Query parameter | `?key=lasso_abc123` |
| Header | `X-Lasso-Api-Key: lasso_abc123` |
| Bearer token | `Authorization: Bearer lasso_abc123` |

**HTTP Example:**

```bash
curl -X POST 'http://localhost:4000/rpc/ethereum?key=lasso_abc123' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**WebSocket Example:**

```bash
wscat -c 'ws://localhost:4000/ws/rpc/ethereum?key=lasso_abc123'
```

---

## Request Headers

| Header | Description |
|--------|-------------|
| `Content-Type` | Must be `application/json` |
| `X-Lasso-Api-Key` | API key for authentication |
| `Authorization` | Bearer token authentication (`Bearer lasso_...`) |
| `X-Lasso-Provider` | Override provider selection (same as `/provider/:id` route) |
| `X-Lasso-Transport` | Force transport: `http` or `ws` |
| `X-Lasso-Include-Meta` | Request observability metadata: `headers` or `body` |

---

## Query Parameters

| Parameter | Values | Description |
|-----------|--------|-------------|
| `key` | `lasso_...` | API key |
| `include_meta` | `headers`, `body` | Return routing metadata with response |
| `transport` | `http`, `ws` | Force transport selection |
| `provider` | provider ID | Override provider selection |

---

## Response Headers

Standard responses include:

| Header | Description |
|--------|-------------|
| `Content-Type` | `application/json` |
| `X-Request-Id` | Phoenix request ID |

With `include_meta=headers`:

| Header | Description |
|--------|-------------|
| `X-Lasso-Request-ID` | Lasso request tracking ID |
| `X-Lasso-Meta` | Base64url-encoded JSON with routing metadata |

---

## Observability Metadata

Request `include_meta=headers` or `include_meta=body` to receive routing metadata.

### Headers Mode

```bash
curl -X POST 'http://localhost:4000/rpc/ethereum?include_meta=headers' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -i
```

Response headers include `X-Lasso-Request-ID` and `X-Lasso-Meta` (base64url-encoded JSON).

### Body Mode

```bash
curl -X POST 'http://localhost:4000/rpc/ethereum?include_meta=body' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Response body includes a `lasso_meta` field:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x8471c9a",
  "lasso_meta": {
    "request_id": "abc-123",
    "strategy": "fastest",
    "selected_provider": {"id": "ethereum_llamarpc"},
    "upstream_latency_ms": 45,
    "retries": 0,
    "circuit_breaker_state": "closed"
  }
}
```

### WebSocket Metadata

Add `"lasso_meta": "notify"` to your request to receive metadata as a separate frame:

```json
{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1,"lasso_meta":"notify"}
```

The server sends two frames:
1. The RPC response (unmodified)
2. A metadata notification:

```json
{"jsonrpc":"2.0","method":"lasso_meta","params":{"request_id":"...","upstream_latency_ms":45}}
```

---

## Batch Requests

HTTP endpoints support JSON-RPC batch requests (arrays). Maximum 50 requests per batch (configurable).

```bash
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2}
  ]'
```

Response preserves request order as a JSON array.

---

## Supported Methods

### Read-Only Methods (HTTP + WebSocket)

| Method | Description |
|--------|-------------|
| `eth_blockNumber` | Latest block number |
| `eth_getBlockByNumber` | Block by number |
| `eth_getBlockByHash` | Block by hash |
| `eth_getLogs` | Historical log queries |
| `eth_getBalance` | Account balance |
| `eth_getTransactionCount` | Account nonce |
| `eth_getCode` | Contract bytecode |
| `eth_call` | Read-only contract call |
| `eth_estimateGas` | Gas estimation |
| `eth_gasPrice` | Current gas price |
| `eth_maxPriorityFeePerGas` | EIP-1559 priority fee |
| `eth_feeHistory` | Historical fee data |
| `eth_chainId` | Chain ID (served locally, no upstream call) |
| `eth_getTransactionByHash` | Transaction by hash |
| `eth_getTransactionReceipt` | Transaction receipt |
| `eth_getStorageAt` | Storage slot value |

### Subscription Methods (WebSocket Only)

| Method | Description |
|--------|-------------|
| `eth_subscribe` | Create subscription (newHeads, logs) |
| `eth_unsubscribe` | Cancel subscription |

### Unsupported Methods

Write methods (`eth_sendRawTransaction`, `eth_sendTransaction`) are not currently supported. Subscription methods (`eth_subscribe`) are rejected over HTTP with a WebSocket URL hint.

---

## Error Responses

All errors follow JSON-RPC 2.0 format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not supported over HTTP. Use WebSocket connection for subscriptions.",
    "data": {"websocket_url": "/socket/websocket"}
  }
}
```

### Error Codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error (malformed JSON) |
| `-32600` | Invalid Request (missing required fields, batch too large) |
| `-32601` | Method not found or not supported on this transport |
| `-32602` | Invalid params (unsupported chain, missing chain_id) |
| `-32603` | Internal error |
| `-32000` | Server error (rate limit, strategy access denied, quota exceeded) |

### Rate Limiting

When rate limited, the error includes retry information:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32000,
    "message": "Rate limit exceeded. Limit: 100 requests per second.",
    "data": {"retry_after_ms": 150, "rate_limit": 100}
  }
}
```

---

## Non-RPC API Endpoints

### Health Check

```
GET /api/health
```

Returns system health status.

### Chain Status

```
GET /api/chains
GET /api/chains/:chain_id/status
```

Returns available chains and per-chain provider status.

### Metrics

```
GET /api/metrics/:chain
```

Returns provider performance metrics for a chain.

---

## CORS

All origins are allowed (`*`). Allowed headers:

- `Content-Type`
- `Authorization`
- `X-Requested-With`
- `X-Lasso-Provider`
- `X-Lasso-Transport`

Preflight responses are cached for 24 hours.
