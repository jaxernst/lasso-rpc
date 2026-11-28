# core-websocket-6

- `core-websocket-6` A subscription that fails over to an upstream behind the head it already delivered stays open: Lasso holds the replacement's older heads, resumes once the replacement reaches the delivered head with the same block hash, and closes with `1011` at the recovery deadline when it never gets there. Log delivery is not exactly-once: duplicate suppression is bounded, a re-added log is delivered again, and a log from below the last delivered block can arrive after it (see [WebSocket configuration](../../../CONFIGURATION.md#websocket)). A replacement on another branch at that height is replayed as a reorg, not spliced. Heads and logs the replacement announces while replay runs never raise the height replay must reach; a held head past a height gap or a held log above the replayed head makes replay run another round, without spending a recovery attempt (see [WebSocket configuration](../../../CONFIGURATION.md#websocket) for its limits).

[Area and shared preconditions](README.md).

Guard: `harness/test/subscription_lagging_failover_test.exs` uses the public WebSocket subscription socket and two owned fixture upstreams that serve one chain over HTTP and WebSocket.

## Driving it through surfaces

Configure an owned file profile with both upstreams, `subscribe_new_heads: true` and their `ws_url`s, the first at priority 1. Both serve one deterministic block sequence: `hash(n)` and `parentHash = hash(n - 1)`, one log per block. The second trails the first by `lag` blocks on `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getLogs` and its subscriptions.

Subscribe through `$WS` and push heads 101 to 105 from the first upstream. Then kill it: suspend its listener, close its WebSocket with `1011` and disconnect every later request. Advance the second upstream one block every 250 ms.

- `newHeads` at `lag` 0 to 3: the socket stays open and the client receives every height from 101 to the replacement's last head exactly once, each with the canonical hash and a `parentHash` equal to the hash of the previous head received.
- `logs` at `lag` 2: the socket stays open and the client receives exactly one log per block, with no gap or duplicate.
- The second upstream frozen 2 blocks behind: the client receives nothing more, and the socket closes with `1011` between 29 and 33 seconds after the first upstream dies.
- The second upstream on another branch from height 105, at `lag` 0 and 2: the client receives that branch's block 105 before any child of it, then the branch's later heads, each linked to the previous head received. Both lags deliver the same frames.

The remaining cases hold the second upstream's HTTP `eth_blockNumber` requests from just before the first upstream dies, and answer each at a chosen height. Each scripted step continues without a held request once the client has the height it waits for.

- `newHeads` at `lag` 0: the second upstream announces 106 over WebSocket while the backfill's head request is held, and its HTTP head stays at 105. The client receives 106 and then 107, with the socket open.
- `newHeads` from 102: each round the second upstream announces the next even head, 104 to 114, while a head request is held, and HTTP answers at the previous announcement. The client receives 101 to 115 contiguous, with the socket open.
- `logs` from 102, where the second upstream subscribes after block 103's log and holds it back over WebSocket. While replay reaches only 102 it pushes the log at 104, then HTTP answers at 103 and 104. The client receives 101 to 105 once each.
- The same, with block 104 holding two logs and the push being the second: the client receives both of block 104's logs.
- The same, with the first upstream's log at 102 on a fork and the push opening with its delayed removal before the log at 104: the client receives the canonical log at 102 and then 103 to 105.
- The same, with a late push of the log at 102 before the log at 104: the client receives 101 to 105 once each.
- The same, with the only push a delayed removal of a fork log at 104: the client receives 101 to 105.
- `logs` from 102, where block 103 has no matching log. While replay reaches only 102, the second upstream pushes the log at 104 and an unrelated removal at 106. HTTP answers at 104, then the second upstream's WebSocket closes and its reconnects are held, and the chain reorgs from 103 onto a branch whose block 103 has a matching log. HTTP then serves that branch through 106. The client receives the new branch's logs from 103 to 106, then 107 once the reconnect is released.

The oracle is the client's recorded frames and close code.
