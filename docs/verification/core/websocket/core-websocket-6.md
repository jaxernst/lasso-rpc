# core-websocket-6

- `core-websocket-6` A subscription that fails over to an upstream behind the head it already delivered stays open: Lasso holds the replacement's older heads and logs, resumes once the replacement reaches the delivered head with the same block hash, and closes with `1011` at the recovery deadline when it never gets there. A replacement on another branch at that height is replayed as a reorg, not spliced.

[Area and shared preconditions](README.md).

Guard: `harness/test/subscription_lagging_failover_test.exs` uses the public WebSocket subscription socket and two owned fixture upstreams that serve one chain over HTTP and WebSocket.

## Driving it through surfaces

Configure an owned file profile with both upstreams, `subscribe_new_heads: true` and their `ws_url`s, the first at priority 1. Both serve one deterministic block sequence: `hash(n)` and `parentHash = hash(n - 1)`, one log per block. The second trails the first by `lag` blocks on `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getLogs` and its subscriptions.

Subscribe through `$WS` and push heads 101 to 105 from the first upstream. Then kill it: suspend its listener, close its WebSocket with `1011` and disconnect every later request. Advance the second upstream one block every 250 ms.

- `newHeads` at `lag` 0 to 3: the socket stays open and the client receives every height from 101 to the replacement's last head exactly once, each with the canonical hash and a `parentHash` equal to the hash of the previous head received.
- `logs` at `lag` 2: the socket stays open and the client receives exactly one log per block, with no gap or duplicate.
- The second upstream frozen 2 blocks behind: the client receives nothing more, and the socket closes with `1011` between 29 and 33 seconds after the first upstream dies.
- The second upstream on another branch from height 105, at `lag` 0 and 2: the client receives that branch's block 105 before any child of it, then the branch's later heads, each linked to the previous head received. Both lags deliver the same frames.

The oracle is the client's recorded frames and close code.
