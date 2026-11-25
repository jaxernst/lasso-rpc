# core-failover-8

- `core-failover-8` A head poll answered with a transient HTTP 429 holds its upstream out of routing for the upstream's `Retry-After` alone, not for two poll intervals. Once that cooldown ends, the upstream is polled again on its ordinary cadence. A 429 naming exhausted capacity keeps the upstream out of routing and unpolled for an hour.

[Area and shared preconditions](README.md).

Guard: `harness/test/head_poll_quota_backoff_test.exs` uses real HTTP RPC and owned fixture upstreams whose head polls answer HTTP 429.

## Driving it through surfaces

Configure an owned file profile with three fixture upstreams in priority order (quota, throttle, backup), background observations on and a three-second `http_heads_interval_ms`.

- Answer the quota upstream's next `eth_blockNumber` poll with HTTP 429, `Retry-After: 1` and a message naming exhausted monthly capacity, and note the time. Hold the throttle upstream's next poll, note the time, then answer it with HTTP 429, `Retry-After: 1` and `Too many requests`.
- Balance reads must reach the backup, then the throttle again within 1.5 seconds of its answer, with no throttle poll in between.
- Afterwards the throttle must be polled in the same rounds as the backup, so the two have been polled equally often.
- 31 seconds after the quota upstream's 429, a balance read must still skip it, and it must have received no further poll.

The oracle is which fixture received each read and each poll, and the time from the throttle's answer to the first read it serves again. The full hour is covered by the code, not this journey.
