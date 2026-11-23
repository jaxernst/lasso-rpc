# core-failover-6

- `core-failover-6` An HTTP 429 on a client read records capacity, not unreliability: once its `Retry-After` passes, the upstream is ranked as before.

[Area and shared preconditions](README.md).

Guard: `harness/test/rate_limit_recovery_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams. Pin three balance reads to the first upstream, then three more that it answers with HTTP 429 and `Retry-After: 1`.

- **core-failover-6.** Once the hint has passed, `balanced-fast` balance reads must reach the first upstream again.

The oracle is which fixture received each read.
