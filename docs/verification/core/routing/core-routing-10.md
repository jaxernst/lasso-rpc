# core-routing-10

- `core-routing-10` Under load-balanced, an upstream that times out on one read in ten loses most of its share of first picks while its peers keep sharing the load, and regains a fair share once it answers again.

[Area and shared preconditions](README.md).

Guard: `harness/test/load_balanced_deferral_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with three fixture upstreams and send `eth_getBalance` reads through its `load-balanced` URL, one at a time. Script one upstream to hold every tenth read it receives until the attempt times out, so that read waits out the timeout before a peer answers it. The other two answer every read.

- **core-routing-10.** After 200 warm-up reads, send 400 more. Every read must be served. The flaky upstream may receive at most 80 of the 400 and at most 8 of them may time out, and each peer must receive at least 100. Then script the flaky upstream to answer every read and send reads in blocks of 90: within 12 blocks, one block must give it at least 20 reads, with no timeouts.

Undeferred, the flaky upstream takes about a third of first picks (about 133 of 400, standard deviation 9.4) and about 13 of those time out, so the bounds fail a regression to the uniform shuffle. Deferral left it at most 61 first picks and 6 timeouts in 20,000 simulated runs, and simulated recovery needed at most 671 reads.
