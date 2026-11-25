# core-failover-6

- `core-failover-6` A raw transaction send fails over after a 429 or an unclassified error, and a send an earlier upstream may have broadcast returns its hash as a success once a hash lookup finds it, whatever wording a later upstream rejects it with.

[Area and shared preconditions](README.md).

Guard: `harness/test/raw_send_failover_test.exs` uses real HTTP and WebSocket RPC and owned fixture upstreams.

## Driving it through surfaces

Configure an owned file profile with one or two fixture upstreams under `priority`. Send one `eth_sendRawTransaction` per journey over HTTP or WebSocket ingress, and count fixture sends and `eth_getTransactionByHash` lookups between cursors. A lookup answers `null` unless the journey scripts it.

- The first upstream answers `-32000 "internal server error"`, an unclassified error after a broadcast. The second answers `-32000 "already known"` and its lookup returns the transaction. The client receives the transaction hash as the result, after one send to each upstream and one lookup on the second.
- The same journey where the second upstream answers `-32010 "submission refused by gateway"`, a rejection that is not on the stop list. The client again receives the hash, with the same sends and lookup.
- The first upstream answers HTTP 429. The second accepts the send. The client receives its result after one send to each upstream and no lookup.
- The first upstream answers HTTP 500 with a plaintext body of `insufficient funds for gas * price + value`, `intrinsic gas too low` or `nonce too high`. The second never receives the send, and the client receives a non-retryable `-32000` error after one lookup on the first.
- The first upstream answers `-32000 "internal server error"` or drops the connection, and only its lookup returns the transaction. The second answers `"nonce too low"` or `"already known"`. The client receives the hash, after one send to each upstream and a lookup on each.
- The same first send, with the first upstream's lookup answering an error, an HTTP 503 or a dropped connection, and the second answering `"nonce too low"`. The client receives `-32000 "Upstream dispatch outcome is indeterminate"`, not the rejection.
- The same first send, with a lookup held past the request deadline, the second upstream's lookup held so no time is left to ask the first, or a lookup returning another transaction's hash. The client receives the indeterminate error by the request's own deadline, the method budget over HTTP and the socket's fixed 10 s over WebSocket, and never the other hash. A single upstream whose lookup returns another hash keeps its rejection.
- The same first send, with both lookups answering `null`. The client receives the second upstream's `"nonce too low"` with the check-the-hash guidance.
- A recognized rejection on the first upstream (`"replacement transaction underpriced"`) then `"nonce too low"` on the second, or a single upstream's rejection, keeps one lookup on the upstream that answered last.

`harness/test/send_policy_test.exs` covers the same rule across send phases: a transaction provider answers `"internal server error"`, the read-provider fallback answers `"nonce too low"`, and only the transaction provider's lookup finds the hash. The client receives the hash with the fallback phase in its send policy metadata.

The oracle is the result body and which fixture received each send and lookup. The hash lookups, not the rejection wording, decide success: a rejection stands only once every send that may have broadcast the transaction reports it absent.
