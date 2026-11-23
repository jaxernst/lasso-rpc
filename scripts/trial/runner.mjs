// Runs one scenario for several candidates concurrently. Each candidate gets its own
// mock upstream process and port block, so upstream logs never mix.
// Usage: node runner.mjs <scenario> [candidates comma list] [duration_s]
// See README.md for candidates, scenarios and environment variables.
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { trueHead } from "./mock.mjs";
import { signedTransfer, txHash } from "./tx.mjs";

const KIT = path.dirname(fileURLToPath(import.meta.url));
const PORT_BASE = Number(process.env.PORT_BASE || 43000);
const BLOCK = 60;

// The endpoint candidate comes first so its mock upstreams sit at PORT_BASE+1, +2 and +3.
const NAMES = ["endpoint", "direct", "race2", "lasso", "lasso-fastest", "lasso-bf"];
const DEFS = {
  endpoint: { proxy: "endpoint" },
  direct: {},
  race2: {},
  lasso: { proxy: "lasso", route: "/rpc/profile/trial/{chain}" },
  "lasso-fastest": { proxy: "lasso", route: "/rpc/profile/trial/fastest/{chain}" },
  "lasso-bf": { proxy: "lasso", route: "/rpc/profile/trial/balanced-fast/{chain}" },
};
// Port block per candidate: upstreams base+1..base+39, distribution base+48, mock control base+49,
// proxy base+50. base+59 stays closed (Lasso's placeholder public provider).
const CANDIDATES = Object.fromEntries(NAMES.map((n, i) => {
  const base = PORT_BASE + BLOCK * i;
  return [n, { ...DEFS[n], base, port: base + 50, control: base + 49, dist: base + 48, closed: base + 59 }];
}));

const S6_UP = [{ latency_ms: 20 }, { latency_ms: 60 }, { latency_ms: 120 }];
const S9B_UP = [{ latency_ms: 20, send_timeout: true }, { latency_ms: 60 }, { latency_ms: 120 }];
const IDLE_CHAINS = [1, 10, 56, 100, 137, 250, 324, 8453, 42161, 43114, 59144, 81457, 534352];
const SCENARIOS = {
  S1: { up: [{ closed: true }, { closed: true }, { latency_ms: 50 }] },
  S2: { up: [{ hang: true }, { hang: true }, { latency_ms: 50 }] },
  S3: { up: [{ latency_ms: 20, rate_429: 0.6 }, { latency_ms: 60 }, { latency_ms: 120 }] },
  S4: { up: [{ latency_ms: 10, behind: 5 }, { latency_ms: 60 }, { latency_ms: 60 }] },
  S5: { up: [{ latency_ms: 20, refuse_methods: ["eth_getLogs", "eth_getTransactionReceipt"] }, { latency_ms: 60 }, { latency_ms: 120 }] },
  S6: { up: S6_UP },
  S8: { up: S6_UP, idle_s: 600 },
  S9a: { up: S6_UP, broadcast: 50 },
  S9b: { up: S9B_UP, broadcast: 50 },
  // All healthy at start; up1 and up2 start accepting and never answering at 60 s.
  S2m: { up: [{ latency_ms: 20 }, { latency_ms: 30 }, { latency_ms: 50 }], switch_at_s: 60, switch: { up1: { hang: true }, up2: { hang: true } } },
  // Read mix at 5 per second plus one send every 2 s. S9s: up1 hangs on sends from the start.
  // S9m: all healthy at start; up1 starts hanging on sends at 60 s.
  S9s: { up: S9B_UP, sends_every_ms: 2000 },
  S9m: { up: S6_UP, sends_every_ms: 2000, switch_at_s: 60, switch: { up1: { send_timeout: true } } },
  // Head faults that start mid-run. S4m: the quickest upstream's head stops at 60 s and stays stopped.
  // S4r: it stops at 60 s and rejoins the chain at 120 s. S4n: no upstream is quicker; up1 stops at 60 s.
  S4m: { up: [{ latency_ms: 10 }, { latency_ms: 60 }, { latency_ms: 60 }], switch_at_s: 60, switch: { up1: { stall: true } } },
  S4r: { up: [{ latency_ms: 10 }, { latency_ms: 60 }, { latency_ms: 60 }], switch_at_s: 60, switch: { up1: { stall: true } }, then: [{ at_s: 120, switch: { up1: { stall: false } } }] },
  S4n: { up: [{ latency_ms: 40 }, { latency_ms: 40 }, { latency_ms: 40 }], switch_at_s: 60, switch: { up1: { stall: true } } },
  // S11: the quickest upstream keeps answering but takes 2 s from 60 s on.
  S11: { up: S6_UP, switch_at_s: 60, switch: { up1: { latency_ms: 2000 } } },
  // 13 chains with 3 healthy upstreams each (20, 60, 120 ms), no client traffic.
  S10: { up: S6_UP, chains: IDLE_CHAINS, idle_s: 600 },
  // Wide backfill. Each upstream caps the eth_getLogs block range differently, and up2 also
  // throttles 30% of its calls. Every 6 s a client starts a pass over 100,000 blocks, sent as
  // ten 10,000-block windows one after another.
  B1: {
    up: [
      { latency_ms: 20, max_range: 1_000 },
      { latency_ms: 60, max_range: 10_000, range_error: { code: -32000, message: "exceed maximum block range: {cap}" }, rate_429: 0.3 },
      { latency_ms: 120 },
    ],
    backfill: { span: 100_000, window: 10_000, every_ms: 6000 },
  },
  // Real endpoints from UPSTREAMS, read mix only, no injected faults.
  R: { up: [], real: true },
};
const JITTER = 0.2;
const RATE = 5;
const CLIENT_TIMEOUT_MS = 10_000;
const SEED = 527;

