# Prototype result

## Verdict

**GO behind the existing internal response-validation seam, with one required
error-path correction.** This is a parser-adoption recommendation, not a
Wayfinder launch-performance result.

OTP 27+ `:json.decode/3` can validate the complete JSON grammar in one pass,
capture only the top-level JSON-RPC response fields plus bounded error metadata,
discard the `result` containers, and return the exact original binary for a
same-ID HTTP response. The prototype agreed with all 12 strictness expectations,
and `:erts_debug.same/2` confirmed that the returned raw response is the input
binary rather than a re-encoded copy.

The provisionally weighted EVM corpus did **not** reverse the scalar-string
result. OTP was faster than Jason in every measured receipt, block, log, trace,
and successful-result cell. A shape detector is not justified by this evidence;
its detection pass would add complexity and work without selecting a measured
winner. Keep the seam because a future native or streaming implementation must
remain substitutable.

The active transport candidate performs a second parse for JSON-RPC errors.
That path must instead construct the bounded error from facts already captured
by the OTP pass. A 100 KiB error took 3.44 ms and caused 7.8 MiB of GC-reclaimed
allocation pressure in the transport-equivalent path, versus 0.06 ms and 3.6
KiB for the one-pass OTP result. The error path is only 5% of the provisional
mix, so it did not reverse the aggregate, but the duplicate parse is unnecessary
and conflicts with the bounded-error-fact direction.

The qualifications are:

1. Full validation is necessarily linear in response bytes and scalar count.
   It is not the current scanner's apparent constant-time operation. The
   current scanner achieved about 0.01 ms by inspecting at most 2,000 bytes,
   but agreed with only 4 of 12 strictness probes and accepted malformed JSON,
   invalid UTF-8, nested-only IDs, duplicate IDs, trailing bytes, and ambiguous
   result/error responses.
2. OTP decodes a string before its discard callback runs. A large unescaped
   result string remains copy-free, but any escape in a large result string
   produces a transient decoded binary. If “zero-copy” means no transient
   result-payload copy for every valid JSON input, OTP's standard parser cannot
   provide that guarantee. The guarantee should either become “no retained
   decoded result/tree, and copy-free on the ordinary unescaped path,” or Lasso
   must own a custom raw-byte JSON validator.

## Realistic weighted-corpus round

The corpus is deterministic synthetic EVM JSON, not captured production
traffic. Its provisional request-frequency model is:

| Shape | Weight | Size distribution within shape |
|---|---:|---|
| Large hex result | 35% | 50% 1 KiB, 35% 100 KiB, 12% 1 MiB, 3% 10 MiB |
| Receipt object | 20% | 85% about 1 KiB, 15% 100 KiB |
| Block object | 15% | 10% about 1 KiB, 60% 100 KiB, 25% 1 MiB, 5% 10 MiB |
| Log array | 15% | 40% about 1 KiB, 35% 100 KiB, 20% 1 MiB, 5% 10 MiB |
| Trace array | 10% | 10% about 1 KiB, 45% 100 KiB, 35% 1 MiB, 10% 10 MiB |
| Error object | 5% | 95% 1 KiB, 5% 100 KiB |

The weights deliberately retain a large-response tail. Replace them with
observed method/size telemetry before using the modeled mean as a product
forecast.

### c1 result

Apple M4, OTP 28.0.1, Elixir 1.18.4; medians of five interleaved
isolated-process runs:

| Parser | Weighted wall/response | Reductions/response | Pre-GC heap peak proxy | GC-reclaimed pressure | Post-GC retention |
|---|---:|---:|---:|---:|---:|
| OTP discard | 0.80 ms | 219,921 | 9.4 KiB | 602.9 KiB | 0 B |
| Transport-equivalent | 0.82 ms | 220,588 | 7.6 KiB | 626.9 KiB | 0 B |
| Jason full decode then discard | 2.05 ms | 605,594 | 934.7 KiB | 1.3 MiB | 0 B |

