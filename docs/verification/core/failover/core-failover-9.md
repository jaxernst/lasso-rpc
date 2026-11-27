# core-failover-9

- `core-failover-9` A client that reads a head through Lasso and then reads that block gets the block, even when an upstream that lacks it answers first with null: the head Lasso served counts as that route's report, so the null fails over to it with one extra send. When that route has already failed the read, the null stands.

[Area and shared preconditions](README.md).

Guard: `harness/test/missing_block_recovery_test.exs` uses real HTTP RPC and owned fixture upstreams whose heads advance between reads.

## Driving it through surfaces

Configure an owned file profile on a chain with `block_time_ms: 20`, background observations on, and `probe_interval_ms` and `http_heads_interval_ms` of 600000, so only the opening rounds poll heads. A laggard answers `eth_blockNumber` with 9,950 and null for any block above it. Peers answer with a shared head that starts at 10,000 and answer every block up to it.

- Under `priority` with the laggard first and two peers, wait until head reads avoid the laggard. Then wait until both a read of block 10,000 and a read of the round's target block go first to the laggard, with no head read reaching any fixture in between. That shows the laggard's age credit covers the target. In each of ten rounds, advance the head twice, reading `eth_blockNumber` through Lasso after each step, then read the new head block. The client must receive the block, after one send to the laggard and one to the first peer.
- With the peer first and the laggard second, advance the head twice the same way, then have the peer answer the block read with HTTP 503. The client must receive `null` after one send to each, and the null-recovery decision must be `alternate_unavailable`: the error failover leaves the extra send unspent, and the only route that reported the block was already tried.

The oracle is the result body, which fixture received each block read, and the `[:lasso, :rpc, :null_recovery, :decision]` result. A client that learned the block outside Lasso is outside this promise: its read looks exactly like a poll for the next block.
