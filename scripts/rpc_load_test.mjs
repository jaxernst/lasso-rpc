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
      process.env.RPC_URL || "http://localhost:4000/rpc/load-balanced/ethereum",
    host: process.env.HOST || null, // base host URL
    chains: process.env.CHAINS || null, // comma-separated chain names
    strategy: process.env.STRATEGY || "load-balanced", // routing strategy
    profile: process.env.PROFILE || null, // profile name (e.g., "default", "testnet")
    apiKey: process.env.API_KEY || null, // API key for authentication
    concurrency: Number(process.env.CONCURRENCY) || 16,
    duration: Number(process.env.DURATION) || 30, // seconds
    rampUpDuration: Number(process.env.RAMP_UP_DURATION) || null, // seconds (defaults to 10s or 20% of duration, whichever is smaller)
    timeout: Number(process.env.TIMEOUT) || 10000, // ms
    verbose: Boolean(process.env.VERBOSE) || false,
    methods: null, // comma-separated names
    rpsLimit: Number(process.env.RPS_LIMIT) || null, // requests per second limit (global or per-chain)
    chainRates: process.env.CHAIN_RATES || null, // comma-separated "chain:rate" pairs
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
      case "--host":
        opts.host = next();
        i++;
        break;
      case "--chains":
        opts.chains = String(next());
        i++;
        break;
      case "--strategy":
      case "-s":
        opts.strategy = String(next());
        i++;
        break;
      case "--profile":
      case "-p":
        opts.profile = String(next());
        i++;
        break;
      case "--api-key":
      case "-k":
        opts.apiKey = String(next());
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
      case "--ramp-up":
      case "--ramp-up-duration":
        opts.rampUpDuration = Number(next());
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
      case "--chain-rates":
        opts.chainRates = String(next());
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
      `  -u, --url <url>           RPC endpoint (default: http://localhost:4000/rpc/load-balanced/ethereum)\n` +
      `                             (ignored if --chains is used)\n` +
      `  --host <url>              Base host URL (default: http://localhost:4000)\n` +
      `                             (used with --chains)\n` +
      `  --chains <list>           Comma-separated chain names (e.g., "ethereum,base")\n` +
      `                             If specified, tests all chains in parallel\n` +
      `  -s, --strategy <name>     Routing strategy: load-balanced, fastest, latency-weighted\n` +
      `                             (default: load-balanced, used with --chains)\n` +
      `  -p, --profile <name>      Profile name (e.g., "default", "testnet")\n` +
      `                             If not specified, uses legacy routes (default profile)\n` +
      `  -k, --api-key <key>       API key for authentication (lasso_...)\n` +
      `                             Can also be set via API_KEY environment variable\n` +
      `  -c, --concurrency <n>     Concurrent workers per chain (default: 16)\n` +
      `  -d, --duration <sec>      Test duration seconds (default: 30)\n` +
      `  --ramp-up <sec>           Ramp-up duration seconds (default: 10s or 20% of duration, whichever is smaller)\n` +
      `                             Gradually increases RPS from 0 to target during this period\n` +
      `  -t, --timeout <ms>        Per-request timeout ms (default: 10000)\n` +
      `  -m, --methods <list>      Comma-separated method names to include\n` +
      `  -r, --rps-limit <n>       Maximum requests per second (default: unlimited)\n` +
      `                             If --chains is used, applies to each chain\n` +
      `  --chain-rates <list>      Per-chain rate limits: "chain1:rate1,chain2:rate2"\n` +
      `                             (e.g., "ethereum:100,base:50")\n` +
      `  -v, --verbose             Log each request timing\n` +
      `\n` +
      `Examples:\n` +
      `  # Single chain (existing behavior)\n` +
      `  node scripts/rpc_load_test.mjs --url http://localhost:4000/rpc/ethereum\n` +
      `\n` +
      `  # Multiple chains with default rate\n` +
      `  node scripts/rpc_load_test.mjs --chains ethereum,base --rps-limit 50\n` +
      `\n` +
      `  # Multiple chains with per-chain rates\n` +
      `  node scripts/rpc_load_test.mjs --chains ethereum,base --chain-rates "ethereum:100,base:50"\n` +
      `\n` +
      `  # All chains with fastest strategy and 15s ramp-up\n` +
      `  node scripts/rpc_load_test.mjs --chains ethereum,base --strategy fastest --ramp-up 15\n` +
      `\n` +
      `  # Single chain with specific profile\n` +
      `  node scripts/rpc_load_test.mjs --url http://localhost:4000/rpc/ethereum --profile testnet\n` +
      `\n` +
      `  # Multiple chains with profile\n` +
      `  node scripts/rpc_load_test.mjs --chains ethereum,base --profile testnet --strategy fastest\n`
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
async function rpc(url, body, timeoutMs, apiKey = null) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const headers = { "content-type": "application/json" };
    if (apiKey) {
      headers["x-lasso-api-key"] = apiKey;
    }
    const res = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    // Capture raw response text before parsing
    const rawText = await res.text().catch(() => "");
    let json;
    try {
      json = rawText
        ? JSON.parse(rawText)
        : { error: { code: -32700, message: "Empty response" } };
    } catch (parseErr) {
      json = { error: { code: -32700, message: "Invalid JSON", raw: rawText } };
    }
    return {
      ok: res.ok && !json.error,
      status: res.status,
      json,
      rawResponse: rawText,
      requestPayload: body,
    };
  } catch (err) {
    return {
      ok: false,
      status: 0,
      error: String((err && err.message) || err),
      requestPayload: body,
    };
  } finally {
    clearTimeout(timer);
  }
}

