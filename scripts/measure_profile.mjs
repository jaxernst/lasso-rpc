#!/usr/bin/env node
// Measures a Lasso profile against the providers behind it. See docs/MIGRATION.md,
// "Measure a profile against its own providers".
//
//   node scripts/measure_profile.mjs \
//     --lasso lasso=env:LASSO_URL \
//     --provider provider-1=env:PROVIDER_1_URL \
//     --provider provider-2=env:PROVIDER_2_URL \
//     --out comparison.json
//
// Each endpoint is LABEL=URL, where URL is a literal or env:NAME. Output and the
// samples file name endpoints by label and host only, and record errors by kind
// only: no URL, response text or exception message is ever written.
//
// Comparison (default): every round sends one call to every endpoint at once.
//   --calls 200     rounds
//   --rate 2        rounds per second, so calls per second to each endpoint
// Rate limit: --rate-limit LABEL calls that provider directly and the first
// Lasso URL at the same time, at --limit-rate calls/s for up to --limit-seconds.
// It stops early once the caller sees 3 errors through Lasso or 3 calls need
// three or more upstream sends, and is incomplete if the provider refused nothing.
//   --limit-rate 20 (at most 50)   --limit-seconds 20 (at most 60)
// Both: --timeout 10000 (ms per call)   --out FILE (samples, JSON)
//
// The last line is "Result: complete." or "Result: incomplete. <reasons>." and
// the exit status is 1 for an incomplete result or a failed setup.

import { writeFileSync } from "node:fs";

if (Number(process.versions.node.split(".")[0]) < 18) {
  console.error(`Node 18 or newer is required (found ${process.versions.node}).`);
  process.exit(1);
}

const USAGE = `Usage:
  node scripts/measure_profile.mjs \\
    --lasso lasso=env:LASSO_URL \\
    --provider provider-1=env:PROVIDER_1_URL \\
    --provider provider-2=env:PROVIDER_2_URL \\
    --out comparison.json

Add --rate-limit provider-1 --limit-rate 20 --limit-seconds 20 to call that
provider directly and through Lasso at once, above its limit. Setup, flags and output: docs/MIGRATION.md,
"Measure a profile against its own providers".`;

const PIN_DEPTH = 16;
const LOG_RANGE = 10;
const MAX_LIMIT_RATE = 50;
const MAX_LIMIT_SECONDS = 60;
const STOP_AFTER = 3;

function fail(message) {
  console.error(message);
  process.exit(1);
}

const flagName = (arg) => (/^--?[a-z][a-z-]*$/.test(arg) ? arg : "an argument");

function parseEndpoint(spec, kind) {
  const shape = `--${kind} takes LABEL=URL or LABEL=env:NAME, where LABEL is letters, digits, ".", "_" or "-".`;
  const eq = spec.indexOf("=");
  const label = spec.slice(0, Math.max(eq, 0));
  if (!/^[A-Za-z0-9._-]{1,40}$/.test(label)) fail(`A --${kind} value is malformed. ${shape}`);
  let url = spec.slice(eq + 1);
  if (url.startsWith("env:")) {
    const name = url.slice(4);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) fail(`The --${kind} value for ${label} has a malformed env: name. ${shape}`);
    url = process.env[name];
    if (!url) fail(`The environment variable named for ${label} is not set.`);
  }
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    fail(`The URL for ${label} is not a valid URL.`);
  }
  if (kind === "lasso") parsed.searchParams.set("include_meta", "body");
  return { label, kind, host: parsed.host, url: parsed.toString() };
}

