# core-routing-12

- `core-routing-12` A route held back by a learned method refusal is a last resort: it serves a read once every other route has failed and dispatch budget remains, and it never goes ahead of an ordinary route.

[Area and shared preconditions](README.md).

Guard: `harness/test/deferral_budget_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with fixture upstreams in priority order. Train each refusing route with reads pinned to it until its operator knowledge report carries the learned hint.

- **core-routing-12.** With two routes, A learned to refuse `eth_getCode` with `-32601 method not found` and then answers it, while B answers `-32000 upstream could not serve this request`. A read through the priority URL must send to both and return A's answer. With a one-second `eth_getCode` timeout, once B has answered one pinned read with HTTP 429 and then holds every request without answering, a read must still return A's answer after sends to both, because B's attempt, the request's first, leaves time for the saved route. With six routes, A and B learned to refuse (`eth_getCode` with `-32601`, or a 500-block `eth_getLogs` with a 10-block range limit) and keep refusing, C and D answer HTTP 503, and E and F serve. Each of three reads must be served by E after sends to C, D and E only.

Before this behaviour the two-route read returned B's error after one send, with dispatch budget unspent.