async function getLatestBlockNumber(url, timeoutMs, apiKey = null) {
  const body = { jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] };
  const { ok, json } = await rpc(url, body, timeoutMs, apiKey);
  if (!ok || !json || !json.result) return null;
  return Number(BigInt(json.result));
}

async function getBlockByNumber(url, num, fullTx = false, timeoutMs = 10000, apiKey = null) {
  const param = typeof num === "string" ? num : toHex(num);
  const body = {
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getBlockByNumber",
    params: [param, Boolean(fullTx)],
  };
  const { ok, json } = await rpc(url, body, timeoutMs, apiKey);
  if (!ok || !json) return null;
  return json.result || null;
}

async function findRecentTxHash(
  url,
  startNumber,
  searchBack = 20,
  timeoutMs = 10000,
  apiKey = null
) {
  let n = startNumber;
  for (let i = 0; i < searchBack && n >= 0; i++, n--) {
    const block = await getBlockByNumber(url, n, false, timeoutMs, apiKey);
    if (
      block &&
      Array.isArray(block.transactions) &&
      block.transactions.length > 0
    ) {
      return { txHash: block.transactions[0], blockHash: block.hash };
    }
  }
  // Fallback: latest block (hash) even if no tx, txHash undefined
  const latest = await getBlockByNumber(url, "latest", false, timeoutMs, apiKey);
  return { txHash: undefined, blockHash: latest && latest.hash };
}

