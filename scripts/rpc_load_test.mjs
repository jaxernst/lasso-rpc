#!/usr/bin/env node
"use strict";

// Node 18+ required for global fetch
const MIN_NODE_MAJOR = 18;
const nodeMajor = Number(process.versions.node.split(".")[0]);
if (Number.isFinite(nodeMajor) && nodeMajor < MIN_NODE_MAJOR) {
  console.error(
    `This script requires Node ${MIN_NODE_MAJOR}+ (found ${process.versions.node}).`
  );
  process.exit(1);
}

// -----------------------------
// Argument parsing
// -----------------------------
function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    url:
      process.env.RPC_URL || "http://localhost:4000/rpc/round-robin/ethereum",
    concurrency: Number(process.env.CONCURRENCY) || 16,
    duration: Number(process.env.DURATION) || 30, // seconds
    timeout: Number(process.env.TIMEOUT) || 10000, // ms
    verbose: Boolean(process.env.VERBOSE) || false,
    methods: null, // comma-separated names
    rpsLimit: Number(process.env.RPS_LIMIT) || null, // requests per second limit
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = () => args[i + 1];
    switch (a) {
      case "--url":
      case "-u":
        opts.url = next();
        i++;
        break;
      case "--concurrency":
      case "-c":
        opts.concurrency = Number(next());
        i++;
        break;
      case "--duration":
      case "-d":
        opts.duration = Number(next());
        i++;
        break;
      case "--timeout":
      case "-t":
        opts.timeout = Number(next());
        i++;
        break;
      case "--methods":
      case "-m":
        opts.methods = String(next());
        i++;
        break;
      case "--rps-limit":
      case "-r":
        opts.rpsLimit = Number(next());
        i++;
        break;
      case "--verbose":
      case "-v":
        opts.verbose = true;
        break;
      case "--help":
      case "-h":
        printHelpAndExit();
        break;
      default:
        // ignore unknowns for simplicity
        break;
    }
  }

  return opts;
}

function printHelpAndExit() {
  console.log(
    `Usage: node scripts/rpc_load_test.mjs [options]\n\n` +
      `Options:\n` +
      `  -u, --url <url>           RPC endpoint (default: http://localhost:4000/rpc/round-robin/ethereum)\n` +
      `  -c, --concurrency <n>     Concurrent workers (default: 16)\n` +
      `  -d, --duration <sec>      Test duration seconds (default: 30)\n` +
      `  -t, --timeout <ms>        Per-request timeout ms (default: 10000)\n` +
      `  -m, --methods <list>      Comma-separated method names to include\n` +
      `  -r, --rps-limit <n>       Maximum requests per second (default: unlimited)\n` +
      `  -v, --verbose             Log each request timing\n`
  );
  process.exit(0);
}

const options = parseArgs(process.argv);

// -----------------------------
// Utilities
// -----------------------------
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
const nowNs = () => process.hrtime.bigint();
const nsToMs = (ns) => Number(ns) / 1e6;
const toHex = (n) => "0x" + BigInt(n).toString(16);
const clamp = (n, min, max) => Math.max(min, Math.min(max, n));

function hexStrip(hex) {
  return hex.startsWith("0x") ? hex.slice(2) : hex;
}

function pad32(hexNo0x) {
  return hexNo0x.padStart(64, "0");
}

function percentile(values, p) {
  if (!values || values.length === 0) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[clamp(idx, 0, sorted.length - 1)];
}

// -----------------------------
// Fixtures and param builders
// -----------------------------
const ADDRS = {
  WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  UNISWAP_V2_ROUTER: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
  VITALIK: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
};

const TOPICS = {
  TRANSFER:
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
};

function data_balanceOf(address) {
  const selector = "70a08231"; // balanceOf(address)
  const addr = pad32(hexStrip(address.toLowerCase()));
  return "0x" + selector + addr;
}

