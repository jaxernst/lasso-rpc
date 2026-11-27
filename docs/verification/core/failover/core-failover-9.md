# core-failover-9

- `core-failover-9` A read of a block that a lagging upstream refuses as `header not found` spends its one extra send on an upstream whose fresh head reached the block, even when that upstream is half-open behind closed laggards, in every strategy order, and the read keeps failing over if that send fails.

[Area and shared preconditions](README.md).

Guard: `harness/test/missing_block_recovery_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with four fixture upstreams, background observations on and `monitoring.http_heads_interval_ms: 600000`. Three laggards answer `eth_blockNumber` with 9,000 and `eth_getBalance` with `-32000 header not found`; the supporter answers `eth_blockNumber` with 10,002 and `eth_getBalance` with `0x10`. Wait for each head poll, open the supporter's HTTP breaker with a short recovery timeout and wait for its half-open transition.

- **core-failover-9.** Under each of `priority`, `fastest`, `balanced-fast` and `load-balanced`, read the balance at block 10,001. It must return `0x10` after one send to a laggard and one to the supporter. A second read does the same, the supporter's breaker then closes, and the next read is answered by the supporter alone.
- On three fresh upstreams that all report 10,002 under `priority`, the first answers `header not found` and the second HTTP 503. The read must return the third's `0x10` after one send to each.
- Under `priority`, the first of three upstreams reports 10,002 and answers `header not found`, the second has no head observation and answers `0x10`, and the third reports 10,002, is half-open and answers HTTP 503. The read must return `0x10` after one send to each: the third goes ahead of the second, and the second still serves after it fails.

Before this behaviour every read failed after one send to each laggard and never reached the supporter.
