import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const checker = new URL("./feature-map.mjs", import.meta.url).pathname;
function world(t) {
  const root = mkdtempSync(join(tmpdir(), "core-feature-map-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const write = (path, source) => {
    mkdirSync(join(root, path, ".."), { recursive: true });
    writeFileSync(join(root, path), source);
  };
  const entry = "docs/verification/core/reads/core-read-1.md";
  const promise = '# core-read-1\n\n- `core-read-1` A read reaches the backup.\n\n## Driving it through surfaces\n\nFail the primary; require the backup result and one send per provider.\n';
  write(entry, promise);
  write("docs/verification/core/reads/README.md", "# Reads\n\nTwo owned upstreams.\n");
  const source = tags => write("harness/test/read_test.exs", `defmodule Read do\n  use ExUnit.Case\n  ${tags}\n  test "read", do: assert true\nend\n`);
  const run = (status, pattern) => {
    const p = spawnSync(process.execPath, [checker], { cwd: root, encoding: "utf8" });
    assert.equal(p.status, status, p.stdout + p.stderr);
    assert.match(p.stdout + p.stderr, pattern);
  };
  return { write, source, run, entry, promise };
}

test("per-feature guards retain missing, stale, unknown and skipped-tag checks", t => {
  const { write, source, run, entry, promise } = world(t);
  source('@tag feature: ["core-read-1"]');
  run(0, /1 sub-features, 1 guarded, 0 unguarded/);
  source('@tag feature: ["missing-1"]');
  run(1, /unknown feature ID missing-1/);
  source('@tag feature: ["core-read-1"]\n@tag :skip');
  run(1, /core-read-1 has no guard/);
  source("");
  run(1, /harness-lane test has no feature tag/);
  write(entry, promise.replace('A read reaches the backup.', 'A read reaches the backup. **unguarded**.'));
  source('@tag feature: ["core-read-1"]');
  run(1, /has a guard; remove its unguarded marker/);
});

test("a file declares exactly its filename ID and its recipe; flat areas fail", t => {
  const { write, source, run, entry, promise } = world(t);
  source('@tag feature: ["core-read-1"]');
  write(entry, promise.replace('`core-read-1`', '`core-read-2`'));
  run(1, /does not match file name core-read-1/);
  write(entry, "# Missing promise\n");
  run(1, /expected exactly one feature ID and statement/);
  write(entry, promise.split('## Driving')[0]);
  run(1, /missing driving recipe and oracle/);
  write(entry, promise);
  write("docs/verification/core/other/core-read-1.md", promise);
  run(1, /duplicate feature ID core-read-1/);
  write("docs/verification/core/legacy.md", promise);
  run(1, /expected <area>\/<feature-id>\.md/);
});
