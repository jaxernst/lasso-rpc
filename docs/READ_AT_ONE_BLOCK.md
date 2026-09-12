# Read at one block

Separate `latest` calls can read different blocks. Fetch one block, then reuse
its hash for every related state read. This standard JSON-RPC pattern works
with **Block regression protection Off**.

Use your client's `request()` helper, which returns `result` and throws on RPC
errors. Set `address` to the account you want to read.

```js
const block = await request({
  method: "eth_getBlockByNumber",
  params: ["latest", false],
});
if (!block?.hash) throw new Error("Block unavailable");

const at = { blockHash: block.hash, requireCanonical: true };
const [balance, nonce] = await Promise.all([
  request({ method: "eth_getBalance", params: [address, at] }),
  request({ method: "eth_getTransactionCount", params: [address, at] }),
]);

console.log({ blockHash: block.hash, balance, nonce });
```

Both values describe the selected block; the nonce excludes pending
transactions. Reuse `at` for contract calls and dependent reads too. In a
JSON-RPC batch, put the selector on **every item**.

## Essential limits

- Providers must support [block-hash selectors](https://eips.ethereum.org/EIPS/eip-1898)
  and retain the requested state. Lasso preserves the hash through retries.
- `requireCanonical: true` asks the provider to reject a block it knows was
  removed from the canonical chain. It does not guarantee finality or prove
  execution correctness.
- If a read fails and you choose a new block, repeat all related reads. Do not
  mix results from different hashes.

For historical reads, resolve a block number to a hash once. Use `"finalized"`
instead of `"latest"` when you need the chain's finality semantics and your
provider supports it.

[Block regression protection](BLOCK_CONTINUITY.md) separately protects successive
latest-block requests. [Routing metadata](OBSERVABILITY.md#response-metadata)
is optional.
