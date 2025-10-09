// Fly.io Machines + GraphQL provisioning
// Requires: FLY_API_TOKEN, FLY_APP_NAME, IMAGE_REF
// Optional: REGIONS (csv), MACHINE_COUNT, VOLUME_SIZE_GB, SECRETS_JSON

const FLY_TOKEN = process.env.FLY_API_TOKEN;
const APP = process.env.FLY_APP_NAME;
const IMAGE = process.env.IMAGE_REF;
const REGIONS = (process.env.REGIONS || "iad,sea,ams").split(",");
const COUNT = parseInt(process.env.MACHINE_COUNT || "2", 10);
const VOL_SIZE = parseInt(process.env.VOLUME_SIZE_GB || "3", 10);

const GQL = "https://api.fly.io/graphql";
const MACHINES = "https://api.machines.dev/v1";

const headers = (extra = {}) => ({
  Authorization: `Bearer ${FLY_TOKEN}`,
  "Content-Type": "application/json",
  ...extra,
});

async function gql(query, variables) {
  const r = await fetch(GQL, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  if (j.errors) throw new Error(JSON.stringify(j.errors));
  return j.data;
}

async function getDefaultOrgId() {
  const q = `query { organizations { nodes { id slug type } } }`;
  const d = await gql(q, {});
  if (!d.organizations.nodes.length) throw new Error("No organizations found");
  return d.organizations.nodes[0].id;
}

async function createAppIfNeeded() {
  const orgId = await getDefaultOrgId();
  const mu = `mutation($orgId: ID!, $name: String!) {
    createApp(input: { organizationId: $orgId, name: $name, runtime: "machines" }) { app { id name } }
  }`;
  try {
    const res = await gql(mu, { orgId, name: APP });
    return res.createApp.app.id;
  } catch (_e) {
    const q = `query($name:String!){ app(name:$name){ id name } }`;
    const d = await gql(q, { name: APP });
    return d.app.id;
  }
}

async function setSecrets() {
  const secrets = {
    SECRET_KEY_BASE: process.env.SECRET_KEY_BASE || "",
    PHX_HOST: `${APP}.fly.dev`,
    LASSO_CHAINS_PATH: "/data/chains.yml",
    LASSO_SNAPSHOTS_DIR: "/data/benchmark_snapshots",
    LASSO_BACKUP_DIR: "/data/config_backups",
    INFURA_API_KEY: process.env.INFURA_API_KEY || "",
    ALCHEMY_API_KEY: process.env.ALCHEMY_API_KEY || "",
  };
  if (process.env.SECRETS_JSON)
    Object.assign(secrets, JSON.parse(process.env.SECRETS_JSON));

  const appId = (
    await gql(`query($name:String!){ app(name:$name){ id } }`, { name: APP })
  ).app.id;
  const arr = Object.entries(secrets)
    .filter(([, v]) => v !== "")
    .map(([k, v]) => ({ key: k, value: v }));
  if (!arr.length) return;
  const q = `mutation($appId: ID!, $secrets: [SecretInput!]!) {
    setSecrets(input: { appId: $appId, secrets: $secrets }) { release { id } }
  }`;
  await gql(q, { appId, secrets: arr });
}

async function ensureVolume(region, name) {
  const body = { name, size_gb: VOL_SIZE, region };
  const r = await fetch(`${MACHINES}/apps/${APP}/volumes`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    const t = await r.text();
    if (!t.includes("already exists")) throw new Error(`volume ${region} ${t}`);
  }
}

function machineConfig(region, volumeName) {
  return {
    image: IMAGE,
    platform: "linux/amd64",
    restart: { policy: "always" },
    auto_destroy: false,
    stop: { signal: "SIGINT", timeout: "30s" },
    guest: { cpu_kind: "shared", cpus: 1, memory_mb: 1024 },
    mounts: [{ volume: volumeName, path: "/data" }],
    env: { PORT: "4000", PHX_SERVER: "true" },
    services: [
      {
        protocol: "tcp",
        internal_port: 4000,
        ports: [
          { port: 80, handlers: ["http"] },
          { port: 443, handlers: ["tls", "http"] },
        ],
        concurrency: { type: "connections", soft_limit: 500, hard_limit: 1000 },
      },
    ],
    checks: {
      http: {
        type: "http",
        port: 4000,
        path: "/api/health",
        interval: "10s",
        timeout: "2s",
        grace_period: "15s",
        method: "GET",
      },
    },
  };
}

async function launchMachines() {
  for (const region of REGIONS) {
    const volumeName = `data_${region}`;
    await ensureVolume(region, volumeName);
    for (let i = 0; i < COUNT; i++) {
      const cfg = machineConfig(region, volumeName);
      const body = { region, config: cfg };
      const r = await fetch(`${MACHINES}/apps/${APP}/machines`, {
        method: "POST",
        headers: headers(),
        body: JSON.stringify(body),
      });
      if (!r.ok) throw new Error(await r.text());
    }
  }
}

async function main() {
  if (!FLY_TOKEN || !APP || !IMAGE)
    throw new Error("Missing FLY_API_TOKEN, FLY_APP_NAME, or IMAGE_REF");
  await createAppIfNeeded();
  await setSecrets();
  await launchMachines();
  console.log("Provisioned app, secrets, volumes, and machines.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