Representative large cells:

| Shape | Size | OTP discard | Transport-equivalent | Jason |
|---|---:|---:|---:|---:|
| Large hex | 1 MiB | 0.56 ms | 0.57 ms | 1.38 ms |
| Large hex | 10 MiB | 5.67 ms | 5.66 ms | 13.43 ms |
| Block objects | 1 MiB | 1.77 ms | 1.79 ms | 5.32 ms |
| Block objects | 10 MiB | 18.21 ms | 18.68 ms | 55.45 ms |
| Log objects | 1 MiB | 1.53 ms | 1.51 ms | 3.46 ms |
| Log objects | 10 MiB | 16.78 ms | 16.69 ms | 39.10 ms |
| Trace objects | 1 MiB | 2.17 ms | 2.19 ms | 4.44 ms |
| Trace objects | 10 MiB | 22.21 ms | 22.34 ms | 57.49 ms |

The transport-equivalent builds the current success response struct around the
same parser and reproduces its second error parse. Its successful-response
overhead is noise-level, which supports keeping parser choice behind that seam.

### c64 bounded diagnostic

Each of five interleaved trials prestarted 64 workers with distinct raw binaries
sampled from the weighted distribution. It is a synchronized mixed-response
burst diagnostic, not a fixed-resource launch benchmark. Input response buffers
are excluded from the parser memory deltas.

| Parser | Responses/s | Payload MiB/s | Batch wall | p50 parse | p95 parse | Reductions/response | Aggregate pre-GC heap peak | Post-GC retention |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| OTP discard | 3,242 | 1,952 | 19.74 ms | 0.18 ms | 4.28 ms | 246,915 | 601.8 KiB | 0 B |
| Transport-equivalent | 3,301 | 2,048 | 19.39 ms | 0.14 ms | 4.34 ms | 247,060 | 487.2 KiB | 0 B |
| Jason | 934 | 566 | 68.54 ms | 0.51 ms | 11.75 ms | 572,640 | 63.1 MiB | 0 B |

The small OTP/transport-equivalent ordering difference is benchmark noise; they
share the same successful-response parser. The important result is that the
object-rich weighted mix did not expose the reversal predicted by the earlier
prototype. The optimized callbacks avoid constructing nested containers and
return ordinary small integers as immediate BEAM terms.

### OTP 27 compatibility

The production-image runtime was tested directly:

```sh
docker run --rm \
  -v "$PWD/scripts/prototypes/response_parser:/prototype:ro" \
  hexpm/elixir:1.17.3-erlang-27.3.4.14-debian-bullseye-20260713 \
  elixir -r /prototype/response_parser.ex -r /prototype/corpus.ex -e \
  'entries = LassoPrototype.ResponseCorpus.entries(); Enum.each(entries, fn e -> {:ok, p} = LassoPrototype.ResponseParser.validate(e.bytes, 7); true = :erts_debug.same(e.bytes, p.raw_bytes) end); IO.inspect({System.otp_release(), length(entries)})'
```

Result: OTP `27`, all 20 corpus entries strictly accepted, and raw identity
preserved. A separate malformed trailing-data probe returned
`{:error, :trailing_data}`.

## Correctness probes

The one-pass OTP parser and the scan-plus-OTP hybrid matched all 12 expected
accept/reject outcomes. Jason matched 11: its map construction collapses a
duplicate top-level ID. The current scanner matched 4.

The probe set covered:

- malformed result grammar;
- invalid UTF-8;
- a nested ID before a valid top-level ID;
- a nested ID with no top-level ID;
- duplicate top-level IDs;
- trailing bytes;
- simultaneous result and error fields;
- bounded error-object structure;
- escaped top-level keys; and
- same-ID raw-binary identity.

## Performance evidence

