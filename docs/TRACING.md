# OpenTelemetry tracing

Tracing is optional and disabled by default. JSON logs and Prometheus metrics
continue to work without a trace backend. Enable after configuring an OTLP
receiver such as Grafana Alloy or the OpenTelemetry Collector:

`LASSO_OTEL_ENABLED` accepts `true`/`1` and `false`/`0`, matching other runtime
boolean flags. Omission defaults to disabled.

```sh
LASSO_OTEL_ENABLED=true
OTEL_SERVICE_NAME=lasso
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy.observability.svc:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.01
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=production,service.namespace=blockchain
LOG_FORMAT=json
```

Use standard `OTEL_EXPORTER_OTLP_HEADERS` or trace-specific headers for an
authenticated receiver, provided through your existing secret mechanism.
Do not put credentials in provider IDs, profile names or resource attributes.
`OTEL_EXPORTER_OTLP_ENDPOINT` is a base URL: the exporter appends `/v1/traces`.
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is an exact trace URL, including its path.
Default transport is HTTP/protobuf; `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` is also
supported by the exporter. HTTP/JSON is not supported.
`OTEL_SDK_DISABLED=true` disables the SDK even when the Lasso flag is enabled.

Root sampling defaults to 1%. Sampled incoming parents keep their traces;
unsampled incoming parents stay unsampled. This works with an indexer whose
HTTP client propagates W3C `traceparent`. Parent-based sampling does not cap
traffic from clients that deliberately send sampled parents. For a strict
local sampling ratio on public endpoints, use `OTEL_TRACES_SAMPLER=traceidratio`
instead, or normalize trace context at trusted ingress. Use `always_on` for
short staging investigations; it can be expensive under production load.

## Span tree and privacy

```text
indexer span (if its HTTP client propagates traceparent)
  lasso.http                  HTTP RPC router, SERVER
    lasso.rpc                 one routed JSON-RPC item, INTERNAL
      lasso.upstream          first owned attempt, CLIENT
      lasso.upstream          fallback owned attempt, CLIENT
```

Concurrent batch items stay children of the HTTP span. Context follows owned
transport tasks and Finch deadline workers. Outgoing HTTP provider requests
carry the attempt's `traceparent` without changing authentication headers.
Providers must support tracing to extend the tree beyond the attempt.
WebSocket ordinary RPC items get request/attempt spans but independent roots:
JSON-RPC messages do not have standard HTTP trace headers. No long-lived socket
or per-notification span is created. Subscription establishment, recovery and
delivery pressure remain visible in Prometheus and operational logs.

HTTP spans start after body parsing and end when routing returns; the
Prometheus ingress histogram covers the full endpoint. Health, metrics and
dashboard routes do not generate HTTP spans. Invalid RPC routes may create an
HTTP span without a routed item. An upstream span covers owned execution,
including admission and timeout/cancellation, and reports the canonical terminal
diagnostic rather than subsequent head-policy qualification.

Attributes include chain ID, bounded configured profile/provider identity,
transport, client/system origin, allowlisted RPC method, outcome and attempt
count. Unknown methods become `other`. No RPC bodies/params, wallets,
transaction data, URLs, query strings, caller request IDs, exception messages
or stacktraces are exported. Incoming baggage and tracestate are not propagated.
Exceptions retain their original application behavior and mark spans as errors
without copying their messages. HTTP spans contain method/status, not raw paths.

JSON log metadata includes `trace_id` (32 hex characters) and `span_id` (16 hex
characters) while a request/attempt is active. Both context and logger metadata
are restored on success and failure. Unsampled traces also have correlation IDs
but will not be available in Tempo. This does not add per-request access logs.

## Collector and operator workflow

A minimal Collector trace pipeline:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
  batch: {}
exporters:
  otlp/tempo:
    endpoint: tempo.observability.svc:4317
    tls:
      insecure: true
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo]
```

The plaintext example uses private in-cluster services. Use your existing
TLS/authenticated receiver when crossing that boundary. Prometheus still
scrapes `/metrics`; stdout collection still ships JSON logs. This change does
not introduce OTLP metrics or OTLP log export.

Choose a Tempo datasource in the operator dashboard's optional `traces`
selector and open **Explore Lasso traces**. Search with TraceQL:

```text
{ resource.service.name = "lasso" && span.lasso.origin = "client" }
```

Add `span.lasso.chain_id = 1` or `span.lasso.provider = "provider_id"` as needed.
Compare total `lasso.rpc` duration with individual `lasso.upstream` attempts.
A failed attempt followed by a successful request shows recovered failover;
a failed request span shows exhausted/local failure. Use Prometheus for
unsampled totals/rates. Change the service selector if you override the name.

For Loki-to-Tempo links, configure a Loki derived field `trace_id` with regex
`"trace_id":"([a-f0-9]{32})"`, select Tempo and pass the captured value as the
trace ID. With a JSON parser, extract `metadata.trace_id`. Never promote trace
IDs to Loki stream labels or Prometheus labels.

## Export failure and tuning

The SDK uses a batch processor, default 2,048-span queue and 10-second export
timeout. Export runs outside request workers: collector failure does not delay
or change RPC results. This is best-effort telemetry; spans can be dropped
under pressure or on shutdown. The queue bounds finished spans, not total VM
memory or all in-flight spans. Tune standard `OTEL_BSP_MAX_QUEUE_SIZE`,
`OTEL_BSP_SCHEDULE_DELAY_MILLIS` and `OTEL_BSP_EXPORT_TIMEOUT_MILLIS` variables.
The SDK may flush synchronously during application shutdown and delay exit
after Lasso has stopped. Its batch export timeout does not guard that synchronous
shutdown flush; allow for graceful shutdown and verify the chosen exporter's
behavior when sizing the pod's termination grace period.

If traces disappear, check the Lasso flag, `OTEL_SDK_DISABLED`, receiver
address/protocol/authentication, sampler and collector export/drop metrics.
Distinguish collector failure from upstream failure using Prometheus circuit
and request panels. An empty Tempo search alone does not prove health or idle
traffic. Roll back with `LASSO_OTEL_ENABLED=false` and restart the release.
The collector and trace backend are never required for routing/readiness.
