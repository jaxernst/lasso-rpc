# Strategy evidence safe-first verification

This artifact records the bounded correctness slice tracked by
[lasso-rpc#48](https://github.com/jaxernst/lasso-rpc/issues/48) and
[lasso-cloud#492](https://github.com/jaxernst/lasso-cloud/issues/492). It is reconnaissance and
review evidence, not routing-launch acceptance evidence.

## Contract boundary

This change establishes:

- exactly one typed terminal event for each dispatched upstream attempt;
- separate admission, attempt, failover-recovery, and client-outcome telemetry;
- successful strategy analytics measured from attempt-local upstream I/O rather than whole-request
  duration;
- recovered failure attribution to the failed upstream;
- a published-summary reader seam that prevents `fastest` and `latency_weighted` from reading
  BenchmarkStore lifetime averages;
- reliability qualification as a boundary before latency ranking;
- scale-free latency weights and exponential-race weighted permutations;
- the health tier order `closed/live`, `half-open/live`, `closed/limited`,
  `half-open/limited`.

BenchmarkStore remains a compatibility analytics sink. It receives usable success, service failure,
and timeout observations from the new attempt boundary, but performance strategies do not read it.

The rotating dual-bounded window, Wilson qualification, publication cadence, summary storage,
sharding, eviction, hysteresis, and compiled route-plan topology remain deferred to the measured
decisions in lasso-cloud#504 and #501.

## Behavior evidence

| Scenario | Previous strategy evidence | Safe-first result |
| --- | --- | --- |
| Direct success | Final whole-request duration | One usable-success event with exact attempt I/O |
| Recovered failover | Failed upstream omitted; rescue recorded with whole-request duration | Failed upstream gets its failure event; rescue gets only its own success latency |
| Terminal failure | Final provider could receive whole-request failure duration | One service-failure event with attempt-local diagnostic duration |
| Timeout | Ordinary failure latency | One reliability failure with a right-censoring boundary |
| Rate limit/quota | Mixed into failure handling | Capacity-rejection attempt, separate from reliability and successful latency |
| Client/application/policy error | Implicitly omitted | Explicit reliability-neutral attempt |
| Cancellation | No typed strategy-evidence outcome | Neutral censored terminal outcome in the attempt interface |
| Circuit/parameter rejection | Could be described as a failed try | Admission event; never an attempt or zero-latency observation |
| Fastest source | BenchmarkStore lifetime averages | Qualified immutable summaries only; explicit availability degradation otherwise |
| Latency weighted | Absolute floor, success/confidence multipliers, `random * weight` sort | Relative weights and exponential-race permutation |

The focused tests assert the outcome matrix, no rejection-as-attempt, recovered attribution, stale
summary rejection, qualification boundaries, scale invariance, deterministic tier preservation,
and a seeded weighted-order distribution.

## Bounded microbenchmark

Environment:

- base revision: `2296965aecbe0aec9fc7cbe49b0409df50c0a213` (`v0.2.0`);
- candidate: `t3code/strategy-evidence-ranking` working tree;
- Erlang/OTP 28, Elixir 1.18.4;
- developer macOS host, not the pinned Linux acceptance host;
- fixed cardinality: 32 qualified channels for ranking and one evidence key for recording;
- five runs of 2,000 rankings and 20,000 terminal recordings;
- no concurrent benchmark or profiler during the successful measurements.

Raw microseconds per operation:

| Path | Base runs | Candidate runs | Median |
| --- | --- | --- | --- |
| 32-channel latency-weighted ranking | 14.9745, 14.4780, 19.4240, 14.2655, 14.1425 | 33.2450, 32.3630, 32.1805, 32.2595, 32.5220 | 14.4780 → 32.3630 |
| One bounded evidence record | 2.5625, 2.15345, 1.9542, 1.87975, 1.85215 | 2.27105, 1.87805, 1.88945, 1.80025, 1.81695 | 1.9542 → 1.87805 |

The qualified weighted-ranking microbenchmark is about 2.24 times the old incorrect algorithm,
principally because correct exponential-race ordering evaluates a logarithm per candidate. This is
an explicit input to #504/#501: qualified summary ranking should be compiled or refreshed off the
request path rather than optimized by weakening the distribution. Recording shows no material
regression at this scale, but this does not validate mailbox, memory, or high-cardinality bounds.

Reproduce the candidate measurement with:

```sh
LASSO_BENCHMARK_REVISION=$(git rev-parse HEAD) MIX_ENV=test \
  mix run scripts/strategy_evidence_benchmark.exs
```

## Verification commands

```sh
mix format
MIX_ENV=test mix compile --warnings-as-errors
mix test test/lasso/core/routing_evidence test/lasso/core/selection \
  test/lasso/core/request test/unit/strategies --include integration
mix test test/integration/selection_test.exs \
  test/integration/request_pipeline_integration_test.exs \
  test/integration/attempt_evidence_integration_test.exs --include integration
mix test --include integration
```

The first focused group passed 79 tests. The integration group passed 39 tests before the
compatibility analytics assertion was added; the attempt-evidence subset then passed 9 tests. The
repository-wide path passed 1,016 tests with zero failures.
