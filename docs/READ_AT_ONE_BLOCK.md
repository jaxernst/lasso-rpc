# Read at one block

Two RPC calls using `latest` can read different blocks if the chain advances
between calls or their providers have different heads. For a consistent account
view, such as a balance and transaction count from the same block, fetch a block
once and pass its hash to both reads.

This is standard Ethereum JSON-RPC. It works with **Block regression protection
Off**, using your usual Lasso endpoint and authentication. Your providers must
support the requested methods, block-hash selectors and state history.

## 1. Choose a block once

The examples use your client's `request({ method, params })` function. It should
return the JSON-RPC response's `result` and throw on errors. If your client's
convenience methods do not expose block-hash selectors, use its raw JSON-RPC
request method.

```js
const block = await request({
  method: "eth_getBlockByNumber",
  params: ["latest", false],
});

if (!block?.number || !block?.hash) {
  throw new Error("No block is available");
}
```

Keep `block.number` and `block.hash`. A number identifies a height; a hash
identifies the particular block at that height. A chain reorganization can
replace a block with a different block at the same height, so use the hash
when several reads must refer to the same block.

## 2. Reuse the hash for every read

Replace `address` with the account you want to inspect. Pass the same block
selector to both methods. `requireCanonical: true` asks the provider to reject
a block it knows has been removed from the canonical chain:

```js
const address = "0x1234567890123456789012345678901234567890";
const at = { blockHash: block.hash, requireCanonical: true };

const [balance, nonce] = await Promise.all([
  request({ method: "eth_getBalance", params: [address, at] }),
  request({ method: "eth_getTransactionCount", params: [address, at] }),
]);

console.log({
  blockNumber: block.number,
  blockHash: block.hash,
  balance,
  nonce,
});
```

Both reads request the state at `block.hash`, even if a new block arrives between
them. Lasso keeps that hash through routing and retries; it does not silently
replace it with `latest` or a block number. If the requested state cannot be
served, the read fails. Keeping the number and hash with the results helps you
identify the state you read; it does not change the underlying RPC response.

The balance is in wei and the nonce is the account's transaction count at the
chosen block. Both are returned as hexadecimal quantities. This nonce excludes
pending transactions; use the usual `pending` request when you need that
different view.

You can also send these reads in a JSON-RPC batch, with the same selector on
**each item**. A batch alone does not give its items a shared block.

## Other methods and block targets

[EIP-1898](https://eips.ethereum.org/EIPS/eip-1898) defines block-hash selectors
for the following state methods. Your upstream providers must support the
method and selector; support for an ordinary `latest` call is not sufficient.

| Method | Parameters using the selected block |
| --- | --- |
| `eth_getBalance` | `[address, at]` |
| `eth_getTransactionCount` | `[address, at]` |
| `eth_getCode` | `[address, at]` |
| `eth_getStorageAt` | `[address, slot, at]` |
| `eth_call` | `[transaction, at]` |
| `eth_getProof` | `[address, storageKeys, at]` |

For an older or finalized snapshot, change how you choose the block:

| Starting point | How to obtain the block hash |
| --- | --- |
| Latest block | `eth_getBlockByNumber` with `["latest", false]`. |
| Finalized block | `eth_getBlockByNumber` with `["finalized", false]`, where the chain and provider support it. |
| A block number, such as 100 | `eth_getBlockByNumber` with `["0x64", false]`. |
| A known block hash | Reuse it. Call `eth_getBlockByHash` with `[hash, false]` if you also need the number. |

Resolve a number to a hash once before reading, rather than separately for each
call. Historical reads need providers that retain the required state. They can
target an older block even after protection has accepted a newer height.

## Handle errors and reorganizations

`requireCanonical: true` asks the provider to return an error if it knows the
block is no longer in its canonical chain. That is the provider's view at the
time of the request, not a promise that the block can never be reorganized.
Choose a finalized block when your application requires the chain's finality
semantics.

| Failure | What to do |
| --- | --- |
| Block lookup returns null or an error | Do not start the state reads. Retry within your application's deadline or report the failure. |
| A provider cannot serve the hash or state | Lasso can try eligible providers at the same target within its request budget. If exhausted, report the failure or start a new snapshot. |
| The block is reported noncanonical | Discard partial results. If a fresh snapshot is useful, choose a new block and repeat every read. |
| A contract call reverts | Handle the contract error. A revert alone is not evidence of a reorganization. |

If you start again at another block, do not combine old partial results with the
new ones. Hash selectors express the requested state; they do not prove that an
upstream executed it correctly. A provider that silently ignores the selector
can return incorrect data without revealing the mismatch in a scalar result.

## Optional: protect later refreshes

Selecting one block keeps the reads in a refresh together. To also prevent a
later latest-block request from returning a lower height on the same running
Lasso server, enable [Block regression protection](BLOCK_CONTINUITY.md).
With `head_policy: local`, server-switch and restart recovery is best effort;
see the protection guide for the separate Global contract. Protection does not
change explicit historical targets or pin ordinary `latest` state calls
automatically.

## Optional: inspect routing metadata

Add `?include_meta=headers` to see request IDs, providers and retries while
preserving the JSON-RPC body. See [routing metadata](OBSERVABILITY.md#response-metadata).
Neither this recipe nor protection requires metadata collection.

## Contract calls and larger workflows

Use the same `at` selector for `eth_call`, including calls to a Multicall
contract. If one read determines a later call, keep the hash for that later call
too. This also applies to proxy discovery, multiple Multicall chunks and work
sent to another process. Cache state-derived results by chain and block hash.

The optional [logical-read integration example](https://github.com/jaxernst/lasso-rpc/tree/main/examples/logical-read)
demonstrates a larger workflow with viem, SEL, shared deadlines and workers.
