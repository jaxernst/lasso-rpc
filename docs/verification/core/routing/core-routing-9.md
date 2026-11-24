# core-routing-9

- `core-routing-9` Under fastest, an unproven upstream that only returns errors receives a small, bounded share of first picks, and every read is still served.

[Area and shared preconditions](README.md).

Guard: `harness/test/fastest_unproven_share_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams. Measure one with three successful `eth_getBalance` reads pinned to it with `?provider_override=`. Script the other to answer every `eth_getBalance` with `-32000 "internal server error"`, an unclassified error that records no evidence, so it stays unproven.

- **core-routing-9.** Send 200 unpinned `fastest` state reads. Each must return the measured upstream's answer, and the broken upstream may receive at most 53 of them, counted from fixture sends between cursors.

The unproven upstream weighs 1/8 of the quickest measured one, so it ranks first with probability 1/9 on each read, and Binomial(200, 1/9) exceeds 53 with probability below 4.4e-10. At the quickest's weight the count would be Binomial(200, 1/2), so the bound also fails a regression to that weight.
