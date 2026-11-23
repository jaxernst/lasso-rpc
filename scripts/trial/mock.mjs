// Deterministic EVM JSON-RPC mock upstreams (chain id 137 unless set per instance, one block every 2 s).
// Usage: node mock.mjs <config.json>
// config: { log: "path.jsonl", control_port: N, token: "run identity", instances: [{ name, port, chain_id, latency_ms, jitter,
//           behind, stall, rate_429, refuse_methods, hang, send_timeout, max_range, range_error, seed }] }
// max_range caps the blocks one eth_getLogs call may span (to - from + 1). A wider range gets
// range_error, a JSON-RPC error whose message may contain {cap}.
// The log has one "call" line per request item when it arrives and one "outcome" line
// (ok, error, 429 or hang) per item, both keyed by instance and call number.
import http from "node:http";
import fs from "node:fs";
import crypto from "node:crypto";
import { pathToFileURL } from "node:url";
import { txHash } from "./tx.mjs";

export const START_MS = Date.parse("2026-11-20T00:00:00Z");
export const BLOCK_MS = 2000;
export const BASE_BLOCK = 70_000_000;
// BLOCK_PATTERN=burst: 20 s cycles of 10 s at 250 ms blocks, then 10 s at 2 s blocks (45 blocks a cycle).
const BURST = process.env.BLOCK_PATTERN === "burst";
const burstHead = (ms) => {
  const within = ms % 20_000;
  return Math.floor(ms / 20_000) * 45 + (within < 10_000 ? Math.floor(within / 250) : 40 + Math.floor((within - 10_000) / 2000));
};
export const trueHead = (now = Date.now()) => BASE_BLOCK + (BURST ? burstHead(now - START_MS) : Math.floor((now - START_MS) / BLOCK_MS));

const hex = (n) => "0x" + BigInt(n).toString(16);
const word = (n) => "0x" + BigInt(n).toString(16).padStart(64, "0");
const blockHash = (n) => "0x" + crypto.createHash("sha256").update("block:" + n).digest("hex");
// Each block holds one transaction. Its hash starts with the block number, which is how
// eth_getTransactionReceipt knows where any harness hash was mined.
const blockTxHash = (n) => "0x" + BigInt(n).toString(16).padStart(16, "0") + crypto.createHash("sha256").update("tx:" + n).digest("hex").slice(0, 48);
const blockTimestamp = (n) => Math.floor((START_MS + (n - BASE_BLOCK) * BLOCK_MS) / 1000);
const ZERO32 = "0x" + "0".repeat(64);
const ZERO20 = "0x" + "0".repeat(40);

