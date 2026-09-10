import test from "node:test";
import assert from "node:assert/strict";
import { evidenceRpc } from "./evidence-rpc.mjs";
import { publishedBlockQuery } from "../published-block-query.mjs";
import { queryContext, resumeQuery, cacheKey, assertPublishedChoice } from "./query-context.mjs";

const block = { number: "0x64", hash: `0x${"a".repeat(64)}` };
const scope = { url: "https://rpc.example/rpc/profile/customer/1", profile: "u_customer", chainId: 1 };
function transport(transform = r => r) {
  const calls = [];
  return {
    calls,
    fetch: async (_url, opts) => {
      const call = JSON.parse(opts.body);
      calls.push(call);
      assert.equal(opts.credentials, "omit");
      assert.equal(opts.redirect, "error");
      const metadata = { version: "1.0", chain_id: 1, profile_id: "u_customer_id",
        service_profile_id: "u_customer_id", request_id: `rpc-${call.id}`,
        selected_provider: { id: "節-provider" },
        ...(call.method === "eth_getBlockByNumber" ? { head_policy: {
          policy: "global", scope: "profile_chain_fleet", source: "published_block",
          block_number: block.number, block_hash: block.hash,
        } } : {}),
      };
      const response = { body: { jsonrpc: "2.0", id: call.id,
        result: call.method === "eth_getBlockByNumber" ? block : "0x" },
      headers: { "x-lasso-profile": scope.profile, "x-lasso-request-id": metadata.request_id,
        "x-lasso-meta": Buffer.from(JSON.stringify(metadata)).toString("base64url") } };
      const changed = transform(response, call, metadata);
      return new Response(JSON.stringify(changed.body), { headers: changed.headers });
    },
  };
}

test("one query returns identity and attributed UTF-8 evidence for every HTTP operation", async () => {
  const wire = transport();
  const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
  const query = await publishedBlockQuery(rpc);
  assertPublishedChoice(query, rpc);
  await query.batch([
    { method: "eth_getCode", params: ["contract"] },
    { method: "eth_getStorageAt", params: ["proxy", "0x0"] },
  ]);
  const report = rpc.evidence();
  assert.equal(report.complete, true);
  assert.equal(report.started, 3);
  assert.equal(report.entries[1].metadata.selected_provider.id, "節-provider");
  assert.deepEqual(report.entries.map(e => e.requestId), ["rpc-1", "rpc-2", "rpc-3"]);
  assert.ok(report.entries.slice(1).every(e => e.blockHash === block.hash));
  assert.ok(wire.calls.every(call => !Array.isArray(call)));
});

test("absent, malformed, unsupported and oversized metadata never claim complete coverage", async () => {
  for (const encoded of [undefined, "not-json", Buffer.from('{"version":"2.0"}').toString("base64url"), "a".repeat(4097)]) {
    const wire = transport(r => {
      if (encoded) r.headers["x-lasso-meta"] = encoded;
      else delete r.headers["x-lasso-meta"];
      return r;
    });
    const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
    const query = await publishedBlockQuery(rpc);
    assert.equal(rpc.evidence().complete, false);
    assert.equal(rpc.evidence().missing, 1);
    assert.throws(() => assertPublishedChoice(query, rpc), /lacks matching/);
  }
});

test("unbound profile changes and chain mismatch reject the response before it enters a query", async () => {
  for (const change of [
    r => { r.headers["x-lasso-profile"] = "public"; return r; },
    (r, _call, metadata) => { metadata.chain_id = 2; r.headers["x-lasso-meta"] = Buffer.from(JSON.stringify(metadata)).toString("base64url"); return r; },
  ]) {
    const rpc = evidenceRpc({ ...scope, fetch: transport(change).fetch });
    await assert.rejects(publishedBlockQuery(rpc), /changed within query/);
    assert.equal(rpc.evidence().complete, false);
  }
});

