// Reads <results>/<run>/<candidate>/ and writes results.json plus tables.md into <results>.
// Runs named <scenario>-r<N> are repeats of one scenario; the Repeats section reports their spread.
// Rates and means keep full precision in results.json; only the tables round.
// Exits 2 when a bar in expected.json fails.
// Usage: node analyze.mjs [results dir]
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const KIT = path.dirname(fileURLToPath(import.meta.url));
const RES = path.resolve(process.argv[2] || process.env.RESULTS_DIR || path.join(KIT, "results", "runs"));
const SEND = "eth_sendRawTransaction";
const UNTAGGED_CLIENT = ["eth_chainId", "eth_blockNumber", "eth_gasPrice"];
const ORDER = ["direct", "race2", "endpoint", "lasso", "lasso-fastest", "lasso-bf", "lasso-lb", "lasso-learned", "lasso-unlearned"];
// Repeats agree when every metric's spread (max minus min) is within these bounds. README.md explains them.
const TOLERANCE = { success_pp: 1, stale_pp: 1, latency_ms: 5, latency_frac: 0.2, calls_per_request: 0.1 };

function readJsonl(f) {
  let text = null;
  if (fs.existsSync(f)) text = fs.readFileSync(f, "utf8");
  else if (fs.existsSync(f + ".gz")) text = zlib.gunzipSync(fs.readFileSync(f + ".gz")).toString("utf8");
  return text ? text.split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
}
const pct = (xs, p) => { if (!xs.length) return null; const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };
const r1 = (x) => (x === null || x === undefined || Number.isNaN(x) ? null : Math.round(x * 10) / 10);
const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
// One record per upstream call, from its arrival line, with the outcome line joined on. A call
// whose outcome never got written (the mock stopped first) is "unanswered".
function upstreamCalls(lines) {
  const outcomes = new Map(lines.filter((l) => l.kind === "outcome").map((l) => [`${l.inst}:${l.call}`, l.outcome]));
  return lines.filter((l) => l.kind === "call").map((l) => ({ ...l, outcome: outcomes.get(`${l.inst}:${l.call}`) ?? "unanswered" }));
}
// A client failure is either an error from the endpoint or a result that failed validation.
const errorKey = (r) => (r.rpc_ok ? `invalid result: ${r.data_problem}`
  : typeof r.error === "object" && r.error ? `${r.error.code} ${String(r.error.message).slice(0, 70)}` : `${r.status} ${r.error}`);
const count = (xs, key) => xs.reduce((a, x) => { const k = key(x); a[k] = (a[k] || 0) + 1; return a; }, {});

function latencyStats(recs) {
  const l = recs.map((r) => r.latency_ms);
  return { n: l.length, p50: pct(l, 50), p95: pct(l, 95), p99: pct(l, 99), max: l.length ? Math.max(...l) : null };
}
function windowStats(recs) {
  const ok = recs.filter((r) => r.ok);
  return { requests: recs.length, success_rate: recs.length ? ok.length / recs.length : null, latency_success: latencyStats(ok), latency_all: latencyStats(recs) };
}
const inWindow = (recs, from, to) => recs.filter((r) => r.since_ready_ms >= from && r.since_ready_ms < to);
function series(recs, stepMs, endMs) {
  const out = [];
  for (let t = 0; t < endMs; t += stepMs) { const w = inWindow(recs, t, t + stepMs); out.push({ from_s: t / 1000, n: w.length, ok: w.filter((r) => r.ok).length }); }
  return out;
}

function sendStats(sends, byTag, switchMs) {
  const reach = sends.map((r) => new Set((byTag.get(r.tag) || []).map((u) => u.inst)).size);
  const total = sends.map((r) => (byTag.get(r.tag) || []).length);
  const firstInst = count(sends, (r) => ((byTag.get(r.tag) || []).sort((a, b) => a.t - b.t)[0] || {}).inst || "none");
  const out = {
    txs: sends.length, client_success: sends.filter((r) => r.ok).length, upstreams_reached_histogram: count(reach, (x) => x),
    max_upstreams_reached: reach.length ? Math.max(...reach) : 0, mean_upstreams_reached: mean(reach),
    total_upstream_sends: total.reduce((a, b) => a + b, 0), max_sends_one_tx: total.length ? Math.max(...total) : 0, first_upstream: firstInst,
    latency_all: latencyStats(sends), errors: count(sends.filter((r) => !r.ok), errorKey),
    per_30s: series(sends, 30_000, Math.max(...sends.map((r) => r.since_ready_ms)) + 1),
  };
  if (switchMs !== undefined) {
    const before = sends.filter((r) => r.since_ready_ms < switchMs), after = sends.filter((r) => r.since_ready_ms >= switchMs);
    out.before_switch = { txs: before.length, ok: before.filter((r) => r.ok).length };
    out.after_switch = { txs: after.length, ok: after.filter((r) => r.ok).length };
    out.after_switch_30s = series(after.map((r) => ({ ...r, since_ready_ms: r.since_ready_ms - switchMs })), 30_000, 120_000);
  }
  return out;
}

