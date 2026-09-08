# RPC Core method support

This page describes the self-hosted **v0.3.6** runtime. Lasso Cloud has a separate
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

## Signed transaction submission

`eth_sendRawTransaction` receives one upstream dispatch. Lasso does not retry or
fan out after dispatch. A lost response may mean the upstream accepted the
transaction. Clients remain responsible for signing, nonce management,
replacement, transaction-hash reconciliation, receipts, and finality.

## Node-local methods

The transport policy globally disallows `eth_sendTransaction`, `eth_accounts`,
`eth_sign`, `eth_signTransaction`, and `personal_sign`. Provider capability
policy can reject additional methods, including the `local_only` category.
Do not treat a profile as an authentication or authorization boundary.

## Stateful filters and extensions

RPC Core v0.3.6 can forward provider-local filter methods when capability policy
permits them. They receive one dispatch per request and have **no cross-request
affinity guarantee**. A filter ID created on one upstream may be invalid on a
later selected upstream. Prefer `eth_getLogs` or supported WebSocket subscriptions;
Core does not advertise a reliable multi-provider filter lifecycle.

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

In Core v0.3.6, `subscribe_new_heads` controls automatic block monitoring **and**
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