function parseArgs(argv) {
  const o = {
    endpoints: [],
    calls: 200,
    rate: 2,
    timeout: 10000,
    out: `measure_profile_${Date.now()}.json`,
    rateLimit: null,
    limitRate: 20,
    limitSeconds: 20,
  };
  const numbers = { "--calls": "calls", "--rate": "rate", "--timeout": "timeout", "--limit-rate": "limitRate", "--limit-seconds": "limitSeconds" };
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(USAGE);
    process.exit(0);
  }
  for (let i = 2; i < argv.length; i++) {
    const flag = argv[i];
    const value = argv[++i];
    if (value === undefined) fail(`Missing value for ${flagName(flag)}.`);
    if (flag === "--lasso") o.endpoints.push(parseEndpoint(value, "lasso"));
    else if (flag === "--provider") o.endpoints.push(parseEndpoint(value, "provider"));
    else if (flag === "--out") o.out = value;
    else if (flag === "--rate-limit") o.rateLimit = value;
    else if (numbers[flag] && Number(value) > 0) o[numbers[flag]] = Number(value);
    else fail(`Unknown flag or bad value for ${flagName(flag)}. See docs/MIGRATION.md for usage.`);
  }
  const labels = o.endpoints.map((e) => e.label);
  if (new Set(labels).size !== labels.length) fail("Endpoint labels must be unique.");
  if (!o.endpoints.some((e) => e.kind === "lasso")) fail("Pass at least one --lasso LABEL=URL.");
  if (!o.endpoints.some((e) => e.kind === "provider")) fail("Pass at least one --provider LABEL=URL.");
  if (o.rateLimit) {
    if (!o.endpoints.some((e) => e.kind === "provider" && e.label === o.rateLimit))
      fail(`--rate-limit must name a --provider label.`);
    o.limitRate = Math.min(o.limitRate, MAX_LIMIT_RATE);
    o.limitSeconds = Math.min(o.limitSeconds, MAX_LIMIT_SECONDS);
  }
  return o;
}

const opts = parseArgs(process.argv);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const hex = (n) => "0x" + n.toString(16);
const RATE_LIMIT_TEXT = /rate.?limit|too many requests|exceeded.*(capacity|limit|quota|throughput)|compute units/i;

let nextId = 1;
async function rpc(endpoint, method, params) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeout);
  const started = performance.now();
  try {
    const res = await fetch(endpoint.url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
      signal: controller.signal,
    });
    const text = await res.text();
    const ms = performance.now() - started;
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {}
    return { ms, status: res.status, json };
  } catch (err) {
    const ms = performance.now() - started;
    if (err.name === "AbortError") return { ms, error: "timeout" };
    const code = (err.cause || err).code;
    return { ms, error: typeof code === "string" && /^[A-Z0-9_]+$/.test(code) ? `network ${code}` : "network" };
  } finally {
    clearTimeout(timer);
  }
}

function classify(r) {
  if (r.error) return r.error;
  const body = r.json !== null && typeof r.json === "object" && !Array.isArray(r.json) ? r.json : null;
  const err = body?.error;
  const code = Number.isInteger(err?.code) ? err.code : "unknown";
  if (r.status === 429 || code === 429 || code === -32029 || RATE_LIMIT_TEXT.test(String(err?.message ?? ""))) return "rate limit";
  if (err) return `rpc ${code}`;
  if (r.status < 200 || r.status >= 300) return `http ${r.status}`;
  if (!body || !("result" in body)) return "bad response";
  return null;
}

function metaOf(r) {
  const m = r.json?.lasso_meta;
  if (m === null || typeof m !== "object") return null;
  const sends = m.dispatches ?? (Array.isArray(m.attempted_channels) ? m.attempted_channels.length : null);
  const round = (v) => (typeof v === "number" ? Math.round(v * 10) / 10 : null);
  return {
    provider: m.selected_provider?.id ?? null,
    sends,
    strategy: m.strategy ?? null,
    upstreamMs: round(m.upstream_latency_ms),
    routingMs: round(m.lasso_overhead_ms),
  };
}

async function call(endpoint, method, params, extra = {}) {
  const r = await rpc(endpoint, method, params);
  const error = classify(r);
  const sample = { endpoint: endpoint.label, method, ...extra, ms: Math.round(r.ms * 10) / 10, ok: !error };
  if (error) sample.error = error;
  if (endpoint.kind === "lasso") sample.meta = metaOf(r);
  return { sample, result: error ? undefined : r.json.result };
}

