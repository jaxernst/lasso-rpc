import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { Worker } from "node:worker_threads";
import { createPublicClient, createWalletClient, custom, http, parseAbi, encodeFunctionData } from "viem";
import { createSEL } from "@seljs/runtime";
import { buildSchema } from "@seljs/env";
import solc from "solc";
import { publishedBlockQuery } from "../published-block-query.mjs";
import { evidenceRpc } from "./evidence-rpc.mjs";
import { queryContext, cacheKey, assertPublishedChoice } from "./query-context.mjs";

const slot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
setTimeout(() => { process.stderr.write("Logical-read fixture deadline exceeded\n"); process.exit(1); }, 45_000).unref();
const account = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
const direct = createPublicClient({ transport: http(process.env.ANVIL_URL, { retryCount: 0 }) });
const wallet = createWalletClient({ account, transport: http(process.env.ANVIL_URL, { retryCount: 0 }) });
const abi = parseAbi([
  "function stakedTokenId(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
]);

async function deploy() {
  const source = await readFile(new URL("./Fixture.sol", import.meta.url), "utf8");
  const output = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity",
    sources: { "Fixture.sol": { content: source } },
    settings: { evmVersion: "cancun", outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
  })));
  const errors = output.errors?.filter(error => error.severity === "error") ?? [];
  assert.deepEqual(errors, []);
  const contracts = output.contracts["Fixture.sol"];
  async function install(name, args = []) {
    const hash = await wallet.deployContract({ abi: contracts[name].abi,
      bytecode: `0x${contracts[name].evm.bytecode.object}`, args, chain: null });
    return (await direct.waitForTransactionReceipt({ hash })).contractAddress;
  }
  const first = await install("Implementation", [1n]);
  const second = await install("Implementation", [2n]);
  return { first, second, proxy: await install("Proxy", [first]), multicall: await install("Multicall") };
}

async function verify(fixture) {
  const scope = { url: process.env.RPC_URL, apiKey: process.env.LASSO_API_KEY,
    profile: process.env.LASSO_PROFILE, chainId: 31337, deadline: Date.now() + 25_000 };
  const trace = [];
  const captureFetch = (url, options) => {
    const { method, params } = JSON.parse(options.body);
    trace.push({ method, target: params.at(-1), to: params[0]?.to ?? null });
    return fetch(url, options);
  };
  const rpc = evidenceRpc({ ...scope, fetch: captureFetch });
  const query = await publishedBlockQuery(rpc);
  assertPublishedChoice(query, rpc);
  const context = queryContext(query, rpc);

  // Advance and upgrade before discovery. All query reads must still see V1.
  const tx = await wallet.sendTransaction({ chain: null, to: fixture.proxy,
    data: encodeFunctionData({ abi: parseAbi(["function upgrade(address)"]), functionName: "upgrade", args: [fixture.second] }),
  });
  await direct.waitForTransactionReceipt({ hash: tx });
  assert.ok(await direct.getBlockNumber({ cacheTime: 0 }) > query.blockNumber);
  const latestStorage = await direct.getStorageAt({ address: fixture.proxy, slot });
  assert.equal(`0x${latestStorage.slice(-40)}`.toLowerCase(), fixture.second.toLowerCase());

  const client = createPublicClient({ transport: custom(query, { retryCount: 0 }) });
  assert.equal(await client.getChainId(), 31337);
  const proxyCode = await client.getCode({ address: fixture.proxy });
  const implementationSlot = await client.getStorageAt({ address: fixture.proxy, slot });
  const implementation = `0x${implementationSlot.slice(-40)}`;
  const code = await client.getCode({ address: implementation });
  assert.equal(implementation.toLowerCase(), fixture.first.toLowerCase());
  assert.ok(proxyCode.length > 2 && code.length > 2);

  const clientCalls = [];
  const selClient = {
    getBlockNumber: () => client.getBlockNumber({ cacheTime: 0 }),
    call: params => {
      clientCalls.push({ to: params.to, blockNumber: params.blockNumber?.toString() ?? null });
      return client.call(params);
    },
  };
  const sel = createSEL({ client: selClient,
    schema: buildSchema({ contracts: Object.fromEntries(["token", "staking", "nft"].map(name =>
      [name, { address: fixture.proxy, abi }])), context: { user: "sol_address" } }),
    multicall: { address: fixture.multicall, batchSize: 1 }, limits: { maxCalls: 12, maxRounds: 4 },
  });
  const independent = await sel.evaluate("token.totalSupply() + token.balanceOf(user) + staking.stakedTokenId(user)", { user: account });
  assert.equal(independent.value, 1107n);
  assert.equal(clientCalls.length, 3);
  assert.ok(clientCalls.every(call => call.to.toLowerCase() === fixture.multicall.toLowerCase()));
  const dependent = await sel.evaluate("nft.ownerOf(staking.stakedTokenId(user))", { user: account });
  assert.equal(dependent.value.toLowerCase(), "0x000000000000000000000000000000000000dead");
  assert.equal(dependent.meta.roundsExecuted, 2);

  // Runtime-evaluated lambda arguments exercise the direct (unplanned) call path.
  const dynamic = await sel.evaluate("[user].map(who, token.balanceOf(who)).sum()", { user: account });
  assert.equal(dynamic.value, 1000n);
  assert.ok(clientCalls.some(call => call.blockNumber === null));

  const worker = await new Promise((resolve, reject) => {
    const thread = new Worker(new URL("./worker.mjs", import.meta.url), {
      workerData: { scope, context, implementation },
    });
    let result;
    thread.once("message", message => { result = message; });
    thread.once("error", reject);
    thread.once("exit", code => code === 0 && result ? resolve(result) : reject(new Error("Query worker failed")));
  });
  trace.push(...worker.trace);
  assert.equal(worker.code, code);
  const cache = new Map([[cacheKey(context, ["eth_getCode", implementation]), code]]);
  assert.equal(cache.get(cacheKey(worker.context, ["eth_getCode", implementation])), code);
  assert.equal(cache.has(cacheKey({ ...context, hash: `0x${"f".repeat(64)}` }, ["eth_getCode", implementation])), false);

  assert.equal(trace.filter(call => call.method === "eth_getBlockByNumber").length, 1);
  assert.equal(trace.filter(call => call.method === "eth_chainId").length, 1);
  for (const call of trace.slice(1).filter(call => call.method !== "eth_chainId")) {
    assert.deepEqual(call.target, query.selector);
  }
  assert.equal(rpc.evidence().complete, true);
  assert.equal(worker.evidence.complete, true);
  return { schema: 1, runtime: "@seljs/runtime@1.4.0", viem: "2.47.6", context,
    result: { independent: independent.value.toString(), dependent: dependent.value,
      dynamic: dynamic.value.toString(), dependentRounds: dependent.meta.roundsExecuted },
    proxyChangedAfterSelection: true, discoveryUsedOriginalImplementation: true,
    clientCalls, trace, evidence: { parent: rpc.evidence(), worker: worker.evidence } };
}

const result = process.argv[2] === "deploy" ? await deploy() : await verify(JSON.parse(process.env.QUERY_FIXTURE));
process.stdout.write(JSON.stringify(result));
