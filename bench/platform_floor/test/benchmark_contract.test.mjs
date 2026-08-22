import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import test from "node:test";

const benchmarkRoot = fileURLToPath(new URL("..", import.meta.url));

async function freePort() {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  server.close();
  await once(server, "close");
  return port;
}

async function waitFor(url, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url, { headers: { connection: "close" } });
      if (response.ok) return;
    } catch {
      // The clustered data and admin listeners may not be ready yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timed out waiting for ${url}`);
}

async function stop(child) {
  if (child.exitCode !== null) return;
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("child did not exit")), 5_000);
    child.once("exit", () => {
      clearTimeout(timeout);
      resolve();
    });
    child.kill("SIGTERM");
  });
}

function runNode(script, arguments_, options = {}) {
  return spawn(process.execPath, [script, ...arguments_], {
    cwd: benchmarkRoot,
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  });
}

async function collect(child) {
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const [code, signal] = await once(child, "exit");
  assert.equal(signal, null, stderr);
  assert.equal(code, 0, stderr);
  return stdout;
}

test("clustered upstream and multi-worker driver preserve exact amplification", async (t) => {
  const dataPort = await freePort();
  const adminPort = await freePort();
  const upstream = runNode("synthetic_upstream.mjs", [], {
    env: {
      ...process.env,
      PORT: String(dataPort),
      ADMIN_PORT: String(adminPort),
      WORKERS: "2",
      RESPONSE_DELAY_MS: "0",
    },
  });
  t.after(() => stop(upstream));
  await waitFor(`http://127.0.0.1:${adminPort}/stats`);

  const driver = runNode("load_driver.mjs", [
    `--url=http://127.0.0.1:${dataPort}`,
    "--workers=2",
    "--concurrency=4",
    "--warmup=0.05",
    "--duration=0.1",
    "--timeout=2000",
    `--upstreamAdminUrl=http://127.0.0.1:${adminPort}`,
    "--label=contract-test",
  ]);
  const output = JSON.parse((await collect(driver)).trim());

  assert.equal(output.label, "contract-test");
  assert.equal(output.workload.workerCount, 2);
  assert.equal(output.counters.errors, 0);
  assert.ok(output.counters.success > 0);
  assert.equal(output.counters.started, output.counters.success);
  assert.equal(output.upstream.stats.workers, 2);
  assert.equal(output.upstream.stats.totals.benchmarkRequests, output.counters.success);
  assert.equal(output.upstream.stats.totals.benchmarkResponses, output.counters.success);
  assert.equal(output.upstream.reset.totals.connectionsAccepted, 0);
  assert.equal(output.latencyUs.bins, undefined);
});

test("driver rejects more workers than concurrent requests", async () => {
  const driver = runNode("load_driver.mjs", [
    "--url=http://127.0.0.1:1",
    "--workers=3",
    "--concurrency=2",
    "--duration=0.1",
  ]);
  let stderr = "";
  driver.stderr.on("data", (chunk) => { stderr += chunk; });
  const [code] = await once(driver, "exit");

  assert.notEqual(code, 0);
  assert.match(stderr, /workers must be less than or equal to concurrency/);
});
