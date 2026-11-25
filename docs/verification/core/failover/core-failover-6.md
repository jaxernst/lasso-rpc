# core-failover-6

- `core-failover-6` A raw transaction send fails over after a 429 or an unclassified error, and a send an earlier upstream broadcast returns its hash as a success once the hash lookup finds it, whatever wording the next upstream rejects it with.

[Area and shared preconditions](README.md).

Guard: `harness/test/raw_send_failover_test.exs` uses real HTTP RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with two fixture upstreams under `priority`. Send one `eth_sendRawTransaction` per journey and count fixture sends and `eth_getTransactionByHash` lookups between cursors.

- The first upstream answers `-32000 "internal server error"`, an unclassified error after a broadcast. The second answers `-32000 "already known"` and its lookup returns the transaction. The client receives the transaction hash as the result, after one send to each upstream and one lookup on the second.
- The same journey where the second upstream answers `-32010 "submission refused by gateway"`, a rejection that is not on the stop list. The client again receives the hash, with the same sends and lookup.
- The first upstream answers HTTP 429. The second accepts the send. The client receives its result after one send to each upstream and no lookup.

The oracle is the result body and which fixture received each send and lookup. The hash lookup, not the rejection wording, decides success: when the lookup finds nothing, the client receives an error.