// -----------------------------
// Bootstrap dynamic context
// -----------------------------
async function rpc(url, body, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    const json = await res
      .json()
      .catch(() => ({ error: { code: -32700, message: "Invalid JSON" } }));
    return { ok: res.ok && !json.error, status: res.status, json };
  } catch (err) {
    return { ok: false, status: 0, error: String((err && err.message) || err) };
  } finally {
    clearTimeout(timer);
  }
}

async function getLatestBlockNumber(url, timeoutMs) {
  const body = { jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] };
  const { ok, json } = await rpc(url, body, timeoutMs);
  if (!ok || !json || !json.result) return null;
  return Number(BigInt(json.result));
}

async function getBlockByNumber(url, num, fullTx = false, timeoutMs = 10000) {
  const param = typeof num === "string" ? num : toHex(num);
  const body = {
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getBlockByNumber",
    params: [param, Boolean(fullTx)],
  };
  const { ok, json } = await rpc(url, body, timeoutMs);
  if (!ok || !json) return null;
  return json.result || null;
}

async function findRecentTxHash(
  url,
  startNumber,
  searchBack = 20,
  timeoutMs = 10000
) {
  let n = startNumber;
  for (let i = 0; i < searchBack && n >= 0; i++, n--) {
    const block = await getBlockByNumber(url, n, false, timeoutMs);
    if (
      block &&
      Array.isArray(block.transactions) &&
      block.transactions.length > 0
    ) {
      return { txHash: block.transactions[0], blockHash: block.hash };
    }
  }
  // Fallback: latest block (hash) even if no tx, txHash undefined
  const latest = await getBlockByNumber(url, "latest", false, timeoutMs);
  return { txHash: undefined, blockHash: latest && latest.hash };
}

async function bootstrapContext(url, timeoutMs) {
  const latestNum = await getLatestBlockNumber(url, timeoutMs);
  if (latestNum == null) {
    return { latestNumber: 0, txHash: undefined, blockHash: undefined };
  }
  const found = await findRecentTxHash(url, latestNum, 30, timeoutMs);
  return {
    latestNumber: latestNum,
    txHash: found.txHash,
    blockHash: found.blockHash,
  };
}

// -----------------------------
// Method pool
// -----------------------------
function makeMethodPool(ctxRef) {
  const methods = [
    {
      name: "eth_blockNumber",
      params: () => [],
    },
    {
      name: "eth_chainId",
      params: () => [],
    },
    {
      name: "eth_gasPrice",
      params: () => [],
    },
    {
      name: "eth_maxPriorityFeePerGas",
      params: () => [],
    },
    {
      name: "eth_feeHistory",
      params: () => [10, "latest", [10, 50, 90]],
    },
    {
      name: "eth_getBalance",
      params: () => [ADDRS.VITALIK, "latest"],
    },
    {
      name: "eth_getTransactionCount",
      params: () => [ADDRS.VITALIK, "latest"],
    },
    {
      name: "eth_getCode",
      params: () => [ADDRS.WETH, "latest"],
    },
    {
      name: "eth_getStorageAt",
      params: () => [ADDRS.WETH, "0x0", "latest"],
    },
    {
      name: "eth_getBlockByNumber",
      params: () => {
        const latest = ctxRef.latestNumber || 0;
        const randBack = Math.floor(Math.random() * 1000);
        const n = latest > 0 ? Math.max(0, latest - randBack) : "latest";
        return [typeof n === "number" ? toHex(n) : n, false];
      },
    },
    {
      name: "eth_getBlockByHash",
      params: () => [ctxRef.blockHash || "0x0", false],
      enabled: () => Boolean(ctxRef.blockHash),
    },
    {
      name: "eth_getTransactionByHash",
      params: () => [ctxRef.txHash || "0x0"],
      enabled: () => Boolean(ctxRef.txHash),
    },
    {
      name: "eth_getTransactionReceipt",
      params: () => [ctxRef.txHash || "0x0"],
      enabled: () => Boolean(ctxRef.txHash),
    },
    {
      name: "eth_call",
      params: () => [
        { to: ADDRS.WETH, data: data_balanceOf(ADDRS.VITALIK) },
        "latest",
      ],
    },
    {
      name: "eth_estimateGas",
      params: () => [
        {
          to: ADDRS.WETH,
          data: data_balanceOf(ADDRS.VITALIK),
          from: ADDRS.VITALIK,
        },
      ],
    },
    {
      name: "eth_getLogs",
      params: () => {
        const latest = ctxRef.latestNumber || 0;
        const span = 5000;
        const from = latest > 0 ? Math.max(0, latest - span) : 0;
        return [
          {
            fromBlock: toHex(from),
            toBlock: "latest",
            address: ADDRS.WETH,
            topics: [TOPICS.TRANSFER],
          },
        ];
      },
    },
  ];

  return methods;
}

