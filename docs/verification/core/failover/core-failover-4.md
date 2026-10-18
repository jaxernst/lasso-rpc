# core-failover-4

- `core-failover-4` Open circuits are excluded and recovery admits suitable providers again. **unguarded**.

[Area and shared preconditions](README.md).

## Driving it with the harness

Use the priority profile and two owned upstreams. For 1, queue an HTTP 503 on
the primary, then a success on the alternate. For 2, return an error after
receiving an unknown method or signed bytes and drain both fixture ledgers;
require exactly one dispatch. For 3, return `-32601` on the primary and a success
on the alternate for a replay-safe read. For 4, drive real primary failures
until the operator circuit event closes the action, then observe backup routing;
after recovery evidence, prove admission through a request. Each action has
unique params and its own acknowledged fleet cursors.

For each numbered journey, send the specific payload (`read.json`,
`unknown.json` or `signed.json`), then record the response and drained sends:

```bash
curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/priority/$CHAIN"
curl -sS -i -H 'content-type: application/json' --data @unknown.json "$RPC/priority/$CHAIN"
curl -sS -i -H 'content-type: application/json' --data @signed.json "$RPC/priority/$CHAIN"
```

The recurring shared guard for **core-routing-1** and **core-failover-1** is:

```bash
scripts/verify-harness harness/test/core_routing_test.exs
```

In the companion repository its runner is `scripts/verify test harness/test/core_routing_test.exs`.
The scenario file is byte-identical; only tenant provisioning and credentials differ.