const [scenarioName, candArg, durArg] = process.argv.slice(2);
const scenario = SCENARIOS[scenarioName];
if (!scenario) throw new Error("unknown scenario " + scenarioName);
const requested = (candArg || "direct,race2,lasso,lasso-fastest,lasso-bf").split(",");
for (const n of requested) if (!CANDIDATES[n]) throw new Error("unknown candidate " + n);
// Idle scenarios measure a proxy process the kit starts, so they run the Lasso candidates only.
const candNames = scenario.idle_s ? requested.filter((n) => CANDIDATES[n].proxy === "lasso") : requested;
if (candNames.length < requested.length) console.log(`${scenarioName} is idle; skipping ${requested.filter((n) => !candNames.includes(n)).join(", ")}`);
const DURATION_S = Number(durArg || 180);
const RUN_ID = process.env.RUN_ID || `${scenarioName}-${new Date().toISOString().replace(/[-:]|\.\d+/g, "")}`;
const OUT = path.join(process.env.RESULTS_DIR || path.join(KIT, "results", "runs"), RUN_ID);
// Claim the run directory before anything else, so a repeated RUN_ID never touches the earlier run.
fs.mkdirSync(path.dirname(OUT), { recursive: true });
try { fs.mkdirSync(OUT); } catch (e) {
  if (e.code === "EEXIST") throw new Error(`${OUT} already exists; choose another RUN_ID or RESULTS_DIR`);
  throw e;
}
const REAL = process.env.UPSTREAMS ? process.env.UPSTREAMS.split(",").map((u) => u.trim()).filter(Boolean) : null;
if (Boolean(REAL) !== Boolean(scenario.real)) throw new Error("scenario R needs UPSTREAMS, and UPSTREAMS works only with scenario R");
if (REAL) console.error("warning: R mode writes the UPSTREAMS URLs into configuration files under " + OUT + ". Remove any keys before sharing results.");
if (candNames.includes("endpoint") && !process.env.ENDPOINT_URL) throw new Error("the endpoint candidate needs ENDPOINT_URL");
const CHAINS = REAL ? [Number(requireEnv("CHAIN_ID"))] : scenario.chains ?? [137];
const BLOCK_TIME_MS = Number(process.env.BLOCK_TIME_MS || 2000);
// With real endpoints the head comes from polling the first upstream; with mocks it is the mock clock.
let realHead = null;
// Transaction hashes mined a few blocks below the real head, for the receipt reads in R.
let realTxs = [];
const headNow = () => (REAL ? realHead : trueHead());

function requireEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (n) => "0x" + BigInt(n).toString(16);
const pad = (n, w) => BigInt(n).toString(16).padStart(w, "0");
const now = () => Date.now();