function filterMethods(methods, allowListCsv) {
  if (!allowListCsv) return methods;
  const allow = new Set(
    String(allowListCsv)
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
  );
  return methods.filter((m) => allow.has(m.name));
}

// -----------------------------
// Load generation
// -----------------------------
async function run() {
  console.log(`RPC load test starting...`);
  console.log(`  url=${options.url}`);
  console.log(`  concurrency=${options.concurrency}`);
  console.log(`  duration=${options.duration}s`);
  console.log(`  timeout=${options.timeout}ms`);
  if (options.methods) console.log(`  methods=${options.methods}`);
  if (options.rpsLimit) console.log(`  rps limit=${options.rpsLimit}`);
  if (options.verbose) console.log(`  verbose logging enabled`);

  const ctx = await bootstrapContext(options.url, options.timeout);
  const ctxRef = {
    latestNumber: ctx.latestNumber,
    txHash: ctx.txHash,
    blockHash: ctx.blockHash,
  };
  console.log(`Bootstrap:`);
  console.log(`  latest block number: ${ctxRef.latestNumber}`);
  console.log(`  sample block hash:   ${ctxRef.blockHash || "(not found)"}`);
  console.log(`  sample tx hash:      ${ctxRef.txHash || "(not found)"}`);

  const methodPool = filterMethods(
    makeMethodPool(ctxRef).filter((m) => !m.enabled || m.enabled()),
    options.methods
  );
  if (methodPool.length === 0) {
    console.error("No methods to test (after filtering).");
    process.exit(1);
  }

  let nextId = 1;
  let stop = false;
  const endAt = Date.now() + options.duration * 1000;
  const allDurations = [];
  const perMethod = new Map(); // name -> { count, errors, durations[] }
  const inFlight = new Set();

  // Rate limiting setup
  let rateLimiter = null;
  if (options.rpsLimit && options.rpsLimit > 0) {
    const tokensPerMs = options.rpsLimit / 1000;
    let tokens = options.rpsLimit; // Start with full bucket
    let lastRefill = Date.now();

    rateLimiter = {
      async acquire() {
        while (!stop) {
          const now = Date.now();
          const elapsed = now - lastRefill;

          // Refill tokens based on elapsed time
          tokens = Math.min(options.rpsLimit, tokens + elapsed * tokensPerMs);
          lastRefill = now;

          if (tokens >= 1) {
            tokens -= 1;
            return; // Token acquired
          }

          // Wait for next token to be available
          const waitMs = (1 - tokens) / tokensPerMs;
          await sleep(Math.ceil(waitMs));
        }
      },
    };
  }

  let windowReq = 0;
  let windowErr = 0;
  let windowDur = [];
  const startedAt = Date.now();
  let tickCount = 0;

  const ticker = setInterval(() => {
    tickCount++;
    const rps = windowReq;
    const err = windowErr;
    const avg = windowDur.length
      ? windowDur.reduce((a, b) => a + b, 0) / windowDur.length
      : 0;
    const p50 = percentile(windowDur, 50);
    const p95 = percentile(windowDur, 95);
    const p99 = percentile(windowDur, 99);
    const elapsed = Math.round((Date.now() - startedAt) / 1000);
    process.stdout.write(
      `t=${elapsed}s rps=${rps} err=${err} lat(ms) avg=${avg.toFixed(
        1
      )} p95=${p95.toFixed(1)} p99=${p99.toFixed(1)}\n`
    );
    windowReq = 0;
    windowErr = 0;
    windowDur = [];
    if (Date.now() >= endAt) stop = true;
  }, 1000);

  async function doRequest(methodDef) {
    const id = nextId++;
    const body = {
      jsonrpc: "2.0",
      id,
      method: methodDef.name,
      params: methodDef.params(),
    };
    const t0 = nowNs();
    const res = await rpc(options.url, body, options.timeout);
    const dtMs = nsToMs(nowNs() - t0);

    windowReq++;
    windowDur.push(dtMs);
    allDurations.push(dtMs);
    const stats = perMethod.get(methodDef.name) || {
      count: 0,
      errors: 0,
      durations: [],
    };
    stats.count++;
    stats.durations.push(dtMs);
    if (!res.ok) {
      stats.errors++;
      windowErr++;
    }
    perMethod.set(methodDef.name, stats);
    if (options.verbose) {
      const status = res.ok ? "OK" : "ERR";
      process.stdout.write(
        `${methodDef.name} ${status} ${dtMs.toFixed(1)}ms\n`
      );
    }
  }

  async function worker() {
    while (!stop) {
      // Acquire rate limit token if rate limiting is enabled
      if (rateLimiter) {
        await rateLimiter.acquire();
      }

      const m = methodPool[Math.floor(Math.random() * methodPool.length)];
      const p = doRequest(m);
      inFlight.add(p);
      try {
        await p;
      } finally {
        inFlight.delete(p);
      }
    }
  }

  const workers = Array.from({ length: options.concurrency }, () => worker());
  await Promise.race([
    Promise.all(workers),
    (async () => {
      while (!stop) await sleep(50);
    })(),
  ]);

  // Wait for in-flight requests to finish
  while (inFlight.size > 0) {
    await Promise.allSettled(Array.from(inFlight));
  }
  clearInterval(ticker);

  // Final summary
  const totalSec = Math.max(1, Math.round((Date.now() - startedAt) / 1000));
  const totalCount = Array.from(perMethod.values()).reduce(
    (a, s) => a + s.count,
    0
  );
  const totalErrors = Array.from(perMethod.values()).reduce(
    (a, s) => a + (s.errors || 0),
    0
  );
  const overallAvg = allDurations.length
    ? allDurations.reduce((a, b) => a + b, 0) / allDurations.length
    : 0;
  const overallP50 = percentile(allDurations, 50);
  const overallP95 = percentile(allDurations, 95);
  const overallP99 = percentile(allDurations, 99);

  console.log("\n=== Summary ===");
  console.log(
    `Requests: ${totalCount}  Errors: ${totalErrors}  Duration: ${totalSec}s  RPS: ${(
      totalCount / totalSec
    ).toFixed(1)}`
  );
  console.log(
    `Latency ms: avg=${overallAvg.toFixed(1)} p50=${overallP50.toFixed(
      1
    )} p95=${overallP95.toFixed(1)} p99=${overallP99.toFixed(1)}`
  );
  console.log("\nPer-method:");
  const byName = Array.from(perMethod.entries()).sort(
    (a, b) => b[1].count - a[1].count
  );
  for (const [name, s] of byName) {
    const p50 = percentile(s.durations, 50).toFixed(1);
    const p95 = percentile(s.durations, 95).toFixed(1);
    const p99 = percentile(s.durations, 99).toFixed(1);
    const avg = (
      s.durations.reduce((a, b) => a + b, 0) / s.durations.length
    ).toFixed(1);
    console.log(
      `- ${name}: count=${s.count} errors=${
        s.errors || 0
      } lat(ms) avg=${avg} p50=${p50} p95=${p95} p99=${p99}`
    );
  }
}

run().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
