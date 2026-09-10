// One instance belongs to one query or worker. Only standard JSON-RPC is sent.
import { stateBlockSelector } from "../published-block-query.mjs";

export function evidenceRpc({ url, apiKey, profile, profileId, chainId, deadline = Date.now() + 10_000,
  maxRequests = 128, maxConcurrency = 4, maxEvidenceBytes = 65_536, maxResponseBytes = 4_194_304,
  fetch: fetchImpl = globalThis.fetch }) {
  if (!profile || BigInt(chainId) < 0n || !Number.isSafeInteger(deadline)
    || ![maxRequests, maxConcurrency, maxEvidenceBytes, maxResponseBytes].every(n => Number.isSafeInteger(n) && n > 0)) {
    throw new Error("Invalid query scope or limits");
  }
  const expectedChain = BigInt(chainId).toString();
  let boundProfileId = profileId ?? null;
  const entries = [];
  const slots = concurrencySlots(maxConcurrency);
  const lifetime = new AbortController();
  let deadlineSignal;
  let started = 0, completed = 0, missing = 0, omitted = 0, bytes = 0;

  async function request({ method, params = [], signal: parentSignal }) {
    const remaining = deadline - Date.now();
    if (remaining <= 0 || deadlineSignal?.aborted) throw new Error("Logical query deadline exceeded");
    deadlineSignal ??= AbortSignal.timeout(remaining);
    lifetime.signal.throwIfAborted();
    if (started >= maxRequests) throw new Error("Logical query RPC limit exceeded");
    const id = ++started;
    const entry = { sequence: id, method, outcome: "transport_error", metadataStatus: "missing" };
    const controller = new AbortController();
    const signal = AbortSignal.any([lifetime.signal, controller.signal, deadlineSignal, ...(parentSignal ? [parentSignal] : [])]);
    const supplied = stateBlockSelector({ method, params });
    if (supplied?.blockHash) entry.blockHash = supplied.blockHash;
    let release, response, reader, pending;
    const wait = operation => {
      pending = Promise.resolve(operation);
      return abortable(pending, signal);
    };
    try {
      release = await slots.acquire(signal);
      signal.throwIfAborted();
      response = await wait(Promise.resolve().then(() => fetchImpl(url, {
        method: "POST", credentials: "omit", redirect: "error",
        signal,
        headers: {
          "Content-Type": "application/json", "X-Lasso-Include-Meta": "headers",
          ...(apiKey ? { "X-Lasso-Api-Key": apiKey } : {}),
        },
        body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
      })).then(result => {
        response = result;
        // A fetch implementation may deliver headers after the caller has aborted.
        if (signal.aborted) {
          return result.body?.cancel().then(() => { throw signal.reason; });
        }
        return result;
      }));
      entry.httpStatus = response.status;
      entry.profile = response.headers.get("x-lasso-profile");
      entry.requestId = response.headers.get("x-lasso-request-id")
        ?? response.headers.get("x-request-id");
      const decoded = decodeMetadata(response.headers.get("x-lasso-meta"));
      entry.metadataStatus = decoded.status;
      if (decoded.metadata) entry.metadata = decoded.metadata;

      const serviceId = entry.metadata?.service_profile_id;
      if (boundProfileId && serviceId !== undefined && serviceId !== boundProfileId) {
        entry.metadataStatus = "scope_mismatch";
        throw new Error("RPC profile identity changed within query");
      }
      if (entry.profile && entry.profile !== profile
        && (!boundProfileId || serviceId !== boundProfileId)) {
        entry.metadataStatus = "scope_mismatch";
        throw new Error("RPC profile changed within query");
      }
      let metadataChain;
      if (entry.metadata?.chain_id !== undefined) {
        try { metadataChain = BigInt(entry.metadata.chain_id).toString(); }
        catch { entry.metadataStatus = "invalid"; }
      }
      if (metadataChain !== undefined && metadataChain !== expectedChain) {
        entry.metadataStatus = "scope_mismatch";
        throw new Error("RPC chain changed within query");
      }
      if (entry.metadataStatus === "present"
        && (!entry.profile || entry.metadata.chain_id === undefined || !entry.metadata.request_id
          || typeof entry.metadata.profile_id !== "string" || !entry.metadata.profile_id
          || typeof serviceId !== "string" || !serviceId
          || entry.metadata.request_id !== entry.requestId)) {
        entry.metadataStatus = "incomplete";
      }
      if (entry.metadataStatus === "present") {
        boundProfileId = serviceId;
      }

      reader = response.body?.getReader();
      if (!reader) throw new Error("RPC response body missing");
      const rpc = JSON.parse(await boundedBody(reader, maxResponseBytes, wait));
      if (rpc.jsonrpc !== "2.0" || rpc.id !== id || Array.isArray(rpc)
        || Object.hasOwn(rpc, "result") === Object.hasOwn(rpc, "error")) {
        throw new Error("Invalid JSON-RPC response envelope");
      }
      if (rpc.error) {
        entry.outcome = "rpc_error";
        entry.errorCode = rpc.error.code;
        const error = new Error(rpc.error.message ?? "RPC failed");
        error.code = rpc.error.code;
        error.data = rpc.error.data;
        throw error;
      }
      if (!response.ok) throw new Error(`RPC HTTP status ${response.status}`);
      entry.outcome = "success";
      return rpc.result;
    } finally {
      controller.abort();
      const cleanup = Promise.allSettled([
        pending,
        Promise.resolve().then(() => reader ? reader.cancel() : response?.body?.cancel()),
      ]).then(() => reader?.releaseLock());
      if (!await settlesWithin(cleanup, 100)) {
        entry.cleanupStatus = "unconfirmed";
        lifetime.abort(new Error("Logical query transport retired: cleanup did not settle"));
      }
      release?.();
      completed++;
      if (entry.metadataStatus !== "present") missing++;
      const size = new TextEncoder().encode(JSON.stringify(entry)).length;
      if (bytes + size <= maxEvidenceBytes) { entries.push(entry); bytes += size; }
      else omitted++;
    }
  }

  return Object.freeze({
    request, deadline, profile, chainId: expectedChain,
    get profileId() { return boundProfileId; },
    evidence() {
      return structuredClone({
        coverage: "individual_http_responses", started, completed, missing, omitted,
        retired: lifetime.signal.aborted,
        complete: !lifetime.signal.aborted && started === completed && missing === 0 && omitted === 0,
        entries: [...entries].sort((a, b) => a.sequence - b.sequence),
      });
    },
  });
}