test("unparseable chain metadata cannot claim complete evidence", async () => {
  const wire = transport((response, _call, metadata) => {
    metadata.chain_id = "invalid-chain";
    response.headers["x-lasso-meta"] = Buffer.from(JSON.stringify(metadata)).toString("base64url");
    return response;
  });
  const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
  const query = await publishedBlockQuery(rpc);
  assert.equal(rpc.evidence().complete, false);
  assert.equal(rpc.evidence().entries[0].metadataStatus, "invalid");
  assert.throws(() => assertPublishedChoice(query, rpc), /lacks matching/);
});

test("authorized fallback keeps query identity while recording the effective route", async () => {
  const wire = transport((response, call, metadata) => {
    if (call.method !== "eth_getBlockByNumber") {
      metadata.profile_id = "public";
      response.headers["x-lasso-meta"] = Buffer.from(JSON.stringify(metadata)).toString("base64url");
    }
    return response;
  });
  const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
  const query = await publishedBlockQuery(rpc);
  const context = queryContext(query, rpc);
  await query.request({ method: "eth_getCode", params: ["contract"] });
  const worker = evidenceRpc({ ...scope, profileId: context.profileId, deadline: context.deadline, fetch: wire.fetch });
  await resumeQuery(worker, context).request({ method: "eth_getCode", params: ["contract"] });
  assert.equal(rpc.profileId, "u_customer_id");
  assert.equal(rpc.evidence().entries[1].metadata.profile_id, "public");
  assert.equal(rpc.evidence().entries[1].profile, scope.profile);
  assert.equal(rpc.evidence().complete, true);
  assert.equal(worker.evidence().complete, true);
  assert.ok(wire.calls.slice(1).every(call => call.params[1].blockHash === block.hash));
});

test("a changed or absent service identity cannot authorize a fallback response", async () => {
  for (const serviceId of ["u_another_account", undefined]) {
    const wire = transport((response, call, metadata) => {
      if (call.method !== "eth_getBlockByNumber") {
        response.headers["x-lasso-profile"] = "public";
        metadata.service_profile_id = serviceId;
        response.headers["x-lasso-meta"] = Buffer.from(JSON.stringify(metadata)).toString("base64url");
      }
      return response;
    });
    const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
    const query = await publishedBlockQuery(rpc);
    await assert.rejects(query.request({ method: "eth_getCode", params: ["contract"] }), /changed within query/);
    assert.equal(rpc.evidence().complete, false);
  }
});

test("wrong response identity, canonical errors and oversized bodies do not trigger a new choice", async () => {
  for (const [change, message, extra] of [
    [r => { r.body.id = 42; return r; }, /envelope/, {}],
    [r => { delete r.body.result; r.body.error = { code: -32000, message: "block is not canonical" }; return r; }, /not canonical/, {}],
    [r => r, /byte limit/, { maxResponseBytes: 10 }],
  ]) {
    const wire = transport(change);
    const rpc = evidenceRpc({ ...scope, fetch: wire.fetch, ...extra });
    await assert.rejects(publishedBlockQuery(rpc), message);
    assert.equal(wire.calls.length, 1);
  }
});

test("a worker rejects another account's profile even when the slug and chain match", async () => {
  const rpc = evidenceRpc({ ...scope, profileId: "u_different_account", fetch: transport().fetch });
  await assert.rejects(rpc.request({ method: "eth_getCode", params: ["contract", { blockHash: block.hash }] }), /profile identity changed/);
  assert.equal(rpc.evidence().complete, false);
  assert.equal(rpc.evidence().entries[0].metadataStatus, "scope_mismatch");
});

test("call overrides retain both their contents and the selector's evidence attribution", async () => {
  const wire = transport();
  const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
  const query = await publishedBlockQuery(rpc);
  const overrides = { "0x000000000000000000000000000000000000dead": { balance: "0x10" } };
  await query.request({ method: "eth_call", params: [{}, "latest", overrides] });
  assert.deepEqual(wire.calls[1].params, [{}, query.selector, overrides]);
  assert.equal(rpc.evidence().entries[1].blockHash, block.hash);
});

