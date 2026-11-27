# core-routing-13

- `core-routing-13` A provider whose application error a peer then served for the same read moves behind that peer for matching reads, while a sampled share still tries it first and its next success retracts the deferral.

[Area and shared preconditions](README.md).

Guard: `harness/test/disproved_error_deferral_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams in priority order. Script the first to answer `eth_getBalance` with `-32000 upstream could not serve this request` and the second to answer it.

- **core-routing-13.** Read a balance at `latest` through the priority URL. It must return the second upstream's answer after one send to each. The first upstream's operator knowledge report must then hold a `disproved_error` hint for `eth_getBalance`, attributed to the second upstream, expiring 30 minutes after it was observed. Of twenty further balance reads, at most six may try the first upstream first, while an `eth_getCode` read still goes to the first upstream alone. When the first upstream serves balances again, a sampled read that reaches it retracts the hint, and the next balance read is served by the first upstream with one send. A profile with the first upstream as its only route still sends to it.

Before this behaviour every balance read tried the erroring upstream first.
