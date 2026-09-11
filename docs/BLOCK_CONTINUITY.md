# Block continuity

Keep each query at one block, and keep later block choices from going backwards.

Set `head_policy: global` for a chain in your file profile after
[configuring the publication journal and serving fleet](BLOCK_CONTINUITY_OPERATIONS.md). Choose a
block once with `eth_getBlockByNumber("latest", false)` and pass its hash to
every state read in your query. Your existing RPC endpoint and standard Ethereum
methods stay the same.

This works for queries that combine proxy resolution, storage and code reads,
Multicall, and dependent `eth_call` rounds. Follow the
[read at one block guide](READ_AT_ONE_BLOCK.md) to integrate it.

## Local choices with peer recovery hints

Set `head_policy: local` to preserve sequential nondecreasing block choices
within each application generation. This mode needs no publication journal.
Overlapping choices may complete out of order; each must meet the local floor
captured when it starts. A lower provider response triggers bounded retry or an
explicit error, and same-height hash conflicts remain errors.

A background worker shares accepted heights with connected peers. A recovered
height prefers providers with fresh observations at that height or higher while
retaining valid lower fallbacks. Opt-in metadata reports `minimum_height`,
`recovery_height` and `recovery_gap_blocks`. Remote hints never raise the mandatory
local minimum or add a database hop to a request.

Worker restart retains learned hints. Application or machine replacement starts
a new generation and recovers asynchronously from surviving peers. Cross-instance
regressions remain possible during cold startup, partitions, message loss or total
memory loss. This is a soft recovery aid, not the global contract below. Hash-pinned
queries retain their ordinary behavior in either mode. See the
[design and qualification boundary](adr/0006-local-head-recovery.md).

## What the global setting guarantees

After a successful block choice returns height **N**, a later block choice
returns **N or higher**, or an error. Returning the same height is allowed.

The guarantee is shared by all callers and enrolled serving instances on the
same profile and chain. Different profiles and chains have independent floors.
It applies when the later request starts after the earlier response completes;
overlapping requests can finish out of height order.

| Request | Behavior with Block continuity enabled |
| --- | --- |
| `eth_blockNumber []` | Returns the retained block number. |
| `eth_getBlockByNumber ["latest", false]` | Returns the retained block, including its number and hash. Use this to start a query. |
| `eth_getBlockByNumber ["latest", true]` | Returns the selected block with full transactions, or an error if unavailable. |
| State reads with an explicit number or hash | Keep the requested target through routing and retries, including targets below the latest floor. |
| State reads using `latest` or an omitted selector | Use ordinary provider routing. Separate reads can observe different blocks. |

The setting does not group requests into a query. Your application carries the
chosen hash through discovery, independent calls, and dependent rounds. A
JSON-RPC batch alone does not select a shared block. `safe`, `finalized`,
`pending`, log ranges, and subscriptions retain their usual semantics.

## One query, one block identity

For state reads, use the standard
[EIP-1898 selector](https://eips.ethereum.org/EIPS/eip-1898):

```js
{ blockHash: block.hash, requireCanonical: true }
```

A number identifies a height; a hash identifies the particular block at that
height. During a reorg, the same number can refer to a different block. If you
start with a number, resolve it to a hash **once**, before the first state read.

Use providers that support the method, hash selector and required state history.
Lasso keeps the hash during failover and returns an error if the read cannot be
completed. Provider capability evidence guides routing; it does not certify that
every backend behind an endpoint can execute the request.
Your query can therefore finish at block 100 while a newer query reads block 101.

## Freshness and provider lag

Lasso retains its selected block even if providers subsequently report lower
heights. It can return 101 again after observing 101, without accepting a later
provider response of 100.

That block expires after the greater of **60 seconds or four configured block
intervals**, measured from its timestamp. Repeating it does not renew its age.
If Lasso cannot provide a fresh block at or above the floor, it returns an error.
This bounds staleness; it does not promise the newest block on the network.
Executing state reads still requires a provider with the selected state.

Block choices normally use the retained block locally. During a publication
change, a choice can wait up to one second within its request deadline before
failing. Reads already pinned to a hash continue without that publication wait.

A provider URL can sit in front of several nodes with different heads. Lasso
keeps the hash on every attempt; a lagging node must serve that state or return
an error. A successful head probe alone does not establish state availability.

One provider is enough to enable the policy. It provides no provider failover or
independent verification; reads fail if that provider cannot serve the chosen state.

## Reorgs and failures

With `requireCanonical: true`, a provider must reject a block it knows is no
longer canonical. Lasso surfaces that conflict; it does not silently replace
the query's hash. Discard the incomplete query and retry the whole operation
within your deadline if a fresh result is still useful.

Detected replacements at the previous selected height appear in routing
metadata as `anchor_hash_changed`. This does not detect every reorg, and missing
state alone is not evidence of one. The height floor never resets downward,
including during a reorg, so recovery can temporarily prevent new block choices.

Canonicality reflects provider observations at the time of a read. A block can
be reorganized later. Lasso does not cryptographically verify arbitrary
`eth_call` results: a provider that silently ignores the selector can return
incorrect data without revealing that in its response. Provider head checks
and routing evidence do not prove execution correctness or finality.

## Return the block and routing evidence

Add `?include_meta=headers` to collect Lasso's request ID and routing metadata
without changing the JSON-RPC result. Return the chosen number, hash, and
collected evidence alongside your application's query result. The
[guide](READ_AT_ONE_BLOCK.md#3-return-results-with-evidence) shows what to retain.

The continuity floor survives service restarts using the shared PostgreSQL journal.
[Coordinated disabling](BLOCK_CONTINUITY_OPERATIONS.md#changing-or-disabling-the-policy) suspends
protection; reenabling it retains the floor but cannot cover reads made while
it was disabled.
