# core-head-policy-1

- `core-head-policy-1` Local protected head choices preserve the height floor while accepting an equal-height revision only from the establishing upstream against the exact captured floor revision.

[Area and shared preconditions](README.md).

Guard: `harness/test/local_head_reorg_test.exs` uses real HTTP RPC and owned fixture upstreams. Provider order and explicit overrides make selection deterministic.

## Driving it through surfaces

Configure an owned file profile with `head_policy: local` and two fixture upstreams in priority order. Accept `(H, A)`, then have the preferred upstream return `(H, B)` while the fallback still returns `(H, A)`. Require B and a successful `eth_call` pinned to its hash with `requireCanonical: true`. A conflicting fallback cannot restore A during failover; once it agrees with B it may serve it. Both providers below H must fail.

Repeat with every upstream already at B, and reject an alternate upstream's conflicting B before the establishing source reports it. Hold an A response across acceptance of B and require that old response to fail. Finally, let an alternate upstream advance to H+1: it becomes the source allowed to revise that height, while a different upstream cannot do so.

The oracle is the returned block, canonical state response, and attributed RPC failure. This establishes provider continuity and height ordering, not independent proof of chain canonicality or atomicity between separate requests.
