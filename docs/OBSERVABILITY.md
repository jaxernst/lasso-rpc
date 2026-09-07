# Observability

Lasso exposes dashboard measurements, opt-in JSON-RPC response metadata, BEAM
telemetry events, and operational logs. These signals describe different units:
a client request can produce several upstream attempts during failover.

## Dashboard and metrics API

The dashboard shows provider connectivity, circuit state, block freshness,
upstream attempt rates, success rates, and latency distributions. Measurements
are local to the selected node and available observation window. Missing
observations display as unavailable rather than a measured zero.

`GET /api/metrics/:chain` reports node-local upstream attempt metrics for the
`public` profile. It is a JSON endpoint. See [API Reference](API_REFERENCE.md#non-rpc-api-endpoints)
for its fields and units. Lasso does not expose a Prometheus scrape endpoint.

The browser request tester generates real upstream traffic. Its HTTP success,
error, and latency counters describe that browser's run. WebSocket connection
counts describe open sockets; they do not prove every subscription succeeded.
The activity feed records subscription confirmations and errors separately.

System metrics are disabled by default. Set `LASSO_VM_METRICS_ENABLED=true`
to collect and display VM metrics. Protect dashboard and operational endpoints
at your ingress if the deployment is reachable by untrusted clients.

## Response metadata

HTTP clients can opt in with `?include_meta=headers`, `?include_meta=body`, or
`X-Lasso-Include-Meta: headers|body`:

```bash
curl -X POST 'http://localhost:4000/rpc/fastest/ethereum?include_meta=body' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Body mode adds `lasso_meta` to the JSON-RPC response. Header mode adds
`X-Lasso-Request-ID` and base64url-encoded JSON in `X-Lasso-Meta`.
The metadata contains available request, chain, strategy, selected-provider,
retry, and timing fields. It contains provider identifiers rather than upstream
URLs or authentication headers. Do not put secrets in provider identifiers.

```elixir
config :lasso, :observability, max_meta_header_bytes: 4096
```

This limit applies to the encoded metadata header. If the payload exceeds it,
Lasso omits `X-Lasso-Meta` and retains the request ID header. Body metadata is
not limited by this setting. WebSocket metadata uses the separate notification
contract described in [API Reference](API_REFERENCE.md).

## Telemetry

The request pipeline emits `[:lasso, :rpc, :request, :stop]` with:

- Measurement: `duration` in milliseconds.
- Metadata: `chain_id`, `method`, `strategy`, `provider_id`, `transport`,
  `result`, and `failovers`.

This event describes routed request completion. Locally handled methods,
invalid requests, and failures before dispatch have separate paths; do not use
this event alone as a complete ingress request counter.

An embedding deployment can attach a handler:

```elixir
:telemetry.attach(
  "lasso-request-observer",
  [:lasso, :rpc, :request, :stop],
  fn event, measurements, metadata, _config ->
    send(observer_pid, {event, measurements, metadata})
  end,
  nil
)
```

Set `observer_pid` to your collector process first. Telemetry handlers run
synchronously in the emitting process: keep them short and offload blocking
work. Detach with `:telemetry.detach("lasso-request-observer")`.

The [pipeline observability module](../lib/lasso/core/request/request_pipeline/observability.ex)
and [circuit breaker](../lib/lasso/core/support/circuit_breaker.ex) define
additional failure, exhaustion, slow-request, and state-transition events.

## Operational logs

Production enables `Lasso.TelemetryLogger` for slow requests, failover, and
circuit transitions. Standard Logger configuration controls output level and
format. The proxy does not emit a JSON `rpc.request.completed` log for every
request, and there is no request-log sampling configuration.

## Block freshness

Provider synchronization derives from timestamped block observations in ETS.
HTTP observations may receive bounded time-alignment credit up to one polling
interval; WebSocket observations remain direct evidence. Stale evidence is
excluded, and consensus does not advance beyond an observed upstream height.
See [Configuration](CONFIGURATION.md) for probe intervals, routing lag limits,
and the dashboard lag status threshold.