const providers = opts.endpoints.filter((e) => e.kind === "provider");
const lassos = opts.endpoints.filter((e) => e.kind === "lasso");

async function setup() {
  const chainIds = await Promise.all(opts.endpoints.map((e) => call(e, "eth_chainId", [])));
  const ids = new Map(chainIds.map((c, i) => [opts.endpoints[i].label, c.result]));
  const quantity = (v) => typeof v === "string" && /^0x[0-9a-f]+$/i.test(v);
  for (const c of chainIds)
    if (!quantity(c.result)) fail(`${c.sample.endpoint} did not answer eth_chainId: ${c.sample.error ?? "bad response"}.`);
  const distinct = new Set([...ids.values()].map((id) => BigInt(id)));
  if (distinct.size > 1) fail(`Endpoints report different chains: ${[...ids].map(([l, id]) => `${l} ${BigInt(id)}`).join(", ")}.`);
  const chainId = Number([...distinct][0]);

  const heads = (await Promise.all(providers.map((p) => call(p, "eth_blockNumber", []))))
    .filter((c) => quantity(c.result))
    .map((c) => Number(BigInt(c.result)));
  if (!heads.length) fail("No provider answered eth_blockNumber.");
  const source = providers[0];
  let pin = Math.max(0, Math.min(...heads) - PIN_DEPTH);
  let txs = [];
  for (let back = 0; back < 10 && pin - back >= 0; back++) {
    const block = (await call(source, "eth_getBlockByNumber", [hex(pin - back), false])).result;
    if (block?.transactions?.length) {
      pin -= back;
      txs = block.transactions.slice(0, 20);
      break;
    }
  }
  const addresses = new Set();
  let logAddress = null;
  for (const hash of txs.slice(0, 6)) {
    const receipt = (await call(source, "eth_getTransactionReceipt", [hash])).result;
    if (!receipt) continue;
    for (const a of [receipt.from, receipt.to]) if (a) addresses.add(a);
    logAddress ??= receipt.logs?.[0]?.address ?? null;
  }
  return { chainId, pin, txs, addresses: [...addresses], logAddress };
}

function methodsFor(chain) {
  const at = hex(chain.pin);
  const pick = (list, round) => list[Math.floor(round / 6) % list.length];
  const methods = [
    ["eth_blockNumber", () => []],
    ["eth_getBlockByNumber", () => [at, false]],
  ];
  if (chain.addresses.length) {
    methods.push(["eth_getBalance", (round) => [pick(chain.addresses, round), at]]);
    methods.push(["eth_getCode", (round) => [pick(chain.addresses, round), at]]);
  }
  if (chain.txs.length) methods.push(["eth_getTransactionReceipt", (round) => [pick(chain.txs, round)]]);
  if (chain.logAddress)
    methods.push(["eth_getLogs", () => [{ fromBlock: hex(Math.max(0, chain.pin - LOG_RANGE + 1)), toBlock: at, address: chain.logAddress }]]);
  return methods;
}

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))];
}

const fmt = (v) => (v == null ? "n/a" : String(Math.round(v)));
const signed = (v) => (v == null ? "n/a" : `${v >= 0 ? "+" : ""}${Math.round(v)}`);
const counts = (items) => {
  const m = new Map();
  for (const k of items) m.set(k, (m.get(k) || 0) + 1);
  return [...m].sort((a, b) => b[1] - a[1]);
};
const listCounts = (items) => counts(items).map(([k, v]) => `${k} ${v}`).join(", ") || "none";

