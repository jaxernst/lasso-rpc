# core-routing-12

- `core-routing-12` A route that a learned method refusal or span limit moved behind its peers still serves a read when every peer ahead of it fails, within the read's dispatch budget.

[Area and shared preconditions](README.md).

Guard: `harness/test/deferral_budget_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with four fixture upstreams, A to D, in priority order.

- **core-routing-12.** Pin reads to A while it refuses them, until A's operator knowledge report carries the learned hint: `-32601 method not found` on `eth_getCode` for the method refusal, and `-32600` with a 10-block range limit on a 500-block `eth_getLogs` for the span limit. Then script A to answer and B, C and D to answer `-32000 upstream could not serve this request`. Each of ten reads through the priority URL must return A's answer.

Before this behaviour every read sent to B, C and D, spent its dispatch budget of three, and returned the `-32000` error without reaching A.
