# Core verification

The map describes the standalone runtime at source revision
`0538eecf8e422635560350ca5a2c1bd531678a30`, plus the retirement completion
introduced alongside these entries. It makes no release inclusion claim.

- [Routing](routing.md)
- [Failover](failover.md)
- [Configuration publication](config.md)
- [WebSocket lifecycle](websocket.md)

## Baseline and proof

Use a disposable instance with its own profiles directory, endpoint port and
controlled upstreams. Set `$BASE` to its HTTP origin, `$PROFILE` to its YAML slug,
`$RPC` to `$BASE/rpc/profile/$PROFILE`, and `$CHAIN` to its numeric chain ID.
`read.json` is a JSON-RPC eth_getBalance request with a unique ID and address.
Unknown-method and signed-transaction journeys supply their own valid envelopes.
The operator reload command requires a built release and access to its local node.
The WebSocket client must record every received frame through closure.
Missing fixtures or credentials fail the precondition; they never weaken the oracle.

Record each feature ID, source revision, exact command, exit status, response and
fixture sends. Observe surfaces: sockets, operator completion telemetry and the
upstream's acknowledged ledger. No private runtime state establishes coverage.
Attach completion listeners before the action. Quiesce clients before retirement,
retire before stopping upstreams, and keep all evidence scoped to the addressed node.

A literal ExUnit feature tag is a recurring guard only for the promise its test
asserts. **unguarded** is an explicit coverage gap. The first shared HTTP scenario
guards priority selection and replay-safe failover; it does not guard WebSocket
lifecycle or configuration mutation. `node scripts/feature-map.mjs` detects stale
markers, unknown tags and missing guards without booting the application.

## Running the shared scenario

In the standalone repository:

```bash
mix deps.get
scripts/verify-harness harness/test/core_routing_test.exs
```

The runner creates the VM's own profiles directory, copies empty baseline
profiles and boots real clients in a separate test root. `Tenant.isolate!`,
`open!`, `credentials` and `close!` form the adapter contract. Core writes YAML,
reloads through `Lasso.Diagnostics.reload_profiles/0`, checks readiness and
proves the credentials route. Removal is followed by
`Lasso.Diagnostics.retire_tenant/1`; completion names profile, node, generation,
operation and outcome. A failed reload or still-present profile produces no
retirement event. Still-referenced instances survive reconciliation.

The identical scenario file runs in the companion application through its own
provisioning adapter. Test files, support and this map are promoted with the
behavior they cover. CI must run the standalone runner without retries.
