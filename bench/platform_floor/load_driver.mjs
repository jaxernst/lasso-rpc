#!/usr/bin/env node
import { execFile } from "node:child_process";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import { appendFileSync } from "node:fs";
import { promisify } from "node:util";
import { isMainThread, parentPort, Worker, workerData } from "node:worker_threads";
import { RelativeHistogram } from "./relative_histogram.mjs";

const execFileAsync = promisify(execFile);

function parseArgs(argv) {
  return Object.fromEntries(argv.map((argument) => {
    const separator = argument.indexOf("=");
    if (!argument.startsWith("--") || separator < 3) throw new Error(`invalid argument ${argument}`);
    return [argument.slice(2, separator), argument.slice(separator + 1)];
  }));
}

function integer(value, label, minimum = 1) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum) {
    throw new Error(`${label} must be an integer >= ${minimum}`);
  }
  return parsed;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function requestBody(id) {
  return JSON.stringify({
    jsonrpc: "2.0",
    id,
    method: "eth_getBalance",
    params: [`0x${id.toString(16).padStart(40, "0")}`, "latest"],
  });
}

function invoke(target, agent, id, timeoutMs, histogram, counters) {
  const body = requestBody(id);
  const transport = target.protocol === "https:" ? https : http;
  const startedAt = process.hrtime.bigint();
  counters.started += 1;

  return new Promise((resolve) => {
    let finished = false;
    const finish = (category) => {
      if (finished) return;
      finished = true;
      if (category === null) {
        counters.success += 1;
        histogram.record(Number(process.hrtime.bigint() - startedAt) / 1_000);
      } else {
        counters.errors += 1;
        counters.errorCategories[category] = (counters.errorCategories[category] || 0) + 1;
      }
      resolve();
    };

    const request = transport.request({
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port,
      path: `${target.pathname}${target.search}`,
      method: "POST",
      agent,
      timeout: timeoutMs,
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
      },
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("aborted", () => finish("network_error"));
      response.on("error", () => finish("network_error"));
      response.on("end", () => {
        if (response.statusCode !== 200) return finish(`http_${response.statusCode}`);
        try {
          const decoded = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          const valid = decoded?.jsonrpc === "2.0" && decoded?.id === id &&
            Object.hasOwn(decoded, "result") && !Object.hasOwn(decoded, "error");
          finish(valid ? null : "invalid_json_rpc_response");
        } catch {
          finish("invalid_json");
        }
      });
    });
    request.on("timeout", () => request.destroy(new Error("timeout")));
    request.on("error", (error) => finish(error.message === "timeout" ? "timeout" : "network_error"));
    request.end(body);
  });
}

async function runWorker() {
  const target = new URL(workerData.url);
  const transport = target.protocol === "https:" ? https : http;
  const agent = new transport.Agent({
    keepAlive: true,
    maxSockets: workerData.concurrency,
    maxFreeSockets: workerData.concurrency,
  });
  let sequence = (workerData.index + 1) * 1_000_000_000;

  const runFor = async (durationMs, record) => {
    const endsAt = process.hrtime.bigint() + BigInt(durationMs) * 1_000_000n;
    const histogram = new RelativeHistogram();
    const counters = { started: 0, success: 0, errors: 0, errorCategories: {} };
    await Promise.all(Array.from({ length: workerData.concurrency }, async () => {
      while (process.hrtime.bigint() < endsAt) {
        sequence += 1;
        await invoke(target, agent, sequence, workerData.timeoutMs, histogram, counters);
      }
    }));
    return record ? { histogram: histogram.serialize(), counters } : null;
  };

  await runFor(workerData.warmupMs, false);
  parentPort.postMessage({ type: "ready" });
  parentPort.once("message", async ({ type, durationMs }) => {
    if (type !== "measure") throw new Error(`unexpected command ${type}`);
    const startedAt = process.hrtime.bigint();
    const result = await runFor(durationMs, true);
    const elapsedSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
    agent.destroy();
    parentPort.postMessage({ type: "result", elapsedSeconds, ...result });
  });
}

async function dockerCgroupSample(container) {
  if (!container) return null;
  const script = [
    "cat /sys/fs/cgroup/cpu.stat",
    "printf '\\n--cpu-max--\\n'",
    "cat /sys/fs/cgroup/cpu.max",
    "printf '\\n--memory-current--\\n'",
    "cat /sys/fs/cgroup/memory.current",
    "printf '\\n--memory-peak--\\n'",
    "cat /sys/fs/cgroup/memory.peak 2>/dev/null || true",
    "printf '\\n--pids--\\n'",
    "cat /sys/fs/cgroup/pids.current",
  ].join("; ");
  const { stdout } = await execFileAsync("docker", ["exec", container, "sh", "-c", script]);
  const [cpu, cpuMax, memoryCurrent, memoryPeak, pids] = stdout.split(/\n--[^\n]+--\n/);
  const cpuStat = Object.fromEntries(cpu.trim().split("\n").map((line) => {
    const [key, value] = line.trim().split(/\s+/, 2);
    return [key, Number(value)];
  }));
  return {
    capturedAt: new Date().toISOString(),
    cpuStat,
    cpuMax: cpuMax.trim(),
    memoryCurrentBytes: Number(memoryCurrent.trim()),
    memoryPeakBytes: memoryPeak.trim() === "" ? null : Number(memoryPeak.trim()),
    pidsCurrent: Number(pids.trim()),
  };
}

