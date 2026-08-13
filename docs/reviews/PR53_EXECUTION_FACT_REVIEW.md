# PR 53 execution-fact review record

This record captures the specialist review of the version-one execution-fact foundation and the disposition of each merge-blocking finding.

## Review scope

- Tagged admission, attempt, request, and late-observation facts
- Reducer ordering, certainty, bounded memory, and materialization
- Canonical projection policy
- Portable codec and its 4 KiB ceiling
- Execution-plan, admission-lease, and route-generation contracts
- Dead-code, unnecessary payload retention, and premature runtime wiring

## Findings and dispositions

| Severity | Finding | Disposition |
| --- | --- | --- |
| High | Deadline materialization used an absolute monotonic deadline as a portable duration. | Fixed. Reducers capture `started_us` and calculate `deadline_us - started_us`; a realistic negative monotonic origin is covered by regression test. |
| High | Application responses lacked a complete normalized classification contract. | Fixed. Application errors require a signed 32-bit code and a category from `deterministic`, `quota`, `capability`, or `provider_failure`; optional `retry_after_ms` is bounded and encoded. The projector has an exhaustive category-by-safety matrix. |
| Medium | Malformed version objects could omit `minor` or use a non-integer value. | Fixed. Both `major` and `minor` must be non-negative integers; unknown fields remain forward-compatible. |
| High | Reducer state could retain payload-bearing observations or lose terminal metadata. | Fixed. Observation normalization is closed and bounded, and terminal states materialize directly into tagged attempt facts. |
| High | Arrival order and observation saturation could change authoritative terminal truth. | Fixed. Logical timestamps drive recomputation and a bounded per-kind summary cannot suppress decisive evidence. |
| High | Replay-safe attempt deadlines were incorrectly terminal rather than fallback-eligible. | Fixed. Attempt deadline projection follows safety and dispatch certainty; request deadline remains terminal. |
| High | Execution-plan fragments and count/certainty combinations admitted impossible states. | Fixed. Typed fragments are revalidated, strategies match the runtime registry, workload class is required, and count/certainty invariants are enforced. |
| Medium | Late-observation discriminator coverage drifted from reducer output. | Fixed. All reducer late kinds are represented by the fact and codec contracts. |

## Verification contract

- `mix compile --warnings-as-errors`
- `mix format --check-formatted`
- `mix test`
- `mix test --include integration`
- Dialyzer, Credo, Docker boot, unit, and hermetic integration jobs in hosted CI

The review deliberately found no request-pipeline or Cloud wiring in this slice. Those consumers remain assigned to later changes in the accepted implementation train.