function table(header, rows) {
  const all = [header, ...rows].map((r) => r.map(String));
  const widths = header.map((_, i) => Math.max(...all.map((r) => r[i].length)));
  return all.map((r) => r.map((c, i) => (i === 0 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join("  ")).join("\n");
}

function endpointTable(samples, endpoints) {
  const rows = endpoints.map((e) => {
    const mine = samples.filter((s) => s.endpoint === e.label);
    const ms = mine.filter((s) => s.ok).map((s) => s.ms);
    return [
      `${e.label} (${e.kind})`,
      e.host,
      mine.length,
      ms.length,
      listCounts(mine.filter((s) => !s.ok).map((s) => s.error)),
      fmt(percentile(ms, 50)),
      fmt(percentile(ms, 90)),
      fmt(percentile(ms, 99)),
    ];
  });
  return table(["Endpoint", "Host", "Calls", "Answered", "Errors", "p50 ms", "p90 ms", "p99 ms"], rows);
}

function routingLines(samples, lasso) {
  const mine = samples.filter((s) => s.endpoint === lasso.label);
  const withMeta = mine.filter((s) => s.meta);
  if (!withMeta.length) return [`${lasso.label}: responses carried no lasso_meta, so the answering provider and upstream sends are unknown.`];
  const lines = [];
  if (withMeta.length < mine.length) lines.push(`${lasso.label}: ${mine.length - withMeta.length} of ${mine.length} responses carried no lasso_meta.`);
  lines.push(`${lasso.label} strategy reported by Lasso: ${listCounts(withMeta.map((s) => s.meta.strategy ?? "unreported"))}`);
  lines.push(`${lasso.label} answered by: ${listCounts(withMeta.filter((s) => s.ok).map((s) => s.meta.provider ?? "unnamed"))}`);
  const sends = withMeta.map((s) => s.meta.sends).filter((v) => v != null);
  if (sends.length) {
    lines.push(`${lasso.label} upstream sends per call: ${sendsPerCall(sends)}`);
  } else lines.push(`${lasso.label}: lasso_meta reported no upstream send count.`);
  return lines;
}

function costLine(samples, lasso, directs) {
  const okMs = (label) => samples.filter((s) => s.endpoint === label && s.ok).map((s) => s.ms);
  const best = directs
    .map((d) => ({ d, ms: okMs(d.label) }))
    .filter((x) => x.ms.length)
    .sort((a, b) => percentile(a.ms, 50) - percentile(b.ms, 50))[0];
  const mine = okMs(lasso.label);
  if (!best || !mine.length) return `${lasso.label} latency against the best direct provider: n/a`;
  const diff = (p) => percentile(mine, p) - percentile(best.ms, p);
  return `${lasso.label} latency against the best direct provider (${best.d.label}, lowest p50): p50 ${signed(diff(50))} ms, p90 ${signed(diff(90))} ms, p99 ${signed(diff(99))} ms`;
}

function reportedTime(samples) {
  const answered = samples.filter((s) => s.ok && s.meta);
  const routing = answered.map((s) => s.meta.routingMs).filter((v) => v != null);
  const upstream = answered.map((s) => s.meta.upstreamMs).filter((v) => v != null);
  if (!routing.length && !upstream.length) return "lasso_meta reported no timing";
  const pair = (xs) => `p50 ${fmt(percentile(xs, 50))} ms, p90 ${fmt(percentile(xs, 90))} ms`;
  return `routing apart from upstream waits ${pair(routing)}; waiting on the upstream ${pair(upstream)}`;
}

function methodTable(samples, endpoints, methods) {
  const rows = methods.map(([m]) => [
    m,
    ...endpoints.map((e) => fmt(percentile(samples.filter((s) => s.endpoint === e.label && s.method === m && s.ok).map((s) => s.ms), 50))),
  ]);
  return table(["p50 ms by method", ...endpoints.map((e) => e.label)], rows);
}

async function compare(chain) {
  const methods = methodsFor(chain);
  const interval = 1000 / opts.rate;
  const samples = [];
  const t0 = performance.now();
  for (let round = 0; round < opts.calls; round++) {
    const [method, params] = methods[round % methods.length];
    const p = params(round);
    const at = Math.round(performance.now() - t0);
    const results = await Promise.all(opts.endpoints.map((e) => call(e, method, p, { round, at })));
    samples.push(...results.map((r) => r.sample));
    if ((round + 1) % 50 === 0) console.error(`${round + 1}/${opts.calls} rounds`);
    const wait = t0 + (round + 1) * interval - performance.now();
    if (wait > 0) await sleep(wait);
  }
  const lines = [
    `Comparison: chain ${chain.chainId}, ${opts.calls} rounds at ${opts.rate} per second, block ${chain.pin} pinned for block-dependent calls.`,
    `Methods in rotation: ${methods.map(([m]) => m).join(", ")}.`,
    "",
    endpointTable(samples, opts.endpoints),
    "",
    methodTable(samples, opts.endpoints, methods),
    "",
  ];
  const incomplete = [];
  for (const lasso of lassos) {
    lines.push(
      ...routingLines(samples, lasso),
      costLine(samples, lasso, providers),
      `${lasso.label} routing time reported by Lasso for the same calls: ${reportedTime(samples.filter((s) => s.endpoint === lasso.label))}`,
      ""
    );
    incomplete.push(...metaGaps(samples.filter((s) => s.endpoint === lasso.label), lasso));
  }
  for (const e of opts.endpoints)
    if (!samples.some((s) => s.endpoint === e.label && s.ok)) incomplete.push(`${e.label} answered no calls`);
  return { lines, samples, incomplete, methods: methods.map(([m]) => m) };
}

function metaGaps(samples, lasso) {
  const answered = samples.filter((s) => s.ok);
  const gaps = [];
  if (answered.some((s) => !s.meta?.provider)) gaps.push(`${lasso.label}: some answered calls carried no lasso_meta provider`);
  if (answered.some((s) => s.meta?.sends == null)) gaps.push(`${lasso.label}: some answered calls carried no lasso_meta send count`);
  return gaps;
}

function sendsPerCall(sends) {
  const byCount = counts(sends).sort((a, b) => a[0] - b[0]);
  return `${byCount.map(([n, v]) => `${n} send${n === 1 ? "" : "s"}: ${v}`).join(", ")} (total ${sends.reduce((a, b) => a + b, 0)} for ${sends.length} calls)`;
}

async function rateLimit(chain) {
  const target = providers.find((p) => p.label === opts.rateLimit);
  const lasso = lassos[0];
  const total = Math.round(opts.limitRate * opts.limitSeconds);
  const interval = 1000 / opts.limitRate;
  const method = chain.logAddress ? "eth_getLogs" : "eth_getBlockByNumber";
  const samples = [];
  let stopped = null;
  const stopRule = () => {
    const mine = samples.filter((s) => s.endpoint === lasso.label);
    const errors = mine.filter((s) => !s.ok).length;
    if (errors >= STOP_AFTER) return `the caller saw ${errors} errors through ${lasso.label}`;
    const maxed = mine.filter((s) => s.meta?.sends >= 3).length;
    if (maxed >= STOP_AFTER) return `${maxed} calls through ${lasso.label} needed three or more upstream sends`;
    return null;
  };
  console.error(`${opts.limitRate} calls/s for up to ${opts.limitSeconds} s to ${target.label} directly and to ${lasso.label} at once.`);
  const t0 = performance.now();
  const pending = [];
  for (let i = 0; i < total && !stopped; i++) {
    const wait = t0 + i * interval - performance.now();
    if (wait > 0) await sleep(wait);
    if (stopped) break;
    const pin = Math.max(0, chain.pin - (i % 50));
    const params = chain.logAddress
      ? [{ fromBlock: hex(Math.max(0, pin - LOG_RANGE + 1)), toBlock: hex(pin), address: chain.logAddress }]
      : [hex(pin), false];
    const at = Math.round(performance.now() - t0);
    for (const endpoint of [target, lasso])
      pending.push(
        call(endpoint, method, params, { round: i, at }).then(({ sample }) => {
          samples.push(sample);
          stopped ??= stopRule();
        })
      );
  }
  await Promise.all(pending);
  samples.sort((a, b) => a.round - b.round);

  const direct = samples.filter((s) => s.endpoint === target.label);
  const profile = samples.filter((s) => s.endpoint === lasso.label);
  const refusals = direct.filter((s) => s.error === "rate limit").length;
  const okMs = profile.filter((s) => s.ok).map((s) => s.ms);
  const sends = profile.map((s) => s.meta?.sends).filter((v) => v != null);
  const ms = (pred) => profile.filter((s) => s.ok && pred(s)).map((s) => s.ms);
  const once = ms((s) => s.meta?.sends === 1);
  const more = ms((s) => s.meta?.sends > 1);
  const lines = [
    `Rate limit: chain ${chain.chainId}, ${method}, ${opts.limitRate} calls/s for up to ${opts.limitSeconds} s, ${direct.length} of ${total} planned rounds sent.`,
    `Stopped early: ${direct.length < total ? stopped : "no"}`,
    "",
    `${target.label} directly (${target.host}): ${direct.length} calls, ${refusals} refusals (HTTP 429 or a rate-limit error)`,
    `${lasso.label} (${lasso.host}): ${profile.length} calls, answered ${okMs.length}, errors: ${listCounts(profile.filter((s) => !s.ok).map((s) => s.error))}`,
    `  latency of answered calls: p50 ${fmt(percentile(okMs, 50))} ms, p90 ${fmt(percentile(okMs, 90))} ms, p99 ${fmt(percentile(okMs, 99))} ms`,
  ];
  if (sends.length)
    lines.push(
      `  upstream sends per call: ${sendsPerCall(sends)}`,
      `  answered by: ${listCounts(profile.filter((s) => s.ok).map((s) => s.meta?.provider ?? "unnamed"))}`,
      `  strategy reported by Lasso: ${listCounts(profile.filter((s) => s.meta).map((s) => s.meta.strategy ?? "unreported"))}`,
      `  routing time reported by Lasso: ${reportedTime(profile)}`,
      `  p50 latency: ${fmt(percentile(once, 50))} ms for calls sent once (${once.length}), ${fmt(percentile(more, 50))} ms for calls sent more than once (${more.length})`
    );
  lines.push("");
  const incomplete = metaGaps(profile, lasso);
  if (!refusals) incomplete.push(`${target.label} refused nothing at ${opts.limitRate} calls/s, so it was not over its limit; raise --limit-rate`);
  return { lines, samples, incomplete };
}

async function main() {
  const chain = await setup();
  const run = opts.rateLimit ? await rateLimit(chain) : await compare(chain);
  const manifest = {
    mode: opts.rateLimit ? "rate-limit" : "comparison",
    startedAt: new Date(Date.now() - performance.now()).toISOString(),
    node: process.version,
    chainId: chain.chainId,
    pinnedBlock: chain.pin,
    endpoints: opts.endpoints.map(({ label, kind, host }) => ({ label, kind, host })),
    settings: opts.rateLimit
      ? { rateLimit: opts.rateLimit, limitRate: opts.limitRate, limitSeconds: opts.limitSeconds, timeoutMs: opts.timeout }
      : { calls: opts.calls, rate: opts.rate, timeoutMs: opts.timeout, methods: run.methods },
    percentiles: "nearest rank over answered calls; ms is the time to the full response body",
    complete: !run.incomplete.length,
    incomplete: run.incomplete,
  };
  writeFileSync(opts.out, JSON.stringify({ manifest, samples: run.samples }, null, 1) + "\n");
  run.lines.push(`Samples: ${opts.out}`);
  run.lines.push(run.incomplete.length ? `Result: incomplete. ${run.incomplete.join("; ")}.` : "Result: complete.");
  console.log(run.lines.join("\n"));
  if (run.incomplete.length) process.exit(1);
}

main().catch((e) => fail(`Unexpected ${e.name}\n${String(e.stack).split("\n").slice(1).join("\n")}`));
