# core-routing-8

- `core-routing-8` With no qualified upstream, fastest tries an untried upstream before one whose evidence is unreliable.

[Area and shared preconditions](README.md).

Guard: `harness/test/fastest_unreliable_test.exs` uses real HTTP RPC and owned fixture upstreams. The failing upstream sorts first by provider id, so a send to the other one is the unreliable ordering, not an identity tie-break.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams. Fail three `eth_getBalance` reads pinned to the upstream that sorts first with `?provider_override=`, each with a 503 (under the circuit's failure threshold), and leave the other upstream untried.

- **core-routing-8.** Require the next unpinned `fastest` state read to make its one send to the untried upstream and return its answer, counted from fixture sends between cursors.

The oracle is which fixture received the request. This establishes the ordering among unqualified upstreams, not how qualified ones are ranked.
