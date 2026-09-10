# Read at one block

Choose a block before a query starts, reuse its hash for every state read, and
return that identity with the result. This keeps proxy discovery, Multicall,
and dependent calls on the same state as providers and regions change.

Configure `head_policy: global` and its shared journal to also keep later
block choices from returning a lower height. See
[Block continuity](BLOCK_CONTINUITY.md) for the scope and freshness bound.

## 1. Choose a block once

Send this standard JSON-RPC request to your profile endpoint:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getBlockByNumber",
  "params": ["latest", false]
}
```

Keep `result.number` and `result.hash`. A null result or error means the query
cannot start. If you already have a target, select it as follows:

| Starting point | Request |
| --- | --- |
| Latest state | `eth_getBlockByNumber ["latest", false]` |
| A block number, such as 100 | `eth_getBlockByNumber ["0x64", false]` |
| A block hash | Keep that hash. Use `eth_getBlockByHash [hash, false]` if you need its number. |

Resolve a number only once per query. Resolving it separately for each read
can select different hashes across a reorg. An explicit historical target
remains valid even when it is below the profile's latest floor.

## 2. Reuse the hash for every read

Pass this object in the method's existing block parameter:

```js
const at = { blockHash: block.hash, requireCanonical: true };
```

The example below uses your client's standard `request({ method, params })`
operation. Addresses, calldata, and decoding functions belong to your
application. `block` is the block object selected in step 1.

```js
// Resolve the proxy before building the calls that depend on it.
const slot = await request({
  method: "eth_getStorageAt", params: [proxy, implementationSlot, at]
});
const implementation = decodeImplementation(slot);
const code = await request({
  method: "eth_getCode", params: [implementation, at]
});

// Batch independent reads through your existing Multicall encoding.
const firstRound = await request({
  method: "eth_call",
  params: [{ to: multicall, data: encodeIndependentCalls(code) }, at]
});

// Keep the same target for calls that depend on the first round.
const result = await request({
  method: "eth_call",
  params: [{ to: proxy, data: encodeDependentCall(firstRound) }, at]
});
```

Hash selectors are supported for `eth_call`, `eth_getBalance`, `eth_getCode`,
`eth_getStorageAt`, `eth_getTransactionCount`, and `eth_getProof`. Storage and
proof reads take the selector as their third parameter; the others take it
as their second. See [EIP-1898](https://eips.ethereum.org/EIPS/eip-1898).

Apply the selector before **any** discovery starts. Carry it into direct-call
fallbacks, every Multicall chunk, and background workers. Scope cached state
and proxy-resolution results to the chain and block hash. A JSON-RPC batch,
connection, or shared API key cannot supply that query boundary for you.

For a simpler account view, use the same selector for `eth_getBalance` and
`eth_getCode`. For a historical query, use the hash resolved from your chosen
number; the pool must include a provider with the required state history.

## 3. Return results with evidence

Use your usual profile URL with header metadata enabled:

```text
https://your-lasso-host/rpc/profile/<profile-slug>/fastest/1?include_meta=headers
```

Use any authentication required by your deployment. Core does not manage Cloud
API keys. At your HTTP transport, capture the
following for block selection and each state request:

| Response header | Keep it for |
| --- | --- |
| `x-lasso-request-id` | Correlating the routed operation with Lasso; use `x-request-id` when no routing context was created. |
| `x-lasso-meta` | Optional base64url JSON containing routing evidence, including the serving provider when one executed the request. |

The block-selection record's `head_policy` includes the number, hash, age,
scope, serving instance, and observed chain-change information. A retained
block response has no executing upstream provider. State responses record
routing evidence; their scalar results do not independently attest which
block executed. See [routing evidence](OBSERVABILITY.md).

Retain `service_profile_id` to check that responses belong to the same service
profile. `profile_id` records the effective routing profile. Core currently uses the
same file-profile identity for both fields. Both IDs are opaque.

Aggregate the records in your application. For example, **your query API** can
return this shape while each underlying Ethereum response stays standard:

```js
return {
  result,
  blockNumber: block.number, // Ethereum hex quantity
  blockHash: block.hash,
  routing: evidence         // Records collected by your HTTP transport
};
```

Use individual HTTP RPC responses or on-chain Multicall to collect evidence
for every operation. One HTTP batch exposes only one item's routing metadata;
oversized metadata can be omitted. Mark evidence incomplete when any record
is missing, or fail the query if complete evidence is required.

## Handle an interrupted query

| Failure | Action |
| --- | --- |
| No fresh block can be selected | Retry selection within a total deadline, or return an availability error. |
| The chosen state is unavailable | Lasso attempts eligible providers at the same hash within its request budget. If exhausted, fail the query or restart the whole operation. |
| The block is reported noncanonical or conflicting | Discard partial results. Choose a new block and rerun the complete query if your deadline permits. |
| A contract call reverts | Handle the application error. A revert alone is not a reorg or a reason to change blocks. |

A restarted query must not reuse state-derived discovery or cached values
from the abandoned block. Never combine partial results from different hashes.
Applications that need finality should choose a finalized block before reading;
a successful tip query can still be affected by a later reorg.

## Executable example

The optional [logical-read example](../examples/logical-read/README.md) uses
standard JSON-RPC, viem and SEL, with a shared deadline, hash propagation,
bounded response evidence and worker handoff. It is an integration reference,
not a required SDK. Never send credentials with captured evidence.
