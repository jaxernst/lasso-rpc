# Routing

Provider selection in Lasso operates as a 4-stage pipeline that transforms a pool of candidate providers into an ordered execution plan. Strategy ranking consumes published recent routing evidence, while live admission remains authoritative.

Numeric historical-request age is measured against a fresh concrete head from
the requested file profile, not another profile's upstreams. A qualified or
single-upstream uncorroborated snapshot can provide that height; ambiguous or
missing evidence cannot establish age. Block-hash selectors still require a
declared archival provider because their age is unknown before dispatch.

## Pipeline Overview

```
Candidate Pool → Strategy Ranking → Health Tiering → Execution
```

1. **Candidate Pool**: All providers configured in the profile that support the requested chain and method
2. **Strategy Ranking**: Strategy-specific ordering (latency, weighted random, priority, etc.)
3. **Health Tiering**: Circuit breaker and rate limit state reordering into 4 tiers
4. **Execution**: Sequential attempts with failover

The pipeline ensures that healthy providers receive preference while recovering providers are gradually reintroduced. Open-circuit providers are excluded entirely.

## Head freshness

A request that needs the chain's moving head prefers routes measured at it.
Background head observations run in rounds: once per head interval, every
upstream on a chain is asked for its head in the same tick. An upstream fed by a
live `newHeads` subscription answers with its latest head and needs no poll; any
other is polled over HTTP. A route is compared with the other upstreams its
profile observes in that round, and an upstream's HTTP and WebSocket routes
share its verdict. The round's mark is their highest height; with three or more
upstreams, a height more than the agreement band above their lower median is an
outlier and cannot be the mark. A route's lag is the mark less its own height.
Answers land at different moments, since an HTTP poll may take up to its 3 s
deadline, so a route that answered before the mark is also credited with the
whole blocks its `block_time_ms` fits between the two answers. The credit
assumes the chain makes blocks at its configured `block_time_ms` and never
consults measured cadence, so it is exactly as good as that setting: on a chain
that runs faster than configured, an early answer can still look up to the
difference behind, and the band absorbs small drift. The band is the blocks the chain produces in two seconds at its `block_time_ms`,
from 1 to 20, the same span of time on a 250 ms chain and a 12 s chain. A route
whose lag exceeds the band is deferred behind the others in its health tier
until a later round measures it within the band. Client head reads and
`newHeads` events between rounds never change a route's moving-head verdict.

A round judges a profile's routes only when at least two of its upstreams
answered. Two heights cannot show which one is wrong, so the higher one is the
mark, and the lower route is deferred when its lag exceeds the band. A profile
with fewer than two upstreams with background observations on a chain gets no
lag verdict there, so its moving-head reads keep strategy order.
A round counts every answer that arrives before its poll deadline, even after
the next round has started. A round with at least two of a profile's upstreams
records each one's lag for that profile; a round with fewer leaves the
profile's lags as they are, so another profile's rounds never replace them.
Changing a profile's upstreams, which of them have background observations on,
or its `block_time_ms` starts it with no lags, even when the change restores an
earlier configuration. Only a round that starts after the change records lags
for it, and a round starts before it asks any upstream for a head, so neither an
answer given before the change nor a lag measured against other upstreams is
ever read. Until a round that started after the change has heights from at
least two of the profile's observing upstreams, the profile has no lag verdict,
and its moving-head reads keep strategy order as they do with no stored lag. A
route that errors or skips a round keeps its last measured lag until that
measurement is older than the freshness window of the route's own head
observations. When an upstream switches between `newHeads` and HTTP polling, or
its `newHeads` head moves backward, a round starts at once, so the change is
measured without waiting for the next tick.

A profile with background observations off gets no round lag, so its
moving-head reads keep strategy order even when another profile observes the
same upstreams, and so do unobserved and stale routes. A read at a fixed block,
in any profile, defers a route whose fresh observation stays short of that
block even after crediting the blocks the chain could have produced since. A
fresh route that reports the qualified reference height on a different block
hash is deferred the same way. Deferral never excludes a route, so when every
current route fails or lacks the method, a lagging route still serves.

What a request needs comes from its own parameters:

| Request | Requirement |
|---------|-------------|
| `latest` selector | The moving head |
| Numeric selector | That block |
| Range (`eth_getLogs`, `trace_filter`, `debug_getModifiedAccountsByNumber`) | Its upper bound; an omitted upper bound means the moving head |
| Omitted optional selector (see below) | The moving head |
| Replay-safe read with no block parameter, such as `eth_blockNumber` or `eth_getTransactionReceipt` | The moving head |
| Block hash, `earliest`, `safe`, `finalized`, `pending`, an unusable selector, or an omitted required selector | None |
| Writes and subscriptions | None |

