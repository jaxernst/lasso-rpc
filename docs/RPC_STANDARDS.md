# RPC Core method support

This page describes the self-hosted **v0.7.0** runtime. Lasso Cloud has a separate
[compatibility contract](https://docs.lasso.sh/cloud/json-rpc-compatibility).
Do not infer parity from a shared method name or product version.

## Reads and execution safety

Common Ethereum reads such as `eth_blockNumber`, `eth_getBalance`, `eth_call`,
`eth_getTransactionReceipt`, and `eth_getLogs` are routable, subject to provider
capability, transport availability, history, and request parameters. A routable
method is not a guarantee that every provider supports it.

Methods classified as replay-safe by the released `ExecutionEnvelope` can use
bounded further attempts within the original deadline. Unknown methods receive
one upstream dispatch. Provider error classification does not override execution
safety. The registry classifies methods; it does not certify upstream semantics
or full compliance with every Ethereum specification.

A replay-safe read that receives `-32601` from one upstream continues to another
within its bounded attempts, and the rejected attempt consumes one of them.
Unknown methods and `eth_sendRawTransaction` without a transaction policy keep their single dispatch, so that
upstream's `-32601` is the answer. When a request ends unsuccessfully and every
upstream it reached rejected the method, Lasso returns that rejection with the
upstream's message and data instead of `-32000`. The request retains only the
latest rejection whole, so when a later candidate fails before dispatch the
caller receives the availability error instead. A later success or terminal
upstream error is returned as before. When the request ends unsuccessfully after
a rejection mixed with another outcome, the rejection is not the answer. The
caller receives the other outcome's error or the availability error, in either
order, depending on how the exhausted request ends. Lasso keeps no record that a
provider lacks a method beyond the request that observed it.

## Signed transaction submission

`eth_sendRawTransaction` without a transaction policy receives one upstream dispatch
and is not retried after dispatch. With a policy, sends receive at most three
sequential, identical-byte dispatches within the original deadline. Sends stay
inside the configured relay set unless public fallback is enabled. Terminal
failures can trigger hash confirmation inside that relay set. A lost response may mean the upstream accepted the
transaction. Clients remain responsible for signing, nonce management,
replacement, transaction-hash reconciliation, receipts, and finality.

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

## Transaction send policies

A chain `transactions` block applies to the `raw_transaction_broadcast` execution class, `eth_sendRawTransaction` and the relay-native send family. Reads and subscriptions exclude relay providers. Invalid send/read pins return `-32602` before dispatch (`pin_outside_transaction_providers` or `transaction_provider_send_only`).

Relays can reject read methods and report stale heads; sends therefore have no head-lag gate. A null send result remains null and does not imply hash acceptance. Transaction hash confirmation stays within the captured terminal send phase, including when a relay rejects that lookup.

When no send dispatch occurs under a policy, exhaustion returns `-32000` with `reason: transaction_providers_unavailable`, `error_type: transaction_provider_unavailable`, retry guidance and policy metadata. After dispatched sends fail and hash confirmation finds nothing, the last upstream error is retained with `send_policy` added and `phase` naming its phase. No synthetic exhaustion reason replaces that upstream error.

Private sends establish no read affinity. While a transaction remains private,
ordinary providers return null for its transaction and receipt, and their pending
nonce excludes that transaction until inclusion. Clients manage their own nonces;
Lasso maintains no private pending overlay.

Lasso does not forward caller request headers such as `X-Flashbots-Signature`.
Methods requiring a sender signature header are not supported through Lasso yet.
Configured provider headers are separate from per-request sender signatures.
Relay-native send methods stay inside the transaction provider set, but routing
them there does not remove an upstream signature-header requirement. Only
`eth_sendRawTransaction` receives post-error hash confirmation; other send methods
return their upstream result without a hash lookup.

The transaction send class includes `eth_sendRawTransaction`,
`eth_sendPrivateRawTransaction`, `eth_sendPrivateTransaction`,
`eth_cancelPrivateTransaction`, `eth_sendBundle`, `eth_cancelBundle`,
`mev_sendBundle`, `eth_sendRawTransactionConditional` and
`eth_sendRawTransactionSync`.
Transaction providers are selected one at a time; fallback and any resend remain
sequential within the original request budget.

## Method effects

Registered reads are replay-safe and use the normal three-dispatch budget.
Learned method refusals exclude an upstream for that method, retaining one last route when all upstreams have refused it. An unlearned refusal consumes a read dispatch.
Registered submissions use the transaction provider set. The engine default is
one dispatch; a transaction policy grants registered submissions up to three.
Unregistered methods carrying signed transaction envelopes also use that set
and execute once. Invalid responses, ambiguous application errors and transport
ambiguity return `-32000` with category `indeterminate_dispatch` for these sends.
Other unregistered methods use one dispatch in the read provider set.
Opt-in metadata exposes `execution_safety` and `classified_by` (`registry`,
`signed_bytes`, `default`). Classification scans unregistered params once.

The submission registry includes raw, synchronous, conditional and private
transactions, bundle sends and cancellations, `eth_callBundle`, `mev_simBundle`
and `trace_rawTransaction`. Simulations carrying signed bytes use the transaction
set to preserve disclosure boundaries. Provider-local signing and filters are
restricted before routing. Unknown methods stop on `-32601`; learned support
steers later requests. Signed-envelope detection accepts typed transactions
(types 1 through 4) and nine-item legacy RLP lists, including bare hex, within
three parameter levels and eight RLP list levels. Metadata reports the four
safety values `replay_safe`, `raw_transaction_broadcast`, `subscription`, `unknown`.

Automatic selection skips learned method refusals when another candidate remains.
The last route remains available for automatic recovery. Explicit provider pins
retain direct dispatch, including to verify recovery of a refused method.
