# WebSocket lifecycle

## Sub-features

- `core-websocket-1` WebSocket unary calls preserve JSON-RPC IDs and results. **unguarded**.
- `core-websocket-2` newHeads and logs acknowledge only after a usable upstream exists. **unguarded**.
- `core-websocket-3` Compatible downstream streams can share upstream subscriptions and unsubscribe independently. **unguarded**.
- `core-websocket-4` Failover uses bounded replay and deduplication; exceeding recovery limits closes the affected connection explicitly. **unguarded**.
- `core-websocket-5` New profiles can subscribe through an already-connected upstream after reload. **unguarded**.

## How to get to it (user POV)

Use the configured profile’s RPC URL with a real HTTP or WebSocket client.

## Driving it with the harness

Use a frame-recording WebSocket client and fixture upstreams supporting
subscriptions plus HTTP replay. Set `$WS` to the profile's WebSocket URL using
`ws` or `wss`. For 1, send the unary frame below and match its ID/result.
For 2, hold upstream establishment before releasing it; no downstream success
may precede establishment. For 3, open two clients with equal subscription
params, inspect fixture subscription sends, then unsubscribe one and prove the
other still receives notifications. For 4, disconnect the live upstream while
emitting numbered blocks and logs, release replay and replacement stream, and
assert continuity/deduplication from captured frames; exceed a configured limit
in a separate journey and require closure. For 5, install another YAML profile
sharing that upstream, reload, then subscribe through its URL.

Open each required client, send the frames for its numbered journey and record
all acknowledgments, notifications and close frames:

```bash
websocat "$WS"
```

```json
{"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["0x0000000000000000000000000000000000000001","latest"]}
{"jsonrpc":"2.0","id":2,"method":"eth_subscribe","params":["newHeads"]}
{"jsonrpc":"2.0","id":3,"method":"eth_subscribe","params":["logs",{}]}
{"jsonrpc":"2.0","id":4,"method":"eth_unsubscribe","params":["REPLACE_WITH_RETURNED_SUBSCRIPTION_ID"]}
```

## Gotchas

- The HTTP shared routing test does not guard subscription lifecycle.
- `subscribe_new_heads` must be true for client newHeads eligibility.
- The current Fleet scripts unary WebSocket responses; notification/replay
  journeys require a subscription-capable world and remain unguarded.
- Recovery is bounded; arbitrary outages do not promise lossless delivery.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso_web/sockets/rpc_socket.ex; lib/lasso_web/sockets/rpc_socket/item_owner.ex; lib/lasso/core/streaming/upstream_subscription_pool.ex; lib/lasso/core/streaming/replay_window.ex.
