// Construct this query-scoped transport before contract/proxy discovery.
// It accepts the same request({ method, params }) shape as a viem custom transport.
const blockPositions = new Map([
  ["eth_call", 1], ["eth_getBalance", 1], ["eth_getCode", 1],
  ["eth_getTransactionCount", 1], ["eth_getStorageAt", 2], ["eth_getProof", 2],
]);

export function stateBlockSelector({ method, params = [] }) {
  const index = blockPositions.get(method);
  return index === undefined ? undefined : params[index];
}

export async function publishedBlockQuery(rpc) {
  const block = await rpc.request({ method: "eth_getBlockByNumber", params: ["latest", false] });
  return queryAtBlock(rpc, block);
}

// A worker receives this identity from its parent query; it never resolves latest.
export function queryAtBlock(rpc, block) {
  if (!block || !/^0x[0-9a-f]+$/i.test(block.number) || !/^0x[0-9a-f]{64}$/i.test(block.hash)) {
    throw new Error("RPC did not return a usable published block");
  }
  const identity = Object.freeze({ number: `0x${BigInt(block.number).toString(16)}`, hash: block.hash.toLowerCase() });
  const selector = Object.freeze({ blockHash: identity.hash, requireCanonical: true });

  function pin({ method, params = [] }) {
    if (!blockPositions.has(method)) throw new Error(`Method ${method} is outside this state query`);
    const index = blockPositions.get(method);
    const supplied = params[index];
    const sameNumber = typeof supplied === "string" && /^0x[0-9a-f]+$/i.test(supplied) && BigInt(supplied) === BigInt(identity.number);
    const sameHash = supplied && typeof supplied === "object" && !Array.isArray(supplied)
      && typeof supplied.blockHash === "string" && supplied.blockHash.toLowerCase() === identity.hash
      && (supplied.requireCanonical === undefined || supplied.requireCanonical === true)
      && Object.keys(supplied).every(key => key === "blockHash" || key === "requireCanonical");
    if (supplied !== undefined && supplied !== "latest" && !sameNumber && !sameHash) {
      throw new Error(`Conflicting block selector in ${method}`);
    }
    if (params.length < index) throw new Error(`Missing parameters for ${method}`);
    const pinned = [...params];
    pinned[index] = selector;
    return { method, params: pinned };
  }

  return Object.freeze({
    blockNumber: BigInt(identity.number),
    blockHash: identity.hash,
    identity,
    selector,
    async request(call) {
      if (call.method === "eth_blockNumber") return identity.number;
      if (call.method === "eth_chainId" || call.method === "net_version") return rpc.request(call);
      return rpc.request(pin(call));
    },
    async batch(calls) {
      const pinned = calls.map(pin);
      // Individual HTTP responses retain per-RPC evidence. On-chain Multicall
      // still batches contract execution within a single eth_call.
      const group = new AbortController();
      const outcomes = await Promise.allSettled(pinned.map(async call => {
        try { return await rpc.request({ ...call, signal: group.signal }); }
        catch (error) { group.abort(error); throw error; }
      }));
      if (group.signal.aborted) throw group.signal.reason;
      return outcomes.map(outcome => outcome.value);
    },
  });
}