function mulberry32(a) {
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function block(n, full) {
  if (n < 0) return null;
  return {
    number: hex(n), hash: blockHash(n), parentHash: n === 0 ? ZERO32 : blockHash(n - 1),
    nonce: "0x0000000000000000", sha3Uncles: "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
    logsBloom: "0x" + "0".repeat(512), transactionsRoot: "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
    stateRoot: "0x" + crypto.createHash("sha256").update("state:" + n).digest("hex"),
    receiptsRoot: "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
    miner: ZERO20, difficulty: "0x0", totalDifficulty: "0x0", extraData: "0x", size: "0x220",
    gasLimit: hex(30_000_000), gasUsed: "0x0", timestamp: hex(blockTimestamp(n)),
    transactions: full ? [{ hash: blockTxHash(n), blockHash: blockHash(n), blockNumber: hex(n), transactionIndex: "0x0", from: ZERO20, to: ZERO20,
      nonce: "0x0", value: "0x0", gas: hex(21000), gasPrice: hex(30_000_000_000), input: "0x", type: "0x0" }] : [blockTxHash(n)], uncles: [], baseFeePerGas: hex(30_000_000_000), mixHash: ZERO32,
    withdrawals: [], withdrawalsRoot: "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
  };
}

// Tags make each client request traceable through a proxy: the harness embeds a
// request sequence number in params, the mock logs it.
function tagOf(method, params = []) {
  try {
    switch (method) {
      case "eth_getBalance":
      case "eth_getTransactionCount":
        return String(params[0]).toLowerCase();
      case "eth_call":
        return String(params[0]?.data ?? params[0]?.input ?? "").toLowerCase();
      case "eth_getLogs":
        return String(params[0]?.address ?? "").toLowerCase();
      case "eth_getTransactionReceipt":
        return String(params[0]).toLowerCase();
      case "eth_sendRawTransaction":
        return String(params[0]).toLowerCase();
      default:
        return undefined;
    }
  } catch { return undefined; }
}

class Instance {
  constructor(cfg, logStream) {
    this.cfg = { chain_id: 137, latency_ms: 20, jitter: 0, behind: 0, rate_429: 0, refuse_methods: [], hang: false, send_timeout: false,
      max_range: 0, range_error: { code: -32000, message: "query exceeds max block range {cap}" }, ...cfg };
    this.rand = mulberry32(cfg.seed ?? (cfg.port * 7919));
    this.log = logStream;
    this.sent = new Set();
  }
  // `stall` freezes the head where it stood when the flag was set; clearing it returns to the chain.
  head() {
    const h = trueHead() - this.cfg.behind;
    if (!this.cfg.stall) { this.stalledAt = undefined; return h; }
    return (this.stalledAt ??= h);
  }
  resolveTag(tag) {
    const h = this.head();
    if (tag === undefined || tag === null || tag === "latest" || tag === "pending") return h;
    if (tag === "finalized") return h - 64;
    if (tag === "safe") return h - 32;
    if (tag === "earliest") return 0;
    if (typeof tag === "object") {
      if (tag.blockNumber !== undefined) return this.resolveTag(tag.blockNumber);
      if (tag.blockHash !== undefined) return undefined;
    }
    if (typeof tag === "string" && tag.startsWith("0x")) return Number(BigInt(tag));
    return h;
  }
  delay() {
    const { latency_ms, jitter } = this.cfg;
    const j = latency_ms * jitter * (this.rand() * 2 - 1);
    return Math.max(0, latency_ms + j);
  }
  handle(req) {
    const { id = null, method, params = [] } = req ?? {};
    const ok = (result) => ({ jsonrpc: "2.0", id, result });
    const err = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });
    if (!req || typeof method !== "string") return err(-32600, "invalid request");
    if (this.cfg.refuse_methods.includes(method)) return err(-32601, `the method ${method} does not exist/is not available`);
    const h = this.head();
    const atBlock = (tag) => {
      const n = this.resolveTag(tag);
      if (n === undefined) return { error: err(-32000, "header not found") };
      if (n > h) return { error: err(-32000, "header not found") };
      return { n };
    };
    switch (method) {
      case "eth_chainId": return ok(hex(this.cfg.chain_id));
      case "net_version": return ok(String(this.cfg.chain_id));
      case "web3_clientVersion": return ok("trial-mock/v1.0.0");
      case "eth_syncing": return ok(false);
      case "eth_blockNumber": return ok(hex(h));
      case "eth_gasPrice": return ok(hex(30_000_000_000));
      case "eth_maxPriorityFeePerGas": return ok(hex(30_000_000_000));
      case "eth_getBlockByNumber": {
        const n = this.resolveTag(params[0]);
        return ok(n === undefined || n > h || n < 0 ? null : block(n, params[1]));
      }
      case "eth_getBlockByHash": {
        const want = String(params[0]).toLowerCase();
        for (let n = h; n > h - 2048; n--) if (blockHash(n) === want) return ok(block(n, params[1]));
        return ok(null);
      }
      case "eth_getBalance":
      case "eth_getTransactionCount": {
        const r = atBlock(params[1]); if (r.error) return r.error;
        return ok(hex(r.n));
      }
      case "eth_call": {
        const r = atBlock(params[1]); if (r.error) return r.error;
        return ok(word(r.n));
      }
      case "eth_estimateGas": return ok(hex(21000));
      case "eth_getCode": return ok("0x");
      case "eth_feeHistory": {
        const count = Math.min(Number(BigInt(params[0] ?? "0x1")), 1024);
        const newest = this.resolveTag(params[1]);
        if (newest === undefined || newest > h) return err(-32000, "header not found");
        const pct = Array.isArray(params[2]) ? params[2] : [];
        return ok({
          oldestBlock: hex(newest - count + 1),
          baseFeePerGas: Array(count + 1).fill(hex(30_000_000_000)),
          gasUsedRatio: Array(count).fill(0.5),
          reward: Array(count).fill(pct.map(() => hex(1_000_000_000))),
        });
      }
      case "eth_getLogs": {
        const f = params[0] ?? {};
        if (f.blockHash) return ok([]);
        const from = this.resolveTag(f.fromBlock ?? "latest");
        const to = this.resolveTag(f.toBlock ?? "latest");
        if (to > h || from > h) return err(-32000, "block range extends beyond current head block");
        if (from > to) return err(-32602, "invalid block range params");
        const cap = this.cfg.max_range;
        if (cap > 0 && to - from + 1 > cap) return err(this.cfg.range_error.code, this.cfg.range_error.message.replace("{cap}", String(cap)));
        const logs = [];
        for (let n = from; n <= to; n++) {
          if (n % 10 !== 0) continue;
          logs.push({ address: f.address ?? ZERO20, topics: [ZERO32], data: word(n), blockNumber: hex(n), blockHash: blockHash(n),
            transactionHash: blockTxHash(n), transactionIndex: "0x0", logIndex: "0x0", removed: false });
        }
        return ok(logs);
      }
      case "eth_getTransactionReceipt": {
        // Harness hashes encode the mined block in their first 16 hex digits.
        const hash = String(params[0]);
        const n = Number(BigInt("0x" + hash.slice(2, 18)));
        if (!(n <= h)) return ok(null);
        return ok({ transactionHash: hash, transactionIndex: "0x0", blockHash: blockHash(n), blockNumber: hex(n), from: ZERO20, to: ZERO20,
          cumulativeGasUsed: hex(21000), gasUsed: hex(21000), effectiveGasPrice: hex(30_000_000_000), contractAddress: null, logs: [],
          logsBloom: "0x" + "0".repeat(512), status: "0x1", type: "0x2" });
      }
      case "eth_getBlockReceipts": {
        const n = this.resolveTag(params[0]);
        return ok(n === undefined || n > h ? null : []);
      }
      case "eth_sendRawTransaction": {
        const raw = String(params[0]).toLowerCase();
        if (this.sent.has(raw)) return err(-32000, "already known");
        this.sent.add(raw);
        return ok(txHash(raw));
      }
      default: return err(-32601, `the method ${method} does not exist/is not available`);
    }
  }
  serve(httpReq, res, body) {
    const t = Date.now();
    let parsed;
    try { parsed = JSON.parse(body); } catch { parsed = null; }
    const items = Array.isArray(parsed) ? parsed : [parsed];
    const isSend = items.some((r) => r?.method === "eth_sendRawTransaction");
    const throttled = this.cfg.rate_429 > 0 && this.rand() < this.cfg.rate_429;
    const hang = this.cfg.hang || (this.cfg.send_timeout && isSend);
    const calls = items.map((r) => {
      const call = (this.calls = (this.calls ?? 0) + 1);
      this.log.write(JSON.stringify({ kind: "call", t, inst: this.cfg.name, call, m: r?.method, tag: tagOf(r?.method, r?.params), id: r?.id ?? null,
        batch: Array.isArray(parsed) ? items.length : 0, ua: httpReq.headers["user-agent"], p: JSON.stringify(r?.params ?? []).slice(0, 240) }) + "\n");
      return call;
    });
    const outcome = (outcomeOf) => calls.forEach((call, i) =>
      this.log.write(JSON.stringify({ kind: "outcome", t: Date.now(), inst: this.cfg.name, call, outcome: outcomeOf(i) }) + "\n"));
    if (hang) return outcome(() => "hang"); // accept the request, never answer
    setTimeout(() => {
      if (throttled) {
        outcome(() => "429");
        res.writeHead(429, { "content-type": "application/json", "retry-after": "1" });
        return res.end(JSON.stringify({ jsonrpc: "2.0", id: items[0]?.id ?? null, error: { code: 429, message: "Too Many Requests" } }));
      }
      const out = parsed === null ? { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }
        : Array.isArray(parsed) ? parsed.map((r) => this.handle(r)) : this.handle(parsed);
      const outs = Array.isArray(out) ? out : [out];
      outcome((i) => (outs[i]?.error ? "error" : "ok"));
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(out));
    }, this.delay());
  }
  listen() {
    this.server = http.createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        if (req.method !== "POST") { res.writeHead(200); return res.end("ok"); }
        this.serve(req, res, body);
      });
    });
    this.server.requestTimeout = 0;
    this.server.headersTimeout = 0;
    this.server.keepAliveTimeout = 65_000;
    return listenOn(this.server, this.cfg.port);
  }
}

