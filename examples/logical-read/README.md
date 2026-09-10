# Read one block through discovery and dependent execution

This executable reference uses standard Ethereum JSON-RPC and the public
`@seljs/runtime@1.4.0` with `viem@2.47.6`. It chooses N/H **before** discovery,
then supplies `{blockHash: H, requireCanonical: true}` to storage, code and call
requests. Planned Multicall chunks and runtime-dependent direct calls use the
same transport. Lasso does not infer a logical query from a connection or batch.

```js
const rpc = evidenceRpc({ url: rpcUrl, apiKey, profile: profileSlug, chainId: 1 });
const query = await publishedBlockQuery(rpc);
assertPublishedChoice(query, rpc);
const client = createPublicClient({ transport: custom(query, { retryCount: 0 }) });
// Give this client to discovery and the complete logical operation.
const result = await executeLogicalRead(client);
if (Date.now() >= rpc.deadline) throw new Error("Logical query deadline exceeded");
return { result, block: query.identity, evidence: rpc.evidence() };
```

`evidenceRpc` owns one query's HTTP requests, deadline and evidence. It sends
individual JSON-RPC envelopes, including when the query helper batches
independent calls. On-chain Multicall still performs multiple contract calls in
one `eth_call`. Server retries retain the supplied selector. The reference adds
no client retries; after a failure, discard the incomplete result before a
bounded whole-query retry chooses another block.

## Identity, workers and caches

Metadata's opaque `service_profile_id` identifies the original service profile.
The transport binds it on selection and rejects another service profile or chain
before accepting a later result. `profile_id` records the effective routing profile;
`x-lasso-profile` retains the slug resolved at HTTP admission. When used with Cloud, configured fallback can change the effective routing
profile. Core uses the same file-profile identity for both fields. A changed slug requires
matching service-identity evidence. Do not construct or parse the opaque IDs.

Pass `queryContext(query, rpc)` to a worker. Construct its transport with the same
expected chain, slug, `profileId` (the service identity) and absolute deadline, then call
`resumeQuery(workerRpc, context)`. It uses the retained H without resolving
`latest`. Collect the worker's evidence separately and combine only workers from
that context. Each transport has its own request cap; the application must also
bound worker count and allocate its total work budget.

`cacheKey(context, operationKey)` separates chains, profiles and hashes. Include
the method, all arguments and state overrides in the operation key, for example
`{ method: "ownerOf", args: [7n], overrides: {} }`. Plain objects, arrays, finite
JSON primitives and nested native `bigint` are supported. Object-key order does
not change the key; numbers, bigint and strings remain distinct. Cycles,
undefined values and class instances are rejected. Cached data
at H can avoid repeating an execution; it does **not** establish that H is still
canonical. Reusing a query client for an unrelated logical operation would also
reuse its old H: construct a new client for each new latest operation.

## Evidence and limits

The default deadline is ten seconds, with at most 128 admitted HTTP requests,
four concurrent requests, 4 MiB per response and 64 KiB of retained evidence per
transport. Queued requests share the same deadline and total request budget.
The concurrency slot covers body consumption, not just response headers.
`batch()` cancels siblings on failure and settles them before rejecting; deadline
expiry also aborts fetch and body reads, including injected implementations that
ignore the signal. Cleanup gets at most 100 ms after each request terminates. If
cleanup does not settle, the transport retires: queued and future calls reject,
no new HTTP work starts, and evidence reports `retired: true` and
`cleanupStatus: "unconfirmed"`. Completed evidence counts settled client promises;
it does not claim an uncooperative stream or dispatched server work has stopped.
Scope-rejected responses release their slot only after cleanup or retirement.
No database calls or new RPC methods are introduced by the example.

The caller also checks the deadline before accepting the finished logical result;
the transport cannot interrupt application CPU work between RPCs.

`eth_chainId` is supported and included in evidence even when Lasso answers it
locally; a local response has service identity but no executing provider.

`complete` means each attempted HTTP RPC has a correlated, supported metadata
record within the retention limit, and no requests remain pending. `missing`
and `omitted` make absent/invalid metadata and retention truncation explicit.
HTTP request IDs, service identity and chain are checked; effective routes are
recorded separately. A caller requiring
complete evidence must reject an incomplete report, including every worker's
report. Ordinary RPC results can remain usable when optional metadata is absent.

Coverage refers to Lasso's **per-request summaries**, not a full upstream attempt
transcript or an execution proof. Reported canonicality is provider-observed at
execution; neither a scalar result nor Multicall proves permanent finality.
Unknown metadata versions are incomplete. Raw calldata, API keys and endpoint
URLs are excluded from the retained records and committed fixture trace.

## Reproduce the real-path test

From the repository root, with Anvil installed and a dedicated PostgreSQL test
database provided through `LASSO_TEST_PUBLICATION_DATABASE_URL`:

```sh
npm ci --prefix examples/logical-read --ignore-scripts
node --test examples/published-block-query.test.mjs examples/logical-read/evidence-rpc.test.mjs
LASSO_QUERY_EVIDENCE_PATH=/tmp/logical-read-evidence.json \
  mix test test/integration/global_publication_ingress_test.exs --include integration --include anvil --include publication_db
node examples/logical-read/verify-evidence.mjs /tmp/logical-read-evidence.json
```

The test deploys an upgradeable EIP-1967 proxy, two implementations and a minimal
`aggregate3` fixture. Requests cross Core's actual HTTP endpoint
and route to Anvil. After selection, the proxy upgrades and the chain advances;
discovery must still find the old implementation. The actual SEL runtime executes
three independent chunks, two dependent rounds and a direct lambda call. A Node
worker receives the context and performs another pinned read. The enclosing test
then replaces the branch and verifies the old canonical selector fails and the
next publication reports the changed anchor.

The lockfile identifies the tested published packages; npm records runtime 1.4.0
at source commit `9b94df144b8f587410189d7a18a659ce35edcf00`. This is distinct from
the later public source snapshot examined during initial research. This fixture
does not run evmquery's inaccessible hosted discovery/backend or establish that
its REST API can be replaced with an RPC URL. Customer shadow validation and the
mission's recent-state qualification, multi-region recovery and OSS release gates
remain separate evidence requirements. Production result comparison and broader
archive intelligence are follow-ups outside this logical-read release.

For self-hosted Core, use your file-profile URL and omit `LASSO_API_KEY` unless
your own authentication layer requires it. Global mode requires the optional
[publication journal](../../docs/BLOCK_CONTINUITY_OPERATIONS.md).
