import test from "node:test";
import assert from "node:assert/strict";
import { publishedBlockQuery } from "./published-block-query.mjs";

test("discovery, independent Multicall and dependent rounds keep one identity", async () => {
  const calls = [];
  const hash = `0x${"a".repeat(64)}`;
  const rpc = { request: async call => {
    calls.push(call);
    return call.method === "eth_getBlockByNumber" ? { number: "0x64", hash } : "0x";
  }};
  const query = await publishedBlockQuery(rpc);
  await query.request({ method: "eth_getCode", params: ["contract"] });
  await query.request({ method: "eth_getStorageAt", params: ["proxy", "0x0", "latest"] });
  await query.batch([
    { method: "eth_call", params: [{ to: "multicall", data: "0xfirst" }, "latest"] },
    { method: "eth_getBalance", params: ["contract", "0x64"] },
  ]);
  await query.request({ method: "eth_call", params: [{ to: "resolved", data: "0xdependent" }] });
  assert.equal(await query.request({ method: "eth_blockNumber" }), "0x64");
  assert.equal(calls.filter(c => c.method === "eth_getBlockByNumber").length, 1);
  assert.equal(calls.length, 6);
  for (const call of calls.slice(1)) {
    assert.deepEqual(call.params.at(-1), { blockHash: hash, requireCanonical: true });
  }
  await assert.rejects(query.request({ method: "eth_call", params: [{}, "0x63"] }), /Conflicting/);
  await assert.rejects(query.request({ method: "eth_getLogs", params: [{}] }), /outside/);
});

test("a failed pinned read does not resolve latest again or fall back to a number", async () => {
  let choices = 0;
  const rpc = { request: async ({ method }) => {
    if (method === "eth_getBlockByNumber") {
      choices++;
      return { number: "0x65", hash: `0x${"b".repeat(64)}` };
    }
    throw new Error("block is not canonical");
  }};
  const query = await publishedBlockQuery(rpc);
  await assert.rejects(query.request({ method: "eth_call", params: [{}] }), /not canonical/);
  assert.equal(choices, 1);
});
