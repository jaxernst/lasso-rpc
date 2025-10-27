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

import { writeFile } from "fs/promises";
import { join } from "path";

// -----------------------------
// Argument parsing
// -----------------------------
function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    url: process.env.METRICS_URL || "http://localhost:4000/api/metrics",
    chain: process.env.CHAIN || "ethereum",
    output: process.env.OUTPUT || null, // auto-generate if not specified
    timeout: Number(process.env.TIMEOUT) || 10000, // ms
    format: process.env.FORMAT || "csv", // csv or json
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
      case "--chain":
      case "-c":
        opts.chain = next();
        i++;
        break;
      case "--output":
      case "-o":
        opts.output = next();
        i++;
        break;
      case "--timeout":
      case "-t":
        opts.timeout = Number(next());
        i++;
        break;
      case "--format":
      case "-f":
        opts.format = next();
        i++;
        break;
      case "--help":
      case "-h":
        printHelpAndExit();
        break;
      default:
        break;
    }
  }

  // Auto-generate output filename if not specified
  if (!opts.output) {
    const ext = opts.format === "json" ? "json" : "csv";
    opts.output = `${opts.chain}_rpc_performance.${ext}`;
  }

  return opts;
}

function printHelpAndExit() {
  console.log(
    `Usage: node scripts/export_metrics_csv.mjs [options]\n\n` +
      `Fetches RPC performance metrics and exports to CSV or JSON.\n\n` +
      `Options:\n` +
      `  -u, --url <url>        Metrics base URL (default: http://localhost:4000/api/metrics)\n` +
      `  -c, --chain <name>     Chain name (default: ethereum)\n` +
      `  -o, --output <file>    Output file (default: {chain}_rpc_performance.csv)\n` +
      `  -t, --timeout <ms>     Request timeout ms (default: 10000)\n` +
      `  -f, --format <type>    Output format: csv or json (default: csv)\n` +
      `  -h, --help             Show this help\n\n` +
      `Examples:\n` +
      `  node scripts/export_metrics_csv.mjs\n` +
      `  node scripts/export_metrics_csv.mjs --chain base --output base_metrics.csv\n` +
      `  node scripts/export_metrics_csv.mjs --format json --output metrics.json\n`
  );
  process.exit(0);
}

const options = parseArgs(process.argv);

// -----------------------------
// Fetch metrics
// -----------------------------
async function fetchMetrics(baseUrl, chain, timeoutMs) {
  const url = `${baseUrl}/${chain}`;
  console.log(`Fetching metrics from: ${url}`);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      method: "GET",
      headers: { accept: "application/json" },
      signal: controller.signal,
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(
        `HTTP ${res.status}: ${res.statusText}\n${text.slice(0, 200)}`
      );
    }

    const json = await res.json();
    return json;
  } catch (err) {
    throw new Error(
      `Failed to fetch metrics: ${err.message || String(err)}`
    );
  } finally {
    clearTimeout(timer);
  }
}

// -----------------------------
// Parse and transform data
// -----------------------------
function parseMethodName(methodWithTransport) {
  // Split on @ to separate method from transport
  // e.g., "eth_getLogs@http" -> ["eth_getLogs", "http"]
  const parts = methodWithTransport.split("@");
  if (parts.length === 2) {
    return { method: parts[0], transport: parts[1] };
  }
  // Fallback: no transport suffix
  return { method: methodWithTransport, transport: "unknown" };
}

function transformToRows(metricsData) {
  const rows = [];

  // Extract from rpc_performance_by_method
  const byMethod = metricsData.rpc_performance_by_method || [];

  for (const methodEntry of byMethod) {
    const methodWithTransport = methodEntry.method;
    const { method, transport } = parseMethodName(methodWithTransport);

    for (const providerData of methodEntry.providers || []) {
      rows.push({
        method: method,
        provider_id: providerData.provider_id,
        provider_name: providerData.provider_name,
        transport_type: transport,
        success_rate: providerData.success_rate,
        p50_latency_ms: providerData.p50_latency_ms,
        p90_latency_ms: providerData.p90_latency_ms,
        p95_latency_ms: providerData.p95_latency_ms,
        p99_latency_ms: providerData.p99_latency_ms,
        avg_latency_ms: providerData.avg_latency_ms,
        total_calls: providerData.total_calls,
        last_updated: providerData.last_updated,
      });
    }
  }

  // Sort rows to group by method, then transport, then provider
  // This ensures http and ws for the same method appear together
  rows.sort((a, b) => {
    // Primary sort: by method name
    if (a.method !== b.method) {
      return a.method.localeCompare(b.method);
    }
    // Secondary sort: by transport (http before ws)
    if (a.transport_type !== b.transport_type) {
      const transportOrder = { http: 0, ws: 1, unknown: 2 };
      return (
        (transportOrder[a.transport_type] || 999) -
        (transportOrder[b.transport_type] || 999)
      );
    }
    // Tertiary sort: by provider name
    return a.provider_name.localeCompare(b.provider_name);
  });

  return rows;
}

