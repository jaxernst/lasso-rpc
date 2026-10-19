# Failover

## How to get to it (user POV)

Use the configured profile’s RPC URL with a real HTTP or WebSocket client.

## Gotchas

- Core does not replay signed transactions after dispatch. Clients reconcile hashes.
- A missing response can mean a transaction was accepted.
- No-send evidence ends at a correlated closing marker and fleet drain.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso/core/request/execution_envelope.ex; lib/lasso/core/request/execution_projector.ex; lib/lasso/core/request/request_pipeline.ex.