function analyzeCandidate(dir) {
  const meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8"));
  const all = readJsonl(path.join(dir, "client.jsonl")).sort((a, b) => a.seq - b.seq);
  const up = upstreamCalls(readJsonl(path.join(dir, "upstream.jsonl")));
  const kind = meta.idle_s ? "idle" : meta.backfill ? "backfill" : "workload";
  const out = { candidate: meta.candidate, kind, meta: { start_to_healthy_ms: meta.start_to_healthy_ms ?? null, resources_during_run: meta.resources_during_run ?? null,
    load_avg_start: meta.load_avg_start ?? null, load_avg_end: meta.load_avg_end ?? null, switch_since_ready_ms: meta.switch_since_ready_ms ?? null, error: meta.error ?? null } };

  if (kind === "idle") {
    if (meta.error || !meta.idle_start) return out;
    const res = JSON.parse(fs.readFileSync(path.join(dir, "resources.json"), "utf8"));
    const idle = up.filter((u) => u.t >= meta.idle_start && u.t <= meta.idle_end);
    const mins = (meta.idle_end - meta.idle_start) / 60000;
    const cpu = res.samples.map((s) => s.cpu_pct).filter((x) => x !== null);
    const rss = res.samples.map((s) => s.rss_mb);
    out.idle = {
      minutes: r1(mins), chains: meta.chains?.length ?? 1, start_to_first_success_ms: res.start_to_first_success_ms, start_to_all_chains_ms: res.start_to_all_chains_ms ?? null,
      total_upstream_calls: idle.length, calls_per_minute: r1(idle.length / mins), calls_per_upstream_per_minute: idle.length / mins / new Set(idle.map((u) => u.inst)).size,
      by_upstream: count(idle, (u) => u.inst), by_method: count(idle, (u) => u.m),
      rss_mb: { first: rss[0], last: rss[rss.length - 1], max: Math.max(...rss), median: pct(rss, 50) },
      cpu_pct: { mean: r1(cpu.reduce((a, b) => a + b, 0) / cpu.length), p50: pct(cpu, 50), max: Math.max(...cpu) },
      processes: res.samples[res.samples.length - 1]?.procs,
    };
    return out;
  }
  if (!all.length) return out;

  const byTag = new Map();
  for (const u of up) if (u.tag) { if (!byTag.has(u.tag)) byTag.set(u.tag, []); byTag.get(u.tag).push(u); }
  const sends = all.filter((r) => r.method === SEND);
  const onlySends = sends.length === all.length;
  const client = onlySends ? all : all.filter((r) => r.method !== SEND);
  const switchMs = meta.switch_since_ready_ms ?? undefined;
  if (sends.length) out.broadcast = sendStats(sends, byTag, switchMs);

  const firstSend = Math.min(...client.map((r) => r.t_send));
  const firstOk = client.filter((r) => r.ok).sort((a, b) => a.t_recv - b.t_recv)[0];
  out.overall = windowStats(client);
  out.first_30s = windowStats(inWindow(client, 0, 30_000));
  out.after_30s = windowStats(client.filter((r) => r.since_ready_ms >= 30_000));
  out.first_success_ms = firstOk ? firstOk.t_recv - firstSend : null;
  out.series_10s = series(client, 10_000, 180_000);
  if (switchMs !== undefined) {
    out.switch = {
      at_ms: switchMs, before: windowStats(client.filter((r) => r.since_ready_ms < switchMs)), after: windowStats(client.filter((r) => r.since_ready_ms >= switchMs)),
      plus30_10s: windowStats(inWindow(client, switchMs + 30_000, switchMs + 40_000)), plus90_10s: windowStats(inWindow(client, switchMs + 90_000, switchMs + 100_000)),
      last_60s: windowStats(client.filter((r) => r.since_ready_ms >= switchMs + 60_000)),
    };
  }
  out.errors = count(client.filter((x) => !x.ok), errorKey);
  out.failures_by_method = count(client.filter((x) => !x.ok), (r) => r.method);

  // Upstream fan-out for tagged client requests (exact: tag appears only in client traffic).
  // Real endpoints have no mock logs, so these are unavailable there.
  const tagged = client.filter((r) => r.tag);
  const fan = tagged.map((r) => (byTag.get(r.tag) || []).length);
  const servedBy = {};
  for (const r of tagged) for (const u of byTag.get(r.tag) || []) { const k = `${u.inst}:${u.outcome}`; servedBy[k] = (servedBy[k] || 0) + 1; }
  out.tagged = meta.real ? { requests: tagged.length, upstream_calls: null, calls_per_request: null, fanout_histogram: null, by_upstream_outcome: null }
    : { requests: tagged.length, upstream_calls: fan.reduce((a, b) => a + b, 0), calls_per_request: mean(fan), fanout_histogram: count(fan, (x) => x), by_upstream_outcome: servedBy };
  // Tagged reads after the first 30 s that were sent to an upstream which held them unanswered.
  // A candidate that also asks another upstream at once may still answer such a read quickly.
  const settled = tagged.filter((r) => r.since_ready_ms >= 30_000);
  const sent = settled.filter((r) => (byTag.get(r.tag) || []).some((u) => u.outcome === "hang"));
  out.tagged.sent_to_hang_after_30s = meta.real ? null
    : { requests: settled.length, sent: sent.length, rate: settled.length ? sent.length / settled.length : null };
  if (switchMs !== undefined && !meta.real) {
    const t = (rs) => mean(rs.map((r) => (byTag.get(r.tag) || []).length));
    out.tagged.calls_per_request_before_switch = t(tagged.filter((r) => r.since_ready_ms < switchMs));
    out.tagged.calls_per_request_after_switch = t(tagged.filter((r) => r.since_ready_ms >= switchMs));
  }

  const runStart = firstSend, runEnd = Math.max(...client.map((r) => r.t_recv));
  const inRun = up.filter((u) => !u.tag && u.t >= runStart && u.t <= runEnd);
  out.untagged = { upstream_by_method: count(inRun, (u) => u.m), client_by_method: count(client.filter((x) => !x.tag), (r) => r.method),
    background_only_methods: Object.fromEntries(Object.entries(count(inRun, (u) => u.m)).filter(([m]) => !UNTAGGED_CLIENT.includes(m))) };

  // Freshness. Real endpoints have no mock clock, so it is unavailable there.
  const withBlock = client.filter((r) => r.ok && r.served_block !== null && r.served_block !== undefined);
  const stale = withBlock.filter((r) => r.lag_blocks > 1);
  const byRecv = [...withBlock].sort((a, b) => a.t_recv - b.t_recv);
  let max = -Infinity, back = 0, backGt1 = 0;
  for (const r of byRecv) { if (r.served_block < max) { back++; if (max - r.served_block > 1) backGt1++; } max = Math.max(max, r.served_block); }
  const lags = withBlock.map((r) => r.lag_blocks);
  out.freshness = meta.real ? { reads_with_block: null, stale_reads: null, stale_rate: null, stale_by_method: null, max_lag_blocks: null, backwards_any: null, backwards_gt1: null }
    : { reads_with_block: withBlock.length, stale_reads: stale.length, stale_rate: withBlock.length ? stale.length / withBlock.length : null, stale_by_method: count(stale, (r) => r.method),
      max_lag_blocks: lags.length ? Math.max(...lags) : null, backwards_any: back, backwards_gt1: backGt1 };
  if (switchMs !== undefined && !meta.real) {
    const rate = (recs) => { const n = recs.length; return { n, stale: recs.filter((r) => r.lag_blocks > 1).length }; };
    out.freshness.before_switch = rate(withBlock.filter((r) => r.since_ready_ms < switchMs));
    out.freshness.after_switch_10s = Array.from({ length: 12 }, (_, i) => rate(inWindow(withBlock, switchMs + i * 10_000, switchMs + (i + 1) * 10_000)));
  }
  out.data_problems = count(client.filter((x) => x.data_problem), (r) => r.data_problem.replace(/_\d+_of_\d+/, "_mismatch"));

  if (meta.backfill) {
    const passes = Object.values(client.reduce((a, r) => { (a[r.pass] ||= []).push(r); return a; }, {}));
    const wall = passes.map((p) => Math.max(...p.map((r) => r.t_recv)) - Math.min(...p.map((r) => r.t_send)));
    out.backfill = { ...meta.backfill, windows: client.length, windows_ok: client.filter((r) => r.ok).length, passes: passes.length,
      complete_passes: passes.filter((p) => p.every((r) => r.ok)).length, pass_wall_ms: { p50: pct(wall, 50), max: wall.length ? Math.max(...wall) : null } };
  }
  if (client.some((r) => r.winner)) out.race_winners = count(client.filter((x) => x.winner), (r) => r.winner);
  return out;
}