A route proven below a numeric block is deferred for that request; a route at or
above it keeps its order. A provider a few blocks behind therefore still serves
historical reads under any strategy, while it loses `latest` reads to a current
peer.

Omitted optional selectors resolve to the client's current state. Lasso treats
these methods' omissions as the moving head, from these pinned client sources:

| Method | Client source |
|--------|---------------|
| `eth_call`, `eth_estimateGas`, `eth_simulateV1` | Geth [Call](https://github.com/ethereum/go-ethereum/blob/v1.16.4/internal/ethapi/api.go#L769-L777), [EstimateGas](https://github.com/ethereum/go-ethereum/blob/v1.16.4/internal/ethapi/api.go#L880-L886), [SimulateV1](https://github.com/ethereum/go-ethereum/blob/v1.16.4/internal/ethapi/api.go#L791-L802); Erigon [Call and EstimateGas](https://github.com/erigontech/erigon/blob/v3.2.2/rpc/jsonrpc/eth_call.go#L57-L166) |
| `eth_getBalance`, `eth_getCode`, `eth_getTransactionCount`, `eth_getStorageAt` | Nethermind [EthRpcModule](https://github.com/NethermindEth/nethermind/blob/1.35.2/src/Nethermind/Nethermind.JsonRpc/Modules/Eth/EthRpcModule.cs#L161-L279) through [SearchForHeader](https://github.com/NethermindEth/nethermind/blob/1.35.2/src/Nethermind/Nethermind.JsonRpc/Modules/BlockFinderExtensions.cs#L29-L36), which resolves null to latest |
| `eth_getProof`, `eth_getStorageValues` | Geth v1.17.10 [blockNrOrHashOrLatest](https://github.com/ethereum/go-ethereum/blob/v1.17.10/internal/ethapi/api.go#L334-L341) |
| `eth_createAccessList` | Geth [CreateAccessList](https://github.com/ethereum/go-ethereum/blob/v1.16.4/internal/ethapi/api.go#L1141-L1147) uses latest; Erigon [uses pending](https://github.com/erigontech/erigon/blob/v3.2.2/rpc/jsonrpc/eth_call.go#L750-L803), which also depends on current state |
| `debug_traceCall`, `trace_call`, `trace_callMany` | Nethermind [debug](https://github.com/NethermindEth/nethermind/blob/1.35.2/src/Nethermind/Nethermind.JsonRpc/Modules/DebugModule/DebugRpcModule.cs#L84-L90) and [trace](https://github.com/NethermindEth/nethermind/blob/1.35.2/src/Nethermind/Nethermind.JsonRpc/Modules/Trace/TraceRpcModule.cs#L56-L73) modules; Erigon [trace_adhoc](https://github.com/erigontech/erigon/blob/v3.2.2/rpc/jsonrpc/trace_adhoc.go#L1030-L1235) |

Lasso never rewrites the parameters; the requirement only orders routes. These
sources are evidence for the rule, not a qualification of any live provider.

## Learned provider limits

Method refusal, historical depth and `eth_getLogs` span learning are enabled by
default. Repeated matching outcomes move an unsuitable connection behind other
eligible connections in the same availability tier, and a learned method refusal
skips that connection for the method while another candidate remains. Methods
outside the registry learn sooner, since they cannot fail over within a request.
A learned limit never removes the final candidate, overrides operator capability
declarations, increases the request deadline or grants another transaction
dispatch. Because the final candidate is still tried, a provider that starts
serving a method again is found by ordinary traffic.

Evidence belongs to the configured endpoint, credentials, transport and sharing
scope. Method refusal is method-specific. Historical hints are method- and
resource-specific and need a qualified request age plus fresh failure witnesses;
head lag, empty results and zero values do not establish missing history. Span
learning uses numeric block ranges and explicit block-span failures; result-volume
limits and mixed or ambiguous wording do not establish a span boundary.

Hints expire and newer successful evidence can withdraw them. Unknown or missing
knowledge keeps ordinary routing available. Feedback is delivered on a bounded
background lane; overload can discard observations without delaying RPC. Learned
state lives in local memory and is rebuilt from traffic after restart. Core does
not restore database checkpoints or start cross-node knowledge-image exchange.

Use `include_meta=body` or `include_meta=headers` for the bounded
`learning_decision` explanation. It includes the effect kind, support and ordering
scope, while excluding request bodies and internal route mappings. On the node,
`Lasso.Diagnostics.provider_knowledge(profile, chain_id, provider_id)` returns
current hints per transport. A deferral records an order change, not proof that a
failure was prevented.

See [configuration](CONFIGURATION.md#learned-routing) for per-kind kill switches.

## Routing Strategies

Strategies control the initial ordering of providers. Select via URL path segment: `/rpc/:strategy/:chain`.

`lasso_meta.strategy` reports the strategy that routed the request as an atom name with an
underscore, such as `load_balanced` or `balanced_fast`. URLs use the hyphenated slug.

### Load Balanced

**URL**: `/rpc/load-balanced/:chain`
**Module**: `Lasso.RPC.Strategies.LoadBalanced`

Randomizes physical provider instances first, then the transports within each
instance. An upstream offering both HTTP and WebSocket receives one first-pick
share. For replay-safe unary reads, fallback
tries distinct physical provider instances before sibling transports within each
availability tier. Alternate transports remain available; a healthy alternate
still precedes a different provider in a lower availability tier. The lazy cursor
bounds healthy-sibling deferral by its remaining candidate limit, and explicit
recovered-head preference takes precedence over diversity.

Unsafe or unknown methods retain the instance-shuffled order and existing replay limits.
This ordering does not increase the dispatch budget or deadline, infer
archive capabilities, or guarantee successful historical reads. A hash selector
can leave more distinct providers eligible than the budget can cover. Trying
another provider first can also delay a working alternate transport on the
previous provider.

The strategy provides statistical distribution over time, not exact shares,
capacity awareness, or cluster-global balancing.

### Fastest

**URL**: `/rpc/fastest/:chain`
**Module**: `Lasso.RPC.Strategies.Fastest`

Ranks with the balanced-fast permutation below at exponent 8 instead of 3, so the quickest measured upstream takes nearly all traffic. At a twofold latency gap the slower of two upstreams ranks first in about one request in 257; at a tenfold gap, about one in 10^8. Every request runs the full ranking. Evidence is local to the routing node and keyed by a bounded registered workload key rather than arbitrary RPC method strings.

Client and system attempts use separate fixed method families: basic, state, logs, trace, transaction, and subscription. Unknown methods share one fallback partition. A successful `eth_blockNumber` read can qualify the basic family but does not qualify `eth_getBalance` or `eth_getLogs`; system observations can seed ordering in their family but cannot qualify client traffic.

**Use When**:
- Latency is the primary concern
- You're willing to concentrate load on the fastest provider
- The method being called is latency-sensitive (e.g., `eth_getBlockByNumber`)

**Behavior**:
- One unproven upstream per request, with no latency evidence in the family or only stale evidence, competes at the weight of the quickest. A slow first winner cannot hold a family: an untried upstream gets about half the first picks until it has a sample, and an upstream whose evidence expired is challenged again
- Weighs a measured upstream that has not qualified, including one known only from its system prior, by its mean like a qualified one; client samples replace the prior once they exist
- Orders upstreams with unreliable evidence after the others, as in balanced-fast
- Never uses lifetime averages for routing
- Preserves all live candidates and emits an availability degradation when none qualifies
- Makes no switching-margin or measured-p95 promise; live admission and health tiering still apply afterwards

### Balanced Fast

**URL**: `/rpc/balanced-fast/:chain` (`latency-weighted` is an alias), or `/rpc/:chain` with no strategy, since this is the default
**Module**: `Lasso.RPC.Strategies.BalancedFast`

Orders reliable upstreams by a weighted random permutation over each upstream's best latency evidence: its client mean in the method family, else the same family's system prior. It sits between load-balanced and fastest: load stays spread while the quickest providers receive more of it.

**Use When**:
- You want a balance between performance and distribution
- Avoiding single-provider concentration is important
- You have providers with significantly different performance profiles

**Behavior**:
- Calculates dimensionless relative weights:
  ```
  weight = (best_mean / candidate_mean)^beta
  ```
- Generates the permutation with exponential-race keys: `-log(U) / weight`
- Places upstreams in this order: (1) a weighted permutation of the upstreams with current latency evidence plus one picked at random from the unproven ones, those with no latency evidence or only evidence that has gone stale, which weighs as much as the quickest so it earns a sample instead of being starved and an expired upstream is retried rather than left last; (2) the remaining unproven upstreams, shuffled; (3) upstreams whose evidence is unreliable (three consecutive failures, or recent success probability below 0.75), ordered among themselves the same way
- Applies reliability as a boundary, not a weight multiplier
- Bounds the ranking, not every dispatch order: among upstreams that are not unreliable, at most one unproven upstream ranks ahead of those with current latency evidence, but health tiering runs afterwards and can move a measured upstream with a half-open circuit behind unproven ones
- Uses no latency floor or weight floor
- When no candidate qualifies, emits an availability degradation; the ordering is unchanged

**Configuration**:
- `BALANCED_FAST_BETA`: Latency exponent (default: 3.0, higher = more aggressive preference for low latency)

**Evidence lifetime**: a route's family evidence expires for ranking five minutes after its last comparable observation. Each consecutive client failure after the first doubles that lifetime, up to an hour, and a success resets it; system evidence from probes and head polls keeps five minutes. A route that never answers is therefore re-sampled a few times a day instead of every five minutes.

Opaque server and vendor errors are ambiguous: replay-safe reads may fall back without a health penalty or success evidence, while unsafe requests return the original error without replay. The execution-fact codec writes major version 2 and also reads ordinary version-1 facts; version 1 cannot express ambiguous response semantics.

### Priority

**URL**: `/rpc/priority/:chain`, or `/rpc/:chain` when `config :lasso, :provider_selection_strategy, :priority` is set. The shipped default is `:balanced_fast`.
**Module**: `Lasso.RPC.Strategies.Priority`

Selects providers in the order defined by the `priority` field in the profile. Lower priority values are tried first.

**Use When**:
- You have a preferred provider (e.g., your own node) with fallbacks
- Predictable routing order is more important than performance optimization
- You want explicit control over provider precedence

**Behavior**:
- Sorts providers by priority field (ascending)
- No dynamic reordering based on performance
- Still subject to health tiering (closed-circuit providers preferred)

**Configuration**:
Set `priority` in the profile YAML:

```yaml
providers:
  - id: "my_node"
    url: "https://my-node.example.com"
    priority: 1
  - id: "alchemy_backup"
    url: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    priority: 2
```

## Health-Based Tiering

After strategy ranking, the pipeline applies a 4-tier reordering based on circuit breaker state and rate limit status. This ensures healthy providers receive traffic first while allowing recovering providers to gradually reintegrate.

### The 4 Tiers

Providers are reordered into these tiers (descending preference):

1. **Tier 1**: Closed circuit + not rate-limited
2. **Tier 2**: Half-open circuit + not rate-limited
3. **Tier 3**: Closed circuit + rate-limited
4. **Tier 4**: Half-open circuit + rate-limited

**Excluded**: Open circuit providers are filtered out entirely.

Within each tier, the strategy's original ranking is preserved. For example, with load-balanced, Tier 1 providers remain shuffled relative to each other.

### Circuit Breaker States

Circuit breakers track provider health per transport (HTTP/WS independently):

- **Closed**: Healthy. Provider is tried normally.
- **Half-open**: Recovering. Provider is deprioritized but periodically probed for recovery.
- **Open**: Failing. Provider is excluded from selection entirely until timeout expires.

Circuit breakers trip based on consecutive failures and success rate thresholds. See [OBSERVABILITY.md](OBSERVABILITY.md#circuit-breaker-metrics) for metrics and configuration.

### Rate Limit Detection

Rate limit status is tracked separately from circuit breakers. A provider can be closed-circuit but rate-limited, meaning it's healthy but temporarily throttled.

Rate-limited providers are not excluded but are deprioritized to Tier 3 or Tier 4. This allows Lasso to try a recovering channel with available capacity before one already marked capacity-limited.

## Example: Why Traffic Distribution May Be Uneven

Even with the load-balanced strategy, traffic may appear concentrated on certain providers. This is intentional and reflects health tiering.

**Scenario**: 3 providers (A, B, C)

- Provider A: Closed circuit, not rate-limited → **Tier 1**
- Provider B: Closed circuit, rate-limited → **Tier 3**
- Provider C: Half-open circuit, not rate-limited → **Tier 2**

With load-balanced, Lasso shuffles providers then reorders by tier:

1. Provider A (Tier 1) receives the first attempt on every request
2. Provider C (Tier 2) receives attempts only if A fails
3. Provider B (Tier 3) receives attempts only if A and C both fail

**Result**: Provider A receives ~100% of traffic as long as it succeeds. This is correct behavior—Lasso routes to the healthiest provider while maintaining fallbacks.

To allow statistical distribution, keep multiple providers in Tier 1 (closed
circuit + not rate-limited). Load-balanced routing does not guarantee exact
shares or account for provider capacity.

## Strategy-Health Interaction

All strategies are subject to health tiering. The strategy determines the order within each tier, but tier ordering takes precedence.

Exception: a connection-class HTTP circuit in half-open with a free probation lease and no rate limit keeps its ordinary strategy ranking instead of being deferred behind closed circuits.

| Strategy | Within-Tier Behavior | Cross-Tier Impact |
|----------|---------------------|-------------------|
| Load Balanced | Randomized; replay-safe fallback gives distinct physical instances a bounded first pass | Health tiers and recovered-head preference dominate |
| Fastest | Latency-ordered | Fastest provider may not receive traffic if unhealthy |
| Latency Weighted | Weighted random | Weights apply only within each tier |
| Priority | Priority-ordered | Priority applies only within each tier |

**Example**: With fastest strategy, if the fastest provider has a half-open circuit outside the connection-probation exception above, any closed-circuit provider will be tried first, even if it's slower.

## Execution and Failover

After tiering, Lasso attempts providers sequentially until success or all providers are exhausted.

**Success**: First provider that returns a valid RPC response (2xx status, valid JSON-RPC structure)

**Failure**: Provider is skipped and the next provider in the list is tried. Failures increment circuit breaker counters.

**All Exhausted**: Returns HTTP `200 OK` with a standard JSON-RPC error response. The error uses code `-32000`, preserves the client's request ID, and does not expose internal provider-attempt details.

See [API_REFERENCE.md](API_REFERENCE.md#error-responses) for error format details.

## Configuration Reference

Strategy behavior can be tuned via environment variables:

| Variable | Strategy | Default | Description |
|----------|----------|---------|-------------|
| `BALANCED_FAST_BETA` | Balanced Fast | 3.0 | Latency exponent |

See [CONFIGURATION.md](CONFIGURATION.md#routing-strategies) for the application default and URL strategy configuration.

## Method and Subscription Policy

Choose request strategies through the URL. YAML does not support a `routing` or
`method_overrides` block. Provider `capabilities` can exclude specific methods
and constrain block ranges and history; see [Configuration](CONFIGURATION.md#provider-capabilities).

WebSocket URL strategies apply to forwarded JSON-RPC calls. `eth_subscribe`
uses a shared subscription pool that selects eligible providers by priority,
independently of the URL strategy. An explicit provider URL constrains the
subscription to that provider and cannot fail over to another provider.

During log recovery, buffered events preserve each log identity's addition/removal
order through its last removal before final additions from replacement blocks are
delivered. Core deduplicates positive and removed events separately by block hash
and log index. Repeated removal and re-addition of the same identity within the
dedupe window is not fully modeled; this ordering rule is not a claim of complete
recovery for every repeated reorg sequence.

## Provider Override

Bypass strategy selection entirely by routing directly to a specific provider:

```
POST /rpc/provider/:provider_id/:chain
```

The provider ID must match a provider configured in the profile. Health checks and circuit breakers still apply—if the provider is open-circuit, the request will fail. Learned limits do not apply, so an override can check whether a provider serves a refused method again.

This is useful for debugging, testing specific provider behavior, or implementing custom provider selection logic outside of Lasso.

## Transaction providers

When a chain declares [`transactions`](CONFIGURATION.md#transaction-providers),
every request uses one side of its providers. Sends
([execution classes](RPC_STANDARDS.md#execution-classes)) go only to the
transaction providers, one at a time, and ignore head lag because a send-only
provider may report a stale head. Reads, subscriptions and block recovery never
use them; a subscription on a provider that becomes a transaction provider moves
to a read provider. Every selection step, including pins and retries, works on
that side alone. Background checks sit outside request routing: the `eth_chainId`
identity probe still reaches every provider, and a transaction provider with a
`ws_url` keeps its `newHeads` head subscription. Neither carries transaction
data. `background_observations: false` on the provider disables both periodic
checks, though a routed request to it that times out still schedules one probe
of that upstream.

Sending fails closed: when no transaction provider can take a send, the request
fails instead of reaching another provider. `fallback: read_providers` adds a
second phase over the profile's read providers once the transaction providers are
exhausted, within the same deadline and dispatch budget. The two sides are never
ranked together, and neither phase leaves the profile. The hash lookup after a
failed send stays in the phase that sent it.