function mulberry32(a) {
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const MIX = [
  ["eth_chainId", 5], ["eth_blockNumber", 15], ["eth_getBalance", 25], ["eth_call", 35],
  ["eth_getTransactionCount", 5], ["eth_gasPrice", 5], ["eth_getLogs", 5], ["eth_getTransactionReceipt", 5],
];
function methodSequence(n) {
  const rand = mulberry32(SEED);
  const total = MIX.reduce((a, [, w]) => a + w, 0);
  return Array.from({ length: n }, () => {
    let x = rand() * total;
    for (const [m, w] of MIX) { if ((x -= w) < 0) return m; }
    return MIX[MIX.length - 1][0];
  });
}

function buildRequest(seq, method, nonce) {
  const H = headNow();
  const s = pad(seq, 10);
  const id = seq + 1;
  switch (method) {
    case "eth_getBalance": return { id, method, params: ["0xb1" + s.padStart(38, "0"), "latest"] };
    case "eth_getTransactionCount": return { id, method, params: ["0xa1" + s.padStart(38, "0"), "latest"] };
    case "eth_call": return { id, method, params: [{ to: "0x00000000000000000000000000000000c0ffee01", data: "0x70a08231" + s.padStart(64, "0") }, "latest"] };
    case "eth_getLogs": return getLogs(seq, H - 100, H - 1);
    case "eth_getTransactionReceipt": return { id, method, params: [REAL ? realTxs[seq % realTxs.length] : "0x" + pad(H - 3, 16) + s.padStart(48, "0")] };
    case "eth_sendRawTransaction": return { id, method, params: [signedTransfer({ chainId: CHAINS[0], nonce }).raw] };
    default: return { id, method, params: [] };
  }
}
// The mock chain has exactly one log at every tenth block. A result must hold one log for each
// such block in the range, from the requested address, and nothing else.
function checkLogs(result, req) {
  if (!Array.isArray(result)) return "logs_not_array";
  const { from, to } = req.expectLogs;
  const address = req.params[0].address.toLowerCase();
  const seen = new Set();
  for (const log of result) {
    const n = typeof log?.blockNumber === "string" ? Number(BigInt(log.blockNumber)) : NaN;
    if (!(n >= from && n <= to) || n % 10 !== 0) return "logs_wrong_block";
    if (String(log.address).toLowerCase() !== address) return "logs_wrong_address";
    if (seen.has(n)) return "logs_duplicate";
    seen.add(n);
  }
  return seen.size === Math.floor(to / 10) - Math.floor((from - 1) / 10) ? null : "logs_missing";
}
function getLogs(seq, from, to) {
  return { id: seq + 1, method: "eth_getLogs", params: [{ address: "0x10" + pad(seq, 10).padStart(38, "0"), fromBlock: hex(from), toBlock: hex(to) }], expectLogs: { from, to } };
}
const tagOfReq = (r) => {
  const p = r.params;
  switch (r.method) {
    case "eth_getBalance": case "eth_getTransactionCount": case "eth_getTransactionReceipt": case "eth_sendRawTransaction": return String(p[0]).toLowerCase();
    case "eth_call": return p[0].data.toLowerCase();
    case "eth_getLogs": return p[0].address.toLowerCase();
    default: return null;
  }
};

function servedBlock(method, result) {
  if (REAL || typeof result !== "string") return null;
  if (["eth_blockNumber", "eth_getBalance", "eth_getTransactionCount", "eth_call"].includes(method)) return Number(BigInt(result));
  return null;
}

// ---------- process management ----------
// Every child starts in its own process group, and cleanup signals the whole group, so a
// server that outlives the shell or script that launched it still stops.
const children = [];
function start(cmd, args, opts, logFile) {
  const out = fs.openSync(logFile, "a");
  const child = spawn(cmd, args, { ...opts, detached: true, stdio: ["ignore", out, out] });
  child.startedAt = now();
  children.push(child);
  return child;
}
const groupAlive = (pid) => { try { process.kill(-pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
async function stop(child, graceMs = 10_000) {
  if (!child || !groupAlive(child.pid)) return;
  try { process.kill(-child.pid, "SIGTERM"); } catch {}
  for (const deadline = now() + graceMs; groupAlive(child.pid) && now() < deadline;) await sleep(100);
  if (!groupAlive(child.pid)) return;
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  for (const deadline = now() + 3000; groupAlive(child.pid) && now() < deadline;) await sleep(100);
}
let exiting = false;
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143]]) {
  process.on(signal, async () => {
    if (exiting) return;
    exiting = true;
    await Promise.all(children.map((c) => stop(c, 2000)));
    process.exit(code);
  });
}

// A port is free when nothing accepts a connection on it and this process can bind it.
function portFree(port) {
  const accepts = new Promise((resolve) => {
    const sock = net.connect({ port, host: "127.0.0.1" });
    sock.setTimeout(500, () => { sock.destroy(); resolve(false); });
    sock.once("connect", () => { sock.destroy(); resolve(true); });
    sock.once("error", () => resolve(false));
  });
  const binds = new Promise((resolve) => {
    const srv = net.createServer();
    srv.once("error", () => resolve(false));
    srv.listen(port, "127.0.0.1", () => srv.close(() => resolve(true)));
  });
  return Promise.all([accepts, binds]).then(([a, b]) => !a && b);
}
async function assertPortsFree(c) {
  const ports = REAL ? [] : [...CHAINS.flatMap((_, k) => upstreamPorts(c, k)), c.control];
  if (c.proxy === "lasso") ports.push(c.port, c.dist, c.closed);
  const busy = [];
  for (const p of ports) if (!(await portFree(p))) busy.push(p);
  if (busy.length) throw new Error(`ports in use: ${busy.join(", ")}. Another run may hold this PORT_BASE; pick another.`);
}

function processTree(rootPid) {
  const rows = execFileSync("ps", ["-A", "-o", "pid=,ppid=,rss=,time=,comm="], { encoding: "utf8" }).trim().split("\n")
    .map((l) => l.trim().split(/\s+/)).map(([pid, ppid, rss, time, ...comm]) => ({ pid: +pid, ppid: +ppid, rss: +rss, time, comm: comm.join(" ") }));
  const set = new Set([rootPid]);
  let grew = true;
  while (grew) { grew = false; for (const r of rows) if (!set.has(r.pid) && set.has(r.ppid)) { set.add(r.pid); grew = true; } }
  const cpuSec = (t) => { const p = t.split(":").map(Number); return p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1]; };
  const procs = rows.filter((r) => set.has(r.pid));
  return { rss_kb: procs.reduce((a, r) => a + r.rss, 0), cpu_s: procs.reduce((a, r) => a + cpuSec(r.time), 0), procs: procs.map((p) => `${p.pid}:${path.basename(p.comm)}`) };
}

