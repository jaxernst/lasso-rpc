# Routing

## Sub-features

- `core-routing-1` Priority sends a read to the first healthy configured provider.
- `core-routing-2` Load-balanced spreads first choices across eligible physical upstreams. **unguarded**.
- `core-routing-3` Fastest prefers qualified recent latency within availability tiers. **unguarded**.
- `core-routing-4` Balanced-fast weights eligible providers by qualified latency; latency-weighted is its alias. **unguarded**.
- `core-routing-5` Explicit provider routes never silently use a different provider. **unguarded**.

## How to get to it (user POV)

Use the configured profile’s RPC URL with a real HTTP or WebSocket client.

## Driving it with the harness

Use two healthy fixture upstreams returning distinct results, with the primary at
priority 1. `$RPC` is `$BASE/rpc/profile/$PROFILE`, `$CHAIN` is `31337`, and
`$PROVIDER` is the primary ID. Before comparing latency strategies, qualify
client evidence in the requested method family with controlled fixture rounds.
For provider exclusion, make the selected upstream unavailable and require no
send to its sibling. Distribution needs a recorded series, not one request.

- **core-routing-1.** Require the provider choice or exclusion named above, with fixture sends and response metadata recorded.

  ```bash
  curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/priority/$CHAIN"
  ```

- **core-routing-2.** Require the provider choice or exclusion named above, with fixture sends and response metadata recorded.

  ```bash
  curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/load-balanced/$CHAIN"
  ```

- **core-routing-3.** Require the provider choice or exclusion named above, with fixture sends and response metadata recorded.

  ```bash
  curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/fastest/$CHAIN"
  ```

- **core-routing-4.** Require the provider choice or exclusion named above, with fixture sends and response metadata recorded.

  ```bash
  curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/balanced-fast/$CHAIN"
  ```

- **core-routing-5.** Require the provider choice or exclusion named above, with fixture sends and response metadata recorded.

  ```bash
  curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/provider/$PROVIDER/$CHAIN"
  ```

## Gotchas

- Availability tiers precede strategy preference. A recovering provider need not win.
- System samples do not qualify client latency in every method family.
- Core profiles select configuration; they do not authenticate clients.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso/core/selection/strategies/priority.ex; lib/lasso/core/selection/strategies/load_balanced.ex; lib/lasso/core/selection/strategies/fastest.ex; lib/lasso/core/selection/strategies/balanced_fast.ex; lib/lasso/core/request/request_pipeline.ex.
