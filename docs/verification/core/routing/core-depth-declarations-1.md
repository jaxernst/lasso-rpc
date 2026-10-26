# core-depth-declarations-1

- `core-depth-declarations-1` Publishing a higher file-profile historical-depth declaration restores primary routing while retaining its learned historical evidence, healthy RPC and serving owners.

[Area and shared preconditions](README.md).

## Driving it with the harness

Run `scripts/verify-harness harness/test/depth_declarations_test.exs`. Real primary failures establish a historical-depth hint visible through operator Diagnostics, and an ordinary request uses the backup. Replace the owned profile file with `max_block_age: 10000` and the matching `block_age_methods`, then use the supported synchronous profile reload. Diagnostics still exposes the learned hint, but the next ordinary RPC succeeds through the primary. Health stays 200 and owned serving processes survive.