const results = { generated_at: new Date().toISOString(), scenarios: {} };
const runNames = fs.readdirSync(RES).filter((d) => fs.statSync(path.join(RES, d)).isDirectory())
  .sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
for (const run of runNames) {
  const cands = fs.readdirSync(path.join(RES, run)).filter((d) => fs.existsSync(path.join(RES, run, d, "meta.json")));
  if (!cands.length) continue;
  results.scenarios[run] = Object.fromEntries(cands.sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b)).map((c) => [c, analyzeCandidate(path.join(RES, run, c))]));
}

// ---------- Markdown ----------
const f = (x, d = "") => (x === null || x === undefined ? "n/a" : `${x}${d}`);
const f3 = (x) => (x === null || x === undefined ? "n/a" : String(Math.round(x * 1000) / 1000));
const pc = (x) => (x === null || x === undefined ? "n/a" : `${(x * 100).toFixed(1)}%`);
const hist = (h) => Object.entries(h).map(([k, v]) => `${k}: ${v}`).join(", ");
const READ_HEAD = "| candidate | success | success 0-30 s | success after 30 s | first success ms | p50 | p95 | p99 | max | upstream calls per tagged request | sent to a hung upstream after 30 s | stale reads | backwards (>1 block) |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|\n";
const failed = (a) => Boolean(a.meta.error) || (a.kind === "idle" ? !a.idle : !a.overall);
const failedRow = (c, a) => `| ${c} | failed: ${(a.meta.error ?? "no client records").split("\n")[0].slice(0, 100)} |\n`;
const readRow = (c, a) => {
  if (!a.overall || a.meta.error) return failedRow(c, a);
  const l = a.overall.latency_success, fr = a.freshness;
  return `| ${c} | ${pc(a.overall.success_rate)} | ${pc(a.first_30s.success_rate)} | ${pc(a.after_30s.success_rate)} | ${f(a.first_success_ms)} | ${f(l.p50)} | ${f(l.p95)} | ${f(l.p99)} | ${f(l.max)} | ${f3(a.tagged.calls_per_request)} | ${sentCell(a.tagged.sent_to_hang_after_30s)} | ${fr.stale_reads === null ? "n/a" : `${fr.stale_reads} (${pc(fr.stale_rate)})`} | ${fr.backwards_any === null ? "n/a" : `${fr.backwards_any} (${fr.backwards_gt1})`} |\n`;
};
const sentCell = (w) => (w ? `${w.sent}/${w.requests} (${pc(w.rate)})` : "n/a");
const BACKFILL_HEAD = "| candidate | windows ok | complete passes | upstream calls per window | window p50 / p95 ms | pass wall time p50 / max s | upstream calls by upstream and outcome | client errors |\n|---|---|---|---|---|---|---|---|\n";
const secs = (ms) => (ms === null || ms === undefined ? "n/a" : (ms / 1000).toFixed(1));
const backfillRow = (c, a) => {
  if (!a.backfill || a.meta.error) return failedRow(c, a);
  const b = a.backfill, l = a.overall.latency_success;
  const outcomes = Object.entries(a.tagged.by_upstream_outcome ?? {}).sort().map(([k, v]) => `${k} ${v}`).join(", ");
  const errs = Object.entries(a.errors).map(([k, v]) => `${k}: ${v}`).join("; ") || "none";
  return `| ${c} | ${b.windows_ok}/${b.windows} (${pc(b.windows_ok / b.windows)}) | ${b.complete_passes}/${b.passes} | ${f3(a.tagged.calls_per_request)} | ${f(l.p50)} / ${f(l.p95)} | ${secs(b.pass_wall_ms.p50)} / ${secs(b.pass_wall_ms.max)} | ${outcomes} | ${errs} |\n`;
};
const SEND_HEAD = "| candidate | client success | upstreams reached per tx (histogram) | max reached | total upstream sends | first upstream per tx | p50 / max latency ms |\n|---|---|---|---|---|---|---|\n";
const sendRow = (c, b) => `| ${c} | ${b.client_success}/${b.txs} | ${hist(b.upstreams_reached_histogram)} | ${b.max_upstreams_reached} | ${b.total_upstream_sends} | ${hist(b.first_upstream)} | ${f(b.latency_all.p50)} / ${f(b.latency_all.max)} |\n`;

