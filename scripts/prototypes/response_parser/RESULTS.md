# Prototype result

## Verdict

Yes, with two explicit qualifications.

OTP 28 `:json.decode/3` can validate the complete JSON grammar in one pass,
capture only the top-level JSON-RPC response fields plus bounded error metadata,
discard the `result` containers, and return the exact original binary for a
same-ID HTTP response. The prototype agreed with all 12 strictness expectations,
and `:erts_debug.same/2` confirmed that the returned raw response is the input
binary rather than a re-encoded copy.

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
