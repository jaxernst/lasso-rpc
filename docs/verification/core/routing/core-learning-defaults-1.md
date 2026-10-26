# core-learning-defaults-1

- `core-learning-defaults-1` Learned method refusal, historical depth and span constraints defer a repeatedly unsuitable upstream by default; disabling a kind preserves its baseline order.

[Area and shared preconditions](README.md).

## Driving it with the harness

Run `scripts/verify-harness harness/test/learning_defaults_test.exs`. Two controlled HTTP upstreams record each send. Repeated explicit-provider calls establish refusal, span or historical evidence, then an ordinary priority call must use the alternative. The health endpoint stays healthy and routing owners survive.

Repeat with each `LASSO_PROVIDER_KNOWLEDGE_<KIND>_MODE=off` (`METHOD_REFUSAL`, `SPAN_LIMIT`, `HISTORICAL_DEPTH`). That kind must retain the primary-first baseline. This checks the runtime environment switches as well as their default.
