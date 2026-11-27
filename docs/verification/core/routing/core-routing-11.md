# core-routing-11

- `core-routing-11` A state read of a past block reaches an archive behind full nodes that refuse it as pruned, and once their state cutoff is learned it tries the archive first, while block and log reads stay on the full nodes.

[Area and shared preconditions](README.md).

Guard: `harness/test/historical_retention_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with four fixture upstreams in priority order: three full nodes, then an archive. Pin one `eth_blockNumber` read to each, answering block 10,000, and wait for each head observation. Script the full nodes to answer `eth_getBalance` with geth's `missing trie node ... is not available` and the archive to answer it.

- **core-routing-11.** Read the balance at block 9,700 through the priority URL. It must return the archive's answer after one send to each of the four upstreams: a pruned-state refusal to a past-block state read does not spend the read's dispatch budget of three. Repeat the read until one returns after a single send to the archive. An `eth_call` at block 9,700, which the full nodes would also refuse as pruned, must then return after a single send to the archive, because the learned cutoff belongs to the state class rather than to `eth_getBalance`. Then a block read and a logs read at block 9,700 must each be answered by the first full node with one send.

Before this behaviour the first read failed after three refusals and never reached the archive.
