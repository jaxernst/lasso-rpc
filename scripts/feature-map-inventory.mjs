import { readFileSync, readdirSync, existsSync } from "node:fs";
import { basename, join } from "node:path";

function files(root, accept) {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    const path = join(root, entry.name);
    return entry.isDirectory() ? files(path, accept) : accept(path) ? [path] : [];
  });
}

// One file declares one promise. All catalogue readers share this inventory.
export function readFeatureMap(root = "docs/verification") {
  const errors = [];
  const entries = new Map();
  for (const path of files(root, p => /\/(cloud|core)\/.*\.md$/.test(p))) {
    const source = readFileSync(path, "utf8");
    const declarations = [...source.matchAll(/^- `([a-z][a-z0-9-]*-\d+)` (.+)$/gm)];
    if (basename(path) === "README.md") {
      if (declarations.length) errors.push(`${path}: feature IDs belong in their own files`);
      continue;
    }
    const id = basename(path, ".md");
    if (!/\/(cloud|core)\/[^/]+\/[^/]+\.md$/.test(path) || !/^[a-z][a-z0-9-]*-\d+$/.test(id)) {
      errors.push(`${path}: expected <area>/<feature-id>.md`);
    }
    if (declarations.length !== 1) errors.push(`${path}: expected exactly one feature ID and statement`);
    for (const [, declared, promise] of declarations) {
      if (declared !== id) errors.push(`${path}: feature ID ${declared} does not match file name ${id}`);
      if (entries.has(id)) errors.push(`${path}: duplicate feature ID ${declared}`);
      entries.set(id, { path, unguarded: /\bunguarded\b/.test(promise) });
    }
    const recipe = source.split(/^## Driving[^\n]*\n/m)[1]?.split(/^## /m)[0].trim();
    if (!recipe) errors.push(`${path}: missing driving recipe and oracle`);
  }
  if (!entries.size) errors.push(`${root}: no feature map found`);
  return { entries, errors };
}
