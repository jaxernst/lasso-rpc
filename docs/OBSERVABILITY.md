# Request Observability System

## Overview

Lasso's observability system provides comprehensive visibility into RPC request routing, execution, and performance with minimal overhead. It captures detailed metadata about provider selection, circuit breaker states, timing breakdowns, and retry behavior through structured logs and optional client-visible metadata.

## Architecture

### Core Components

1. **RequestContext** (`lib/lasso/core/request/request_context.ex`)

   - Stateless struct tracking request lifecycle
   - Threads through entire execution pipeline
   - Captures selection, execution, and result phases

2. **Observability** (`lib/lasso/core/request/request_pipeline/observability.ex`)

   - Emits structured `rpc.request.completed` events
   - Builds client-visible metadata
   - Handles sampling, redaction, and size limits

3. **ObservabilityPlug** (`lib/lasso_web/plugs/observability_plug.ex`)
   - Parses client opt-in preferences
   - Injects metadata into HTTP headers or response body
   - Middleware for all `/rpc/*` endpoints

## Request Lifecycle

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. REQUEST INITIATION                                               │
│    Client → ObservabilityPlug → RPCController                       │
│    • Parse include_meta parameter (headers/body/none)               │
│    • Store preference in conn.assigns                               │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 2. CONTEXT CREATION                                                 │
│    RequestPipeline.execute_via_channels/4                           │
│    • Create RequestContext with request details                     │
│    • Generate unique request_id                                     │
│    • Record chain, method, transport, strategy                      │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 3. PROVIDER SELECTION                                               │
│    RequestPipeline.execute_with_channel_selection/5                 │
│    • Mark selection start time                                      │
│    • Call Selection.select_channels (get candidate list)           │
│    • Mark selection end, compute latency                            │
│    • Record candidate_providers and selected_provider              │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 4. EXECUTION & RETRY                                                │
│    RequestPipeline.attempt_request_on_channels/4                    │
│    • Mark upstream start time                                       │
│    • Capture circuit_breaker_state before call                      │
│    • Execute request via CircuitBreaker.call/3                      │
│    • On retry: increment retries counter                            │
│    • Mark upstream end, compute latency                             │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 5. RESULT RECORDING                                                 │
│    RequestPipeline.execute_with_channel_selection/5                 │
│    • Call RequestContext.record_success/2 or record_error/2        │
│    • Compute end_to_end_latency_ms                                  │
│    • Store result_type or error details                             │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 6. LOGGING & STORAGE                                                │
│    RequestPipeline.execute_via_channels/4                           │
│    • Call Observability.log_request_completed(updated_ctx)          │
│    • Emit telemetry event                                           │
│    • Store context in Process dictionary                            │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 7. METADATA INJECTION                                               │
│    RPCController.handle_json_rpc/3                                  │
│    • Retrieve context from Process dictionary                       │
│    • If include_meta=headers: inject X-Lasso-* headers             │
│    • If include_meta=body: enrich response with lasso_meta         │
│    • Return to client                                               │
└─────────────────────────────────────────────────────────────────────┘
```

## Structured Log Schema

### Complete Event Structure

```json
{
  "event": "rpc.request.completed",
  "request_id": "uuid-v4",
  "strategy": "fastest|priority|round_robin|latency_weighted",
  "chain": "ethereum",
  "transport": "http|ws",
  "jsonrpc_method": "eth_blockNumber",
  "params_present": false,
  "routing": {
    "candidate_providers": [
      "ethereum_cloudflare:http",
      "ethereum_llamarpc:http",
      "ethereum_llamarpc:ws"
    ],
    "selected_provider": {
      "id": "ethereum_llamarpc",
      "protocol": "http"
    },
    "selection_reason": "fastest_method_latency",
    "retries": 2,
    "circuit_breaker_state": "closed|open|half_open|unknown"
  },
  "timing": {
    "selection_latency_ms": 3,
    "upstream_latency_ms": 592,
    "end_to_end_latency_ms": 595
  },
  "response": {
    "status": "success|error",
    "result_type": "string|object|array|null",
    "result_size_bytes": 11,
    "error": {
      "code": -32000,
      "message": "Cannot fulfill request",
      "category": "server_error"
    }
  }
}
```

### Field Descriptions

#### Top-Level Fields

- **event**: Always `"rpc.request.completed"`
- **request_id**: UUID v4 generated per request
- **strategy**: Provider selection strategy used
- **chain**: Chain name (e.g., "ethereum", "base")
- **transport**: Protocol used ("http" or "ws")
- **jsonrpc_method**: RPC method called (e.g., "eth_blockNumber")
- **params_present**: Boolean indicating if params were provided

#### Routing Section

- **candidate_providers**: List of providers considered (format: "provider_id:protocol")
- **selected_provider**: Provider chosen for execution
  - **id**: Provider identifier
  - **protocol**: Transport protocol used
- **selection_reason**: Why this provider was selected
  - `"fastest_method_latency"` - Performance-based (fastest strategy)
  - `"static_priority"` - Config priority (priority strategy)
  - `"round_robin_rotation"` - Load balancing (round_robin strategy)
- **retries**: Number of retry attempts (0 = first try succeeded)
- **circuit_breaker_state**: CB state when request was made
  - `"closed"` - Healthy, normal operation
  - `"open"` - Unhealthy, requests rejected
  - `"half_open"` - Recovery attempt in progress
  - `"unknown"` - CB state unavailable

#### Timing Section

- **selection_latency_ms**: Provider selection duration (authoritative timing metric)
- **upstream_latency_ms**: Time from sending request to receiving response
- **end_to_end_latency_ms**: Total request duration (selection + upstream + overhead)

#### Response Section

- **status**: `"success"` or `"error"`
- **result_type**: Type of result (success only)
- **result_size_bytes**: Byte size of result (success only)
- **error**: Error details (error only)
  - **code**: JSON-RPC error code
  - **message**: Error message (truncated to max_error_message_chars)
  - **category**: Error category (e.g., "server_error", "client_error")

## Client-Visible Metadata

### Opt-in Mechanisms

Clients control metadata visibility via:

1. **Query Parameter**: `?include_meta=headers|body`
2. **Request Header**: `X-Lasso-Include-Meta: headers|body`
3. **Default**: No metadata included (opt-in only)

### Header Mode (`include_meta=headers`)

Response includes:

```
X-Lasso-Request-ID: d12fd341cc14fc97ce9f09876fffa7a3
X-Lasso-Meta: eyJ2ZXJzaW9uIjoiMS4wIiwic3RyYXRlZ3kiOiJjaGVh...
```

`X-Lasso-Meta` contains base64url-encoded JSON with:

```json
{
  "version": "1.0",
  "request_id": "uuid",
  "strategy": "round_robin",
  "chain": "ethereum",
  "transport": "http",
  "selected_provider": { "id": "ethereum_llamarpc", "protocol": "http" },
  "candidate_providers": ["ethereum_cloudflare:http", "ethereum_llamarpc:http"],
  "upstream_latency_ms": 525,
  "retries": 1,
  "circuit_breaker_state": "closed",
  "end_to_end_latency_ms": 528
}
```

**Size Limit**: If encoded metadata exceeds `max_meta_header_bytes` (default 4KB), only `X-Lasso-Request-ID` is included.

### Body Mode (`include_meta=body`)

Standard JSON-RPC response enriched with `lasso_meta` field:

```json
{
  "id": 1,
  "result": "0x8471c9a",
  "jsonrpc": "2.0",
  "lasso_meta": {
    "version": "1.0",
    "request_id": "uuid",
    "strategy": "round_robin",
    "chain": "ethereum",
    "transport": "http",
    "selected_provider": { "id": "ethereum_llamarpc", "protocol": "http" },
    "candidate_providers": ["ethereum_cloudflare:http"],
    "upstream_latency_ms": 525,
    "retries": 1,
    "circuit_breaker_state": "closed",
    "end_to_end_latency_ms": 525
  }
}
```

**No Size Limit**: Body mode always includes full metadata (response body size is not limited).

## Privacy & Redaction

### Sensitive Data Handling

#### Error Message Truncation

- **Truncation**: Error messages limited to `max_error_message_chars` (default 256)
- **Reason**: Prevents logging unbounded error responses from providers
- **Preserves**: Error code and category always included

#### No Secrets in Logs

- **Provider URLs**: Not logged (only provider IDs)
- **API Keys**: Never exposed in any log or metadata
- **Client IPs**: Not logged by default (can be added if needed)

### Sampling

High-volume scenarios can use sampling to reduce log volume:

```elixir
config :lasso, :observability,
  sampling: [rate: 0.1]  # Log 10% of requests