// ---------- candidate setup ----------
// Upstream i (0-based) of chain index k uses port base + 1 + k*3 + i.
const upstreamPorts = (c, k = 0) => [0, 1, 2].map((i) => c.base + 1 + k * 3 + i);
const upstreamUrls = (c, k = 0) => REAL ?? upstreamPorts(c, k).map((p) => `http://127.0.0.1:${p}`);
const instName = (k, i) => (CHAINS.length > 1 ? `c${CHAINS[k]}-up${i + 1}` : `up${i + 1}`);
const routeFor = (c, chain = CHAINS[0]) => c.route.replace("{chain}", String(chain));

async function startMocks(name, c, dir) {
  if (REAL) return null;
  const instances = CHAINS.flatMap((chainId, k) => {
    const ports = upstreamPorts(c, k);
    return scenario.up.map((u, i) => ({ name: instName(k, i), port: ports[i], chain_id: chainId, jitter: JITTER, seed: SEED * 31 + k * 3 + i, ...u }));
  }).filter((u) => !u.closed);
  const token = `${RUN_ID}/${name}/${crypto.randomBytes(8).toString("hex")}`;
  const cfg = { log: path.join(dir, "upstream.jsonl"), control_port: c.control, token, instances };
  fs.writeFileSync(path.join(dir, "mock-config.json"), JSON.stringify(cfg, null, 2));
  const child = start(process.execPath, [path.join(KIT, "mock.mjs"), path.join(dir, "mock-config.json")], {}, path.join(dir, "mock.log"));
  for (const deadline = now() + 10_000; now() < deadline;) {
    if (child.exitCode !== null) throw new Error(`mock exited: ${fs.readFileSync(path.join(dir, "mock.log"), "utf8").trim().slice(-300)}`);
    try {
      const r = await fetch(`http://127.0.0.1:${c.control}/`, { signal: AbortSignal.timeout(1000) });
      const body = await r.json();
      if (body.token === token) return child;
      throw new Error(`control port ${c.control} answers for another run (${body.token})`);
    } catch (e) {
      if (String(e.message).startsWith("control port")) throw e;
      await sleep(100);
    }
  }
  throw new Error("mock did not start for " + name);
}

