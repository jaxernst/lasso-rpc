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
| Ordered primary and fallback | Provider `priority` plus the `:priority` application strategy | The shipped default is `balanced_fast`; use `/rpc/priority/:chain` to select priority explicitly. |
| Even/random pool | `/rpc/load-balanced/:chain` | This is bounded randomized ordering, not exact traffic shares or quota-aware weighting. |
| Latency routing | `/rpc/fastest/:chain` or `/rpc/balanced-fast/:chain` | Rankings use successful-attempt evidence and still apply health/capability filtering. |
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
fallback retains time. Signing, filter creation and consumption,
subscriptions, and unknown methods receive one dispatch. A transaction send
receives one dispatch unless the chain declares
[transaction providers](ROUTING.md#transaction-providers); then the same signed
bytes may be sent up to three times, one provider at a time, within the deadline.

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
Do not automatically replay signing or state-changing requests. Core bounds its
own send attempts as described above; applications may safely reconcile a known
signed transaction by its hash before deciding what to do next.

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

### Measure a profile against its own providers

`scripts/measure_profile.mjs` sends the same calls, at the same moment, to each
provider directly and through a Lasso profile that uses those providers. It
needs Node.js 18 or newer and no packages. It runs from a clone of this
repository, which a Docker install doesn't have, so clone it first
(`git clone https://github.com/jaxernst/lasso-rpc && cd lasso-rpc`) and run it
from the repository root against a profile that is already serving traffic. To serve a profile on Core,
including one exported from Lasso Cloud, see [Deployment](DEPLOYMENT.md).

Set the profile URL your application would use. Self-hosted Core takes no key:

```bash
export LASSO_URL='http://localhost:4000/rpc/profile/<slug>/fastest/<chain>'
```

Lasso Cloud takes the key in the path:

```bash
export LASSO_URL='https://lasso.sh/rpc/k/<key>/profile/<slug>/fastest/<chain>'
```

`<slug>` is the profile slug, `<chain>` is the chain name as the profile lists
it, such as `ethereum`, and `<key>` is your Lasso Cloud key. If your Core node
listens somewhere other than `localhost:4000`, use that address instead.

Set the URL of each provider in the profile, with its key if it has one:

```bash
export PROVIDER_1_URL='<provider-1-url>'
export PROVIDER_2_URL='<provider-2-url>'
```

For a third provider, export `PROVIDER_3_URL` and add
`--provider provider-3=env:PROVIDER_3_URL` after the other `--provider` flags
in both commands below.

#### Comparison

```bash
node scripts/measure_profile.mjs \
  --lasso lasso=env:LASSO_URL \
  --provider provider-1=env:PROVIDER_1_URL \
  --provider provider-2=env:PROVIDER_2_URL \
  --out comparison.json
```

The run takes about 100 seconds: 200 rounds, 2 per second, one call to every
endpoint per round. Calls rotate through `eth_blockNumber`,
`eth_getBlockByNumber`, `eth_getBalance`, `eth_getCode`,
`eth_getTransactionReceipt` and `eth_getLogs` over 10 blocks. Block-dependent
calls use one block 16 below the lowest provider head, and their addresses and
transaction hashes come from that block, so no chain-specific input is needed.
A method that block gives no input for is left out; the output lists the
methods used.
The script refuses to start if the endpoints report different chain IDs.

The output has this shape:

```text
Comparison: chain <id>, 200 rounds at 2 per second, block <n> pinned for block-dependent calls.
Methods in rotation: <methods>.

Endpoint               Host    Calls  Answered  Errors          p50 ms  p90 ms  p99 ms
lasso (lasso)          <host>    200       <n>  <kind> <count>    <ms>    <ms>    <ms>
provider-1 (provider)  <host>    200       <n>  none              <ms>    <ms>    <ms>
provider-2 (provider)  <host>    200       <n>  none              <ms>    <ms>    <ms>

p50 ms by method  lasso  provider-1  provider-2
eth_blockNumber    <ms>        <ms>        <ms>
...

lasso strategy reported by Lasso: <strategy> <count>
lasso answered by: <provider-id> <count>, <provider-id> <count>
lasso upstream sends per call: 1 send: <count>, 2 sends: <count> (total <n> for <n> calls)
lasso latency against the best direct provider (<label>, lowest p50): p50 <+ms> ms, p90 <+ms> ms, p99 <+ms> ms
lasso routing time reported by Lasso for the same calls: routing apart from upstream waits p50 <ms> ms, p90 <ms> ms; waiting on the upstream p50 <ms> ms, p90 <ms> ms

Samples: comparison.json
Result: complete.
```

Errors are counted by kind: `timeout`, `network <code>` (a system error code
such as `ECONNREFUSED`), `rate limit`, `http <status>`, `rpc <code>` and
`bad response`. The script sets `include_meta=body` on the Lasso URL,
replacing any value already there, and reads the strategy that routed each call, the answering
provider, the number of upstream sends and Lasso's routing time from
`lasso_meta`. The metadata names the provider that answered, not one that
refused. Latency is measured from the machine running the script, so it
includes the network path to each endpoint.

The difference against a direct provider includes everything between the
script and Lasso. Measure a release build, such as the published image, not a
development server, which adds time to every request. Lasso's reported time
covers routing: from receiving the request until routing finishes, split into
time waiting on the upstream and the rest. The remainder of the difference is
the path between the script and Lasso plus Lasso's handling of the response.
If `lasso_meta` carries no timing, that line says so and the run is still
complete.

#### Rate limit

This run spends `provider-1`'s quota on purpose: it sends up to 400 calls to
`provider-1` directly, 20 per second for 20 seconds. Name a provider whose
quota you can spare.

```bash
node scripts/measure_profile.mjs \
  --lasso lasso=env:LASSO_URL \
  --provider provider-1=env:PROVIDER_1_URL \
  --provider provider-2=env:PROVIDER_2_URL \
  --rate-limit provider-1 --limit-rate 20 --limit-seconds 20 \
  --out rate-limit.json
```

Each round sends the same `eth_getLogs` call to `provider-1` directly and
through the profile. The direct calls hold `provider-1` over its limit and
count its refusals: HTTP 429 or a JSON-RPC rate-limit error. The run stops
early once the caller sees 3 errors through the profile, or once 3 calls
through the profile need three or more upstream sends. Through the profile, each call
can reach at most three providers. The script caps `--limit-rate` at 50 and
`--limit-seconds` at 60.

The output has this shape:

```text
Rate limit: chain <id>, eth_getLogs, 20 calls/s for up to 20 s, <n> of 400 planned rounds sent.
Stopped early: <reason, or "no" when every planned round was sent>

provider-1 directly (<host>): <n> calls, <count> refusals (HTTP 429 or a rate-limit error)
lasso (<host>): <n> calls, answered <n>, errors: <kind> <count>
  latency of answered calls: p50 <ms> ms, p90 <ms> ms, p99 <ms> ms
  upstream sends per call: 1 send: <count>, 2 sends: <count>, 3 sends: <count> (total <n> for <n> calls)
  answered by: <provider-id> <count>, <provider-id> <count>
  strategy reported by Lasso: <strategy> <count>
  routing time reported by Lasso: routing apart from upstream waits p50 <ms> ms, p90 <ms> ms; waiting on the upstream p50 <ms> ms, p90 <ms> ms
  p50 latency: <ms> ms for calls sent once (<n>), <ms> ms for calls sent more than once (<n>)

Samples: rate-limit.json
Result: complete.
```

If `provider-1` refused nothing, it was not over its limit and the result is
incomplete; raise `--limit-rate`.

#### Reading the result

A run is complete when its last line is `Result: complete.` and it exits with
status 0. A rate-limit run that stopped early is complete. Otherwise the last
line is `Result: incomplete.` followed by the reasons, and the exit status is 1:
an endpoint answered no calls, Lasso responses lacked the answering provider or
send count, or the rate-limit target refused nothing.
A setup failure, such as an endpoint that does not answer `eth_chainId`, prints
the reason and the error kind and exits with status 1 before any calls are
measured. Progress lines, such as `50/200 rounds` and the line that opens a
rate-limit run, go to standard error and are not part of the output shapes
above.

The samples file is JSON written to the `--out` path in the current directory,
complete or not. `manifest` holds the mode, chain ID, pinned block, endpoints
by label and host, settings and completeness. `samples` holds one entry per
call: endpoint label, method, round, latency in `ms`, `ok`, the error
kind, and for Lasso calls `meta.strategy`, `meta.provider`, `meta.sends`,
`meta.routingMs` and `meta.upstreamMs`. Every line of the output can be
recomputed from it.

Neither the output nor the samples file contains anything derived from an
endpoint URL except its host, or any text an endpoint returned apart from the
strategy and provider identifiers in `lasso_meta`. Errors are recorded by kind
only, so keys in URLs cannot reach either file.

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
