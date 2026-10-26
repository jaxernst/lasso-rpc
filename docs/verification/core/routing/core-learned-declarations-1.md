# core-learned-declarations-1

- `core-learned-declarations-1` Published operator span and method declarations outrank retained learning. Invalid capability lists cannot replace a live profile or prevent healthy routing.

[Area and shared preconditions](README.md).

## Driving it with the harness

In standalone Core, run `scripts/verify-harness harness/test/learned_declarations_test.exs`. Two owned HTTP upstreams establish learned failures on the first route. A 700-block request uses the backup after learning a 500-block boundary; publishing a 10,000-block declaration restores primary routing. A declared method restriction excludes the primary. Retained hints are inspected through the supported `Lasso.Diagnostics.provider_knowledge/3` surface, with requests and provider sends observed through real RPC and the owned fleet ledger. Health remains 200 and serving owners survive.

Set `capabilities.limits.max_block_range` or the `capabilities.unsupported_methods` list in the owned profile YAML, then publish the replacement with `Lasso.Diagnostics.reload_profiles/0`. Malformed capability lists are rejected by file-profile validation; the previous live configuration keeps serving through its healthy higher-priority provider.

Historical-depth declarations use `capabilities.limits.max_block_age` and `capabilities.limits.block_age_methods` in the separate file-profile depth journey.
