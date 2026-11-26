# core-websocket-7

- `core-websocket-7` A WebSocket request runs under its method's own deadline, as the same request over HTTP does.

[Area and shared preconditions](README.md).

Guard: `harness/test/websocket_method_timeout_test.exs` uses real HTTP and WebSocket RPC against an owned fixture upstream that holds requests unanswered.

## Driving it through surfaces

Configure an owned file profile with one fixture upstream and set `$WS` to the
profile's WebSocket URL. Each method's budget is `MethodPolicy.timeout_for/1`,
which `:method_timeouts` in application config overrides.

- **Long budget.** Hold `debug_traceTransaction` (30 s budget) at the upstream.
  Send it over HTTP and over WebSocket, keep both held for 11 s, then answer.
  No WebSocket frame may arrive while the request is held, and both clients
  must receive the upstream's answer.
- **Short budget.** Set the `eth_getBalance` budget to 1.5 s and hold it at the
  upstream. Send it over WebSocket. The error frame must arrive no sooner than
  the budget and well before twice the budget.

```json
{"jsonrpc":"2.0","id":1,"method":"debug_traceTransaction","params":["0xabababababababababababababababababababababababababababababababab"]}
{"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["0x1","latest"]}
```

The oracle is the time from sending each frame to its response frame, against
the method's budget. Subscriptions keep the default budget and are outside this
promise.
