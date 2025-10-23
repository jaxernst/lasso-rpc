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

    // Print summary statistics
    console.log("\n=== Summary ===");
    const methods = new Set(rows.map((r) => r.method));
    const providers = new Set(rows.map((r) => r.provider_id));
    const transports = new Set(rows.map((r) => r.transport_type));

    console.log(`Methods: ${methods.size} (${Array.from(methods).join(", ")})`);
    console.log(
      `Providers: ${providers.size} (${Array.from(providers).join(", ")})`
    );
    console.log(
      `Transports: ${transports.size} (${Array.from(transports).join(", ")})`
    );

    // Show top 3 fastest average latencies for most common method
    const methodCounts = new Map();
    rows.forEach((r) => {
      methodCounts.set(r.method, (methodCounts.get(r.method) || 0) + 1);
    });
    const mostCommon = Array.from(methodCounts.entries()).sort(
      (a, b) => b[1] - a[1]
    )[0];

    if (mostCommon) {
      const [method] = mostCommon;
      const methodRows = rows
        .filter((r) => r.method === method)
        .sort((a, b) => a.avg_latency_ms - b.avg_latency_ms)
        .slice(0, 3);

      console.log(`\nTop 3 fastest for ${method}:`);
      methodRows.forEach((r, i) => {
        console.log(
          `  ${i + 1}. ${r.provider_name} (${r.transport_type}): ${r.avg_latency_ms}ms avg`
        );
      });
    }
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