```

- **Rate**: Float between 0.0 (none) and 1.0 (all)
- **Random sampling**: Each request independently sampled
- **Client metadata unaffected**: Sampling only affects server logs

## Configuration Reference

### Complete Configuration

```elixir
# config/config.exs
config :lasso, :observability,
  # Log level for rpc.request.completed events
  log_level: :info,

  # Maximum error message length in logs
  max_error_message_chars: 256,

  # Maximum size for X-Lasso-Meta header
  # If exceeded, only X-Lasso-Request-ID is sent
  max_meta_header_bytes: 4096,

  # Sampling configuration
  sampling: [
    rate: 1.0  # 1.0 = log all requests, 0.1 = log 10%
  ]
```

### Environment-Specific Settings

**Development**:

```elixir
# config/dev.exs
config :lasso, :observability,
  log_level: :debug,
  sampling: [rate: 1.0]
```

**Production**:

```elixir
# config/prod.exs
config :lasso, :observability,
  log_level: :info,
  sampling: [rate: 0.5]  # 50% sampling for high traffic
```

**Test**:

```elixir
# config/test.exs
config :lasso, :observability,
  log_level: :warn,
  sampling: [rate: 0.0]  # Disable in tests
```

## Performance Characteristics

### Overhead Breakdown

| Operation           | Overhead  | Notes                       |
| ------------------- | --------- | --------------------------- |
| Context creation    | <1ms      | Single struct allocation    |
| Timing markers      | <0.1ms    | System.monotonic_time/0     |
| Provider selection  | 2-5ms     | Existing selection overhead |
| Log emission        | <5ms      | Async logger, sampling      |
| Header encoding     | <2ms      | JSON encode + base64url     |
| Body enrichment     | <1ms      | Map.put operation           |
| **Total (headers)** | **~10ms** | End-to-end with metadata    |
| **Total (body)**    | **~9ms**  | End-to-end with metadata    |
| **Total (none)**    | **~8ms**  | End-to-end without metadata |

### Memory Usage

- **RequestContext struct**: ~200 bytes per request
- **Process dictionary storage**: ~200 bytes per request (until response sent)
- **Log buffer**: Varies by logger backend (async by default)
- **Peak usage**: <1KB per in-flight request

### Scalability

- **High concurrency**: No shared state, per-request context
- **Sampling support**: Reduces log volume without code changes
- **Async logging**: Non-blocking log emission
- **No persistence**: Context discarded after response

## Use Cases

### 1. Debugging Provider Selection

**Scenario**: Understand why a specific provider was chosen

**Example**:

```bash
curl "http://localhost:4000/rpc/ethereum?include_meta=body" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Metadata shows**:

