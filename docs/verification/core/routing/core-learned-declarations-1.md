# core-learned-declarations-1

- `core-learned-declarations-1` Republished operator declarations outrank retained learned span, depth and method hints without changing the connection identity. Learned constraints never become hard eligibility policy.

[Area and shared preconditions](README.md).

## Driving it with the harness

Run `harness/test/learned_declarations_test.exs` through the repository harness runner. Two controlled HTTP upstreams establish learned failures on the first route. An ordinary request uses the backup; after publishing a higher span or depth declaration, it uses the primary. A declared method restriction continues to exclude the primary. The learning subject and retained local hint survive publication, health stays 200, and serving owners survive.

The span journey requests 700 blocks after learning from span failures with a stated 500-block limit, then declares a 10,000-block limit. Requests and provider sends are observed through real RPC and the owned fleet ledger. Per-kind environment kill switches retain their baseline behavior.
