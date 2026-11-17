# core-routing-6

- `core-routing-6` After an explicit application capability refusal, a read with at least two dispatch slots remaining may promote one route from another recognised company inside its availability, knowledge and head-preference band. Unknown hosts retain their positions, and the ordinary next route remains reachable.

[Area and shared preconditions](README.md).

## Driving it with the harness

`test/integration/refusal_vendor_diversity_test.exs` points owned HTTP listeners at three same-company fixture hostnames plus one recognised independent hostname. Priority fixes the ranking. The three siblings refuse; the independent route answers in two dispatches under the default three-slot budget, without calling either remaining sibling.

Controls cover an answering sibling with a two-slot budget, an independent refusal followed by an answering sibling under the default budget, mixed and wholly unknown hosts, sibling fallback, rate limits and temporary service failures, and a cold unused route with a suspended registry beside a ready answering sibling. A two-slot envelope control uses the public request pipeline; HTTP cases read the listener port from endpoint configuration.

Reordering under a finite budget cannot promise that every request which previously succeeded still succeeds. This rule reserves a slot for the ordinary next route instead of spending all remaining slots on promoted routes. Queued routes receive the same rule when their completed band is drained. The preference ends after selection. Only compatible cached descriptors participate in preselection ordering. A cache miss keeps the remaining descriptor order lazy; no channel is opened or awaited to apply the preference. Pending ranking batches keep ordinary order until materialised; the preference does not force a search through unresolved batches.

- **core-routing-6.** Require the independent route result and exactly two upstream sends, with no sibling send; require the answering sibling in both budget controls.

Run with `mix test test/integration/refusal_vendor_diversity_test.exs --include integration`.
