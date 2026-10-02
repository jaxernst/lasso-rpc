# Prometheus operator guide

For request-level drilldown and JSON-log correlation, see the optional
[OpenTelemetry trace guide](TRACING.md).

Scrape `GET /metrics` on **each Lasso node**. Counters and histograms are node-local;
keep the Prometheus `instance` label and sum rates across nodes when calculating
fleet throughput. No database, dashboard session, scheduler instrumentation flag,
or additional exporter dependency is required.

## Start here

1. Import [Lasso — Operator Overview](grafana/lasso-core-v1.json) into Grafana.
   Select a Prometheus datasource; then choose scrape job, node, profile, chain,
   provider, method and request origin. The dashboard retains its existing
   `lasso-core-v1` UID so provisioning replaces the earlier minimal dashboard.
2. Keep **Request origin = client** for user-facing completion latency and success.
   Select `system` for health/head probes. Select All to include legacy events
   whose origin is unknown. A zero-traffic ratio/quantile is unavailable, not zero.
3. Check scrape availability, client success, request latency and open circuits.
   Drill into attempt outcomes and head evidence before changing upstream config.
4. Node-wide panels explicitly ignore chain/provider filters. VM and WebSocket
   memory figures are reservation/allocation evidence; obtain container RSS, CPU,
   requests and limits from your Kubernetes/node exporter.

Example scrape configuration (replace the targets with your own node addresses):

```yaml
scrape_configs:
  - job_name: lasso
    scrape_interval: 15s
    metrics_path: /metrics
    static_configs:
      - targets: ["lasso-node-a:4000", "lasso-node-b:4000"]
```

The endpoint has no application authentication. Keep it private or protect it at
an ingress/reverse proxy; add scrape credentials there if required. Provider
identifiers are operator-defined and must not contain secrets. Metrics never
include upstream URLs, auth headers, request IDs, wallets, error messages, filters,
or subscription keys.

## What the measurements mean

| Surface | Meaning | Useful dimensions |
| --- | --- | --- |
| `lasso_rpc_requests_total` | Existing compatible routed completion count | chain, provider, method, outcome |
| `lasso_rpc_request_duration_seconds` | Final routed latency, including attempts/failover | profile, chain, provider, method, transport, origin, outcome |
| `lasso_upstream_attempts_total` | Every dispatched upstream attempt | same route labels plus error category |
| `lasso_upstream_attempt_duration_seconds` | Exact I/O or censored timeout/cancellation boundary | route labels, category, outcome |
| `lasso_rpc_failovers_total` | Sum of failovers recorded at final completion | route labels without outcome |
| `lasso_admission_rejections_total` | Candidate rejected before dispatch | route labels, bounded reason |
| `lasso_failover_events_total` | Skip, fast-fail, degraded recovery or exhaustion events | route labels, kind |
| `lasso_http_requests_total` / `lasso_http_request_duration_seconds` | Completed Phoenix endpoint requests including validation/local handling | normalized route, HTTP status class |
| `lasso_circuit_state` | Existing one-hot local HTTP/WS circuit state | profile, chain, provider, transport, state |
| `lasso_circuit_ready` / `lasso_circuit_failures` | Owner admission readiness and consecutive failures | profile, chain, provider, transport |
| `lasso_circuit_half_open_capacity` / `lasso_circuit_half_open_inflight` | Recovery probe slots and occupancy | profile, chain, provider, transport |
| `lasso_circuit_recovery_delay_seconds` | Remaining local monotonic recovery delay | profile, chain, provider, transport |
| `lasso_circuit_transitions_total` / `lasso_circuit_failures_total` | Physical-instance transition/failure evidence | instance_id, transport, state, reason/category |
| `lasso_circuit_timeouts_total` / `lasso_circuit_recovery_attempts_total` | Timeouts and proactive recovery attempts | instance_id, transport |
| `lasso_chain_ready` / `lasso_chain_eligible_upstreams` | Same node-local HTTP readiness as `/api/ready` and eligible alternatives | profile, chain |
| `lasso_provider_info` | Configured route to physical-instance mapping | profile, chain, provider, instance_id |
| `lasso_provider_transport_configured` | Whether HTTP/WS is configured | profile, chain, provider, transport |
| `lasso_provider_head_observed` | Fresh head-lag evidence exists (1/0) | profile, chain, provider |
| `lasso_provider_head_lag_blocks` | Existing fresh head lag in blocks | profile, chain, provider |
| `lasso_websocket_connections_total` | Connection/disconnection events; not active subscriptions | profile, chain, provider, event |
| `lasso_subscription_events_total` / `lasso_subscription_recovery_duration_seconds` | Failover, reorg repair, drops and slow-consumer termination | available profile/chain/provider, kind/reason |
| `lasso_stream_budget_bytes` / `_messages` / `_owners` | Continuity reservations and queued deliveries | kind where applicable |
| `lasso_stream_ingress_bytes` / `_messages` / `_rejections_total` | Internal ingress reservations and cumulative losses | node-local |
| `lasso_stream_memory_bytes` | Combined used bytes and configured reservation limit | kind=used/limit |
| `lasso_stream_budget_rejections_total` | Continuity reservation rejection events | bounded kind/reason |
| `lasso_credential_health_events_total` | Credential active/recovered transitions; not an active-alert gauge | provider, status |
| `lasso_vm_*` | BEAM allocation, processes/limits, ports/limits, atoms/limits, ETS, run queue, schedulers, GC, reductions, I/O and uptime | node-local, kind/direction where applicable |
| `lasso_build_info` | Running application/Elixir/OTP versions | version, elixir, otp |
| `lasso_observer_*` | New observer occupancy, capacity, drops and invalid measurements | node-local |