test("request and evidence bounds have explicit outcomes", async () => {
  const rpc = evidenceRpc({ ...scope, fetch: transport().fetch, maxRequests: 1, maxEvidenceBytes: 20 });
  const query = await publishedBlockQuery(rpc);
  await assert.rejects(query.request({ method: "eth_call", params: [{}] }), /RPC limit/);
  assert.equal(rpc.evidence().omitted, 1);
  assert.equal(rpc.evidence().complete, false);
  assert.equal(rpc.evidence().started, 1);
});

test("deadline cancels in-flight fetch and prohibits subsequent RPCs", async () => {
  let dispatched = 0;
  const rpc = evidenceRpc({ ...scope, deadline: Date.now() + 30, fetch: (_url, { signal }) => {
    dispatched++;
    return new Promise((_resolve, reject) => {
      const keepAlive = setTimeout(() => reject(new Error("abort was not delivered")), 500);
      signal.addEventListener("abort", () => { clearTimeout(keepAlive); reject(signal.reason); }, { once: true });
    });
  } });
  await assert.rejects(publishedBlockQuery(rpc), /timeout/i);
  await assert.rejects(publishedBlockQuery(rpc), /deadline exceeded/);
  assert.equal(dispatched, 1);
  assert.equal(rpc.evidence().completed, 1);
});

test("worker handoff preserves hash and deadline; cache identity separates forks and scopes", async () => {
  const rpc = evidenceRpc({ ...scope, fetch: transport().fetch });
  const query = await publishedBlockQuery(rpc);
  const context = queryContext(query, rpc);
  const workerWire = transport();
  const workerRpc = evidenceRpc({ ...scope, profileId: context.profileId, deadline: context.deadline, fetch: workerWire.fetch });
  const worker = resumeQuery(workerRpc, JSON.parse(JSON.stringify(context)));
  await worker.request({ method: "eth_call", params: [{}] });
  assert.equal(workerWire.calls.length, 1);
  assert.deepEqual(workerWire.calls[0].params[1], query.selector);
  for (const change of [{ chainId: "2" }, { profile: "other" }, { deadline: context.deadline + 1000 }]) {
    assert.throws(() => resumeQuery(workerRpc, { ...context, ...change }), /scope or deadline/);
  }
  const key = cacheKey(context, ["eth_getCode", "contract"]);
  assert.equal(key, cacheKey(queryContext(worker, workerRpc), ["eth_getCode", "contract"]));
  for (const change of [{ hash: `0x${"b".repeat(64)}` }, { chainId: "2" }, { profileId: "other" }]) {
    assert.notEqual(key, cacheKey({ ...context, ...change }, ["eth_getCode", "contract"]));
  }
});

test("caller mutation or ambiguous hash objects cannot change a retained query identity", async () => {
  const wire = transport();
  const rpc = evidenceRpc({ ...scope, fetch: wire.fetch });
  const query = await publishedBlockQuery(rpc);
  for (const selector of [
    { blockHash: block.hash, blockNumber: "0x63" },
    { blockHash: block.hash, requireCanonical: false },
  ]) await assert.rejects(query.request({ method: "eth_call", params: [{}, selector] }), /Conflicting/);
  assert.equal(wire.calls.length, 1);
});

test("one transport bounds active bodies across batches and direct concurrent calls", async () => {
  const wire = transport();
  const firstWave = Promise.withResolvers();
  const releaseWave = Promise.withResolvers();
  let active = 0, peak = 0;
  const rpc = evidenceRpc({ ...scope, fetch: async (url, opts) => {
    const response = await wire.fetch(url, opts);
    if (JSON.parse(opts.body).method === "eth_getBlockByNumber") return response;
    active++;
    peak = Math.max(peak, active);
    if (active === 4) firstWave.resolve();
    return new Response(new ReadableStream({ async start(controller) {
      await releaseWave.promise;
      controller.enqueue(new TextEncoder().encode(await response.text()));
      active--;
      controller.close();
    } }), { headers: response.headers });
  } });
  const query = await publishedBlockQuery(rpc);
  const call = { method: "eth_getCode", params: ["contract"] };
  const batch = query.batch(Array.from({ length: 8 }, () => call));
  const direct = query.request(call);
  await firstWave.promise;
  assert.equal(wire.calls.length, 5);
  assert.equal(rpc.evidence().complete, false);
  releaseWave.resolve();
  await Promise.all([batch, direct]);
  assert.equal(peak, 4);
  assert.equal(wire.calls.length, 10);
  assert.equal(rpc.evidence().complete, true);
});