async function bootstrapContext(url, timeoutMs, apiKey = null) {
  const latestNum = await getLatestBlockNumber(url, timeoutMs, apiKey);
  if (latestNum == null) {
    return { latestNumber: 0, txHash: undefined, blockHash: undefined };
  }
  const found = await findRecentTxHash(url, latestNum, 30, timeoutMs, apiKey);
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
        const span = 30;
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
// Multi-chain support
// -----------------------------
function parseChainRates(chainRatesCsv) {
  if (!chainRatesCsv) return new Map();
  const rates = new Map();
  const pairs = String(chainRatesCsv)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  for (const pair of pairs) {
    const [chain, rate] = pair.split(":").map((s) => s.trim());
    if (chain && rate) {
      const rateNum = Number(rate);
      if (Number.isFinite(rateNum) && rateNum > 0) {
        rates.set(chain, rateNum);
      }
    }
  }
  return rates;
}

function buildChainUrl(host, strategy, chain, profile) {
  // Remove trailing slash from host
  const base = host.replace(/\/$/, "");
  
  // If profile is specified, use profile-aware routes: /rpc/profile/:profile/...
  if (profile) {
    if (strategy && strategy !== "default") {
      return `${base}/rpc/profile/${profile}/${strategy}/${chain}`;
    }
    return `${base}/rpc/profile/${profile}/${chain}`;
  }
  
  // Legacy routes (no profile - uses default profile)
  if (strategy && strategy !== "default") {
    return `${base}/rpc/${strategy}/${chain}`;
  }
  return `${base}/rpc/${chain}`;
}

function parseChains(chainsCsv) {
  if (!chainsCsv) return [];
  return String(chainsCsv)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

// -----------------------------
// Load generation (single chain)
// -----------------------------
async function runSingleChain(url, chainName, rpsLimit, apiKey = null) {
  const prefix = chainName ? `[${chainName}] ` : "";
  const ctx = await bootstrapContext(url, options.timeout, apiKey);
  const ctxRef = {
    latestNumber: ctx.latestNumber,
    txHash: ctx.txHash,
    blockHash: ctx.blockHash,
  };

  if (options.verbose) {
    console.log(`${prefix}Bootstrap:`);
    console.log(`${prefix}  latest block number: ${ctxRef.latestNumber}`);
    console.log(
      `${prefix}  sample block hash:   ${ctxRef.blockHash || "(not found)"}`
    );
    console.log(
      `${prefix}  sample tx hash:      ${ctxRef.txHash || "(not found)"}`
    );
  }

  const methodPool = filterMethods(
    makeMethodPool(ctxRef).filter((m) => !m.enabled || m.enabled()),
    options.methods
  );
  if (methodPool.length === 0) {
    throw new Error(`${prefix}No methods to test (after filtering).`);
  }

  let nextId = 1;
  let stop = false;
  const startedAt = Date.now();
  const endAt = startedAt + options.duration * 1000;
  const allDurations = [];
  const perMethod = new Map(); // name -> { count, errors, durations[] }
  const inFlight = new Set();

  // Calculate ramp-up duration (default: 10s or 20% of duration, whichever is smaller)
  const defaultRampUp = Math.min(
    5,
    Math.max(1, Math.floor(options.duration * 0.2))
  );
  const rampUpDuration =
    options.rampUpDuration !== null && options.rampUpDuration !== undefined
      ? options.rampUpDuration
      : defaultRampUp;
  const rampUpEndMs = startedAt + rampUpDuration * 1000;

  // Rate limiting setup with ramp-up support
  let rateLimiter = null;
  if (rpsLimit && rpsLimit > 0) {
    let tokens = 0; // Start with empty bucket during ramp-up
    let lastRefill = startedAt;

    rateLimiter = {
      async acquire() {
        while (!stop) {
          const now = Date.now();
          const elapsed = now - lastRefill;

          // Calculate current effective RPS limit (ramp-up or full)
          let currentLimit = rpsLimit;
          if (now < rampUpEndMs) {
            // During ramp-up: linearly increase from 10% to 100% of target RPS
            // Starting at 10% avoids extremely long wait times at the very beginning
            const rampUpElapsed = now - startedAt;
            const rampUpProgress = Math.min(
              1,
              rampUpElapsed / (rampUpDuration * 1000)
            );
            // Ramp from 10% to 100%
            currentLimit = rpsLimit * (0.1 + 0.9 * rampUpProgress);
          }

          // Refill tokens based on elapsed time and current limit
          const tokensPerMs = currentLimit / 1000;
          tokens = Math.min(currentLimit, tokens + elapsed * tokensPerMs);
          lastRefill = now;

          if (tokens >= 1) {
            tokens -= 1;
            return; // Token acquired
          }

          // Wait for next token to be available
          const waitMs = (1 - tokens) / tokensPerMs;
          // Cap wait time at 500ms to allow responsive ramp-up adjustments
          await sleep(Math.min(500, Math.ceil(waitMs)));
        }
      },
    };
  }

  let windowReq = 0;
  let windowErr = 0;
  let windowDur = [];

  const ticker = setInterval(() => {
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
      `${prefix}t=${elapsed}s rps=${rps} err=${err} lat(ms) avg=${avg.toFixed(
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
    const res = await rpc(url, body, options.timeout, apiKey);
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

    // Always log errors in verbose mode, even if they're not in the main flow
    if (options.verbose && !res.ok) {
      const status = "ERR";
      let output = `${prefix}${methodDef.name} ${status} ${dtMs.toFixed(1)}ms`;

      // Print error summary
      if (res.error) {
        output += ` - ${res.error}`;
      } else if (res.json && res.json.error) {
        const err = res.json.error;
        output += ` - ${err.message || err.code || JSON.stringify(err)}`;
      } else if (res.status && res.status !== 200) {
        output += ` - HTTP ${res.status}`;
      } else {
        output += ` - Unknown error`;
      }
      process.stdout.write(output + "\n");

      // Always log full request/response details for errors in verbose mode
      if (res.requestPayload) {
        process.stdout.write(
          `${prefix}  Request Payload:\n${JSON.stringify(
            res.requestPayload,
            null,
            2
          )}\n`
        );
      }
      if (res.rawResponse) {
        process.stdout.write(
          `${prefix}  Raw HTTP Response:\n${res.rawResponse}\n`
        );
      } else if (res.error) {
        process.stdout.write(`${prefix}  Error Details: ${res.error}\n`);
      }
      if (res.status) {
        process.stdout.write(`${prefix}  HTTP Status: ${res.status}\n`);
      }
    } else if (options.verbose && res.ok) {
      // Log successful requests too
      process.stdout.write(
        `${prefix}${methodDef.name} OK ${dtMs.toFixed(1)}ms\n`
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

  return {
    chainName,
    url,
    totalCount,
    totalErrors,
    totalSec,
    overallAvg,
    overallP50,
    overallP95,
    overallP99,
    perMethod,
  };
}

// -----------------------------
// Main entry point
// -----------------------------
async function run() {
  const chains = parseChains(options.chains);
  const chainRates = parseChainRates(options.chainRates);

  // Determine if we're in multi-chain mode
  const isMultiChain = chains.length > 0;

  if (isMultiChain) {
    // Multi-chain mode
    const host = options.host || "http://localhost:4000";
    // Calculate default ramp-up if not specified
    const defaultRampUp = Math.min(
      10,
      Math.max(1, Math.floor(options.duration * 0.2))
    );
    const rampUpDuration =
      options.rampUpDuration !== null && options.rampUpDuration !== undefined
        ? options.rampUpDuration
        : defaultRampUp;

    console.log(`RPC load test starting (multi-chain mode)...`);
    console.log(`  host=${host}`);
    console.log(`  chains=${chains.join(", ")}`);
    console.log(`  strategy=${options.strategy}`);
    if (options.profile) console.log(`  profile=${options.profile}`);
    console.log(`  concurrency=${options.concurrency} per chain`);
    console.log(`  duration=${options.duration}s`);
    console.log(`  ramp-up=${rampUpDuration}s`);
    console.log(`  timeout=${options.timeout}ms`);
    if (options.methods) console.log(`  methods=${options.methods}`);
    if (options.rpsLimit)
      console.log(`  rps limit=${options.rpsLimit} per chain`);
    if (chainRates.size > 0) {
      console.log(
        `  per-chain rates: ${Array.from(chainRates.entries())
          .map(([c, r]) => `${c}:${r}`)
          .join(", ")}`
      );
    }
    if (options.verbose) console.log(`  verbose logging enabled`);

    // Run tests for all chains in parallel
    const chainTests = chains.map(async (chain) => {
      const url = buildChainUrl(host, options.strategy, chain, options.profile);
      const rpsLimit = chainRates.get(chain) || options.rpsLimit || null;
      try {
        return await runSingleChain(url, chain, rpsLimit, options.apiKey);
      } catch (err) {
        console.error(`[${chain}] Fatal error:`, err.message);
        return {
          chainName: chain,
          url,
          totalCount: 0,
          totalErrors: 1,
          totalSec: 0,
          overallAvg: 0,
          overallP50: 0,
          overallP95: 0,
          overallP99: 0,
          perMethod: new Map(),
          error: err.message,
        };
      }
    });

    const results = await Promise.all(chainTests);

    // Aggregate summary
    console.log("\n" + "=".repeat(60));
    console.log("=== Multi-Chain Summary ===");
    console.log("=".repeat(60));

    let grandTotalCount = 0;
    let grandTotalErrors = 0;
    const allDurations = [];

    for (const result of results) {
      if (result.error) {
        console.log(`\n[${result.chainName}] ERROR: ${result.error}`);
        continue;
      }

      console.log(`\n[${result.chainName}]`);
      console.log(
        `  Requests: ${result.totalCount}  Errors: ${
          result.totalErrors
        }  Duration: ${result.totalSec}s  RPS: ${(
          result.totalCount / result.totalSec
        ).toFixed(1)}`
      );
      console.log(
        `  Latency ms: avg=${result.overallAvg.toFixed(
          1
        )} p50=${result.overallP50.toFixed(1)} p95=${result.overallP95.toFixed(
          1
        )} p99=${result.overallP99.toFixed(1)}`
      );

      grandTotalCount += result.totalCount;
      grandTotalErrors += result.totalErrors;
    }

    console.log(`\n=== Overall Totals ===`);
    console.log(
      `Total Requests: ${grandTotalCount}  Total Errors: ${grandTotalErrors}  Duration: ${options.duration}s`
    );
    console.log(
      `Aggregate RPS: ${(grandTotalCount / options.duration).toFixed(1)}`
    );
  } else {
    // Single-chain mode (original behavior)
    // Calculate default ramp-up if not specified
    const defaultRampUp = Math.min(
      10,
      Math.max(1, Math.floor(options.duration * 0.2))
    );
    const rampUpDuration =
      options.rampUpDuration !== null && options.rampUpDuration !== undefined
        ? options.rampUpDuration
        : defaultRampUp;

    console.log(`RPC load test starting...`);
    console.log(`  url=${options.url}`);
    if (options.profile) console.log(`  profile=${options.profile}`);
    console.log(`  concurrency=${options.concurrency}`);
    console.log(`  duration=${options.duration}s`);
    console.log(`  ramp-up=${rampUpDuration}s`);
    console.log(`  timeout=${options.timeout}ms`);
    if (options.methods) console.log(`  methods=${options.methods}`);
    if (options.rpsLimit) console.log(`  rps limit=${options.rpsLimit}`);
    if (options.verbose) console.log(`  verbose logging enabled`);

    // If profile is specified and URL doesn't already include it, construct profile-aware URL
    let testUrl = options.url;
    if (options.profile && !testUrl.includes("/profile/")) {
      // Parse the existing URL to extract base, strategy, and chain
      const urlObj = new URL(testUrl);
      const pathParts = urlObj.pathname.split("/").filter(Boolean);
      
      // Find the position of "rpc" in the path
      const rpcIndex = pathParts.indexOf("rpc");
      if (rpcIndex !== -1) {
        // Extract parts after "rpc"
        const afterRpc = pathParts.slice(rpcIndex + 1);
        
        // Determine if there's a strategy (check if first part is a valid strategy)
        const validStrategies = ["load-balanced", "fastest", "latency-weighted"];
        let strategy = null;
        let chain = null;
        
        if (afterRpc.length >= 2 && validStrategies.includes(afterRpc[0])) {
          strategy = afterRpc[0];
          chain = afterRpc[1];
        } else if (afterRpc.length >= 1) {
          chain = afterRpc[0];
        }
        
        if (chain) {
          // Rebuild URL with profile
          const base = `${urlObj.protocol}//${urlObj.host}`;
          testUrl = buildChainUrl(base, strategy, chain, options.profile);
        }
      }
    }
    
    // Extract chain name from URL for single-chain mode, or use empty string
    const urlMatch = testUrl.match(/\/rpc\/(?:profile\/[^\/]+\/)?(?:[^\/]+\/)?([^\/\?]+)/);
    const chainName = urlMatch ? urlMatch[1] : "";
    const result = await runSingleChain(
      testUrl,
      chainName,
      options.rpsLimit,
      options.apiKey
    );

    console.log("\n=== Summary ===");
    console.log(
      `Requests: ${result.totalCount}  Errors: ${
        result.totalErrors
      }  Duration: ${result.totalSec}s  RPS: ${(
        result.totalCount / result.totalSec
      ).toFixed(1)}`
    );
    console.log(
      `Latency ms: avg=${result.overallAvg.toFixed(
        1
      )} p50=${result.overallP50.toFixed(1)} p95=${result.overallP95.toFixed(
        1
      )} p99=${result.overallP99.toFixed(1)}`
    );
    console.log("\nPer-method:");
    const byName = Array.from(result.perMethod.entries()).sort(
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
}

run().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