function concurrencySlots(limit) {
  let active = 0;
  const waiting = new Set();
  function release() {
    active--;
    waiting.values().next().value?.();
  }
  return {
    acquire(signal) {
      return new Promise((resolve, reject) => {
        function abort() {
          waiting.delete(admit);
          reject(signal.reason);
        }
        function admit() {
          waiting.delete(admit);
          signal.removeEventListener("abort", abort);
          if (signal.aborted) { reject(signal.reason); return; }
          active++;
          resolve(release);
        }
        if (signal.aborted) { reject(signal.reason); return; }
        if (active < limit) admit();
        else {
          waiting.add(admit);
          signal.addEventListener("abort", abort, { once: true });
        }
      });
    },
  };
}

function decodeMetadata(encoded) {
  if (!encoded) return { status: "missing" };
  if (encoded.length > 4096) return { status: "oversized" };
  try {
    if (!/^[A-Za-z0-9_-]+$/.test(encoded)) throw new Error("Invalid base64url");
    const json = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(
      atob(encoded.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)
    ));
    const metadata = JSON.parse(json);
    if (metadata?.version !== "1.0") return { status: "unsupported_version" };
    return { status: "present", metadata };
  } catch { return { status: "invalid" }; }
}

// AbortSignal alone cannot bound an injected fetch or stream implementation.
function abortable(operation, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => {
      signal.removeEventListener("abort", abort);
      reject(signal.reason);
    };
    signal.addEventListener("abort", abort, { once: true });
    operation.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
    if (signal.aborted) abort();
  });
}

async function settlesWithin(operation, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      operation.then(() => true, () => false),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), milliseconds); }),
    ]);
  } finally { clearTimeout(timer); }
}

async function boundedBody(reader, limit, wait) {
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await wait(reader.read());
    if (done) break;
    size += value.byteLength;
    if (size > limit) throw new Error("RPC response byte limit exceeded");
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder("utf-8", { fatal: true }).decode(body);
}
