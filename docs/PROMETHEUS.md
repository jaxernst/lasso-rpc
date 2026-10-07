# Prometheus operator guide

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
| `lasso_rpc_route_requests_total` | Exact routed completions, counted before detail sampling | profile, chain, origin, outcome |
| `lasso_rpc_route_duration_seconds_total` | Exact summed completion time; divide by requests for the mean | profile, chain, origin |
| `lasso_rpc_route_detail_sampled_out_total` | Successes excluded from detail telemetry by the sampling budget | profile, chain, origin |
| `lasso_rpc_requests_total` | Sampled routed completion count by provider and method | chain, provider, method, outcome |
| `lasso_rpc_request_duration_seconds` | Final routed latency, including attempts/failover | profile, chain, provider, method, transport, origin, outcome |
| `lasso_upstream_attempts_total` | Non-success dispatched attempt diagnostics only | profile, chain, provider, transport, origin, outcome, category |
| `lasso_rpc_failovers_total` | Sum of failovers recorded at final completion | route labels without outcome |
| `lasso_circuit_state` | Existing one-hot local HTTP/WS circuit state | profile, chain, provider, transport, state |
| `lasso_circuit_ready` / `lasso_circuit_failures` | Owner admission readiness and consecutive failures | profile, chain, provider, transport |
| `lasso_circuit_half_open_capacity` / `lasso_circuit_half_open_inflight` | Recovery probe slots and occupancy | profile, chain, provider, transport |
| `lasso_circuit_recovery_delay_seconds` | Remaining local monotonic recovery delay | profile, chain, provider, transport |
| `lasso_circuit_transitions_total` / `lasso_circuit_failures_total` | Physical-instance transition/failure evidence | instance_id, transport, state, reason/category |
| `lasso_circuit_recovery_attempts_total` | Proactive recovery attempts | instance_id, transport |
| `lasso_chain_ready` / `lasso_chain_eligible_upstreams` | Same node-local HTTP readiness as `/api/ready` and eligible alternatives | profile, chain |
| `lasso_provider_info` | Configured route to physical-instance mapping | profile, chain, provider, instance_id |
| `lasso_provider_transport_configured` | Whether HTTP/WS is configured | profile, chain, provider, transport |
| `lasso_provider_head_observed` | Routing can assess head lag on at least one transport (1/0) | profile, chain, provider |
| `lasso_provider_head_lag_blocks` | Blocks behind, as routing assesses the route against its routing plan | profile, chain, provider, transport |
| `lasso_websocket_connections_total` | Physical connection/disconnection events; no active subscription count | chain, instance_id, event; route filters use provider_info |
| `lasso_subscription_events_total` / `lasso_subscription_recovery_duration_seconds` | Failover, reorg repair, drops and slow-consumer termination | available profile/chain/provider, kind/reason |
| `lasso_stream_budget_bytes` / `_messages` / `_owners` | Continuity reservations and queued deliveries | kind where applicable |
| `lasso_stream_ingress_bytes` / `_messages` / `_rejections_total` | Internal ingress reservations and cumulative losses | node-local |
| `lasso_stream_memory_bytes` | Combined used bytes and configured reservation limit | kind=used/limit |
| `lasso_stream_budget_rejections_total` | Continuity reservation rejection events | kind=stream_bytes/delivery_bytes/delivery_messages; bounded reason |
| `lasso_credential_health_events_total` | Credential active/recovered transitions; not an active-alert gauge | provider, status |
| `lasso_vm_*` | BEAM allocation, processes/limits, ports/limits, atoms/limits, ETS, run queue, schedulers, GC, reductions, I/O and uptime | node-local, kind/direction where applicable |
| `lasso_build_info` | Running application/Elixir/OTP versions | version, elixir, otp |
| `lasso_observer_*` | New observer occupancy, capacity, drops and invalid measurements | node-local |
| `lasso_observer_route_totals_dropped_total` / `_errors_total` | Route-total increments refused by the 2,048-series limit, and route-total reads that failed and kept prior totals | node-local |

`*_seconds` histograms export `_bucket`, `_sum`, and `_count`. Boundaries are
5, 10, 25, 50, 100, 250, 500 ms; 1, 2.5, 5, 10, 30 seconds; and +Inf. Routed
telemetry durations are **milliseconds**. The observer converts them to seconds. Negative/missing durations
increment `lasso_observer_invalid_total`; they never fabricate zero latency.

Attempt counters observe `[:lasso, :rpc, :attempt, :terminal]` from the canonical
AttemptProjection path. It emits non-success dispatched diagnostics (failures,
cancellations and policy rejections), not successful attempts. It carries profile
and origin but not method, so attempt panels do not apply the method filter. Origin
separates client-driven failures from probes and other system traffic. There is no
successful-attempt latency metric or HTTP ingress metric in this exporter.
An attempt failure may be recovered by another provider; it is not automatically
a failed client request. Diagnostic delivery is bounded and can drop observations.