function resourceDelta(container, start, end, successfulRequests) {
  if (start === null || end === null) return null;
  const cpuMicroseconds = end.cpuStat.usage_usec - start.cpuStat.usage_usec;
  return {
    container,
    start,
    end,
    cpuMicroseconds,
    cpuMicrosecondsPerSuccessful: successfulRequests === 0
      ? null
      : cpuMicroseconds / successfulRequests,
    throttledMicroseconds: end.cpuStat.throttled_usec - start.cpuStat.throttled_usec,
  };
}

async function upstreamRequest(adminUrl, method, path, body = null) {
  if (!adminUrl) return null;
  const response = await fetch(new URL(path, adminUrl), {
    method,
    headers: body === null ? {} : { "content-type": "application/json" },
    body: body === null ? null : JSON.stringify(body),
    signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) throw new Error(`upstream ${path} failed with HTTP ${response.status}`);
  return response.json();
}

async function runMain() {
  const args = parseArgs(process.argv.slice(2));
  const workerCount = integer(args.workers || Math.min(4, os.availableParallelism()), "workers");
  const concurrency = integer(args.concurrency || 64, "concurrency");
  const warmupMs = integer(Math.round(Number(args.warmup || 5) * 1_000), "warmupMs", 0);
  const durationMs = integer(Math.round(Number(args.duration || 15) * 1_000), "durationMs");
  const timeoutMs = integer(args.timeout || 10_000, "timeout");
  const target = new URL(args.url || "http://127.0.0.1:4000/rpc/1");
  const targetContainer = args.targetContainer || null;
  const upstreamContainer = args.upstreamContainer || null;
  const upstreamAdminUrl = args.upstreamAdminUrl || null;
  if (workerCount > concurrency) {
    throw new Error("workers must be less than or equal to concurrency");
  }
  const baseConcurrency = Math.floor(concurrency / workerCount);
  const remainder = concurrency % workerCount;
  const workers = Array.from({ length: workerCount }, (_, index) => new Worker(import.meta.filename, {
    workerData: {
      index,
      url: target.toString(),
      concurrency: baseConcurrency + (index < remainder ? 1 : 0),
      warmupMs,
      timeoutMs,
    },
  }));

  const ready = workers.map((worker) => new Promise((resolve, reject) => {
    worker.once("error", reject);
    worker.once("message", (message) => {
      if (message.type !== "ready") reject(new Error(`unexpected worker message ${message.type}`));
      else resolve();
    });
  }));
  await Promise.all(ready);
  const upstreamReset = await upstreamRequest(upstreamAdminUrl, "POST", "/control", {
    mode: "healthy",
    reset: true,
  });
  const [targetStart, upstreamStart] = await Promise.all([
    dockerCgroupSample(targetContainer),
    dockerCgroupSample(upstreamContainer),
  ]);
  const clientCpuStart = process.cpuUsage();
  const measuredStartedAt = new Date();
  const results = workers.map((worker) => new Promise((resolve, reject) => {
    worker.once("error", reject);
    worker.once("message", (message) => {
      if (message.type !== "result") reject(new Error(`unexpected worker message ${message.type}`));
      else resolve(message);
    });
    worker.postMessage({ type: "measure", durationMs });
  }));
  const workerResults = await Promise.all(results);
  const measuredEndedAt = new Date();
  const clientCpu = process.cpuUsage(clientCpuStart);
  const [targetEnd, upstreamEnd] = await Promise.all([
    dockerCgroupSample(targetContainer),
    dockerCgroupSample(upstreamContainer),
  ]);
  const upstreamStats = await upstreamRequest(upstreamAdminUrl, "GET", "/stats");
  await Promise.all(workers.map((worker) => worker.terminate()));

  const histogram = new RelativeHistogram();
  const counters = { started: 0, success: 0, errors: 0, errorCategories: {} };
  for (const result of workerResults) {
    histogram.merge(result.histogram);
    counters.started += result.counters.started;
    counters.success += result.counters.success;
    counters.errors += result.counters.errors;
    for (const [category, count] of Object.entries(result.counters.errorCategories)) {
      counters.errorCategories[category] = (counters.errorCategories[category] || 0) + count;
    }
  }
  const elapsedSeconds = Math.max(...workerResults.map(({ elapsedSeconds }) => elapsedSeconds));
  const latencyUs = histogram.serialize();
  if (args.includeHistogramBins !== "true") delete latencyUs.bins;

  const output = {
    schemaVersion: 1,
    label: args.label || null,
    target: target.toString(),
    runner: {
      node: process.version,
      platform: process.platform,
      architecture: process.arch,
    },
    workload: { workerCount, concurrency, warmupMs, durationMs, timeoutMs },
    timing: {
      startedAt: measuredStartedAt.toISOString(),
      endedAt: measuredEndedAt.toISOString(),
      elapsedSeconds,
    },
    counters,
    successfulRps: counters.success / elapsedSeconds,
    latencyUs,
    client: {
      cpuMicroseconds: clientCpu.user + clientCpu.system,
      cpuMicrosecondsPerStarted: counters.started === 0
        ? null
        : (clientCpu.user + clientCpu.system) / counters.started,
      equivalentCores: (clientCpu.user + clientCpu.system) / (elapsedSeconds * 1_000_000),
    },
    targetResources: resourceDelta(targetContainer, targetStart, targetEnd, counters.success),
    upstreamResources:
      resourceDelta(upstreamContainer, upstreamStart, upstreamEnd, counters.success),
    upstream: { reset: upstreamReset, stats: upstreamStats },
  };
  const encoded = `${JSON.stringify(output)}\n`;
  if (args.output) appendFileSync(args.output, encoded);
  process.stdout.write(encoded);
  if (counters.errors > 0 || histogram.underflow > 0 || histogram.overflow > 0) process.exitCode = 1;
}

if (isMainThread) await runMain();
else await runWorker();
