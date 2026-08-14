# Routing-kernel diagnostic

This diagnostic measures a narrow, synthetic Layer 1 routing-kernel slice. It is not a load test,
an eRPC comparison, or launch evidence.

The current scenario begins with a prepared request identity and returns a prepared synthetic
success. It includes:

- closed-breaker admission;
- the request owner and its single transport task;
- breaker success reporting;
- canonical terminal-fact construction and policy projection;
- one bounded projection-lane enqueue attempt.

It excludes candidate listing and ranking, request and response parsing, HTTP or WebSocket I/O,
Finch capacity, downstream delivery, and work performed asynchronously by breaker and projection
consumers. The JSON output records these exclusions.

Run it from the repository root:

```sh
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix run --no-compile --no-start bench/routing_kernel/diagnostic.exs
```

Compilation may write progress messages. After compilation succeeds, the `mix run` command writes
exactly one JSON document to standard output. Tunable diagnostic sizes are passed as arguments:

```sh
MIX_ENV=test mix run --no-compile --no-start bench/routing_kernel/diagnostic.exs -- \
  --iterations 1000 --warmup 250 --structural-iterations 250
```

Each measured worker performs its own in-process warmup and verifies that the projection lane has
drained before its measurement begins. Iteration counts are capped at 1,000, below the lane's 2,048
item capacity. Any projection drop in warmup or measurement fails the normal scenario; saturation
belongs in a separate diagnostic.

The counter and timing passes run without call tracing. Counter attribution is synchronous and
limited to checkpoints in the request owner and transport task.
Asynchronous breaker-owner and projection-worker work is excluded. Checkpoints omit the small
transport-task tail after its final report and disclose the accounting message it adds.
No garbage collection is forced inside a measured window.

ERTS does not expose cumulative allocated or reclaimed words for this arbitrary process tree. The
output therefore marks both unavailable instead of deriving them from VM-global counters. It
reports live heap capacity at explicit process checkpoints and attributable minor-GC counts as
separate metrics; neither is labeled as allocation.

Timing samples are collected in their own pass. Each timed success adds one synthetic
transport-start stamp message, and the output discloses that instrumentation. The structural pass
separately traces the warmed request-owner process tree and reports messages, process spawns, and
ETS calls. Raw stable protocol-tag counts are retained. ERTS receive-timeout trace events are
reported separately as scheduling events rather than mailbox messages. Aggregate mailbox receives
still include scheduler- and monitor-order-sensitive `DOWN`, `EXIT`, and reference messages, so
they are diagnostic rather than an exact topology contract.

Layer 2 must use equal raw-HTTP semantics and fixed transport capacity for Lasso and eRPC. Layer 3
must exercise the complete production union. Neither extension may reuse Layer 1 results as an
acceptance verdict.

The process-tree trace should expose one transport-task spawn per success and no intermediate
lifecycle process. Message totals may change with the stamped transport protocol, so compare the
machine-readable message tags rather than requiring a lower aggregate count.