The `lasso_rpc_route_*` counters are exact: RequestAggregate counts every routed
request per profile, chain and origin before any sampling, and the scrape reads those
counters. Use them for throughput, success ratios, mean latency and SLO accounting.
A routing scope keeps its counters across catalog rebuilds; a scope that is removed
is read twice more so its last requests are counted. Successes and errors are separate
counters, so neither can move backwards. A series lasts while any published scope
contributes to it, with at most 2,048 route-total series per node.

Observer failures stay inside the exporter. If a `MetricsScope` hook raises, the
observation is dropped and counted in `lasso_observer_invalid_total`, and route-total
reads keep their previous values and count `lasso_observer_route_totals_errors_total`;
telemetry handlers stay attached and request processes are unaffected.

The latency histogram, `lasso_rpc_requests_total` and completion-reported failovers
consume request **diagnostics**. RequestAggregate samples successful detail above
256 completions/s per profile, chain and origin; failures remain admitted. These
series carry provider and method but are biased under load;
`lasso_rpc_route_detail_sampled_out_total` shows how much was excluded. Observer
drop counters measure observer admission losses, not upstream sampling or
dispatcher drops.

Head lag is routing's own per-transport assessment: each route is compared against
its routing plan's head scope with that transport's compiled freshness, the same
evidence selection uses. HTTP observations count only with a fresh poll reference
for the scope. A transport routing cannot assess has no sample, so compare
`lasso_provider_head_observed` with configured routes to see lag coverage.

A fresh head observation does not prove routing eligibility: identity, circuit,
method capability, lag policy and request range must still permit dispatch.
Missing head lag means no fresh evidence, not zero lag. Disabled WS transports
have no circuit snapshot; consult `lasso_provider_transport_configured` before
interpreting missing circuit-admission samples as a failure.

## Multi-tenant hosts

Profile, chain and provider labels come from configuration. A host that lets
tenants define profiles or providers should bound them before they become labels:
set `config :lasso, :metrics_scope, MyScope` to a module implementing
`Lasso.Observability.MetricsScope`. `bound/1` rewrites event metadata (for example,
folding tenant profiles into `custom`), and `export_route?/1` keeps those profiles
out of the scrape-time route families, where several routes would collapse onto one
series. The default keeps every value.

## Common incidents

### One upstream circuit opens

Check the provider's circuit on each node, head evidence, non-success attempt diagnostics and
client completion success. If alternatives are fresh and client traffic succeeds,
Lasso is containing an upstream failure. Inspect bounded failure categories and
recovery delay; do not repeatedly reset the circuit or restart healthy nodes.
A still-open circuit is reduced redundancy even when client service is healthy.

### Latency climbs under load

Inspect sampled final p95/p99, non-success attempt diagnostics, failovers,
circuit admission readiness, run queue and memory. Inspect upstream logs to compare
provider speed; successful-attempt latency is not exported.
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
`lasso_observer_dropped_total`; existing rows continue to update.
Configured profile and provider IDs use the request path's `BoundedIdentifier`
encoding in every metric family: valid UTF-8 values up to 128 bytes remain
unchanged; longer values use a `sha256:` fingerprint. Dashboard selectors use
these same encoded labels from `lasso_provider_info`. Physical instance IDs
retain their full value, including the credential fingerprint. Method and reason dimensions are
allowlisted. Do not generate per-user provider IDs.

Scrapes read node-local snapshots and BEAM totals, with no dashboard collector or
scheduler-wall-time flags. VM allocation categories overlap: do not sum `total`
with its components. VM metrics describe BEAM, not OS/container CPU or RSS.
No global scheduler settings are changed by scraping.

Treat the dashboard as evidence, then set alert thresholds from your own service
objectives and observed traffic. Low-volume ratios should require a minimum
request rate. Alert separately on client completion failure, loss of fresh
alternatives, and a single quarantined upstream; these have different impacts.

Failover-event and admission-rejection counters are not exported: the legacy
sink has no production callers. Inspect circuit admission gauges and the
sampled completion-reported failover counter instead.

### Dashboard query regression checks

Run `python3 scripts/check_prometheus_dashboard.py /path/to/promtool` with
Prometheus 3.5 or newer. The check parses every dashboard expression and evaluates
route filtering, shared physical connections, pod isolation, and zero versus
unavailable failover evidence against fixture time series.


The Job variable's All option expands only discovered Lasso jobs. The exporter
health query deduplicates both availability and `up` by `(job, instance)` before joining, so unrelated
kubelet endpoints or duplicate scrape labels cannot cause many-to-many errors.
Sparse circuit, subscription, continuity-loss and credential event panels show
`no_events` at zero only when their exporter is available and successfully
scraped. Subscription fallbacks also require the selected chain's inventory.
These baselines disappear when telemetry is unavailable. Credential events can
remain zero when no managed credential source is configured.

Subscription recovery p95 is a stat with three states: a measured duration,
`No completed repairs`, or `Telemetry unavailable`. The display-only `-1`
sentinel identifies an observed chain without repair durations; it is never
presented as a latency. An idle histogram follows the same rule.
