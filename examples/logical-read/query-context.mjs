import { queryAtBlock } from "../published-block-query.mjs";

export function queryContext(query, rpc) {
  return Object.freeze({ version: 1, chainId: rpc.chainId, profile: rpc.profile, profileId: rpc.profileId,
    ...query.identity, deadline: rpc.deadline });
}

export function resumeQuery(rpc, context) {
  if (context.version !== 1 || context.chainId !== rpc.chainId || context.profile !== rpc.profile
    || !context.profileId || context.profileId !== rpc.profileId
    || context.deadline !== rpc.deadline || Date.now() >= context.deadline) {
    throw new Error("Worker query scope or deadline does not match");
  }
  return queryAtBlock(rpc, context);
}

// Include the full operation (method, arguments and overrides) in operationKey.
// A hash-scoped cache stores execution results, not a fresh canonicality assertion.
export function cacheKey(context, operationKey) {
  return JSON.stringify([context.version, context.chainId, context.profileId, context.hash, encodeOperation(operationKey)]);
}

// Tags keep native bigint distinct from strings and user-supplied JSON objects.
function encodeOperation(value, ancestors = new Set()) {
  if (typeof value === "bigint") return ["bigint", value.toString()];
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "object" || ancestors.has(value)
    || (!Array.isArray(value) && Object.getPrototypeOf(value) !== Object.prototype
      && Object.getPrototypeOf(value) !== null)) {
    throw new TypeError("Cache operation must contain finite JSON values or bigint, without cycles");
  }
  ancestors.add(value);
  try {
    return Array.isArray(value)
      ? ["array", Array.from(value, item => encodeOperation(item, ancestors))]
      : ["object", Object.keys(value).sort().map(key => [key, encodeOperation(value[key], ancestors)])];
  } finally { ancestors.delete(value); }
}

export function assertPublishedChoice(query, rpc) {
  const evidence = rpc.evidence();
  const choice = evidence.entries.find(entry => entry.method === "eth_getBlockByNumber");
  const policy = choice?.metadata?.head_policy;
  if (!evidence.complete || policy?.policy !== "global" || policy.scope !== "profile_chain_fleet"
    || policy.source !== "published_block" || policy.block_hash !== query.blockHash
    || BigInt(policy.block_number) !== query.blockNumber) {
    throw new Error("Block choice lacks matching global publication evidence");
  }
}
