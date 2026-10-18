# Routing

## How to get to it (user POV)

Use the configured profile’s RPC URL with a real HTTP or WebSocket client.

## Gotchas

- Availability tiers precede strategy preference. A recovering provider need not win.
- System samples do not qualify client latency in every method family.
- Core profiles select configuration; they do not authenticate clients.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso/core/selection/strategies/priority.ex; lib/lasso/core/selection/strategies/load_balanced.ex; lib/lasso/core/selection/strategies/fastest.ex; lib/lasso/core/selection/strategies/balanced_fast.ex; lib/lasso/core/request/request_pipeline.ex.
