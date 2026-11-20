# core-routing-7

- `core-routing-7` A read that needs the current head prefers a route with fresh evidence of the current head over a route proven behind, in every strategy order. Historical reads, hash lookups by block, tags such as `finalized`, and writes keep strategy order, so a slightly lagging provider still serves the blocks it has. A deferred route stays available when the current route fails.

[Area and shared preconditions](README.md).

Guard: `harness/test/head_freshness_test.exs` uses real HTTP RPC and owned fixture upstreams. Priority puts the lagging upstream first, so any request it loses is a head preference, not a strategy choice.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams in priority order and `selection.max_lag_blocks: 10`, which still loads and has no effect. Pin `eth_blockNumber` to each upstream with `?provider_override=`: the primary answers 9,950 and the alternate 10,000. Those client answers are the head evidence.

Require the alternate to serve `latest` and omitted-selector state reads (`eth_getBalance`, `eth_call`, `eth_estimateGas`, `eth_getTransactionCount`), `eth_blockNumber`, `eth_getTransactionReceipt`, and `eth_getLogs` ranges whose upper bound is `latest`, omitted or above the primary's head. Require the primary to serve numeric reads at 9,000, `eth_call` at `finalized`, `eth_getBlockByHash`, a range ending at 9,000, and `eth_sendRawTransaction`. Then make the alternate return 503 for a `latest` read and require the primary's answer after one send to each upstream.

- **core-routing-7.** Require the upstream named above for each request, counted from fixture sends between cursors.

The oracle is which fixture received each request. This establishes ordering by observed head, not that the preferred upstream's answer is canonical.
