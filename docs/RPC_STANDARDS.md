# RPC Core method support

This page describes the self-hosted **v0.10.0** runtime. Lasso Cloud has a separate
[compatibility contract](https://docs.lasso.sh/cloud/json-rpc-compatibility).
Do not infer parity from a shared method name or product version.

## Execution classes

Lasso decides how a request may run from what its method does, not from which
provider serves it. The registry classifies methods; it does not certify that a
provider implements them.

- **Reads** (`replay_safe`), such as `eth_call`, `eth_getBalance` and
  `eth_getLogs`, have no side effects. A failed or refused read can move to
  another provider within the request deadline. When every provider it reached
  answered `-32601`, the caller receives that upstream error; otherwise the
  request's other failure is returned.
- **Sends** (`raw_transaction_broadcast`) submit a signed transaction or act on a
  submission: `eth_sendRawTransaction`, `eth_sendRawTransactionSync`,
  `eth_sendRawTransactionConditional`, `eth_sendPrivateRawTransaction`,
  `eth_sendPrivateTransaction`, `eth_cancelPrivateTransaction`,
  `eth_sendBundle`, `eth_cancelBundle` and `mev_sendBundle`. Simulations of
  signed transactions (`eth_callBundle`, `mev_simBundle`,
  `trace_rawTransaction`) are sends too, so the bytes stay with the same
  providers. See [transaction sends](#transaction-sends).
- **Subscriptions** (`subscription`): see [WebSocket subscriptions](#websocket-subscriptions).
- **Other methods** (`unknown`) run once on a read provider and are not retried;
  a timeout is reported as indeterminate. A `-32601` is the answer, and Lasso
  learns the refusal so later requests start elsewhere
  ([learned provider limits](ROUTING.md#learned-provider-limits)). When the
  params carry a signed transaction, the method is a send instead: it runs once,
  routed like other [sends](#transaction-sends), and an ambiguous
  outcome returns the [indeterminate error](API_REFERENCE.md#transaction-send-errors-and-metadata).

Responses with `include_meta` report the class and how it was chosen; see
[observability metadata](API_REFERENCE.md#observability-metadata).

## Outbound quota exhaustion

An operator can configure a per-upstream, per-node outbound
[`request_budget`](CONFIGURATION.md#outbound-request-budget). A refusal sends
nothing, leaves upstream health/circuits/cooldowns unchanged, and permits another
eligible route even for methods that cannot replay after dispatch. Transaction
provider restrictions still apply. If every eligible route is budget-refused,
return `-32005` with `data.reason: "upstream_request_budget_exhausted"` and
`data.retry_after_ms` for the earliest refill. Mixed failures follow ordinary
exhaustion rules; existing `eth_getLogs` range advice retains precedence.

## Log range exhaustion

When an `eth_getLogs` request encounters an upstream range or result-size refusal
and no upstream completes it, exhaustion returns `-32005` with
`data.reason: "log_range_too_large"` and `data.action: "reduce_block_range"`.
This applies to provider, dispatch, candidate-admission and deadline exhaustion,
including later timeouts or rate limits. Narrow the range before retrying; the
unchanged request is not retriable. A later rate limit's retry delay is not
attached to this range error: waiting alone does not resolve the range refusal.

A refusal is treated as a per-provider capability failure when the request
selects exactly one block: the resolved `fromBlock` and `toBlock` are equal, or
the filter specifies `blockHash`. Narrowing cannot resolve those refusals (for
example, missing retained history). Lasso tries the remaining providers and
these refusals do not contribute range advice at exhaustion. If every reached
provider refuses, candidate or dispatch exhaustion returns `-32006`
(`capability_violation`) with the message "This provider cannot serve eth_getLogs
for this block; history may not be retained" and no advice data. Upstream
narrowing instructions are not forwarded for these one-block refusals.
A query from block
N through N+1 selects two blocks and can still be narrowed. Multi-block queries
and unknown spans retain the range-refusal behavior described above.
Lasso's local response-size cap still returns range advice immediately.

When a range-refusing provider has an operator-configured
`capabilities.limits.max_block_range`, `data.max_block_range` carries the smallest
such configured cap among this request's refusals. Without that configuration,
the response gives narrowing advice without a number. Provider error wording,
including numbers about retained history or result counts, never supplies a cap.
A configured cap is a span limit, not a guarantee that every filter or upstream
will serve that range. A successful fallback still returns its result.

## Transaction sends

A registered send makes up to three sends to distinct upstreams, one at a time,
within the request deadline. With a chain [`transactions`](CONFIGURATION.md#transaction-providers)
block, sends go only to the listed providers, then to the read providers once
those are exhausted when it sets `fallback: read_providers`
([routing](ROUTING.md#transaction-providers)). A null send result stays null.

`eth_sendRawTransaction` resends the same signed bytes unless the rejection is on
the stop list in the [transaction-outcome module](../lib/lasso/core/support/transaction_outcome.ex):
known transactions and sender faults such as nonce bounds, insufficient funds,
invalid signatures, malformed transactions and invalid gas or fee limits. All
other outcomes fail over, including rate limits, timeouts, 5xx, replacement
underpricing, pool capacity and unfamiliar wording. A rate-limit or quota refusal
and a `-32601` do not use up one of the three sends; such refusals are bounded by
the allowed providers and the request deadline.

Before returning an `eth_sendRawTransaction` error, Lasso looks up the local
hash with `eth_getTransactionByHash`. It asks the
upstream that answered last, then each earlier upstream that may have broadcast
the bytes, one at a time within the remaining deadline. An earlier send may have
broadcast when it got an unclassified error, an invalid response, a timeout or a
connection lost after sending. A rate-limit or quota refusal, a `-32601`, a send
refused before dispatch and a recognized failover rejection such as replacement
underpricing did not, so those earlier upstreams are not asked; the upstream
that answered last is asked whatever its rejection. Each send that may have
broadcast, such as several that timed out, gets its own pinned lookup, in either
send phase. Only when the last upstream gave no answer and no other send may
have broadcast does Lasso ask one healthy upstream among the current send
phase's providers. A send rejected as invalid params before dispatch, or one
that reached no upstream under a policy, gets no lookup. Pending or mined
evidence returns the hash only when the object's hash matches it
case-insensitively. Wording alone never reports success.

A `null` result means that upstream does not have the transaction. When every
upstream asked returns `null`, the original error stands. A lookup that fails,
times out, finds no time left, or returns a mismatched or unreadable object
leaves the outcome unknown. If an earlier send may have broadcast and no lookup
found the hash, an unknown outcome returns `-32000` "Upstream dispatch outcome is
indeterminate" instead of the last rejection; check the hash before sending
again. Its `data.upstream_message` is a shortened copy of the last upstream's
message. With no earlier possible broadcast, an unknown lookup keeps the
original error. Only the EIP-4844 network wrapper is decoded for hashing; other
transaction types route opaquely, and acceptance hashes are not policed. Other
send methods return the upstream result without a lookup.

A response proves submission only, not propagation, inclusion or finality, and
when every attempt fails and the hash is not found the outcome can still be
unknown; reconcile by hash. Clients own signing, nonces, replacement, receipts
and finality. Errors and metadata are in the
[API reference](API_REFERENCE.md#transaction-send-errors-and-metadata).

While a transaction is private, ordinary providers return null for it and their
pending nonce excludes it until inclusion, so manage nonces client-side. Lasso
does not forward caller headers such as `X-Flashbots-Signature`; methods that
need a sender signature header are not supported yet.

## Node-local methods

Core rejects the registry's `local_only` methods, including
`eth_sendTransaction`, `eth_accounts`, `eth_sign`, and `eth_signTransaction`,
as well as `personal_sign`. Provider capability policy can reject additional
methods. Do not treat a profile as an authentication or authorization boundary.

## Stateful filters and extensions

Current Core rejects provider-local filter lifecycle methods such as
`eth_newFilter`, `eth_getFilterChanges`, and `eth_uninstallFilter`. Their filter
IDs belong to one upstream, while Core does not provide cross-request provider
affinity. Use `eth_getLogs` or supported WebSocket subscriptions instead. The
released v0.4.5 could forward these methods when capability policy permitted
them, without a reliable multi-provider filter lifecycle.

Debug, trace, transaction-pool, bundler, and chain-specific methods depend on
upstream support and configured restrictions. Their presence in a registry does
not provide sticky sessions, common history, or a universal parameter contract.

## WebSocket subscriptions

The supported stream kinds are `newHeads` and `logs`. Use:

```json
{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
```

```json
{"jsonrpc":"2.0","method":"eth_subscribe","params":["logs",{}],"id":2}
```

Use `eth_unsubscribe` with the returned subscription ID to stop the stream.
Pending-transaction subscriptions are not part of this released subset.
HTTP subscription requests return a method error with a WebSocket URL hint.

Matching client streams can share upstream subscriptions. Establishment requires
a usable upstream before returning a subscription ID. Recovery uses bounded HTTP
replay and a replacement live stream. Recovery beyond its time, replay, attempt,
or buffer limits terminates the affected downstream connection explicitly; it
does not promise unbounded or lossless delivery through arbitrary outages.

In this release, `subscribe_new_heads` controls automatic block monitoring **and**
client `newHeads` eligibility. Set it to `true` on intended providers. New profiles
can reuse an already-connected upstream after a successful configuration reload.
See [Configuration](CONFIGURATION.md) and [Deployment](DEPLOYMENT.md).

## HTTP batches

HTTP endpoints accept arrays with up to 50 items by default (`max_batch_requests`).
Items are validated and routed independently with bounded concurrency. A batch
is not an atomic state snapshot and does not pin every item to one provider.
Response items retain request order. Valid notifications produce no response;
an all-notification batch returns HTTP 204. Use unique IDs for correlation.

## Deployment boundary

Core does not authenticate clients or enforce incoming customer quotas. Protect
RPC, metrics, and dashboard endpoints through your network or reverse proxy.
Profile tester settings do not create API quotas or upstream quota isolation.

The authoritative implementation is `TransportPolicy`, `ExecutionEnvelope`,
`Capabilities`, `RPCController`, and `RPCSocket.ItemOwner` at the selected release.
See [API reference](API_REFERENCE.md) for routes and metadata.
