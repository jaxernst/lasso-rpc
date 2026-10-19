# core-websocket-4

- `core-websocket-4` Failover uses bounded replay and deduplication; exceeding recovery limits closes the affected connection explicitly. **unguarded**.

[Area and shared preconditions](README.md).

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