test("batch failure cancels queued and active siblings and settles their evidence", async () => {
  const wire = transport();
  const firstWave = Promise.withResolvers();
  let active = 0, dispatched = 0, cancelled = 0;
  const rpc = evidenceRpc({ ...scope, fetch: async (url, opts) => {
    const call = JSON.parse(opts.body);
    if (call.method === "eth_getBlockByNumber") return wire.fetch(url, opts);
    dispatched++;
    if (dispatched === 4) firstWave.resolve();
    if (call.params[0] === "failing") {
      await firstWave.promise;
      throw new Error("fixture upstream failure");
    }
    active++;
    try {
      return await new Promise((_resolve, reject) => {
        const abort = () => { cancelled++; reject(opts.signal.reason); };
        if (opts.signal.aborted) abort();
        else opts.signal.addEventListener("abort", abort, { once: true });
      });
    } finally { active--; }
  } });
  const query = await publishedBlockQuery(rpc);
  const calls = Array.from({ length: 12 }, (_, index) => ({
    method: "eth_getCode", params: [index === 0 ? "failing" : "contract"],
  }));
  await assert.rejects(query.batch(calls), /fixture upstream failure/);
  assert.equal(active, 0);
  assert.ok(dispatched < calls.length);
  assert.equal(cancelled, dispatched - 1);
  const report = rpc.evidence();
  assert.equal(report.started, report.completed);
  assert.equal(report.complete, false);
});

test("a batch exceeding its query budget leaves no siblings pending", async () => {
  const rpc = evidenceRpc({ ...scope, maxRequests: 3, fetch: transport().fetch });
  const query = await publishedBlockQuery(rpc);
  await assert.rejects(query.batch(Array.from({ length: 4 }, () => ({
    method: "eth_getCode", params: ["contract"],
  }))), /RPC limit/);
  assert.equal(rpc.evidence().started, 3);
  assert.equal(rpc.evidence().completed, 3);
});

test("scope rejection cancels unread bodies before admitting more direct requests", async () => {
  for (const change of [
    metadata => { metadata.service_profile_id = "other-account"; },
    metadata => { metadata.chain_id = 2; },
  ]) {
    const wire = transport((response, _call, metadata) => {
      change(metadata);
      response.headers["x-lasso-meta"] = Buffer.from(JSON.stringify(metadata)).toString("base64url");
      return response;
    });
    let active = 0, peak = 0, cancelled = 0;
    const rpc = evidenceRpc({ ...scope, profileId: "u_customer_id", fetch: async (url, opts) => {
      const response = await wire.fetch(url, opts);
      return new Response(new ReadableStream({
        start() { active++; peak = Math.max(peak, active); },
        cancel() { active--; cancelled++; },
      }), { headers: response.headers });
    } });
    const results = await Promise.allSettled(Array.from({ length: 12 }, () =>
      rpc.request({ method: "eth_getCode", params: ["contract", { blockHash: block.hash }] })
    ));
    assert.ok(results.every(result => result.status === "rejected" && /changed within query/.test(result.reason.message)));
    assert.ok(peak <= 4);
    assert.equal(active, 0);
    assert.equal(cancelled, 12);
    assert.equal(rpc.evidence().started, rpc.evidence().completed);
  }
});