let md = "";
for (const [run, cands] of Object.entries(results.scenarios)) {
  md += `\n### ${run}\n\n`;
  const entries = Object.entries(cands);
  const kind = entries[0]?.[1].kind;
  if (kind === "idle") {
    md += "| candidate | chains | start to first success | start to all chains | idle upstream calls/min | per upstream per min | methods (10 min) | RSS MB median (max) | CPU % mean (max) |\n|---|---|---|---|---|---|---|---|---|\n";
    for (const [c, a] of entries) {
      const i = a.idle;
      md += failed(a) ? failedRow(c, a)
        : `| ${c} | ${i.chains} | ${i.start_to_first_success_ms} ms | ${f(i.start_to_all_chains_ms, " ms")} | ${i.calls_per_minute} | ${f3(i.calls_per_upstream_per_minute)} | ${Object.entries(i.by_method).map(([k, v]) => `${k} ${v}`).join(", ")} | ${i.rss_mb.median} (${i.rss_mb.max}) | ${i.cpu_pct.mean} (${i.cpu_pct.max}) |\n`;
    }
    continue;
  }
  if (kind === "backfill") {
    md += BACKFILL_HEAD;
    for (const [c, a] of entries) md += backfillRow(c, a);
    continue;
  }
  const good = entries.filter(([, a]) => !failed(a)).map(([, a]) => a);
  const onlySends = good.length > 0 && good.every((a) => a.broadcast && a.broadcast.txs === a.overall.requests);
  if (!onlySends) { md += READ_HEAD; for (const [c, a] of entries) md += readRow(c, a); }
  if (Object.values(cands).some((a) => a.freshness?.after_switch_10s?.some((w) => w.stale))) {
    md += "\nStale reads of reads with a block, before the switch and per 10 s after it:\n\n| candidate | before | " + Array.from({ length: 12 }, (_, i) => `+${i * 10} s`).join(" | ") + " |\n|---|---|" + "---|".repeat(12) + "\n";
    for (const [c, a] of Object.entries(cands)) if (a.freshness?.after_switch_10s) md += `| ${c} | ${a.freshness.before_switch.stale}/${a.freshness.before_switch.n} | ${a.freshness.after_switch_10s.map((w) => `${w.stale}/${w.n}`).join(" | ")} |\n`;
  }
  if (Object.values(cands).some((a) => a.broadcast)) {
    if (!onlySends) md += "\nSends:\n\n";
    md += SEND_HEAD;
    for (const [c, a] of entries) md += failed(a) ? (onlySends ? failedRow(c, a) : "") : a.broadcast ? sendRow(c, a.broadcast) : "";
    const withWindows = Object.entries(cands).filter(([, a]) => a.broadcast && !onlySends);
    if (withWindows.length) {
      const sw = withWindows.some(([, a]) => a.broadcast.after_switch_30s);
      md += sw ? "\nSends delivered before the switch, after it, and per 30 s after it:\n\n| candidate | before switch | after switch | +0-30 s | +30-60 s | +60-90 s | +90-120 s |\n|---|---|---|---|---|---|---|\n"
        : "\nSends delivered per 30 s window:\n\n| candidate | 0-30 s | 30-60 s | 60-90 s | 90-120 s | 120-150 s | 150-180 s |\n|---|---|---|---|---|---|---|\n";
      for (const [c, a] of withWindows) {
        const b = a.broadcast;
        md += sw ? `| ${c} | ${b.before_switch.ok}/${b.before_switch.txs} | ${b.after_switch.ok}/${b.after_switch.txs} | ${b.after_switch_30s.map((w) => `${w.ok}/${w.n}`).join(" | ")} |\n`
          : `| ${c} | ${b.per_30s.slice(0, 6).map((w) => `${w.ok}/${w.n}`).join(" | ")} |\n`;
      }
    }
  }
  if (Object.values(cands).some((a) => a.switch)) {
    md += "\nReads around the fault switch (10 s windows start 30 s and 90 s after the switch):\n\n| candidate | before switch | after switch | 30-40 s after | 90-100 s after | last 60 s | calls per tagged request before / after |\n|---|---|---|---|---|---|---|\n";
    for (const [c, a] of Object.entries(cands)) {
      const s = a.switch; if (!s) continue;
      md += `| ${c} | ${pc(s.before.success_rate)} | ${pc(s.after.success_rate)} | ${pc(s.plus30_10s.success_rate)} | ${pc(s.plus90_10s.success_rate)} | ${pc(s.last_60s.success_rate)} | ${f3(a.tagged.calls_per_request_before_switch)} / ${f3(a.tagged.calls_per_request_after_switch)} |\n`;
    }
  }
}

