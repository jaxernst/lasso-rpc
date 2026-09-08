# API Reference

Complete reference for Lasso's HTTP and WebSocket JSON-RPC endpoints.

## HTTP Endpoints

All HTTP RPC endpoints accept `POST` requests with `Content-Type: application/json`.

### Base Endpoint

```
POST /rpc/:chain
```

Routes using the default strategy (configurable, defaults to `:load_balanced`).

**Example:**

```bash
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Strategy Endpoints

```
POST /rpc/fastest/:chain
POST /rpc/load-balanced/:chain
POST /rpc/latency-weighted/:chain
POST /rpc/round-robin/:chain
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
POST /rpc/profile/:profile/load-balanced/:chain
POST /rpc/profile/:profile/latency-weighted/:chain
POST /rpc/profile/:profile/provider/:provider_id/:chain
```

Without an explicit profile, requests use the included `"public"` profile. `default` remains a compatibility alias for `public`.

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
Lasso OSS does not provide client authentication. Put it behind reverse-proxy authentication or a private network boundary before exposing it outside a trusted environment. See [SECURITY.md](../SECURITY.md).

---

## Request Headers

| Header | Description |
|--------|-------------|
| `Content-Type` | Must be `application/json` |
| `X-Lasso-Provider` | Override provider selection (same as `/provider/:id` route) |
| `X-Lasso-Transport` | Force transport: `http` or `ws` |
| `X-Lasso-Include-Meta` | Request observability metadata: `headers` or `body` |

---

## Query Parameters

| Parameter | Values | Description |
|-----------|--------|-------------|
| `include_meta` | `headers`, `body` | Return routing metadata with response |
| `transport` | `http`, `ws` | Force transport selection |
| `provider_override` or `provider_id` | provider ID | Override provider selection |

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

Each item is validated and routed independently with bounded concurrency and its own execution deadline. A batch does not imply one provider or an atomic state snapshot. Valid notifications produce no response item; an all-notification batch returns HTTP 204.

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

`eth_sendRawTransaction` is routable with one upstream dispatch under one deadline. A lost response can mean the transaction was accepted; clients reconcile its hash. `eth_sendTransaction`, `eth_accounts`, `eth_sign`, `eth_signTransaction`, and `personal_sign` are globally disallowed. Provider capability policy can impose additional restrictions. Subscription methods are rejected over HTTP with a WebSocket URL hint. See [Method support](RPC_STANDARDS.md) for the released Core contract.

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
    "data": {"websocket_url": "/ws/rpc/ethereum"}
  }
}
```

The `websocket_url` mirrors the HTTP request path — for example, a request to
`/rpc/profile/public/fastest/ethereum` returns `/ws/rpc/profile/public/fastest/ethereum`.

### Error Codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error (malformed JSON) |
| `-32600` | Invalid Request (missing required fields, batch too large) |
| `-32601` | Method not found or not supported on this transport |
| `-32602` | Invalid params (unsupported chain, missing chain_id) |
| `-32603` | Internal error |
| `-32000` | Server error (for example, upstream rate limiting or exhausted routing) |

### Upstream rate limits

RPC Core has no built-in client authentication or incoming per-client quotas.
Provider rate limits can cause cooldowns, failover, or an RPC error. Configure
incoming admission at your reverse proxy. Profile `rps_limit` controls the
dashboard tester maximum; `burst_limit` is metadata, not ingress enforcement.

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
```

Returns the configured chains in the included `public` profile.

### Metrics

```
GET /api/metrics/:chain
```

Returns node-local upstream attempt metrics for a configured chain in the `public`
profile, including provider and per-method latency and success data. These are
upstream attempt measurements, not end-to-end client request counts.

`chain_performance.total_providers` counts configured providers, including those
without traffic. `success_rate` and `error_rate_percent` are percentages and are
`null` before any observations. Provider and per-method success rates are fractions
between 0 and 1. Latency percentiles use retained samples from provider/method
entries updated within five minutes.

The response retains `failovers_last_minute`, `recent_activity`, and
`rpc_calls_per_second` as `null`: this endpoint does not collect those measurements.
The dashboard provides live client traffic counters.

---

## CORS

All origins are allowed (`*`). Allowed headers:

- `Content-Type`
- `Authorization`
- `X-Requested-With`
- `X-Lasso-Provider`
- `X-Lasso-Transport`
- `X-Lasso-Include-Meta`

Preflight responses are cached for 24 hours.
