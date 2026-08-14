# PROTOTYPE — strict unary response correlation

This throwaway prototype answers one question: can Lasso strictly validate and
correlate a complete JSON-RPC unary response in one pass, return the original
binary unchanged when the upstream ID already matches, and avoid constructing
the potentially huge `result` tree at a cost compatible with the routing-engine
throughput mission?

It compares the current `EnvelopeParser`, an OTP 28 `:json.decode/3` decoder with
discard callbacks, a full Jason decode, and a safe scan-plus-OTP hybrid. The
interactive shell exposes malformed grammar, invalid Unicode, nested and
duplicate IDs, trailing bytes, and raw-binary identity. Its benchmark reports
wall time, process reductions, observed peak heap growth, GC-reclaimed bytes,
and off-heap binary growth for 1, 4, and 16 MiB results.

Run everything with one command:

```sh
mix run --no-start scripts/prototypes/response_parser/run.exs -- --all
```

Run the interactive terminal shell:

```sh
mix run --no-start scripts/prototypes/response_parser/run.exs
```

This directory is not production code. The branch is intended to remain a
primary-source artifact and must not be merged.