// Repeats: runs group by scenario, from a <scenario>-r<N> name or the run's run.json. run.sh
// writes plan.json with the scenarios, candidates and repeat count, and the runner writes
// run.json with the candidates it was asked for, so a missing or failed run marks its group
// incomplete instead of dropping out of the comparison.
const readJson = (f) => (fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : null);
const plan = readJson(path.join(RES, "plan.json"));
const groups = {};
for (const run of runNames) {
  const s = run.match(/^(.+)-r(\d+)$/)?.[1] ?? readJson(path.join(RES, run, "run.json"))?.scenario;
  if (s) (groups[s] ||= new Set()).add(run);
}
for (const s of plan?.scenarios ?? []) for (let i = 1; i <= plan.repeats; i++) (groups[s] ||= new Set()).add(`${s}-r${i}`);
results.repeats = {};
const range = (xs) => { const v = xs.filter((x) => x !== null && x !== undefined); return v.length ? { min: Math.min(...v), max: Math.max(...v) } : null; };
const show = (r, fmt) => (r ? (r.min === r.max ? fmt(r.min) : `${fmt(r.min)} to ${fmt(r.max)}`) : "n/a");
const candidatesFor = (s, runs) => {
  const planned = plan?.scenarios?.includes(s) ? plan.candidates : [];
  const asked = new Set([...planned, ...runs.flatMap((r) => [...(readJson(path.join(RES, r, "run.json"))?.candidates ?? []), ...Object.keys(results.scenarios[r] ?? {})])]);
  return [...asked].sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b));
};
const repeatGroups = Object.entries(groups).map(([s, runs]) => [s, [...runs].sort((a, b) => a.localeCompare(b, "en", { numeric: true }))])
  .filter(([, runs]) => !runs.some((r) => Object.values(results.scenarios[r] ?? {}).some((a) => a.kind === "idle")));