function lassoProfile(c) {
  const chains = CHAINS.map((chainId, k) => {
    const providers = upstreamUrls(c, k).map((u, i) => `      - id: "${CHAINS.length > 1 ? `c${chainId}_` : ""}up${i + 1}"\n        url: "${u}"`).join("\n");
    const key = `chain_${chainId}`;
    // LASSO_PROBE_MS sets monitoring.probe_interval_ms; LASSO_MONITORING adds other monitoring keys as JSON, e.g. {"http_heads_interval_ms":5000}.
    const monitoringKeys = { ...(process.env.LASSO_PROBE_MS ? { probe_interval_ms: Number(process.env.LASSO_PROBE_MS) } : {}), ...JSON.parse(process.env.LASSO_MONITORING || "{}") };
    const monitoring = Object.keys(monitoringKeys).length ? `    monitoring:\n${Object.entries(monitoringKeys).map(([k, v]) => `      ${k}: ${v}\n`).join("")}` : "";
    return `  ${key}:\n    chain_id: ${chainId}\n    block_time_ms: ${BLOCK_TIME_MS}\n${monitoring}    providers:\n${providers}`;
  }).join("\n");
  return `---\nname: Trial\nslug: trial\n---\nchains:\n${chains}\n`;
}

function startProxy(name, c, dir) {
  if (c.proxy === "lasso") {
    const rel = requireEnv("LASSO_REL");
    const data = path.join(dir, "lasso-data");
    fs.mkdirSync(path.join(data, "config/profiles"), { recursive: true });
    fs.mkdirSync(path.join(data, "benchmark_snapshots"), { recursive: true });
    fs.writeFileSync(path.join(data, "config/profiles/public.yml"),
      fs.readFileSync(path.join(KIT, "templates/public.yml"), "utf8").replace("{{CLOSED}}", c.closed));
    fs.writeFileSync(path.join(data, "config/profiles/trial.yml"), lassoProfile(c));
    const env = { ...process.env, LASSO_DATA_DIR: data, SECRET_KEY_BASE: crypto.randomBytes(64).toString("base64"), PHX_HOST: "localhost",
      LASSO_NODE_ID: `trial-${name}`, PORT: String(c.port),
      // The release always starts distributed; give each instance its own node name and pin its
      // distribution port inside this candidate's port block.
      RELEASE_NODE: `lasso_trial_${name.replace(/-/g, "_")}_${process.pid}@127.0.0.1`, RELEASE_COOKIE: crypto.randomBytes(16).toString("hex"),
      ERL_AFLAGS: `-kernel inet_dist_listen_min ${c.dist} inet_dist_listen_max ${c.dist}` };
    return start(path.join(rel, "bin/lasso"), ["start"], { env, cwd: dir }, path.join(dir, "proxy.log"));
  }
  if (c.proxy === "endpoint" && process.env.ENDPOINT_CMD) {
    const env = { ...process.env, TRIAL_UPSTREAMS: upstreamUrls(c).join(",") };
    return start("/bin/sh", ["-c", process.env.ENDPOINT_CMD], { env, cwd: dir }, path.join(dir, "proxy.log"));
  }
  return null;
}

// Lasso is healthy when its health route answers. A reader's endpoint is healthy once it
// answers eth_chainId through to the mocks. Either gets ENDPOINT_WAIT_S seconds (default 120).
async function waitHealthy(c, child) {
  const deadline = now() + Number(process.env.ENDPOINT_WAIT_S || 120) * 1000;
  for (;;) {
    if (child && child.exitCode !== null) throw new Error("proxy exited during startup");
    if (now() > deadline) throw new Error(c.proxy === "endpoint" ? "ENDPOINT_URL did not answer eth_chainId" : "proxy did not become healthy");
    if (c.proxy === "endpoint") {
      try { const r = await postJson(process.env.ENDPOINT_URL, { jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }, 2000); if (r.json?.result) return now(); } catch {}
      await sleep(500);
      continue;
    }
    try { const r = await fetch(`http://127.0.0.1:${c.port}/api/health`, { signal: AbortSignal.timeout(1000) }); if (r.ok) return now(); } catch {}
    await sleep(50);
  }
}

function printEndpointUpstreams(c) {
  if (REAL) return;
  const lines = upstreamUrls(c).map((u, i) => `  up${i + 1} ${u}${scenario.up[i]?.closed ? " (closed in this scenario)" : ""}`);
  console.log(`${RUN_ID} endpoint: mock upstreams for chain ${CHAINS[0]}\n${lines.join("\n")}\n${RUN_ID} endpoint: waiting for ${process.env.ENDPOINT_URL}`);
}

