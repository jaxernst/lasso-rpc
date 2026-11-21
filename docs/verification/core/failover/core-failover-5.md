# core-failover-5

- `core-failover-5` An upstream that accepts requests and never answers leaves the route, while requests that time out for one profile leave a shared upstream serving its other profiles.

[Area and shared preconditions](README.md).

Guard: `harness/test/hanging_upstream_test.exs` uses real HTTP RPC and owned fixture upstreams that hold requests unanswered.

## Driving it through surfaces

Configure an owned file profile with three fixture upstreams. Hold every `eth_getBalance` and `eth_chainId` request on the first two and answer reads on the third.

- **core-failover-5.** Under `priority`, repeat balance reads until one returns the third upstream's answer without a send to either held upstream, then require four more reads to do the same. Each request timeout asks for a health probe; two probe timeouts open the held upstream's circuit, which takes about two probe budgets.
- Configure a second profile over one held upstream that a first profile shares with an answering one. Three reads on the first profile time out on the held upstream and fail over. A read on the second profile must still reach the held upstream and return its answer once released.

The oracle is which fixture received each request and the answer returned. Recovery after the upstream answers again is outside this promise.