`*_seconds` histograms export `_bucket`, `_sum`, and `_count`. Boundaries are
5, 10, 25, 50, 100, 250, 500 ms; 1, 2.5, 5, 10, 30 seconds; and +Inf. Routed
telemetry durations are **milliseconds**; Phoenix durations are native monotonic
units. The observer explicitly converts both to seconds. Negative/missing durations
increment `lasso_observer_invalid_total`; they never fabricate zero latency.

Attempt outcomes distinguish `usable_success`, `service_failure`, `timeout`,
`capacity_rejection`, `neutral_error`, and `cancelled`. An attempt failure can be
recovered by another provider: it is not automatically a failed client request.
Timeout/cancellation durations are censored boundaries, not successful latency;
compare provider speed using `outcome="usable_success"`.

Routed completions are not all HTTP ingress: invalid requests, locally handled
methods and pre-dispatch errors have different paths. One HTTP batch can contain
multiple routed calls. HTTP metrics count completed endpoint requests, not active
connections. Counter events retain `unknown` context when a legacy emitter lacks
profile/method/origin; never assume a missing origin was a client request.

A fresh head observation does not prove routing eligibility: identity, circuit,
method capability, lag policy and request range must still permit dispatch.
Missing head lag means no fresh evidence, not zero lag. Disabled WS transports
have no circuit snapshot; consult `lasso_provider_transport_configured` before
interpreting missing circuit-admission samples as a failure.

## Common incidents

### One upstream circuit opens

Check the provider's circuit on each node, head evidence, successful attempts and
client completion success. If alternatives are fresh and client traffic succeeds,
Lasso is containing an upstream failure. Inspect bounded failure categories and
recovery delay; do not repeatedly reset the circuit or restart healthy nodes.
A still-open circuit is reduced redundancy even when client service is healthy.

### Latency climbs under load

Compare final p95/p99 with successful attempt p95. If both climb, inspect upstream
speed and quotas. If final latency climbs while individual attempts stay fast,
check failovers, admission rejections, run queue, memory, and ingress status classes.
Quantiles must sum histogram buckets before `histogram_quantile`; do not average
per-node p95 values. Use a rate window spanning several scrape intervals.

```promql
histogram_quantile(0.95,
  sum by (le, chain) (
    rate(lasso_rpc_request_duration_seconds_bucket{origin="client"}[5m])
  )
)
```

### WebSocket clients lose continuity

Inspect subscription losses, recovery duration, ingress/continuity rejection rates
and queued delivery counts. Compare reserved memory with its configured envelope.
Repeated slow-consumer terminations may require fixing consumers rather than
increasing replay limits. Stream snapshots update every ten seconds independently
of dashboard subscribers. Missing snapshots at startup mean unavailable evidence.

### Charts go blank or counts look incomplete

Check `up`, node uptime and datasource/job filters. Unknown methods fold to `other`;
legacy missing route fields use `unknown`. Inspect observer drops/invalid measurements.
A process/node restart resets its local observation counters; use `rate`/`increase`.
Missing metrics from a down node must not be treated as a healthy zero.

## Bounds and overhead

The compatible request counter keeps its 4,096-row cap. Additional observations
share a separate 4,096-row cap with at most 16 admission probes. Updates run
synchronously on the emitter, use one atomic ETS-row update per measurement, and
perform no network calls or GenServer calls. Concurrent first admissions retry
the same occupied key before probing onward, avoiding duplicate histogram rows.

A histogram row emits 15 series (13 buckets including +Inf, count, sum), so the
new observation store exports at most 61,440 data series plus five observer health
series. Runtime metrics have fixed dimensions; route gauges inspect at most 2,048
configured routes and 2,048 profile/chains (including chains with no providers).
`lasso_observer_route_scan_truncated` and `lasso_observer_chain_scan_truncated`
report when the configuration exceeds these bounded scans. Capacity saturation or probe collisions increase
`lasso_observer_dropped_total`; existing rows continue to update. Provider/profile
identities are truncated to 64 characters; method and reason dimensions are
allowlisted. Do not generate per-user provider IDs.

Scrapes read node-local snapshots and BEAM totals, with no dashboard collector or
scheduler-wall-time flags. VM allocation categories overlap: do not sum `total`
with its components. VM metrics describe BEAM, not OS/container CPU or RSS.
No global scheduler settings are changed by scraping.

Treat the dashboard as evidence, then set alert thresholds from your own service
objectives and observed traffic. Low-volume ratios should require a minimum
request rate. Alert separately on client completion failure, loss of fresh
alternatives, and a single quarantined upstream; these have different impacts.