if (repeatGroups.length) {
  md += "\n## Repeats\n\nEach cell is the lowest and highest value across repeats. A row agrees when success and stale reads stay within " +
    `${TOLERANCE.success_pp} percentage point, p50 and p95 within the larger of ${TOLERANCE.latency_ms} ms and ${TOLERANCE.latency_frac * 100}% of the lowest value, ` +
    `and upstream calls per request within ${TOLERANCE.calls_per_request}. A row is incomplete when any repeat is missing or failed.\n`;
  for (const [s, runs] of repeatGroups) {
    const cands = candidatesFor(s, runs);
    md += `\n### ${s} (${runs.length} ${runs.length === 1 ? "run" : "runs"})\n\n| candidate | success | p50 ms | p95 ms | stale reads | upstream calls per request | agree |\n|---|---|---|---|---|---|---|\n`;
    results.repeats[s] = {};
    for (const c of cands) {
      const status = runs.map((r) => {
        const a = results.scenarios[r]?.[c];
        return { run: r, a, problem: !a ? "missing" : a.meta.error || !a.overall ? "failed" : null };
      });
      const rs = status.filter((x) => !x.problem).map((x) => x.a);
      const spread = {
        runs: runs.length, valid_runs: rs.length, success: range(rs.map((a) => a.overall.success_rate)), p50: range(rs.map((a) => a.overall.latency_success.p50)),
        p95: range(rs.map((a) => a.overall.latency_success.p95)), stale: range(rs.map((a) => a.freshness.stale_rate)), calls_per_request: range(rs.map((a) => a.tagged.calls_per_request)),
      };
      const width = (r) => (r ? r.max - r.min - 1e-9 : 0);
      const latOk = (r) => !r || width(r) <= Math.max(TOLERANCE.latency_ms, TOLERANCE.latency_frac * r.min);
      const misses = [
        width(spread.success) * 100 > TOLERANCE.success_pp && "success", !latOk(spread.p50) && "p50", !latOk(spread.p95) && "p95",
        width(spread.stale) * 100 > TOLERANCE.stale_pp && "stale", width(spread.calls_per_request) > TOLERANCE.calls_per_request && "calls",
      ].filter(Boolean);
      const problems = status.filter((x) => x.problem).map((x) => `${x.run.replace(`${s}-`, "")} ${x.problem}`);
      spread.incomplete = problems;
      spread.agree = problems.length || runs.length < 2 ? null : misses.length === 0;
      results.repeats[s][c] = spread;
      const agree = problems.length ? `incomplete: ${problems.join(", ")}` : runs.length < 2 ? "one run" : misses.length ? `no: ${misses.join(", ")}` : "yes";
      md += `| ${c} | ${show(spread.success, pc)} | ${show(spread.p50, f)} | ${show(spread.p95, f)} | ${show(spread.stale, pc)} | ${show(spread.calls_per_request, f3)} | ${agree} |\n`;
    }
  }
}
// Expected outcomes: expected.json holds bars per scenario and candidate, each a metric with a min
// or max. A bar passes when every repeat meets it; a missing or failed repeat fails it.
const METRICS = {
  stale_rate: { label: "stale reads", value: (a) => a.freshness?.stale_rate },
  sent_to_hang_after_30s: { label: "sent to a hung upstream after 30 s", value: (a) => a.tagged?.sent_to_hang_after_30s?.rate },
  success_after_30s: { label: "success after 30 s", value: (a) => a.after_30s?.success_rate },
  sends_delivered: { label: "sends delivered", value: (a) => (a.broadcast ? a.broadcast.client_success / a.broadcast.txs : null) },
};
const EXPECTED = readJson(path.join(KIT, "expected.json")) ?? {};
const pcBound = (x) => `${Math.round(x * 1000) / 10}%`;
results.expected = [];
for (const [s, runSet] of Object.entries(groups)) {
  if (!EXPECTED[s]) continue;
  const runs = [...runSet].sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
  const cands = candidatesFor(s, runs);
  for (const [c, bars] of Object.entries(EXPECTED[s])) {
    if (!cands.includes(c)) continue;
    for (const [metric, bound] of Object.entries(bars)) {
      const m = METRICS[metric];
      if (!m) throw new Error(`expected.json: unknown metric ${metric} for ${s} ${c}`);
      const repeats = runs.map((r) => {
        const a = results.scenarios[r]?.[c];
        const value = a && !failed(a) ? m.value(a) ?? null : null;
        return { run: r, value, problem: !a ? "missing" : failed(a) ? "failed" : value === null ? "not measured" : null };
      });
      const meets = (v) => (bound.min === undefined || v >= bound.min) && (bound.max === undefined || v <= bound.max);
      const bar = [m.label, bound.min !== undefined && `at least ${pcBound(bound.min)}`, bound.max !== undefined && `at most ${pcBound(bound.max)}`].filter(Boolean).join(" ");
      results.expected.push({ scenario: s, candidate: c, metric, ...bound, bar, repeats, pass: repeats.every((x) => !x.problem && meets(x.value)) });
    }
  }
}
if (results.expected.length) {
  md += "\n## Expected outcomes\n\nBars from `expected.json`. A bar passes when every repeat meets it.\n\n| scenario | candidate | bar | measured across repeats | result |\n|---|---|---|---|---|\n";
  for (const e of results.expected) {
    const problems = e.repeats.filter((x) => x.problem).map((x) => `${x.run.replace(`${e.scenario}-`, "")} ${x.problem}`);
    const measured = [show(range(e.repeats.map((x) => x.value)), pc), ...problems].join("; ");
    md += `| ${e.scenario} | ${e.candidate} | ${e.bar} | ${measured} | ${e.pass ? "pass" : "fail"} |\n`;
  }
}
fs.writeFileSync(path.join(RES, "results.json"), JSON.stringify(results, null, 2));
fs.writeFileSync(path.join(RES, "tables.md"), md);
console.log(md);
const missed = results.expected.filter((e) => !e.pass);
for (const e of missed) console.error(`expected outcome failed: ${e.scenario} ${e.candidate}: ${e.bar}`);
if (missed.length) process.exitCode = 2;
