# Migrating to Lasso RPC

This guide covers two starting points:

1. an application calling one RPC provider or node directly; and
2. an application already using a generic RPC proxy, gateway, or load balancer.

It applies to the self-hosted RPC Core. Core routes upstream JSON-RPC traffic; it
does not provide client authentication, incoming customer quotas, billing, or a
hosted control plane.

## Define the compatibility contract

Inventory the behavior your application depends on before changing traffic:

- chain IDs, chain aliases, HTTP methods, WebSocket subscriptions, and batch use;
- latest-state, pending-state, archival, trace/debug, log-range, and proof reads;
- transaction submission and any provider-local filter methods;
- upstream URLs, credential scopes, headers, quotas, concurrency limits, and
  regional restrictions;
- client timeouts, retry behavior, error handling, and health checks; and
- latency, error-rate, head-lag, subscription-gap, and quota baselines.

Test the real method and block-range distribution. A successful
`eth_blockNumber` call does not establish archival, trace, large-log-range, or
WebSocket support. Mark `archival: true` only for upstreams you have qualified
against the history your application needs, and declare provider capability
limits instead of relying on failover to discover them in production.

## Map the existing configuration

| Existing concept | Lasso Core mapping | Boundary to preserve |
| --- | --- | --- |
| Upstream or backend | One provider under `chains.<chain>.providers` | Give each provider a stable, non-secret `id`. |
| HTTP endpoint | `url` | Use `${ENV_VAR}` substitution for credential-bearing values. |
| WebSocket endpoint | `ws_url` | Qualify subscriptions independently from HTTP. |
| Authorization or custom headers sent upstream | `api_key`, `headers`, or `auth_headers` | These authenticate Lasso to an upstream; they do not authenticate clients to Lasso. |
| Ordered primary and fallback | Provider `priority` plus the `:priority` application strategy | The shipped default is `load_balanced`; priority has no dedicated URL slug. |
| Even/random pool | `/rpc/load-balanced/:chain` | This is bounded randomized ordering, not exact traffic shares or quota-aware weighting. |
| Latency routing | `/rpc/fastest/:chain` or `/rpc/latency-weighted/:chain` | Rankings use successful-attempt evidence and still apply health/capability filtering. |
| Per-backend method restrictions | `capabilities.unsupported_methods`, `unsupported_categories`, and `limits` | Declare known restrictions before canary traffic. |
| Historical-data backend | `archival: true` and chain `selection.archival_threshold` | The flag is an operator assertion, not an automatic proof of retained history. |
| Client API keys, tenant policy, or inbound RPS limits | External ingress proxy or private network | Profiles and `rps_limit` are not authorization or ingress quota boundaries. |
| Gateway health endpoint | `/api/health` plus bounded RPC probes | Application health alone does not verify upstream availability. |

A minimal production profile can start with the same upstream as the current
application, then add a separately qualified fallback:

```yaml
---
name: Production
slug: production
---
chains:
  ethereum:
    chain_id: 1
    selection:
      max_lag_blocks: 2
      archival_threshold: 128
    providers:
      - id: current-primary
        url: ${PRIMARY_RPC_URL}
        ws_url: ${PRIMARY_RPC_WS_URL}
        auth_headers:
          Authorization: ${PRIMARY_RPC_AUTHORIZATION}
        archival: true
        priority: 1
      - id: qualified-fallback
        url: ${FALLBACK_RPC_URL}
        ws_url: ${FALLBACK_RPC_WS_URL}
        archival: false
        priority: 2
        capabilities:
          unsupported_categories: [debug, trace]
```

Unresolved environment variables reject the profile. A failed reload preserves
the last known-good configuration. See [Configuration](CONFIGURATION.md) for the
complete schema and [Deployment](DEPLOYMENT.md) for mounting and reloading files.

## Preserve the ingress boundary

Keep the client-facing authentication and rate-limit layer in front of Lasso.
The ingress proxy or private network should terminate TLS, authenticate the
caller, enforce per-client request and connection limits, bound body size, and
protect RPC, WebSocket, dashboard, and metrics routes as appropriate.

Do not use profiles as tenants or authorization domains. Identical upstreams can
share runtime state across profiles, and the profile's `rps_limit` only bounds the
dashboard tester. If the existing gateway combines routing with client policy,
move only routing into Core and retain the policy layer during the migration.

Forwarding an existing client identity to an upstream is an operator-specific
design choice. Do not forward bearer credentials or tenant headers by default;
explicitly allow only the headers the upstream contract requires.

