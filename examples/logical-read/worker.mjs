import { parentPort, workerData } from "node:worker_threads";
import { evidenceRpc } from "./evidence-rpc.mjs";
import { queryContext, resumeQuery } from "./query-context.mjs";

const { scope, context, implementation } = workerData;
const trace = [];
const rpc = evidenceRpc({ ...scope, profileId: context.profileId, fetch: (url, options) => {
  const { method, params } = JSON.parse(options.body);
  trace.push({ method, target: params.at(-1), to: params[0]?.to ?? null });
  return fetch(url, options);
} });
const query = resumeQuery(rpc, context);
const code = await query.request({ method: "eth_getCode", params: [implementation] });
parentPort.postMessage({ context: queryContext(query, rpc), code, trace, evidence: rpc.evidence() });
parentPort.close();
