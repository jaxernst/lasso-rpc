#!/usr/bin/env node
// The map owns promises; literal ExUnit tags and outer-layer metadata own guard citations.
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

function files(root, accept) {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    const path = join(root, entry.name);
    return entry.isDirectory() ? files(path, accept) : accept(path) ? [path] : [];
  });
}

const errors = [];
const promises = new Map();
const guards = new Set();
const cite = (id, location) => {
  if (!promises.has(id)) errors.push(`${location}: unknown feature ID ${id}`);
  guards.add(id);
};

for (const path of files("docs/verification", p => /\/(cloud|core)\/[^/]+\.md$/.test(p) && !p.endsWith("/README.md"))) {
  const source = readFileSync(path, "utf8");
  const list = source.split(/^## Sub-features\s*$/m)[1]?.split(/^## /m)[0] ?? "";
  const entries = [...list.matchAll(/^- `([a-z][a-z0-9-]*-\d+)` (.+)$/gm)];
  if (!entries.length) errors.push(`${path}: no sub-features`);
  for (const line of list.split("\n").filter(line => line.startsWith("- "))) {
    if (!/^- `[a-z][a-z0-9-]*-\d+` .+/.test(line)) errors.push(`${path}: malformed sub-feature: ${line}`);
  }
  for (const [, id, promise] of entries) {
    if (promises.has(id)) errors.push(`${path}: duplicate feature ID ${id}`);
    promises.set(id, { path, unguarded: /\bunguarded\b/.test(promise) });
  }
}
if (!promises.size) errors.push("docs/verification: no feature map found");

// Harness contract tests exercise the fixtures/adapters, not product promises.
// Keep this exemption confined to the documented support-test subtree.
const tests = ["test", "harness/test"].flatMap(root => files(root, p => /\.(ex|exs)$/.test(p)))
  .filter(path => !path.startsWith("harness/test/support/"));
const parsed = tests.length ? spawnSync("elixir", [new URL("./feature_map_tags.exs", import.meta.url).pathname], {
  input: tests.flatMap(path => [path, readFileSync(path, "utf8")]).join("\0"),
  encoding: "utf8", maxBuffer: 1 << 26
}) : { status: 0, stdout: "" };
if (parsed.status !== 0) errors.push(`feature tag parser failed: ${parsed.stderr || parsed.error?.message}`);
for (const line of (parsed.stdout ?? "").split("\n").filter(Boolean)) {
  const [kind, location, value] = line.split("\t");
  if (kind === "tag") {
    if (!promises.has(value)) errors.push(`${location}: unknown feature ID ${value}`);
  } else if (kind === "guard") cite(value, location);
  else errors.push(`${location}: ${value}`);
}

// Probe/eval owners place a sibling <recipe>.features.json beside the actual recipe.
// Its metadata is {"features":["id"]}; the recipe must exist, so detached citations fail.
for (const root of ["scripts", "docs/internal/adoption-evals/cases"]) {
  for (const path of files(root, p => p.endsWith(".features.json"))) {
    try {
      const metadata = JSON.parse(readFileSync(path, "utf8"));
      if (!existsSync(path.slice(0, -".features.json".length))) throw new Error("citation has no recipe");
      if (!Array.isArray(metadata.features) || !metadata.features.length || !metadata.features.every(id => typeof id === "string")) throw new Error("features must be a nonempty literal array of IDs");
      for (const id of metadata.features) cite(id, path);
    } catch (error) {
      errors.push(`${path}: ${error.message}`);
    }
  }
}

for (const [id, entry] of promises) {
  if (!guards.has(id) && !entry.unguarded) errors.push(`${entry.path}: ${id} has no guard; mark it unguarded`);
  if (guards.has(id) && entry.unguarded) errors.push(`${entry.path}: ${id} has a guard; remove its unguarded marker`);
}
const unguarded = [...promises.values()].filter(entry => entry.unguarded).length;
const guarded = [...promises.keys()].filter(id => guards.has(id)).length;
console.log(`Feature map: ${promises.size} sub-features, ${guarded} guarded, ${unguarded} unguarded`);
if (errors.length) {
  console.error([...new Set(errors)].join("\n"));
  process.exitCode = 1;
}
