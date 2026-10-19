# WebSocket lifecycle

## How to get to it (user POV)

Use the configured profile’s RPC URL with a real HTTP or WebSocket client.

## Gotchas

- The HTTP shared routing test does not guard subscription lifecycle.
- `subscribe_new_heads` must be true for client newHeads eligibility.
- The current Fleet scripts unary WebSocket responses; notification/replay
  journeys require a subscription-capable world and remain unguarded.
- Recovery is bounded; arbitrary outages do not promise lossless delivery.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso_web/sockets/rpc_socket.ex; lib/lasso_web/sockets/rpc_socket/item_owner.ex; lib/lasso/core/streaming/upstream_subscription_pool.ex; lib/lasso/core/streaming/replay_window.ex.
