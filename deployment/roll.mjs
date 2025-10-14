// Blue/green rollout for Fly Machines
// Requires: FLY_API_TOKEN, FLY_APP_NAME, IMAGE_REF

const APP = process.env.FLY_APP_NAME;
const IMAGE = process.env.IMAGE_REF;
const TOK = process.env.FLY_API_TOKEN;
const DRAIN_DELAY_SECS = parseInt(process.env.DRAIN_DELAY_SECS || "15", 10);
const MACH = "https://api.machines.dev/v1";
const H = {
  Authorization: `Bearer ${TOK}`,
  "Content-Type": "application/json",
};

async function listMachines() {
  const r = await fetch(`${MACH}/apps/${APP}/machines`, { headers: H });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

import { buildMachineConfig } from "./config.mjs";

async function createGreen(oldMachine) {
  const region = oldMachine.region;
  const mounts = Array.isArray(oldMachine.config?.mounts)
    ? oldMachine.config.mounts
    : [];
  const stateful = mounts.length > 0;
  const volumeName = stateful ? mounts[0]?.volume : undefined;
  const cfg = buildMachineConfig({ image: IMAGE, stateful, volumeName });
  const body = { region, config: cfg };
  const r = await fetch(`${MACH}/apps/${APP}/machines`, {
    method: "POST",
    headers: H,
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

async function getMachine(id) {
  const r = await fetch(`${MACH}/apps/${APP}/machines/${id}`, { headers: H });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

async function waitHealthy(id, maxSec = 180) {
  for (let i = 0; i < maxSec; i++) {
    const m = await getMachine(id);
    const passing =
      m.state === "started" &&
      (!m.checks ||
        Object.values(m.checks).every((c) => c.status === "passing"));
    if (passing) return;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Machine ${id} not healthy in time`);
}

async function stopMachine(id) {
  const r = await fetch(`${MACH}/apps/${APP}/machines/${id}/stop`, {
    method: "POST",
    headers: H,
  });
  if (!r.ok) {
    const text = await r.text();
    // Ignore already stopped errors
    if (
      !text.includes("already stopped") &&
      !text.includes("not currently started")
    ) {
      throw new Error(text);
    }
  }
}

async function waitStopped(id, maxSec = 30) {
  for (let i = 0; i < maxSec; i++) {
    const m = await getMachine(id);
    if (m.state === "stopped" || m.state === "destroyed") return;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`Machine ${id} did not stop in time`);
}

async function destroyMachine(id) {
  const r = await fetch(`${MACH}/apps/${APP}/machines/${id}`, {
    method: "DELETE",
    headers: H,
  });
  if (!r.ok) throw new Error(await r.text());
}

async function main() {
  if (!APP || !IMAGE || !TOK)
    throw new Error("Missing FLY_APP_NAME, IMAGE_REF, or FLY_API_TOKEN");
  const machines = await listMachines();
  // Group by region for safer rolling replacement
  const byRegion = machines.reduce((acc, m) => {
    acc[m.region] = acc[m.region] || [];
    acc[m.region].push(m);
    return acc;
  }, {});

  for (const region of Object.keys(byRegion)) {
    const oldMachines = byRegion[region];
    // 1) Create greens for all olds
    const greenMachines = [];
    for (const old of oldMachines) {
      const green = await createGreen(old);
      console.log(`Created green ${green.id} for ${old.id}`);
      greenMachines.push({ green, old });
    }
    // 2) Wait all greens healthy
    for (const pair of greenMachines) {
      await waitHealthy(pair.green.id);
      console.log(`Green ${pair.green.id} healthy`);
    }
    // 3) Grace period to allow WS reconnects
    if (DRAIN_DELAY_SECS > 0) {
      await new Promise((r) => setTimeout(r, DRAIN_DELAY_SECS * 1000));
    }
    // 4) Stop and destroy blues sequentially with small delay
    for (const pair of greenMachines) {
      await stopMachine(pair.old.id);
      await waitStopped(pair.old.id);
      await destroyMachine(pair.old.id);
      console.log(`Rolled ${pair.old.id} -> ${pair.green.id} in ${region}`);
      if (DRAIN_DELAY_SECS > 0) {
        await new Promise((r) =>
          setTimeout(r, Math.max(5, Math.min(30, DRAIN_DELAY_SECS)) * 1000)
        );
      }
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
