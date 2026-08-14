# Breaker success epoch prototype

> PROTOTYPE — throwaway evidence. This directory must not be merged into production.

## Question

Can closed-state successes be compressed into a per-breaker success epoch while preserving the
bounded control-ring breaker decisions and materially reducing healthy completion cost? The model
assumes failures remain ordered and bounded, generation and owner epochs remain authoritative, and
half-open leases keep their exact owner-controlled path.

Run the complete self-check and benchmark with one command:

```console
elixir scripts/prototypes/breaker_success_epoch/run.exs
```

Use `-- --interactive` to drive the epoch reducer one event at a time. Use `-- --count=N` to change
the benchmark report count.

## What this prototype covers

- A pure reference reducer for ring and success-epoch control.
- Randomized concurrent completion linearizations with category-specific thresholds.
- Generation replacement, stale receipts, owner restart, strict half-open leases, and ordering.
- A 100,000-success suspended-owner scenario.
- A compact reproduction of ring slot probing, coalesced wakeups, owner scans, and drains.
- Wall time, reductions, owner messages/wakes, and modeled ETS/atomics operations at one and ten
  producers.
- An adversarial schedule that falsifies a naïve atomic-read followed by later ETS publication.

## Result

**GO WITH A LINEARIZATION REQUIREMENT** for a production A/B, not for an immediate hot-path merge.

On an Apple M4, macOS 15.2, Erlang/OTP 28, and Elixir 1.18.4, a representative 100,000-report run
measured:

| Owner | Producers | Ring reports/s | Epoch reports/s | Ring reductions/report | Epoch reductions/report |
| --- | ---: | ---: | ---: | ---: | ---: |
| active | 1 | 1.23M | 7.74M | 119.96 | 49.65 |
| active | 10 | 0.08M | 10.89M | 200.55 | 49.66 |
| suspended | 1 | 0.06M | 7.84M | 269.91 | 49.65 |
| suspended | 10 | 0.05M | 12.14M | 272.85 | 49.66 |

The epoch success path performed one modeled ETS lookup and one atomic increment per report, with
zero owner messages or wakes. The active ring used 9.65 modeled ETS operations/report at one
producer and 40.24 at ten producers in this run; the suspended full ring used 64.96. The ten-producer
active ring saturated during the synthetic burst, so its wall-time ratio is a collapse diagnostic,
not a lossless throughput comparison.

With the owner suspended for 100,000 successes:

- The 64-slot ring accepted 64, dropped 99,936, marked control degraded, and moved admission to the
  exceptional path.
- The epoch accepted all 100,000, dropped none, remained healthy, and kept admission ordinary.

The pure reducers agreed across 250 randomized, ten-producer completion linearizations per run and
the targeted category-threshold, generation, stale-receipt, owner-restart, half-open-lease,
failure-saturation, and success/failure-ordering scenarios.

### Falsification and required production invariants

A naïve implementation is unsafe. If a failure reads epoch 0, stalls before publishing its ring
record, a success advances epoch 1, and the owner applies epoch 1 while handling an earlier wake,
the late epoch-0 failure is applied after the success. The reference order says the success should
clear that failure. Therefore a naked atomic read followed by an unrelated ETS insert is ruled out.

A production experiment must preserve all of these invariants:

1. The success epoch is scoped by breaker ID, transition generation, and owner epoch. A stale receipt
   cannot advance or observe a replacement generation.
2. A routine closed success advances the scoped epoch without a ring slot, global sequence, owner
   wake, owner message, or degraded-control transition.
3. A closed failure remains bounded and ordered. Capturing its observed success epoch and publishing
   the failure must have a documented linearization that survives producer preemption; the
   falsified two-step form is prohibited.
4. Before applying each failure, the owner resets the closed consecutive-failure streak when the
   record observes a newer success epoch. A threshold-crossing failure transition invalidates all
   later receipts from the old generation.
5. A success after the latest failure need not wake the owner. Admission remains correct; any public
   diagnostic failure counter must either expose this lazy reconciliation honestly or derive the
   effective zero from the epoch.
6. Half-open results, composite lease disposition, lease expiry/recovery, failures, and transition
   edges retain the strict owner-controlled path. They are never compressed as ordinary success.
7. Failure-ring saturation remains observable and conservatively degrades admission. Success volume
   alone cannot consume failure capacity or degrade control.
8. Owner restart creates a fresh owner epoch and follows the existing conservative probation path.
   Old atomics references and receipts cannot mutate the replacement owner.
9. Epoch rollover is either practically unreachable with a wide unsigned counter or handled only at
   a generation boundary. No success record retains response or request data.
10. The production A/B must pass breaker semantic/race tests and then improve c64/c128 throughput,
    CPU/success, reductions, messages, ring collisions, and exceptional admissions under the pinned
    launch protocol. This microbenchmark is directional evidence only.