```json
{
  "lasso_meta": {
    "strategy": "fastest",
    "candidate_providers": ["ethereum_alchemy:http", "ethereum_infura:http"],
    "selected_provider": { "id": "ethereum_alchemy", "protocol": "http" },
    "selection_reason": "fastest_method_latency"
  }
}
```

**Insight**: Alchemy selected because it has lowest latency for `eth_blockNumber`

### 2. Monitoring Retry Behavior

**Scenario**: Track failover attempts and circuit breaker states

**Log excerpt**:

```json
{
  "event": "rpc.request.completed",
  "routing": {
    "retries": 2,
    "circuit_breaker_state": "closed",
    "candidate_providers": [
      "ethereum_cloudflare:http",
      "ethereum_llamarpc:http"
    ],
    "selected_provider": { "id": "ethereum_llamarpc", "protocol": "http" }
  }
}
```

**Insight**: Request failed on first two providers, succeeded on third (llamarpc)

### 3. Performance Analysis

**Scenario**: Identify slow requests and upstream latency

**Query**:

```bash
# Extract timing data from logs
cat logs/app.log | grep 'rpc.request.completed' | jq '.timing'
```

**Output**:

```json
{
  "selection_latency_ms": 3,
  "upstream_latency_ms": 592,
  "end_to_end_latency_ms": 595
}
```

**Insight**: 592ms spent waiting for provider, 3ms on selection

### 4. Client-Side Debugging

**Scenario**: End-user reports slow requests, wants visibility

**Client code**:

```typescript
const response = await fetch("http://lasso/rpc/ethereum?include_meta=headers", {
  method: "POST",
  body: JSON.stringify({
    jsonrpc: "2.0",
    method: "eth_blockNumber",
    params: [],
    id: 1,
  }),
});

const requestId = response.headers.get("x-lasso-request-id");
const base64url = response.headers.get("x-lasso-meta") || "";
const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
const meta = JSON.parse(atob(base64));

console.log(
  `Request ${requestId}: ${meta.upstream_latency_ms}ms via ${meta.selected_provider.id}`
);
```

**Output**: `Request d12fd341: 592ms via ethereum_llamarpc`

### 5. Error Correlation

**Scenario**: Track error patterns across providers

**Log excerpt**:

```json
{
  "event": "rpc.request.completed",
  "routing": {
    "selected_provider": { "id": "ethereum_cloudflare", "protocol": "http" },
    "retries": 0,
    "circuit_breaker_state": "closed"
  },
  "response": {
    "status": "error",
    "error": {
      "code": -32046,
      "message": "Cannot fulfill request",
      "category": "server_error"
    }
  }
}
```

**Insight**: Cloudflare returning -32046 errors, may need circuit breaker tuning

## WebSocket Support (Future)

### Planned Implementation

WebSocket observability will follow similar patterns:

**Inline Metadata** (default):

```json
{
  "jsonrpc": "2.0",
  "method": "eth_subscription",
  "params": {
    "subscription": "0x123",
    "result": {...}
  },
  "lasso_meta": {
    "request_id": "uuid",
    "upstream_latency_ms": 12
  }
}
```

**Notification Metadata** (opt-in):

```json
{
  "jsonrpc": "2.0",
  "method": "lasso_meta",
  "params": {
    "request_id": "uuid",
    "subscription": "0x123",
    "routing": {...},
    "timing": {...}
  }
}
```

**Opt-in via connection**:

```json
{
  "jsonrpc": "2.0",
  "method": "lasso_config",
  "params": {
    "include_meta": "inline|notify|none"
  },
  "id": 1
}
```

## Telemetry Integration

### Events Emitted

```elixir
:telemetry.execute(
  [:lasso, :observability, :request_completed],
  %{count: 1},
  %{
    event: "rpc.request.completed",
    request_id: "uuid",
    strategy: "fastest",
    chain: "ethereum",
    # ... full event map
  }
)
```

### Custom Handlers

```elixir
# In your application
:telemetry.attach(
  "my-observability-handler",
  [:lasso, :observability, :request_completed],
  &MyApp.Observability.handle_request_completed/4,
  nil
)

defmodule MyApp.Observability do
  def handle_request_completed(_event, measurements, metadata, _config) do
    # Send to external monitoring service
    MyApp.Monitoring.track_request(metadata)
  end
end
```

---

## TelemetryLogger

`Lasso.TelemetryLogger` bridges telemetry events to structured logs for production debugging. It attaches to events at application startup and logs at appropriate severity levels.

### Configuration

```elixir
config :lasso, Lasso.TelemetryLogger,
  enabled: true,
  log_slow_requests: true,
  log_failovers: true,
  log_circuit_breaker: true
```

### Attached Handlers

| Event | Log Level | Description |
|-------|-----------|-------------|
| `[:lasso, :failover, :fast_fail]` | WARNING | Provider failover triggered |
| `[:lasso, :failover, :circuit_open]` | WARNING | Circuit breaker blocked request |
| `[:lasso, :failover, :degraded_mode]` | WARNING | Entered degraded mode (trying half-open circuits) |
| `[:lasso, :failover, :degraded_success]` | INFO | Recovered via degraded mode |
| `[:lasso, :failover, :exhaustion]` | ERROR | All providers exhausted |
| `[:lasso, :request, :slow]` | WARNING | Request took >2000ms |
| `[:lasso, :request, :very_slow]` | ERROR | Request took >4000ms |
| `[:lasso, :circuit_breaker, :open]` | WARNING | Circuit breaker opened |
| `[:lasso, :circuit_breaker, :close]` | INFO | Circuit breaker closed (recovered) |
| `[:lasso, :circuit_breaker, :half_open]` | INFO | Circuit breaker testing recovery |
| `[:lasso, :circuit_breaker, :proactive_recovery]` | INFO | Circuit breaker proactive recovery |

### Logging Architecture

State transition logs use a single-source-of-truth pattern:

- **TelemetryLogger** handles all state transition logging via telemetry handlers
- **CircuitBreaker** only logs context not available in telemetry metadata:
  - First failure (debug level)
  - Opening after threshold exceeded (warning, includes failure count)
  - Re-opening after failed recovery (error)

---

## Metrics Reference

Metrics defined in `Lasso.Telemetry.metrics/0` for LiveDashboard and reporters.

### Circuit Breaker Metrics

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `lasso.circuit_breaker.admit.latency` | Distribution | chain, provider_id, transport, decision | Admission call latency |
| `lasso.circuit_breaker.admit.count` | Counter | chain, provider_id, transport, decision | Admission decisions |
| `lasso.circuit_breaker.open.count` | Counter | chain, provider_id, transport, reason | Circuit openings |
| `lasso.circuit_breaker.close.count` | Counter | chain, provider_id, transport, reason | Circuit closings |
| `lasso.circuit_breaker.half_open.count` | Counter | chain, provider_id, transport, reason | Half-open transitions |
| `lasso.circuit_breaker.proactive_recovery.count` | Counter | chain, provider_id, transport | Proactive recovery attempts |
| `lasso.circuit_breaker.failure.count` | Counter | chain, provider_id, transport, error_category, circuit_state | Failures by category and state |