// ---------- request senders ----------
async function postJson(url, body, timeoutMs = CLIENT_TIMEOUT_MS) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch {}
  return { status: r.status, json, text: json ? undefined : text.slice(0, 200) };
}

function makeSender(name, c) {
  const urls = upstreamUrls(c);
  if (name === "direct") return (body) => postJson(urls[0], body);
  if (name === "race2") {
    // A client that races two endpoints on every call; the first JSON-RPC result wins.
    return async (body) => {
      const attempts = urls.slice(0, 2).map((u, i) => postJson(u, body).then((r) => {
        if (r.status === 200 && r.json && r.json.result !== undefined) return { ...r, winner: `up${i + 1}` };
        throw Object.assign(new Error("rpc_error"), { resp: r });
      }));
      try { return await Promise.any(attempts); }
      catch (e) { const last = e.errors.map((x) => x.resp).filter(Boolean).pop(); if (last) return last; throw e.errors[e.errors.length - 1]; }
    };
  }
  if (name === "endpoint") return (body) => postJson(process.env.ENDPOINT_URL, body);
  return (body) => postJson(`http://127.0.0.1:${c.port}${routeFor(c)}`, body);
}

// Builds the schedule: [{ at_ms, seq, method }]. Reads at RATE per second, sends either as a
// burst of `broadcast` at RATE per second or every `sends_every_ms` alongside the reads.
function schedule() {
  if (scenario.broadcast) return Array.from({ length: scenario.broadcast }, (_, i) => ({ at: (i * 1000) / RATE, seq: i, method: "eth_sendRawTransaction", nonce: i }));
  const n = DURATION_S * RATE;
  const reads = methodSequence(n).map((m, i) => ({ at: (i * 1000) / RATE, seq: i, method: m }));
  if (!scenario.sends_every_ms) return reads;
  const sends = Array.from({ length: Math.floor((DURATION_S * 1000) / scenario.sends_every_ms) }, (_, k) =>
    ({ at: k * scenario.sends_every_ms + 100, seq: 100_000 + k, method: "eth_sendRawTransaction", nonce: k }));
  return [...reads, ...sends].sort((a, b) => a.at - b.at);
}

async function applySwitch(c, meta, runStart) {
  const wait = runStart + scenario.switch_at_s * 1000 - now();
  if (wait > 0) await sleep(wait);
  meta.switch_at = now();
  meta.switch_since_ready_ms = meta.switch_at - runStart;
  const apply = async (changes) => {
    for (const [inst, change] of Object.entries(changes)) {
      await fetch(`http://127.0.0.1:${c.control}/config/${inst}`, { method: "POST", body: JSON.stringify(change) });
    }
  };
  await apply(scenario.switch);
  for (const step of scenario.then ?? []) {
    const later = runStart + step.at_s * 1000 - now();
    if (later > 0) await sleep(later);
    await apply(step.switch);
  }
}

async function pollRealHead() {
  const rpc = async (method, params) => (await postJson(REAL[0], { jsonrpc: "2.0", id: 1, method, params }, 5000)).json?.result;
  const poll = async () => { try { const h = await rpc("eth_blockNumber", []); if (h) realHead = Number(BigInt(h)); } catch {} };
  const findTxs = async () => {
    for (let n = realHead - 3; n > realHead - 23; n--) {
      try { const b = await rpc("eth_getBlockByNumber", [hex(n), false]); if (b?.transactions?.length) return (realTxs = b.transactions.slice(0, 50)); } catch {}
    }
  };
  while (realHead === null) { await poll(); if (realHead === null) await sleep(1000); }
  await findTxs();
  if (!realTxs.length) throw new Error("found no transactions in the 20 blocks below the head of the first UPSTREAMS URL");
  const heads = setInterval(poll, 1000);
  const txs = setInterval(findTxs, 15_000);
  return { stop: () => { clearInterval(heads); clearInterval(txs); } };
}

