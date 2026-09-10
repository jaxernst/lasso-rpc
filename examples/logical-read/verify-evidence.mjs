import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const evidence = JSON.parse(await readFile(process.argv[2], "utf8"));
const { context, trace, reorg } = evidence;
assert.equal(trace.length, 12);
assert.equal(trace[0].method, "eth_getBlockByNumber");
assert.equal(trace.filter(call => call.method === "eth_chainId").length, 1);
for (const call of trace.slice(1).filter(call => call.method !== "eth_chainId")) {
  assert.deepEqual(call.target, { blockHash: context.hash, requireCanonical: true });
}
const responses = Object.values(evidence.evidence).flatMap(report => {
  assert.equal(report.complete, true);
  assert.equal(report.started, report.completed);
  assert.equal(report.started, report.entries.length);
  assert.equal(report.missing + report.omitted, 0);
  return report.entries;
});
assert.equal(responses.length, trace.length);
assert.equal(new Set(responses.map(r => r.requestId)).size, responses.length);
for (const response of responses) {
  assert.equal(response.outcome, "success");
  assert.equal(response.profile, context.profile);
  assert.equal(response.metadata.service_profile_id, context.profileId);
  assert.equal(BigInt(response.metadata.chain_id), BigInt(context.chainId));
  assert.equal(response.requestId, response.metadata.request_id);
  if (response.method === "eth_chainId") assert.equal(response.metadata.selected_provider ?? null, null);
}
assert.ok(evidence.clientCalls.some(call => call.blockNumber === null));
assert.equal(evidence.result.dependentRounds, 2);
assert.equal(evidence.result.independent, "1107");
assert.equal(evidence.result.dynamic, "1000");
assert.equal(reorg.previous_hash, context.hash);
assert.notEqual(reorg.next_hash, context.hash);
assert.ok(BigInt(reorg.next_number) >= BigInt(context.number));
assert.equal(reorg.reported_change.kind, "anchor_hash_changed");
assert.equal(reorg.reported_change.previous_hash, context.hash);
assert.ok(reorg.old_selector_error_code < 0);
assert.equal(reorg.cleanup, "publication_disabled_and_gate_unmanaged");
console.log("Verified: 12 correlated HTTP responses including local chain ID, one hash across discovery/SEL/worker, visible branch change, safe cleanup.");