// -----------------------------
// CSV formatting
// -----------------------------
function escapeCSVField(value) {
  if (value == null) return "";
  const str = String(value);
  // Escape quotes and wrap in quotes if contains comma, newline, or quote
  if (str.includes(",") || str.includes("\n") || str.includes('"')) {
    return `"${str.replace(/"/g, '""')}"`;
  }
  return str;
}

function rowsToCSV(rows) {
  if (rows.length === 0) {
    return "# No data available\n";
  }

  const headers = Object.keys(rows[0]);
  const lines = [headers.map(escapeCSVField).join(",")];

  for (const row of rows) {
    const values = headers.map((h) => escapeCSVField(row[h]));
    lines.push(values.join(","));
  }

  return lines.join("\n") + "\n";
}

// -----------------------------
// Comprehensive Analysis
// -----------------------------
function printComprehensiveAnalysis(rows, metricsData) {
  console.log("\n╔════════════════════════════════════════════════════════════════╗");
  console.log("║              RPC PROVIDER PERFORMANCE DASHBOARD                ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");

  const methods = new Set(rows.map((r) => r.method));
  const providers = new Set(rows.map((r) => r.provider_id));
  const transports = new Set(rows.map((r) => r.transport_type));
  const totalCalls = rows.reduce((sum, r) => sum + r.total_calls, 0);

  // Compute provider stats
  const providerStats = new Map();
  rows.forEach((r) => {
    if (!providerStats.has(r.provider_id)) {
      providerStats.set(r.provider_id, {
        name: r.provider_name,
        totalLatency: 0,
        totalCalls: 0,
        successRates: [],
        methods: new Set(),
        p50s: [],
        p99s: [],
      });
    }
    const stats = providerStats.get(r.provider_id);
    stats.totalLatency += r.avg_latency_ms * r.total_calls;
    stats.totalCalls += r.total_calls;
    stats.successRates.push(r.success_rate);
    stats.methods.add(r.method);
    stats.p50s.push(r.p50_latency_ms);
    stats.p99s.push(r.p99_latency_ms);
  });

  const providerRankings = Array.from(providerStats.entries())
    .map(([id, stats]) => ({
      id,
      name: stats.name,
      avgLatency: stats.totalLatency / stats.totalCalls,
      minSuccessRate: Math.min(...stats.successRates),
      avgSuccessRate: stats.successRates.reduce((a, b) => a + b, 0) / stats.successRates.length,
      totalCalls: stats.totalCalls,
      methodCount: stats.methods.size,
      avgP50: stats.p50s.reduce((a, b) => a + b, 0) / stats.p50s.length,
      avgP99: stats.p99s.reduce((a, b) => a + b, 0) / stats.p99s.length,
    }))
    .sort((a, b) => a.avgLatency - b.avgLatency);

  const fastest = providerRankings[0];
  const slowest = providerRankings[providerRankings.length - 1];

  // Executive Summary
  console.log("\n📋 EXECUTIVE SUMMARY");
  console.log("─".repeat(64));
  console.log(`Dataset: ${totalCalls.toLocaleString()} total calls across ${providers.size} providers`);
  console.log(`Methods: ${Array.from(methods).join(", ")}`);
  console.log();
  console.log(`🥇 Fastest Provider: ${fastest.name} (${fastest.avgLatency.toFixed(0)}ms avg)`);
  const speedDiff = (slowest.avgLatency / fastest.avgLatency).toFixed(1);
  console.log(`📊 Performance Spread: ${speedDiff}x difference (${fastest.avgLatency.toFixed(0)}ms - ${slowest.avgLatency.toFixed(0)}ms)`);

  const realIssues = rows.filter((r) => r.success_rate < 0.95);
  if (realIssues.length > 0) {
    console.log(`⚠️  Reliability: ${realIssues.length} critical issues detected`);
  } else {
    const minorIssues = rows.filter((r) => r.success_rate < 1.0);
    if (minorIssues.length > 0) {
      console.log(`✓ Reliability: Excellent (${minorIssues.length} minor issues < 100%)`);
    } else {
      console.log(`✓ Reliability: Perfect (100% success across all providers)`);
    }
  }

  // Provider Performance Matrix
  console.log("\n🏆 PROVIDER PERFORMANCE MATRIX");
  console.log("─".repeat(64));
  console.log("Rank  Provider                  Avg Latency  P50   P99   Success  Volume");
  console.log("─".repeat(64));

  providerRankings.forEach((p, i) => {
    const medal = i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : "  ";
    const rank = (i + 1).toString().padStart(2);
    const latencyBar = "█".repeat(Math.max(1, Math.ceil(15 - (p.avgLatency / slowest.avgLatency) * 10)));
    const successIcon = p.minSuccessRate >= 1.0 ? "✓" : p.minSuccessRate >= 0.99 ? "~" : "✗";
    const volumePct = ((p.totalCalls / totalCalls) * 100).toFixed(0);

    console.log(
      `${medal}${rank}  ${p.name.padEnd(24)} ` +
      `${p.avgLatency.toFixed(0).padStart(4)}ms ${latencyBar.padEnd(5)} ` +
      `${p.avgP50.toFixed(0).padStart(4)} ${p.avgP99.toFixed(0).padStart(5)} ` +
      `${successIcon} ${(p.avgSuccessRate * 100).toFixed(1)}% ${volumePct.padStart(3)}%`
    );
  });

  // Method-specific performance with visual bars
  console.log("\n⚡ METHOD PERFORMANCE BREAKDOWN");
  console.log("─".repeat(64));

  // Get method call volumes
  const methodCalls = new Map();
  rows.forEach((r) => {
    methodCalls.set(
      r.method,
      (methodCalls.get(r.method) || 0) + r.total_calls
    );
  });

  const sortedMethods = Array.from(methods).sort((a, b) =>
    methodCalls.get(b) - methodCalls.get(a)
  );

  sortedMethods.forEach((method) => {
    const methodRows = rows
      .filter((r) => r.method === method)
      .sort((a, b) => a.avg_latency_ms - b.avg_latency_ms);

    if (methodRows.length === 0) return;

    const best = methodRows[0];
    const worst = methodRows[methodRows.length - 1];
    const calls = methodCalls.get(method);
    const callPct = ((calls / totalCalls) * 100).toFixed(1);

    console.log(`\n${method} (${calls.toLocaleString()} calls, ${callPct}%)`);
    console.log("─".repeat(64));

    // Show top 3 and bottom 1 if there are many providers
    const displayRows = methodRows.length > 4
      ? [...methodRows.slice(0, 3), methodRows[methodRows.length - 1]]
      : methodRows;

    displayRows.forEach((r, idx) => {
      const isLast = idx === displayRows.length - 1 && methodRows.length > 4;
      const actualIdx = isLast ? methodRows.length - 1 : idx;

      // Create visual bar (scaled to worst performer)
      const barLength = Math.max(1, Math.ceil((r.avg_latency_ms / worst.avg_latency_ms) * 30));
      const bar = "█".repeat(barLength);
      const icon = actualIdx === 0 ? "🥇" : actualIdx === 1 ? "🥈" : actualIdx === 2 ? "🥉" : "  ";

      // Include transport type to distinguish providers
      const providerLabel = transports.size > 1
        ? `${r.provider_name} (${r.transport_type})`
        : r.provider_name;

      console.log(
        `${icon} ${providerLabel.padEnd(32)} ${r.avg_latency_ms.toFixed(0).padStart(4)}ms ${bar}`
      );

      if (isLast && methodRows.length > 4) {
        console.log(`   ... ${methodRows.length - 4} providers omitted ...`);
      }
    });
  });

  // Performance consistency analysis
  console.log("\n📊 CONSISTENCY & RELIABILITY");
  console.log("─".repeat(64));

  // Calculate provider-level consistency metrics
  const providerVariance = new Map();
  rows.forEach((r) => {
    if (r.total_calls >= 10) {
      if (!providerVariance.has(r.provider_id)) {
        providerVariance.set(r.provider_id, {
          name: r.provider_name,
          ratios: [],
          spreads: [],
          successRates: [],
        });
      }
      const pv = providerVariance.get(r.provider_id);
      pv.ratios.push(r.p99_latency_ms / r.p50_latency_ms);
      pv.spreads.push(r.p99_latency_ms - r.p95_latency_ms);
      pv.successRates.push(r.success_rate);
    }
  });

  const varianceSummary = Array.from(providerVariance.entries())
    .map(([id, data]) => ({
      id,
      name: data.name,
      avgP99P50: data.ratios.reduce((a, b) => a + b, 0) / data.ratios.length,
      avgSpread: data.spreads.reduce((a, b) => a + b, 0) / data.spreads.length,
      minSuccess: Math.min(...data.successRates),
    }))
    .sort((a, b) => a.avgP99P50 - b.avgP99P50);

  console.log("\nProvider Consistency Ranking (P99/P50 ratio, lower = more consistent):\n");
  varianceSummary.forEach((p, i) => {
    const emoji = p.avgP99P50 < 2.5 ? "🟢" : p.avgP99P50 < 5.0 ? "🟡" : "🔴";
    const successIcon = p.minSuccess >= 1.0 ? "✓" : p.minSuccess >= 0.99 ? "~" : "✗";
    console.log(
      `${emoji} ${(i + 1).toString().padStart(2)}. ${p.name.padEnd(24)} ` +
      `P99/P50: ${p.avgP99P50.toFixed(1)}x | ` +
      `Tail: +${p.avgSpread.toFixed(0).padStart(4)}ms | ` +
      `Reliability: ${successIcon}`
    );
  });

  // Critical issues only (high bar to avoid noise)
  const criticalIssues = rows
    .filter((r) => {
      // Flag reliability issues
      if (r.success_rate < 0.95) return true;
      // Flag extreme tail latency only for high-volume operations
      if (r.total_calls >= 1000 && r.p99_latency_ms / r.p50_latency_ms > 20) return true;
      return false;
    })
    .sort((a, b) => a.success_rate - b.success_rate);

  if (criticalIssues.length > 0) {
    console.log("\n⚠️  CRITICAL ISSUES DETECTED");
    console.log("─".repeat(64));
    criticalIssues.forEach((r) => {
      if (r.success_rate < 0.95) {
        console.log(
          `❌ ${r.provider_name} - ${r.method}@${r.transport_type}: ` +
          `${(r.success_rate * 100).toFixed(1)}% success rate (${r.total_calls} calls)`
        );
      } else {
        const ratio = r.p99_latency_ms / r.p50_latency_ms;
        console.log(
          `⚠️  ${r.provider_name} - ${r.method}@${r.transport_type}: ` +
          `Extreme tail latency ${ratio.toFixed(1)}x (P50: ${r.p50_latency_ms}ms, P99: ${r.p99_latency_ms}ms, ${r.total_calls.toLocaleString()} calls)`
        );
      }
    });
  }

  // Transport comparison (if both exist)
  const transportStats = new Map();
  rows.forEach((r) => {
    if (!transportStats.has(r.transport_type)) {
      transportStats.set(r.transport_type, {
        totalLatency: 0,
        totalCalls: 0,
      });
    }
    const stats = transportStats.get(r.transport_type);
    stats.totalLatency += r.avg_latency_ms * r.total_calls;
    stats.totalCalls += r.total_calls;
  });

  if (transportStats.size > 1) {
    console.log("\n🔌 TRANSPORT COMPARISON");
    console.log("─".repeat(64));

    const transports = Array.from(transportStats.entries())
      .map(([type, stats]) => ({
        type,
        avg: stats.totalLatency / stats.totalCalls,
        calls: stats.totalCalls,
        pct: (stats.totalCalls / totalCalls) * 100,
      }))
      .sort((a, b) => a.avg - b.avg);

    transports.forEach((t, i) => {
      const icon = i === 0 ? "⚡" : "  ";
      const bar = "█".repeat(Math.max(1, Math.ceil((t.pct / 100) * 40)));
      console.log(
        `${icon} ${t.type.toUpperCase().padEnd(10)} ${t.avg.toFixed(0).padStart(4)}ms | ` +
        `${t.calls.toLocaleString().padStart(7)} calls (${t.pct.toFixed(0)}%) ${bar}`
      );
    });

    if (transports.length === 2) {
      const diff = Math.abs(transports[0].avg - transports[1].avg);
      const diffPct = ((diff / transports[1].avg) * 100).toFixed(1);
      console.log(
        `\n💡 ${transports[0].type.toUpperCase()} is ${diffPct}% faster than ${transports[1].type.toUpperCase()}`
      );
    }
  }

  // Key recommendations
  console.log("\n🎯 RECOMMENDATIONS");
  console.log("─".repeat(64));

  // Best overall provider
  console.log(`\n1. PRIMARY PROVIDER: Use ${fastest.name}`);
  console.log(`   • Fastest average latency: ${fastest.avgLatency.toFixed(0)}ms`);
  console.log(`   • Success rate: ${(fastest.avgSuccessRate * 100).toFixed(2)}%`);

  // Most consistent provider
  if (varianceSummary.length > 0) {
    const mostConsistent = varianceSummary[0];
    if (mostConsistent.name !== fastest.name) {
      console.log(`\n2. MOST CONSISTENT: ${mostConsistent.name}`);
      console.log(`   • Lowest P99/P50 variance: ${mostConsistent.avgP99P50.toFixed(1)}x`);
      console.log(`   • Good for latency-sensitive operations`);
    }
  }

  // Method-specific recommendations
  const methodRecommendations = new Map();
  sortedMethods.forEach((method) => {
    const methodRows = rows
      .filter((r) => r.method === method)
      .sort((a, b) => a.avg_latency_ms - b.avg_latency_ms);

    if (methodRows.length > 0) {
      const best = methodRows[0];
      if (best.provider_name !== fastest.name) {
        methodRecommendations.set(method, best);
      }
    }
  });

  if (methodRecommendations.size > 0) {
    const recNum = varianceSummary[0]?.name !== fastest.name ? 3 : 2;
    console.log(`\n${recNum}. METHOD-SPECIFIC: Consider these specialized providers:`);
    Array.from(methodRecommendations.entries()).forEach(([method, best]) => {
      console.log(`   • ${method}: ${best.provider_name} (${best.avg_latency_ms.toFixed(0)}ms)`);
    });
  }

  // Traffic patterns insight
  const topMethod = Array.from(methodCalls.entries()).sort((a, b) => b[1] - a[1])[0];
  const topMethodPct = ((topMethod[1] / totalCalls) * 100).toFixed(0);
  if (Number(topMethodPct) > 50) {
    const nextNum = methodRecommendations.size > 0 ? (varianceSummary[0]?.name !== fastest.name ? 4 : 3) : (varianceSummary[0]?.name !== fastest.name ? 3 : 2);
    console.log(`\n${nextNum}. TRAFFIC OPTIMIZATION: ${topMethod[0]} dominates traffic (${topMethodPct}%)`);
    console.log(`   • Prioritize optimizing this method for best overall impact`);
  }

  console.log("\n" + "═".repeat(64));
  console.log("Report generated at: " + new Date().toISOString());
  console.log("═".repeat(64));
}

