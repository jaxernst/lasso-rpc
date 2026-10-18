# core-routing-4

- `core-routing-4` Balanced-fast weights eligible providers by qualified latency; latency-weighted is its alias. **unguarded**.

[Area and shared preconditions](README.md).

## Driving it with the harness

Use two healthy fixture upstreams returning distinct results, with the primary at
priority 1. `$RPC` is `$BASE/rpc/profile/$PROFILE`, `$CHAIN` is `31337`, and
`$PROVIDER` is the primary ID. Before comparing latency strategies, qualify
client evidence in the requested method family with controlled fixture rounds.
For provider exclusion, make the selected upstream unavailable and require no
send to its sibling. Distribution needs a recorded series, not one request.

- **core-routing-4.** Require the provider choice or exclusion named above, with fixture sends and response metadata recorded.

  ```bash
  curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/balanced-fast/$CHAIN"
  ```