async function runWorkload(name, c, dir, meta, startAt) {
  const send = makeSender(name, c);
  const rec = fs.createWriteStream(path.join(dir, "client.jsonl"));
  await sleep(startAt - now());
  const runStart = now();
  const switching = scenario.switch ? applySwitch(c, meta, runStart) : null;

  const sendOne = (req, extra = {}) => {
    const { method } = req;
    const seq = req.id - 1;
    const tag = tagOfReq(req);
    const body = { jsonrpc: "2.0", id: req.id, method, params: req.params };
    const tSend = now();
    const headAtSend = REAL ? realHead : trueHead(tSend);
    return send(body).then((r) => {
      const tRecv = now();
      const headAtRecv = REAL ? realHead : trueHead(tRecv);
      const result = r.json && !Array.isArray(r.json) ? r.json.result : undefined;
      const error = r.json && !Array.isArray(r.json) ? r.json.error : undefined;
      // rpc_ok: a JSON-RPC result arrived. ok: that result also passed the checks below.
      const rpcOk = r.status === 200 && result !== undefined && !error;
      let dataProblem = null;
      if (rpcOk && method === "eth_getTransactionReceipt" && result === null) dataProblem = "null_receipt";
      if (!REAL && rpcOk && method === "eth_getLogs" && req.expectLogs) dataProblem = checkLogs(result, req);
      if (rpcOk && method === "eth_chainId" && result !== hex(CHAINS[0])) dataProblem = "wrong_chain";
      if (rpcOk && method === "eth_sendRawTransaction" && result !== txHash(req.params[0])) dataProblem = "wrong_tx_hash";
      const ok = rpcOk && !dataProblem;
      const served = ok ? servedBlock(method, result) : null;
      rec.write(JSON.stringify({ seq, method, tag, ...extra, t_send: tSend, t_recv: tRecv, latency_ms: tRecv - tSend, since_ready_ms: tSend - runStart,
        status: r.status, rpc_ok: rpcOk, ok, error: error ? { code: error.code, message: String(error.message).slice(0, 160) } : (ok ? undefined : (r.text ?? "non-jsonrpc")),
        served_block: served, head_at_send: headAtSend, head_at_recv: headAtRecv, lag_blocks: served !== null ? headAtRecv - served : null,
        data_problem: dataProblem, winner: r.winner, result: method === "eth_sendRawTransaction" ? result : undefined }) + "\n");
      return ok;
    }).catch((e) => {
      const tRecv = now();
      const cause = e?.cause?.code || e?.name || String(e);
      rec.write(JSON.stringify({ seq, method, tag, ...extra, t_send: tSend, t_recv: tRecv, latency_ms: tRecv - tSend, since_ready_ms: tSend - runStart,
        status: 0, rpc_ok: false, ok: false, error: cause, head_at_send: headAtSend }) + "\n");
      return false;
    });
  };

  let requests;
  if (scenario.backfill) {
    // Each pass walks its span window by window and moves on after a failed window, as an
    // indexer without its own retries would. Passes start on a fixed clock and may overlap.
    const { span, window, every_ms } = scenario.backfill;
    const perPass = Math.ceil(span / window);
    const passes = Math.max(1, Math.floor((DURATION_S * 1000) / every_ms));
    const runPass = async (pass) => {
      const wait = runStart + pass * every_ms - now();
      if (wait > 0) await sleep(wait);
      const from = headNow() - 10_000 - span;
      for (let w = 0; w < perPass; w++) {
        const lo = from + w * window;
        await sendOne(getLogs(pass * perPass + w, lo, Math.min(lo + window, from + span) - 1), { pass, window: w });
      }
    };
    await Promise.all(Array.from({ length: passes }, (_, pass) => runPass(pass)));
    requests = passes * perPass;
  } else {
    const plan = schedule();
    const pending = [];
    for (const { at, seq, method, nonce } of plan) {
      const wait = runStart + at - now();
      if (wait > 0) await sleep(wait);
      pending.push(sendOne(buildRequest(seq, method, nonce)));
    }
    await Promise.all(pending);
    if (plan.some((p) => p.method === "eth_sendRawTransaction")) await sleep(5000);
    requests = plan.length;
  }
  if (switching) await switching;
  await new Promise((r) => rec.end(r));
  return { run_start: runStart, run_end: now(), requests };
}