// -----------------------------
// Main execution
// -----------------------------
async function run() {
  console.log(`Export Metrics to CSV/JSON`);
  console.log(`  Chain: ${options.chain}`);
  console.log(`  Output: ${options.output}`);
  console.log(`  Format: ${options.format}`);
  console.log();

  try {
    // Fetch metrics
    const metricsData = await fetchMetrics(
      options.url,
      options.chain,
      options.timeout
    );

    // Check if data exists
    if (!metricsData.rpc_performance_by_method) {
      console.warn(
        "Warning: No rpc_performance_by_method data found in response"
      );
      console.warn("Available keys:", Object.keys(metricsData));
      console.warn(
        "\nTip: Make sure the Lasso server has collected enough data."
      );
      console.warn(
        "     Run some RPC requests first, then try exporting again.\n"
      );
    }

    // Transform to rows
    const rows = transformToRows(metricsData);
    console.log(`Extracted ${rows.length} metric rows`);

    if (rows.length === 0) {
      console.warn(
        "No performance data available. The server may not have collected any metrics yet."
      );
      console.warn("Run some RPC traffic first, then try again.");
      process.exit(1);
    }

    // Write output
    let content;
    if (options.format === "json") {
      content = JSON.stringify(
        {
          chain: options.chain,
          exported_at: new Date().toISOString(),
          metrics: rows,
        },
        null,
        2
      );
    } else {
      // CSV format
      content = rowsToCSV(rows);
    }

    await writeFile(options.output, content, "utf8");
    console.log(`✓ Saved to ${options.output}`);

    // Print comprehensive summary statistics
    printComprehensiveAnalysis(rows, metricsData);
  } catch (err) {
    console.error(`\nError: ${err.message}`);
    if (err.stack) {
      console.error("\nStack trace:");
      console.error(err.stack);
    }
    process.exit(1);
  }
}

run().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
