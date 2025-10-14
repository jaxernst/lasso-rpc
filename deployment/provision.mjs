// Fly.io Machines + GraphQL provisioning
// Requires: FLY_API_TOKEN, FLY_APP_NAME, IMAGE_REF
// Optional: REGIONS (csv), MACHINE_COUNT, VOLUME_SIZE_GB, SECRETS_JSON

const FLY_TOKEN = process.env.FLY_API_TOKEN;
const APP = process.env.FLY_APP_NAME;
const IMAGE = process.env.IMAGE_REF;
const REGIONS = (process.env.REGIONS || "iad,sea,ams").split(",");
const COUNT = parseInt(process.env.MACHINE_COUNT || "2", 10);
const VOL_SIZE = parseInt(process.env.VOLUME_SIZE_GB || "3", 10);
const STATEFUL = false;
String(process.env.STATEFUL || "false").toLowerCase() === "true" ||
  String(process.env.STATEFUL || "0") === "1";

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
    INFURA_API_KEY: process.env.INFURA_API_KEY || "",
    ALCHEMY_API_KEY: process.env.ALCHEMY_API_KEY || "",
  };

  if (STATEFUL) {
    Object.assign(secrets, {
      LASSO_CHAINS_PATH: "/data/chains.yml",
      LASSO_SNAPSHOTS_DIR: "/data/benchmark_snapshots",
      LASSO_BACKUP_DIR: "/data/config_backups",
    });
  }

  if (process.env.SECRETS_JSON) {
    Object.assign(secrets, JSON.parse(process.env.SECRETS_JSON));
  }

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

import { buildMachineConfig } from "./config.mjs";

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function launchMachines() {
  for (const region of REGIONS) {
    for (let i = 0; i < COUNT; i++) {
      const volumeName = STATEFUL ? `data_${region}_${i}` : undefined;
      if (STATEFUL) {
        await ensureVolume(region, volumeName);
      }
      const cfg = buildMachineConfig({
        image: IMAGE,
        stateful: STATEFUL,
        volumeName,
      });
      const body = { region, config: cfg };

      // Retry with exponential backoff for registry tag propagation, which can be slow
      let lastError;
      for (let attempt = 0; attempt < 10; attempt++) {
        const r = await fetch(`${MACHINES}/apps/${APP}/machines`, {
          method: "POST",
          headers: headers(),
          body: JSON.stringify(body),
        });

        if (r.ok) {
          const machine = await r.json();
          console.log(`Created machine ${machine.id} in ${region}`);
          break;
        }

        const errorText = await r.text();
        lastError = errorText;

        // Check if it's a manifest/registry error that might resolve with retry
        if (
          errorText.includes("MANIFEST_UNKNOWN") ||
          errorText.includes("manifest unknown") ||
          errorText.includes("unknown tag")
        ) {
          const delay = Math.min(Math.pow(2, attempt) * 1000, 30000); // cap at 30s
          console.log(
            `Manifest not ready, retrying in ${delay}ms (attempt ${
              attempt + 1
            }/10)...`
          );
          await sleep(delay);
          continue;
        }

        // Other errors, fail immediately
        throw new Error(errorText);
      }

      if (lastError) {
        throw new Error(`Failed after 10 retries: ${lastError}`);
      }
    }
  }
}

async function main() {
  if (!FLY_TOKEN || !APP || !IMAGE)
    throw new Error("Missing FLY_API_TOKEN, FLY_APP_NAME, or IMAGE_REF");
  await createAppIfNeeded();
  await setSecrets();
  await launchMachines();
  console.log(
    `Provisioned app, secrets, ${STATEFUL ? "volumes and " : ""}machines.`
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