async function idleRun(name, c, dir, child) {
  // Time from process start to first successful RPC response on every chain, then pure idle.
  const t0 = child.startedAt;
  const firstOk = {};
  for (const chain of CHAINS) {
    while (!firstOk[chain]) {
      try { const r = await postJson(`http://127.0.0.1:${c.port}${routeFor(c, chain)}`, { jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }, 2000);
        if (r.status === 200 && r.json?.result) firstOk[chain] = now(); } catch {}
      if (!firstOk[chain]) await sleep(50);
    }
  }
  const samples = [];
  const idleStart = now();
  let prev = null;
  while (now() - idleStart < Number(process.env.IDLE_S || scenario.idle_s) * 1000) {
    const t = now();
    const s = processTree(child.pid);
    samples.push({ t, since_idle_s: (t - idleStart) / 1000, rss_mb: +(s.rss_kb / 1024).toFixed(1), cpu_s: s.cpu_s,
      cpu_pct: prev ? +((100 * (s.cpu_s - prev.cpu_s)) / ((t - prev.t) / 1000)).toFixed(2) : null, procs: s.procs });
    prev = { t, cpu_s: s.cpu_s };
    await sleep(10_000);
  }
  const first = Math.min(...Object.values(firstOk)), last = Math.max(...Object.values(firstOk));
  fs.writeFileSync(path.join(dir, "resources.json"), JSON.stringify({ start_to_first_success_ms: first - t0, start_to_all_chains_ms: last - t0, idle_start: idleStart, idle_end: now(), samples }, null, 2));
  return { start_to_first_success_ms: first - t0, start_to_all_chains_ms: last - t0, idle_start: idleStart, idle_end: now() };
}

// Every candidate is prepared (mocks up, proxy healthy) before any workload starts, then all
// workloads start at the same moment.
async function prepare(name) {
  const c = CANDIDATES[name];
  const dir = path.join(OUT, name);
  fs.mkdirSync(dir);
  const meta = { scenario: scenarioName, candidate: name, run_id: RUN_ID, rate: RATE, duration_s: DURATION_S, jitter: JITTER, seed: SEED, real: Boolean(REAL), idle_s: scenario.idle_s ?? null,
    upstreams: scenario.up, chains: CHAINS, switch_at_s: scenario.switch_at_s ?? null, switch: scenario.switch ?? null, then: scenario.then ?? null,
    block_pattern: process.env.BLOCK_PATTERN ?? null, sends_every_ms: scenario.sends_every_ms ?? null, backfill: scenario.backfill ?? null };
  const ctx = { name, c, dir, meta, mock: null, proxy: null };
  try {
    await assertPortsFree(c);
    ctx.mock = await startMocks(name, c, dir);
    meta.mock_ready = now();
    if (c.proxy) {
      ctx.proxy = startProxy(name, c, dir);
      meta.proxy_started = ctx.proxy?.startedAt ?? now();
      meta.proxy_pid = ctx.proxy?.pid ?? null;
      if (c.proxy === "endpoint") printEndpointUpstreams(c);
      if (!scenario.idle_s) {
        meta.healthy_at = await waitHealthy(c, ctx.proxy);
        meta.start_to_healthy_ms = meta.healthy_at - meta.proxy_started;
      }
    }
  } catch (e) {
    meta.error = String(e?.stack || e);
  }
  return ctx;
}

async function execute({ name, c, dir, meta, proxy }, startAt) {
  if (meta.error) return;
  try {
    meta.load_avg_start = os.loadavg().map((x) => +x.toFixed(2));
    if (scenario.idle_s) return Object.assign(meta, await idleRun(name, c, dir, proxy));
    const s0 = proxy && processTree(proxy.pid);
    Object.assign(meta, await runWorkload(name, c, dir, meta, startAt));
    const s1 = proxy && processTree(proxy.pid);
    if (proxy) meta.resources_during_run = { rss_mb_end: +(s1.rss_kb / 1024).toFixed(1), cpu_s: +(s1.cpu_s - s0.cpu_s).toFixed(2) };
  } catch (e) {
    meta.error = String(e?.stack || e);
  }
}

async function finish({ name, dir, meta, mock, proxy }) {
  await stop(proxy);
  await stop(mock, 3000);
  meta.stopped_at = now();
  meta.load_avg_end = os.loadavg().map((x) => +x.toFixed(2));
  fs.writeFileSync(path.join(dir, "meta.json"), JSON.stringify(meta, null, 2));
  console.log(`${RUN_ID} ${name} done${meta.error ? " ERROR " + meta.error : ""}`);
}

fs.writeFileSync(path.join(OUT, "run.json"), JSON.stringify({ scenario: scenarioName, candidates: candNames, duration_s: DURATION_S }, null, 2));
const realPoller = REAL ? await pollRealHead() : null;
const ctxs = await Promise.all(candNames.map(prepare));
const startAt = now() + 250;
await Promise.all(ctxs.map((ctx) => execute(ctx, startAt)));
realPoller?.stop();
await Promise.all(ctxs.map(finish));
process.exit(ctxs.some((ctx) => ctx.meta.error) ? 1 : 0);