## Align timeouts and retries

Lasso applies a single method-specific deadline to each JSON-RPC item. Replay-safe
reads may dispatch to as many as three distinct eligible channels within that
deadline; the first attempt receives at most 60% of the original budget so that
fallback retains time. Transaction broadcast, signing, filter creation and
consumption, subscriptions, and unknown methods receive one dispatch.

Default deadlines range from one second for simple identity/head methods to
longer budgets for proofs and trace/debug calls; unknown methods default to ten
seconds. Operators running from source can override `:method_timeouts` in
application configuration. Validate overrides against observed workloads rather
than increasing all deadlines together.

Set the client or edge timeout slightly above Core's applicable deadline so the
client can receive Core's final response. Avoid retrying every error at the client
or ingress layer: Core already performs bounded fallback for replay-safe reads,
and another retry layer multiplies upstream attempts and quota use. If clients
retry reads, use a bounded count, jittered backoff, and an end-to-end deadline.
Do not automatically replay signing or state-changing requests. Core sends
`eth_sendRawTransaction` once; applications may safely reconcile a known signed
transaction by its hash before deciding what to do next.

## Qualify before shifting traffic

Run the candidate beside the existing path and use the same ingress controls.
Exercise at least:

- `/api/health` and an actual RPC call for each configured chain;
- the application's top methods, batch shapes, error paths, and response sizes;
- recent, early, and boundary historical blocks for every archival workload;
- the largest expected `eth_getLogs` ranges and any trace/debug methods;
- WebSocket connect, subscribe, notification flow, reconnect, and bounded gap
  recovery; and
- transaction submission in a safe environment if the application broadcasts.

Compare results at the same explicit block where consistency matters. Latest-state
requests made at different times can legitimately differ. Use response metadata,
the dashboard, logs, and upstream-attempt metrics to confirm which providers and
transports actually served the tests.

## Canary and rollback

Keep the old route available. Send a small, measurable slice of production read
traffic to Lasso first, then expand only after a full observation window covers
the application's normal peak and background jobs. Canary WebSocket traffic by
whole connections rather than individual messages.

Define numeric rollback thresholds from the existing baseline before the canary.
Rollback immediately when any agreed threshold is crossed, including:

- sustained transport or JSON-RPC error increase;
- latency beyond the client deadline or the agreed percentile budget;
- incorrect chain identity, unacceptable head lag, or inconsistent pinned-block
  results;
- archival, trace, log-range, or proof failures for required workloads;
- unexpected provider-rate-limit exhaustion or quota burn;
- subscription disconnects, gaps, duplicates, or recovery outside the agreed
  window; or
- an authentication, data-exposure, or transaction-safety concern.

Rollback should be an ingress or service-discovery change that sends new traffic
to the previous endpoint. Existing WebSocket connections need explicit draining
or reconnection. Preserve the candidate logs and metrics, stop increasing traffic,
and reconcile in-flight transaction hashes before replaying any broadcast.

## Reconcile provider quotas

Provider limits usually apply to a credential, account, endpoint, or purchased
plan rather than a Lasso profile. Record that quota identity for each configured
provider. Do not assume that two URLs, two profiles, or HTTP and WebSocket have
independent allowances.

Budget from upstream attempts, not only client requests. Replay-safe fallback,
health and chain-identity probes, WebSocket recovery, and dashboard tests can all
consume provider capacity. During canary and after each traffic increase:

1. compare ingress request and connection counts with Lasso upstream-attempt
   metrics and the provider's own usage report;
2. attribute retries, rate-limit responses, and fallback attempts by provider,
   method, and transport;
3. confirm the sustainable aggregate capacity still has the planned headroom;
4. verify that public endpoints are treated as opportunistic capacity unless an
   explicit service contract says otherwise; and
5. keep ingress limits below the capacity you have actually qualified.

Core observes provider rate-limit responses and can cool down or fail over, but
it does not reserve purchased quota, enforce account budgets, or guarantee an
exact traffic split. Those remain operator responsibilities.

## Cut over

After the canary passes, increase traffic in recorded steps. At each step, retain
the exact Core version, profile revision, upstream credential scopes, ingress
configuration, and rollback target. Complete one full peak window before removing
the old route. Keep the old configuration available until quota reconciliation,
WebSocket stability, and the required archival/method matrix remain clean at the
intended load.

See [Routing](ROUTING.md) for selection and retry semantics,
[Observability](OBSERVABILITY.md) for metric meanings, and
[RPC standards](RPC_STANDARDS.md) for supported-method boundaries.
