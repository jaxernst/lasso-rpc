# core-failover-7

- `core-failover-7` A rate-limited identity probe holds its upstream out of routing for the upstream's `Retry-After`, or for 30 seconds without one, and the upstream serves reads again once that cooldown ends.

[Area and shared preconditions](README.md).

Guard: `harness/test/probe_rate_limit_test.exs` uses real HTTP RPC and owned fixture upstreams whose identity probe answers HTTP 429.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams, background observations on and a one-second `probe_interval_ms`. Confirm a `priority` balance read reaches the first upstream.

- Hold the first upstream's next `eth_chainId` probe, note the time, then answer it with HTTP 429, a `-32005` body and `Retry-After: 1`. Balance reads must reach the second upstream, then the first again within 1.5 seconds of the answer.
- On a fresh pair of upstreams, answer the probe with the same 429 and no `Retry-After`. Balance reads must keep reaching the second upstream until 30 seconds after the answer and return to the first within 31.5 seconds.

The oracle is which fixture received each read and the time from the probe's answer to the first read the limited upstream serves again.