### RPC Request Metrics

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `lasso.rpc.request.duration` | Distribution | chain, method, provider_id, transport, status | End-to-end request duration |
| `lasso.rpc.request.count` | Counter | chain, method, provider_id, transport, status | Request count |

### Transport Metrics

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `lasso.http.request.io.latency` | Distribution | provider_id, method | HTTP I/O time |
| `lasso.ws.request.io.latency` | Distribution | provider_id, method | WebSocket I/O time |
| `lasso.websocket.connected.count` | Counter | provider_id, chain | WebSocket connections |
| `lasso.websocket.disconnected.count` | Counter | provider_id, chain, unexpected | WebSocket disconnections |
| `lasso.websocket.request.duration` | Distribution | provider_id, method, status | WebSocket request duration |
| `lasso.websocket.pending_cleanup.count` | Counter | provider_id | Pending request cleanups on disconnect |
| `lasso.websocket.pending_cleanup.pending_count` | Summary | - | Pending requests cleaned up per disconnect |

### Failover Metrics

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `lasso.failover.fast_fail.count` | Counter | chain, provider_id, transport, error_category | Provider failovers |
| `lasso.failover.circuit_open.count` | Counter | chain, provider_id, transport | Requests skipped (circuit open) |
| `lasso.failover.degraded_mode.count` | Counter | chain | Degraded mode entries |
| `lasso.failover.degraded_success.count` | Counter | chain, provider_id, transport | Degraded mode recoveries |
| `lasso.failover.exhaustion.count` | Counter | chain | All providers exhausted |

### Provider & Streaming Metrics

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `lasso.provider.status.count` | Counter | chain, provider_id, status | Provider status changes |
| `lasso.stream.dropped_event.count` | Counter | chain, reason | Events dropped in degraded mode |
| `lasso.upstream_subscriptions.orphaned_event.count` | Counter | chain | Orphaned subscription events |

### Cluster Metrics

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `lasso.cluster.topology.node_connected.count` | Counter | node | Cluster node connections |
| `lasso.cluster.topology.node_disconnected.count` | Counter | node | Cluster node disconnections |

## Troubleshooting

### No Logs Appearing

**Check sampling rate**:

```elixir
# config/config.exs
config :lasso, :observability,
  sampling: [rate: 1.0]  # Ensure this is > 0
```

**Check log level**:

```elixir
config :lasso, :observability,
  log_level: :info  # Must be enabled in logger config
```

### Metadata Not in Response

**Verify opt-in parameter**:

```bash
# ✓ Correct
curl "http://localhost:4000/rpc/ethereum?include_meta=headers"

# ✗ Missing
curl "http://localhost:4000/rpc/ethereum"
```

**Check ObservabilityPlug**:

```elixir
# lib/lasso_web/router.ex
pipeline :api_with_logging do
  plug(LassoWeb.Plugs.ObservabilityPlug)  # Must be present
end
```

### Large Metadata Missing from Headers

**Symptom**: `X-Lasso-Request-ID` present but `X-Lasso-Meta` absent

**Cause**: Metadata exceeds `max_meta_header_bytes`

**Solution**: Use `include_meta=body` instead, or increase limit:

```elixir
config :lasso, :observability,
  max_meta_header_bytes: 8192  # Increase from default 4096
```

### Timing Seems Incorrect

**Symptom**: `end_to_end_latency_ms` < `upstream_latency_ms`

**Cause**: Clock skew or timing marker error

**Debug**:

```elixir
# Check timing markers in RequestContext
ctx.selection_start_time  # Should be < selection_end_time
ctx.upstream_start_time   # Should be < upstream_end_time
```

## Summary

Lasso's observability system provides:

✅ **Comprehensive visibility** into request routing and execution
✅ **Opt-in client metadata** without overhead for those who don't need it
✅ **Structured logs** for easy parsing and aggregation
✅ **Privacy-first design** with params digests and error truncation
✅ **Minimal overhead** (~10ms with metadata, ~8ms without)
✅ **Production-ready** with sampling and configurable limits
✅ **Telemetry integration** for custom monitoring solutions

For more details, see:

- [ARCHITECTURE.md](./ARCHITECTURE.md) - System architecture overview
- [README.md](../README.md) - User-facing documentation
- Module docs: `RequestContext`, `Observability`, `ObservabilityPlug`
