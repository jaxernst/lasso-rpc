# core-failover-8

- `core-failover-8` A head poll answered with a transient HTTP 429 holds its upstream out of routing for the upstream's `Retry-After` alone, and the next poll of that upstream waits at least one full interval from the answer, even when a round opens early. A 429 naming exhausted capacity keeps the upstream out of routing and unpolled for an hour.

[Area and shared preconditions](README.md).

Guard: `harness/test/head_poll_quota_backoff_test.exs` uses real HTTP RPC and owned fixture upstreams whose head polls answer HTTP 429.

## Driving it through surfaces

Configure an owned file profile with three fixture upstreams in priority order (quota, throttle, backup), background observations on and a three-second `http_heads_interval_ms`.

- Answer the quota upstream's next `eth_blockNumber` poll with HTTP 429, `Retry-After: 1` and a message naming exhausted monthly capacity, and note the time. Hold the throttle upstream's next poll, note the time, then answer it with HTTP 429, `Retry-After: 1` and `Too many requests`.
- Balance reads must reach the backup, then the throttle again within 1.5 seconds of its answer, with no throttle poll in between.
- Drain the throttle's ledger once a full interval has passed since its answer. It must show no new poll. A new poll must arrive within the two intervals after that.
- 31 seconds after the quota upstream's 429, a balance read must still skip it, and it must have received no further poll.

For the early round, configure a second owned profile with a throttle and a backup upstream, and a six-second interval. Answer the throttle's held poll with the same transient 429. Half an interval later, open a third owned profile on the same chain with a new upstream, so that upstream's worker joins the chain's round and the round opens early. The backup must be polled again within five seconds of the throttle's answer, which shows that the early round ran. A drain taken once a full interval has passed since the answer must still show no new throttle poll.

The oracle is which fixture received each read and each poll, and when: the time from the throttle's answer to the first read it serves again, and each ledger drain against the deadline it follows.
