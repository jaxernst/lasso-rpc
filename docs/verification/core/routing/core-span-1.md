# core-span-1

- `core-span-1` Two distinct span failures establish a hint, a single failure does not, and a later success retracts it without losing the last candidate.

[Area and shared preconditions](README.md).

## Driving it with the harness

Run `scripts/verify-harness harness/test/span_evidence_test.exs`. A real controlled HTTP upstream returns bounded span or volume errors, then a success. Inspect local hints through `Lasso.Diagnostics.provider_knowledge/3`; verify JSON-RPC remains available, `/api/health` returns 200 and routing owners survive.
