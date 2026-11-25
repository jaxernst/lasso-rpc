# core-failover-8

- `core-failover-8` A head poll answered with a transient HTTP 429 holds its upstream for the upstream's `Retry-After` alone and polls it again in the next round, while a 429 naming exhausted capacity keeps the upstream out of routing and unpolled for an hour.

[Area and shared preconditions](README.md).

Guard: `harness/test/head_poll_quota_backoff_test.exs` uses real HTTP RPC and owned fixture upstreams whose head polls answer HTTP 429.

## Driving it through surfaces

Configure an owned file profile with three fixture upstreams in priority order (quota, throttle, backup), background observations on and a three-second `http_heads_interval_ms`.

- Answer the quota upstream's next `eth_blockNumber` poll with HTTP 429, `Retry-After: 1` and a message naming exhausted monthly capacity. Hold the throttle upstream's next poll, note the time, then answer it with HTTP 429, `Retry-After: 1` and `Too many requests`.
- Balance reads must reach the backup, then the throttle again within 1.5 seconds of its answer, with no throttle poll in between.
- The throttle's next poll must come in the same round as the backup's, so the two have been polled equally often. A balance read then still skips the quota upstream, which received no poll after its 429.

The oracle is which fixture received each read and each poll, and the time from the throttle's answer to the first read it serves again.