Environment: Apple M4, 16 GiB RAM, Erlang/OTP 28.0.1, Elixir 1.18.4. Values are
medians of five isolated-process runs. `heap delta` is observed heap-capacity
growth. `reclaimed` is GC-reclaimed memory and is an allocation-pressure proxy,
not a byte-exact allocation counter. Binary vheap values are upper bounds
because the GC trace can count one shared binary from young and old heaps.

| Result shape | Size | Parser | Wall | Reductions | Heap delta | Reclaimed |
|---|---:|---|---:|---:|---:|---:|
| plain string | 1 MiB | OTP discard | 0.58 ms | 131,252 | 3.1 KiB | 2.6 KiB |
| plain string | 1 MiB | Jason | 1.38 ms | 1,048,634 | 160 B | 1.1 KiB |
| plain string | 4 MiB | OTP discard | 2.31 ms | 524,468 | 3.1 KiB | 2.6 KiB |
| plain string | 4 MiB | Jason | 5.47 ms | 4,194,362 | 160 B | 1.1 KiB |
| plain string | 16 MiB | OTP discard | 9.21 ms | 2,097,332 | 3.1 KiB | 2.6 KiB |
| plain string | 16 MiB | Jason | 19.46 ms | 16,777,274 | 160 B | 1.1 KiB |
| compact integer array | 1 MiB | OTP discard | 5.92 ms | 5,242,882 | 3.1 KiB | 2.7 KiB |
| compact integer array | 1 MiB | Jason | 15.14 ms | 1,642,191 | 17.2 MiB | 32 MiB |
| compact integer array | 4 MiB | OTP discard | 22.89 ms | 20,971,522 | 3.1 KiB | 2.7 KiB |
| compact integer array | 4 MiB | Jason | 114.43 ms | 6,729,993 | 124.7 MiB | 128 MiB |
| compact integer array | 16 MiB | OTP discard | 94.14 ms | 83,886,082 | 3.1 KiB | 2.7 KiB |
| compact integer array | 16 MiB | Jason | 509.15 ms | 27,087,286 | 362.4 MiB | 512 MiB |

At 16 MiB, OTP validated the plain-string response at about 1.7 GiB/s and the
pathological compact integer array at about 170 MiB/s. It was approximately
2.1 times faster than Jason for the string and 5.4 times faster for the compact
array, while avoiding Jason's result-tree heap growth.

The escaped-string run had almost the same wall time as the plain string, but
its binary-vheap upper bound grew by 2, 8, and 32 MiB for 1, 4, and 16 MiB
inputs. This confirms a full transient decoded-string copy. The upper bound can
double-count the same binary across generations, so it is evidence of the copy,
not an exact peak-byte claim.

The scan-plus-OTP hybrid had the same reductions and effectively the same wall
time as OTP alone after numeric discard callbacks were made allocation-free.
It adds no useful production property.

## Recommended production design

Use the pure OTP discard design as the initial HTTP response validator:

- require exactly one top-level `jsonrpc`, `id`, and `result` or `error`;
- reject duplicate or nested-only correlation IDs, trailing bytes, malformed
  grammar, invalid Unicode, and malformed error objects;
- retain only the response kind, normalized ID, and bounded error metadata;
- return the original input binary when the ID already matches; and
- keep the existing fast scanner out of authoritative validation.

Before production adoption, make two policy decisions explicit:

- Raise the documented runtime floor from OTP 26 to OTP 27 or retain a separate
  compatibility path, because the standard `:json` module is not available on
  OTP 26. CI already uses OTP 28 and the production Docker image uses OTP 27.
- Define zero-copy as no re-encoding and no retained decoded result tree, with a
  documented escaped-string transient-copy exception. If that exception is not
  acceptable under concurrent multi-megabyte responses, the invariant requiring
  full JSON validation must be reconsidered or replaced by a separately audited
  raw-byte validator. Hiding that cost behind the current prefix scanner would
  make correlation unsafe.

The next benchmark gate should run the validator inside the real transport task
under concurrent mixed response shapes. The standalone result is strong enough
to choose the parser shape, but it does not establish end-to-end router
throughput or comparison with eRPC.
