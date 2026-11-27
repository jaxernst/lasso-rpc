# core-failover-9

- `core-failover-9` After a lagging upstream refuses a block read as `header not found`, every later failover pick in that request tries upstreams whose fresh head stays short of the block after every other remaining upstream, which keep their cursor order, in every strategy order. A lagging upstream stays reachable, so one that has caught up since its last head poll still serves. Failover sends no more than plain failover and leaves the extra send for a null that follows.

[Area and shared preconditions](README.md).

Guard: `harness/test/missing_block_recovery_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with four fixture upstreams, background observations on and `monitoring.http_heads_interval_ms: 600000`. Three laggards answer `eth_blockNumber` with 9,000 and `eth_getBalance` with `-32000 header not found`; the supporter answers `eth_blockNumber` with 10,002 and `eth_getBalance` with `0x10`. Wait for each head poll. With a short breaker recovery timeout, open the supporter's HTTP breaker with five provider-pinned requests it answers with HTTP 503, and wait for its half-open transition.

- **core-failover-9.** Under each of `priority`, `fastest`, `balanced-fast` and `load-balanced`, read the balance at block 10,001. It must return `0x10` after one send to a laggard and one to the supporter. A second read does the same, the supporter's breaker then reports closed, and the next read is answered by the supporter alone.
- Under `priority`, four upstreams: the first reports 10,002 and answers `header not found`, the second is a closed laggard at 9,000, and the third and fourth report 10,002 and are half-open. The third answers HTTP 503 and the fourth `0x10`. The read must return `0x10` after sends to the first, third and fourth only.
- Under `priority`, the first of three upstreams reports 10,002 and answers `header not found`, the second has no head observation and answers `0x10`, and the third reports 10,002 and is half-open. The read must return `0x10` after sends to the first two only, both when the third answers HTTP 503 and when it holds its answer with a 350 ms method timeout.
- On three fresh upstreams that all report 10,002 under `priority`, read block 10,001 with `eth_getBlockByNumber`. The first answers `header not found`, the second `null` and the third the block. The read must return the block after one send to each.
- Under `priority`, four upstreams: the first reports 10,002 and answers `header not found`, the second has no head observation and answers HTTP 503, the third is a closed laggard at 9,000, and the fourth reports 10,002 and is half-open. The read must return `0x10` after sends to the first, second and fourth only.
- Under each of the four strategies, two upstreams report 10,002 and 9,000. The second then catches up to 10,002 before its next head poll, which a direct `eth_blockNumber` to it confirms, and answers `0x42`. The first answers `header not found`. The read must return `0x42` after at most two sends, one of them to the second.

Before this behaviour every read failed after one send to each laggard and never reached the supporter.
