#!/usr/bin/env node
import cluster from "node:cluster";
import http from "node:http";
import os from "node:os";

const dataPort = Number(process.env.PORT || 4100);
const adminPort = Number(process.env.ADMIN_PORT || dataPort + 1);
const workerCount = Number(process.env.WORKERS || Math.min(4, os.availableParallelism()));
const initialDelayMs = Number(process.env.RESPONSE_DELAY_MS || 1);
const allowedModes = new Set(["healthy", "http_503", "rpc_error", "connection_reset"]);

function readBody(request, limit = 1_048_576) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > limit) reject(new Error("request body exceeded limit"));
      else chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function sendJson(response, status, value, onComplete = null) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": body.length,
  });
  response.end(body, onComplete);
}

if (cluster.isPrimary) {
  if (!Number.isSafeInteger(workerCount) || workerCount < 1) throw new Error("WORKERS must be positive");
  let generation = 0;
  let mode = "healthy";
  let delayMs = initialDelayMs;
  const pending = new Map();

  for (let index = 0; index < workerCount; index += 1) cluster.fork();

  for (const worker of Object.values(cluster.workers)) {
    worker.on("message", (message) => {
      const request = pending.get(message.requestId);
      if (!request) return;
      request.responses.push(message);
      if (request.responses.length === workerCount) {
        pending.delete(message.requestId);
        request.resolve(request.responses);
      }
    });
  }

  const broadcast = (type, payload = {}) => new Promise((resolve, reject) => {
    const requestId = `${process.pid}-${Date.now()}-${Math.random()}`;
    const timeout = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`${type} worker acknowledgement timed out`));
    }, 5_000);
    pending.set(requestId, {
      responses: [],
      resolve: (responses) => {
        clearTimeout(timeout);
        resolve(responses);
      },
    });
    for (const worker of Object.values(cluster.workers)) worker.send({ type, requestId, ...payload });
  });

  const aggregate = (responses) => {
    const totals = {
      requests: 0,
      responses: 0,
      benchmarkRequests: 0,
      benchmarkResponses: 0,
      systemRequests: 0,
      systemResponses: 0,
      errors: 0,
      connectionsAccepted: 0,
      activeRequests: 0,
      peakActiveRequests: 0,
    };
    for (const { stats } of responses) {
      totals.requests += stats.requests;
      totals.responses += stats.responses;
      totals.benchmarkRequests += stats.benchmarkRequests;
      totals.benchmarkResponses += stats.benchmarkResponses;
      totals.systemRequests += stats.systemRequests;
      totals.systemResponses += stats.systemResponses;
      totals.errors += stats.errors;
      totals.connectionsAccepted += stats.connectionsAccepted;
      totals.activeRequests += stats.activeRequests;
      totals.peakActiveRequests += stats.peakActiveRequests;
    }
    return { generation, mode, delayMs, workers: workerCount, totals };
  };

  const admin = http.createServer(async (request, response) => {
    try {
      if (request.method === "GET" && request.url === "/stats") {
        sendJson(response, 200, aggregate(await broadcast("stats")));
        return;
      }
      if (request.method === "POST" && request.url === "/control") {
        const update = JSON.parse((await readBody(request)).toString("utf8") || "{}");
        const nextMode = update.mode ?? mode;
        const nextDelayMs = update.delayMs ?? delayMs;
        if (!allowedModes.has(nextMode)) throw new Error(`unsupported mode ${nextMode}`);
        if (!Number.isFinite(nextDelayMs) || nextDelayMs < 0) throw new Error("invalid delayMs");
        generation += 1;
        mode = nextMode;
        delayMs = nextDelayMs;
        const responses = await broadcast("control", {
          generation,
          mode,
          delayMs,
          reset: update.reset === true,
        });
        sendJson(response, 200, aggregate(responses));
        return;
      }
      sendJson(response, 404, { error: "not found" });
    } catch (error) {
      sendJson(response, 400, { error: String(error) });
    }
  });
  admin.listen(adminPort, "0.0.0.0", () => {
    process.stdout.write(`${JSON.stringify({ ready: true, dataPort, adminPort, workers: workerCount })}\n`);
  });
} else {
  let control = { generation: 0, mode: "healthy", delayMs: initialDelayMs };
  let totals = {
    requests: 0,
    responses: 0,
    benchmarkRequests: 0,
    benchmarkResponses: 0,
    systemRequests: 0,
    systemResponses: 0,
    errors: 0,
    connectionsAccepted: 0,
    activeRequests: 0,
    peakActiveRequests: 0,
  };

  const snapshot = () => ({ ...totals });
  process.on("message", (message) => {
    if (message.type === "control") {
      control = { generation: message.generation, mode: message.mode, delayMs: message.delayMs };
      if (message.reset) {
        totals = {
          ...totals,
          requests: 0,
          responses: 0,
          benchmarkRequests: 0,
          benchmarkResponses: 0,
          systemRequests: 0,
          systemResponses: 0,
          errors: 0,
          connectionsAccepted: 0,
          peakActiveRequests: totals.activeRequests,
        };
      }
      process.send({ requestId: message.requestId, stats: snapshot() });
    } else if (message.type === "stats") {
      process.send({ requestId: message.requestId, stats: snapshot() });
    }
  });

  const server = http.createServer(async (request, response) => {
    if (request.method !== "POST") {
      sendJson(response, 404, { error: "not found" });
      return;
    }
    totals.requests += 1;
    totals.activeRequests += 1;
    totals.peakActiveRequests = Math.max(totals.peakActiveRequests, totals.activeRequests);
    const decision = { ...control };
    try {
      const rpc = JSON.parse((await readBody(request)).toString("utf8"));
      const benchmark = rpc.method === "eth_getBalance";
      totals[benchmark ? "benchmarkRequests" : "systemRequests"] += 1;
      if (decision.delayMs > 0) await new Promise((resolve) => setTimeout(resolve, decision.delayMs));
      if (decision.mode === "connection_reset") {
        request.socket.destroy();
        return;
      }
      if (decision.mode === "http_503") {
        sendJson(response, 503, { error: "synthetic unavailable" }, () => {
          totals.responses += 1;
          totals[benchmark ? "benchmarkResponses" : "systemResponses"] += 1;
        });
        return;
      }
      const body = decision.mode === "rpc_error"
        ? { jsonrpc: "2.0", id: rpc.id ?? null, error: { code: -32000, message: "synthetic error" } }
        : { jsonrpc: "2.0", id: rpc.id ?? null, result: "0x1" };
      sendJson(response, 200, body, () => {
        totals.responses += 1;
        totals[benchmark ? "benchmarkResponses" : "systemResponses"] += 1;
      });
    } catch (error) {
      totals.errors += 1;
      sendJson(response, 400, { error: String(error) });
    } finally {
      totals.activeRequests -= 1;
    }
  });
  server.on("connection", () => { totals.connectionsAccepted += 1; });
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  server.listen(dataPort, "0.0.0.0");
}
