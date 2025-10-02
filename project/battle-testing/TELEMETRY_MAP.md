# Lasso RPC Telemetry & Events Map

Comprehensive guide to all observable events in Lasso RPC for battle testing integration.

## Telemetry Events (`:telemetry.execute`)

### Request Lifecycle

#### `[:lasso, :rpc, :request, :start]`

**When**: RPC request begins in RequestPipeline
**Measurements**: `%{count: 1}`
**Metadata**:

- `chain` - Target chain
- `method` - RPC method
- `strategy` - Routing strategy used
- `provider_id` - Selected provider

#### `[:lasso, :rpc, :request, :stop]`

**When**: RPC request completes (success or failure)
**Measurements**: `%{duration_ms: integer}`
**Metadata**:

- `chain` - Target chain
- `method` - RPC method
- `strategy` - Routing strategy used
- `provider_id` - Provider that handled request
- `result` - `:success` or `:error`
- `failovers` - Number of failover attempts (0 if first provider succeeded)
- `transport` - `:http`, `:ws`, or `:unknown` (optional)

**Critical**: This is the primary event for measuring end-to-end request performance and success rates.

### Circuit Breaker

#### `[:lasso, :circuit_breaker, :open]`

**When**: Circuit breaker opens due to failures
**Measurements**: `%{count: 1}`
**Metadata**: `%{provider_id: string}`

#### `[:lasso, :circuit_breaker, :half_open]`

**When**: Circuit breaker attempts recovery
**Measurements**: `%{count: 1}`
**Metadata**: `%{provider_id: string}`

#### `[:lasso, :circuit_breaker, :close]`

**When**: Circuit breaker closes after successful recovery
**Measurements**: `%{count: 1}`
**Metadata**: `%{provider_id: string}`

### Provider Selection

#### `[:lasso, :selection, :success]`

**When**: Provider successfully selected by Selection module
**Measurements**: `%{count: 1}`
**Metadata**:

- `chain`
- `method`
- `strategy` - `:priority`, `:fastest`, `:cheapest`, `:round_robin`
- `protocol` - `:http`, `:ws`, or `:both`
- `provider_id`

### Response Normalization

#### `[:lasso, :normalize, :result]`

**When**: Response successfully normalized
**Measurements**: `%{count: 1}`
**Metadata**: `%{provider_id, method, status}`

#### `[:lasso, :normalize, :error]`

**When**: Error response normalized
**Measurements**: `%{count: 1}`
**Metadata**:

- `provider_id`
- `method`
- `code` - Error code
- `category` - Error category
- `retriable?` - Whether error is retriable

### WebSocket Subscriptions

#### `[:lasso, :subs, :client_subscribe]`

**When**: Client creates subscription
**Measurements**: `%{count: 1}`
**Metadata**: `%{chain, subscription_id}`

#### `[:lasso, :subs, :client_unsubscribe]`

**When**: Client cancels subscription
**Measurements**: `%{count: 1}`
**Metadata**: `%{chain, subscription_id}`

## PubSub Events (`Phoenix.PubSub.broadcast`)

### Circuit Breaker Events

**Topic**: `"circuit:events"`
**Format**: `{:circuit_breaker_event, event_map}`
**Event Map**:

```elixir
%{
  ts: System.system_time(:millisecond),
  provider_id: string,
  transport: :http | :ws | :unknown,
  from: :closed | :open | :half_open,
  to: :closed | :open | :half_open,
  reason: :failure_threshold_exceeded | :recovered | :manual_open | :manual_close | ...
}
```

### WebSocket Connection Status

**Topic**: `"ws_connections"`
**Format**: `{:ws_connection_status_changed, provider_id, status}`
**Status**: Connection state (`:connected`, `:disconnected`, etc.)

### Routing Decisions

**Topic**: `"routing:decisions"`
**Format**: Map with routing decision details

```elixir
%{
  ts: System.system_time(:millisecond),
  chain: string,
  method: string,
  strategy: atom,
  provider_id: string,
  latency: integer,
  result: :success | :error,
  failovers: integer
}
```

### Raw WebSocket Messages

**Topic**: `"raw_messages:#{chain_name}"`
**Format**: `{:raw_message, provider_id, message, received_at}`

### Provider Health Events

**Topic**: `Provider.topic(chain_name)` (e.g., `"provider:ethereum"`)
**Various provider state change events**

## Battle Testing Integration Recommendations

### Essential Events for Core Metrics

1. **Request Performance**: `[:lasso, :rpc, :request, :stop]`
   - Latency, success rate, failover rate
2. **Circuit Breaker Behavior**: All circuit breaker telemetry events
   - Track opens, recoveries, half-open attempts
3. **Provider Selection**: `[:lasso, :selection, :success]`
   - Strategy effectiveness

### Valuable for Deep Analysis

1. **Routing Decisions** PubSub: Detailed failover path analysis
2. **WebSocket Connection Status**: Connection stability
3. **Error Classification**: `[:lasso, :normalize, :error]`

### For WebSocket Testing

1. **Subscription Events**: `[:lasso, :subs, :*]`
2. **Raw Messages**: For continuity/deduplication analysis
3. **Connection Events**: For failover testing

## Current Battle Testing Issues

**Problem**: Workload emits custom `[:lasso, :battle, :request]` event
**Solution**: Remove custom emission, capture production `[:lasso, :rpc, :request, :stop]`

**Problem**: Collector only listens to custom events
**Solution**: Update Collector to attach to production telemetry events

## Recommended Collector Configuration

```elixir
# Minimal viable collectors
[:requests, :circuit_breaker]

# Full observability
[:requests, :circuit_breaker, :selection, :normalization, :websocket]
```
