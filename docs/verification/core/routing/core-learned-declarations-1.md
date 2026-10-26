# core-learned-declarations-1

- `core-learned-declarations-1` Published operator span and method declarations outrank retained learning. Invalid capability lists cannot replace a live profile or prevent healthy routing.

[Area and shared preconditions](README.md).

## Driving it with the harness

Run `harness/test/learned_declarations_test.exs` through the repository harness runner. Two owned HTTP upstreams establish learned failures on the first route. A 700-block request uses the backup after learning a 500-block boundary; publishing a 10,000-block declaration restores primary routing. A declared method restriction excludes the primary. Retained hints are observed through the profile knowledge API or operator Diagnostics, with requests and provider sends observed through real RPC and the owned fleet ledger. Health remains 200 and serving owners survive.

Publication uses the profile API's `limits.logs_span` / `limits.methods_blocked` fields or their native file-profile equivalents. Malformed raw capabilities are rejected at the profile API schema or file-profile validation boundary; the previous live configuration keeps serving through its healthy higher-priority provider.

The profile API exposes archival permission but no numeric historical-depth declaration. Standalone file profiles expose `max_block_age` and `block_age_methods`; their depth-declaration journey uses that supported surface separately.
