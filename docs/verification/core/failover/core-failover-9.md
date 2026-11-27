# core-failover-9

- `core-failover-9` After a lagging upstream refuses a block read as `header not found`, failover passes over upstreams whose fresh head is known to stay short of the block and keeps every other upstream in cursor order, in every strategy order. It never promotes an upstream, sends no more than plain failover, and leaves the extra send for a null that follows.

[Area and shared preconditions](README.md).

Guard: `harness/test/missing_block_recovery_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with four fixture upstreams, background observations on and `monitoring.http_heads_interval_ms: 600000`. Three laggards answer `eth_blockNumber` with 9,000 and `eth_getBalance` with `-32000 header not found`; the supporter answers `eth_blockNumber` with 10,002 and `eth_getBalance` with `0x10`. Wait for each head poll. With a short breaker recovery timeout, open the supporter's HTTP breaker with five provider-pinned requests it answers with HTTP 503, and wait for its half-open transition.

- **core-failover-9.** Under each of `priority`, `fastest`, `balanced-fast` and `load-balanced`, read the balance at block 10,001. It must return `0x10` after one send to a laggard and one to the supporter. A second read does the same, the supporter's breaker then reports closed, and the next read is answered by the supporter alone.
- Under `priority`, four upstreams: the first reports 10,002 and answers `header not found`, the second is a closed laggard at 9,000, and the third and fourth report 10,002 and are half-open. The third answers HTTP 503 and the fourth `0x10`. The read must return `0x10` after sends to the first, third and fourth only.
- Under `priority`, the first of three upstreams reports 10,002 and answers `header not found`, the second has no head observation and answers `0x10`, and the third reports 10,002 and is half-open. The read must return `0x10` after sends to the first two only, both when the third answers HTTP 503 and when it holds its answer with a 350 ms method timeout.
- On three fresh upstreams that all report 10,002 under `priority`, read block 10,001 with `eth_getBlockByNumber`. The first answers `header not found`, the second `null` and the third the block. The read must return the block after one send to each.

Before this behaviour every read failed after one send to each laggard and never reached the supporter.
