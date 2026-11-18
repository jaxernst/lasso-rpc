# RPC Core method support

This page describes the self-hosted **v0.8.4** runtime. Lasso Cloud has a separate
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
  on a transaction provider when the chain declares them, and an ambiguous
  outcome returns the [indeterminate error](API_REFERENCE.md#transaction-send-errors-and-metadata).

Responses with `include_meta` report the class and how it was chosen; see
[observability metadata](API_REFERENCE.md#observability-metadata).

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

Without a chain [`transactions`](CONFIGURATION.md#transaction-providers) block, a
send runs once and is not retried after dispatch. With one, sends go only to the
listed providers, one at a time, and the same bytes may be resent to another of
them within the request deadline ([routing](ROUTING.md#transaction-providers)).
A null send result stays null.

Under a policy, after a failed `eth_sendRawTransaction` Lasso looks up its hash
among the providers of the phase that sent it before returning the error. Without a
policy, and for other send methods, the upstream result is returned without a
lookup. A lost response may still mean the transaction was accepted. Clients
own signing, nonces, replacement, receipts and finality. Errors and metadata are
in the [API reference](API_REFERENCE.md#transaction-send-errors-and-metadata).

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
