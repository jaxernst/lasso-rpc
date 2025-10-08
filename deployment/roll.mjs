// Blue/green rollout for Fly Machines
// Requires: FLY_API_TOKEN, FLY_APP_NAME, IMAGE_REF

const APP = process.env.FLY_APP_NAME;
const IMAGE = process.env.IMAGE_REF;
const TOK = process.env.FLY_API_TOKEN;
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

async function createGreen(oldMachine) {
  // Reuse region and mounts (volume name) but update image
  const region = oldMachine.region;
  const cfg = oldMachine.config;
  cfg.image = IMAGE;
  // Ensure stop + connections concurrency present
  cfg.stop = cfg.stop || { signal: "SIGINT", timeout: "30s" };
  if (cfg.services && cfg.services[0]) {
    cfg.services[0].concurrency = cfg.services[0].concurrency || {
      type: "connections",
      soft_limit: 500,
      hard_limit: 1000,
    };
  }
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

async function waitHealthy(id, maxSec = 120) {
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
    for (const old of byRegion[region]) {
      const green = await createGreen(old);
      await waitHealthy(green.id);
      await destroyMachine(old.id);
      console.log(`Rolled ${old.id} -> ${green.id} in ${region}`);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