// Resolves once the server is bound; a port already in use ends the process.
function listenOn(server, port) {
  return new Promise((resolve) => {
    server.once("error", (e) => { console.error(`mock: cannot listen on ${port}: ${e.code || e.message}`); process.exit(1); });
    server.listen(port, "127.0.0.1", resolve);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const log = fs.createWriteStream(cfg.log, { flags: "a" });
  log.on("error", () => {});
  const instances = Object.fromEntries(cfg.instances.map((c) => [c.name, new Instance(c, log)]));
  await Promise.all(Object.values(instances).map((i) => i.listen()));
  // The control port opens last and names the run, so a caller knows every instance is bound
  // and that it is talking to its own mock process.
  const control = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const m = req.url.match(/^\/config\/([^/?]+)/);
      res.writeHead(200, { "content-type": "application/json" });
      if (req.method === "POST" && m && instances[m[1]]) {
        Object.assign(instances[m[1]].cfg, JSON.parse(body || "{}"));
        return res.end(JSON.stringify(instances[m[1]].cfg));
      }
      res.end(JSON.stringify({ token: cfg.token ?? null, instances: Object.fromEntries(Object.entries(instances).map(([k, v]) => [k, v.cfg])) }));
    });
  });
  await listenOn(control, cfg.control_port);
  const stop = () => log.end(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