test("cache operations preserve nested bigint, overrides and type identity", () => {
  const context = { version: 1, chainId: "1", profileId: "customer", hash: block.hash };
  const operation = { method: "ownerOf", args: [7n], overrides: { account: { balance: 10n } } };
  assert.equal(cacheKey(context, operation), cacheKey(context, {
    overrides: { account: { balance: 10n } }, args: [7n], method: "ownerOf",
  }));
  for (const args of [["7"], [7], [["bigint", "7"]], [{ bigint: "7" }]]) {
    assert.notEqual(cacheKey(context, operation), cacheKey(context, { ...operation, args }));
  }
  assert.notEqual(cacheKey(context, operation), cacheKey(context, { ...operation, overrides: {} }));
  for (const invalid of [undefined, NaN, Infinity, new Date(), () => {}]) {
    assert.throws(() => cacheKey(context, { nested: invalid }), /Cache operation/);
  }
  const cyclic = {}; cyclic.self = cyclic;
  assert.throws(() => cacheKey(context, cyclic), /without cycles/);
});

for (const failure of ["scope", "oversized", "stalled body", "stalled fetch"]) {
  test(`uncooperative ${failure} settles owned calls and retires the transport`, { timeout: 2000 }, async () => {
    let dispatched = 0;
    const never = new Promise(() => {});
    const wire = transport((response, _call, metadata) => {
      if (failure === "scope") {
        metadata.chain_id = 2;
        response.headers["x-lasso-meta"] = Buffer.from(JSON.stringify(metadata)).toString("base64url");
      }
      return response;
    });
    const keepAlive = setTimeout(() => {}, 1500);
    const rpc = evidenceRpc({ ...scope, maxConcurrency: 1, maxResponseBytes: 32,
      deadline: Date.now() + 150,
      fetch: async (url, opts) => {
        dispatched++;
        if (failure === "stalled fetch") return never;
        const response = await wire.fetch(url, opts);
        return new Response(new ReadableStream({
          start(controller) {
            if (failure === "oversized") controller.enqueue(new Uint8Array(33));
          },
          cancel() { return never; },
        }), { headers: response.headers });
      },
    });
    try {
      const results = await Promise.allSettled(Array.from({ length: 8 }, () => rpc.request({
        method: "eth_getCode", params: ["contract", { blockHash: block.hash }],
      })));
      assert.ok(results.every(result => result.status === "rejected"));
      assert.equal(dispatched, 1);
      assert.equal(rpc.evidence().started, rpc.evidence().completed);
      assert.equal(rpc.evidence().retired, true);
      assert.equal(rpc.evidence().complete, false);
      assert.ok(rpc.evidence().entries.some(entry => entry.cleanupStatus === "unconfirmed"));
      await assert.rejects(rpc.request({ method: "eth_chainId" }), /retired|deadline/);
      assert.equal(dispatched, 1);
    } finally { clearTimeout(keepAlive); }
  });
}


test("batch rejection remains bounded when a sibling ignores abort and cancellation", { timeout: 2000 }, async () => {
  const wire = transport();
  let dispatched = 0;
  const rpc = evidenceRpc({ ...scope, maxConcurrency: 2, fetch: async (url, opts) => {
    const call = JSON.parse(opts.body);
    const response = await wire.fetch(url, opts);
    if (call.method === "eth_getBlockByNumber") return response;
    dispatched++;
    if (call.params[0] === "fail") throw new Error("fixture failure");
    return new Response(new ReadableStream({ cancel: () => new Promise(() => {}) }), {
      headers: response.headers,
    });
  } });
  const query = await publishedBlockQuery(rpc);
  await assert.rejects(query.batch(Array.from({ length: 8 }, (_, index) => ({
    method: "eth_getCode", params: [index === 0 ? "fail" : "contract"],
  }))), /fixture failure/);
  assert.equal(rpc.evidence().started, rpc.evidence().completed);
  assert.equal(rpc.evidence().retired, true);
  assert.ok(dispatched < 8);
  const count = dispatched;
  await assert.rejects(query.request({ method: "eth_getCode", params: ["contract"] }), /retired/);
  assert.equal(dispatched, count);
});
