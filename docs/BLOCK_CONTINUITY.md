# Block regression protection

RPC providers can disagree about the latest block. For example, a block-height
poll might return 100 from one provider, then 99 from a provider that is behind.
Block regression protection prevents that step backwards for sequential
latest-block requests handled by the same running Lasso server.

Use it when polling chain progress or fetching the latest block for your
application. Your Ethereum JSON-RPC requests and responses stay the same.

The following sections describe `local` mode. See
[strict fleet-wide coordination](#optional-strict-fleet-wide-coordination) for
the separate durable `global` contract.

## Enable protection

In an existing chain entry in your file profile, set `head_policy: local`:

```yaml
chains:
  ethereum:
    head_policy: local
    # Keep the chain's existing providers and other settings.
```

This is the behavior labeled **Block regression protection: On** in Lasso Cloud.
`head_policy: off` is the default. Connected RPC Core instances automatically
share progress to help preserve continuity when requests move between them.
There is no additional peer-sharing switch and no publication database is
required for this mode. Configure [clustering](DEPLOYMENT.md#multi-node-clustering) to connect
self-hosted instances.

For example, continue polling with your existing request:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_blockNumber",
  "params": []
}
```

If a protected response returns `"0x64"` (100), the next request on the same
running Lasso server returns 100 or higher, or an error. Returning 100 again is
allowed. You do not need to change your state reads or collect metadata to use
this setting.

## Which requests are protected?

The setting applies to these latest-block requests:

| Method | Parameters | Result |
| --- | --- | --- |
| `eth_blockNumber` | `[]` | A block number. |
| `eth_getBlockByNumber` | `["latest", false]` | A block with transaction hashes. |
| `eth_getBlockByNumber` | `["latest", true]` | A block with full transactions. |

It protects the returned **block height**, not values such as balances or
contract results. For example, `eth_getBalance(address, "latest")` and
`eth_call(transaction, "latest")` still use ordinary provider routing, as do
state reads with an omitted block selector. Separate state reads can observe
different blocks.

Requests for an explicit number or hash keep that target through routing and
retries, even if it is older than the latest protected height. This works with
protection On or Off. Other requests, including `safe`, `finalized`, `pending`,
log ranges and subscriptions, keep their existing semantics.

## What the setting guarantees

Protection applies to requests for the **same profile and chain on the same
running Lasso server**. All API keys and callers using that profile and chain
share the protected height; different profiles and chains are independent.
Here, a Lasso server is the instance routing your request, not an upstream RPC
provider. Changing providers within that instance preserves the protection.

The next request must start after the previous response finishes. Concurrent
requests can finish out of height order. The protected height is retained for
the lifetime of the running application; it survives an internal recovery-worker
restart, but not loss of the application itself. Calls made while protection is
Off are outside the guarantee.

After a Lasso server switch or application restart, recovery is **best effort**:
a lower height remains possible. Servers share progress in the background to
help choose a suitable provider. Those updates do not impose a mandatory minimum
on another server. There is no promised recovery time or block-gap bound, and
disconnected servers or lost history can reduce continuity across the fleet.

## Provider lag, errors and latency

Lasso remembers a minimum accepted height, called the **floor**. Each protected
request checks a provider response against the floor captured when that request
starts. If the response is lower, Lasso can try another eligible provider within
the request's deadline and retry budget. If none succeeds, the request fails
rather than returning a lower height.

Each protected request fetches a provider response. Advancing the floor adds no
synchronous database lookup or wait for peer acknowledgments. Local processing,
provider retries and cold connection setup can still add latency.

A protected block must be no older than the greater of **60 seconds or four
configured block intervals**, measured from its timestamp. Returning the same
block again does not renew its age. This does not promise the newest block on
the network. One provider is enough to enable protection, but it provides no
fallback if that provider cannot serve an acceptable block.

Protection also rejects a conflicting hash at the captured floor height. A
chain reorganization can temporarily prevent new protected responses; the floor
does not reset downwards. Protection does not detect every reorganization,
establish finality or verify the correctness of a provider's execution results.

## Read several values at the same block

If a page needs a balance and transaction count from the same block, specify
that block on both reads. Protection does not pin those calls automatically,
and putting them in a JSON-RPC batch does not select a shared block.

The separate [Read at one block](READ_AT_ONE_BLOCK.md) guide shows this standard
Ethereum JSON-RPC pattern. It works with protection Off; turning protection On
also protects the latest-block requests used to start later refreshes.

## Optional: inspect protection metadata

Add `?include_meta=headers` to inspect routing decisions without changing the
JSON-RPC response body. Protected responses report `head_policy.policy=local`,
the configuration name for protection with automatic fleet sharing.
See [protection metadata](OBSERVABILITY.md#block-protection-metadata) for the
accepted height, server identity and recovery fields. Metadata is diagnostic;
collecting it is not required for protection.

## Optional: strict fleet-wide coordination

`head_policy: global` provides a different contract: sequential protected
latest-block requests share a durable floor across all admitted serving
instances for the same profile and chain. The floor survives application
restarts. Configure its PostgreSQL journal and serving fleet before enabling it;
follow the [operating guide](BLOCK_CONTINUITY_OPERATIONS.md).

Global mode can return the retained block number or block with transaction
hashes without an upstream request. Full-transaction responses still fetch the
published hash from a provider. The same block-age limit applies. Advancement
requires coordination, and requests can wait up to one second within their
deadline during a publication change. Unavailable members or coordination can
prevent advancement or cause errors. Explicit state reads keep their targets
and do not wait for publication.

Global publication can report a replacement at the previous selected height as
`anchor_hash_changed`; this is a provider observation, not complete reorg
detection or finality. Before changing away from an enrolled Global policy,
complete coordinated shutdown and retain the journal and member configuration
as described in the operating guide. A configuration edit alone cannot discard
its durable contract.
