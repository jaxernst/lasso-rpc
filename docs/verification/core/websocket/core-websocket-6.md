# core-websocket-6

- `core-websocket-6` A subscription that fails over to an upstream behind the head it already delivered stays open: Lasso holds the replacement's older heads, resumes once the replacement reaches the delivered head with the same block hash, and closes with `1011` at the recovery deadline when it never gets there. Logs are delivered once per identity (`blockHash`, `logIndex` and `removed`); a log from below the last one delivered can arrive after it. A replacement on another branch at that height is replayed as a reorg, not spliced.

[Area and shared preconditions](README.md).

Guard: `harness/test/subscription_lagging_failover_test.exs` uses the public WebSocket subscription socket and two owned fixture upstreams that serve one chain over HTTP and WebSocket.

## Driving it through surfaces

Configure an owned file profile with both upstreams, `subscribe_new_heads: true` and their `ws_url`s, the first at priority 1. Both serve one deterministic block sequence: `hash(n)` and `parentHash = hash(n - 1)`, one log per block. The second trails the first by `lag` blocks on `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getLogs` and its subscriptions.

Subscribe through `$WS` and push heads 101 to 105 from the first upstream. Then kill it: suspend its listener, close its WebSocket with `1011` and disconnect every later request. Advance the second upstream one block every 250 ms.

- `newHeads` at `lag` 0 to 3: the socket stays open and the client receives every height from 101 to the replacement's last head exactly once, each with the canonical hash and a `parentHash` equal to the hash of the previous head received.
- `logs` at `lag` 2: the socket stays open and the client receives exactly one log per block, with no gap or duplicate.
- The second upstream frozen 2 blocks behind: the client receives nothing more, and the socket closes with `1011` between 29 and 33 seconds after the first upstream dies.
- The second upstream on another branch from height 105, at `lag` 0 and 2: the client receives that branch's block 105 before any child of it, then the branch's later heads, each linked to the previous head received. Both lags deliver the same frames.
- `logs` at `lag` 2: the second upstream announces 105 live and Lasso reads 105 from it over HTTP, and the client receives 105 once.
- `logs` at `lag` 2, with the first upstream announcing only block 105's log: the client receives 104, which the second upstream announces while it catches up, and every log from 105 on, each exactly once in any order.
- `logs` at `lag` 2, with the second upstream on another branch from height 104 and the main chain carrying no log at 104: the client receives main logs 101, 102, 103 and 105, the removal of 105, and the branch's logs from 104 on, each exactly once.
- The same branch, with the first upstream announcing only block 105's log, so no retained log is unchanged: the client receives 105, its removal and the branch's logs from 104 on, each exactly once.

The oracle is the client's recorded frames and close code.
