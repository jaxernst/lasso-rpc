# Block regression protection

Set `head_policy: local` in an existing chain's file-profile configuration.
Lasso protects successive latest-block responses and shares progress across
connected instances. `off` is the default; Local needs no publication database.

Applies to:

- `eth_blockNumber` with `[]`.
- `eth_getBlockByNumber` with `["latest", false]` or `["latest", true]`.

## What to expect

After a protected response returns block 100, the next request on the same
running Lasso server returns **100 or higher, or an error**, even if the upstream
provider changes. The next request must start after the previous response
finishes; overlapping requests can finish out of order.

All callers using the same profile and chain share this protection. After a
server switch or restart, recovery is **best effort**: a lower height remains
possible.

Provider lag, stale blocks or reorganizations can cause retries or errors.
Retries and connection setup can add latency. Protected blocks must be within
**60 seconds or four configured block intervals**, whichever is greater;
protection does not promise the newest block or finality.

## Reading state

Ordinary `latest` balance and contract calls remain unpinned. Explicit block
targets stay unchanged through retries, including older blocks. To read several
values at one block, follow [Read at one block](READ_AT_ONE_BLOCK.md); that works
with protection Off too.

[Routing metadata](OBSERVABILITY.md#block-protection-metadata) is optional.
For the separate durable `global` contract, see [fleet operations](BLOCK_CONTINUITY_OPERATIONS.md).
Enrolled Global scopes require coordinated disablement before changing modes.
