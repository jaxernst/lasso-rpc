## Lasso RPC Production Deployment on Fly.io (Machines)

### Status

- Target: Production-ready
- Reviewers: Platform, Core, Observability
- Goals: Simple regional expansion, zero-downtime, WS-friendly, no cold starts, geo routing, high performance

---

### 1) North Star Objectives

- Simple changes to expand to more regions
- Zero downtime during deploys and failures
- Long-running WebSocket support optimized for blockchain indexing
- Zero cold start time (warm pools, persistent state)
- Automatic routing to the closest region to the client
- High performance, high reliability RPC with graceful failover

---

### 2) Alignment with Architecture

Refer to `README.md` and `project/ARCHITECTURE.md`.

- Regional-first: Keep benchmark data and provider behavior local to each region.
- Transport-agnostic: HTTP and WS proxied via Phoenix, single internal port 4000.
- Observability: Structured logs and status endpoints; opt-in client metadata.
- State: Config cached in ETS; dynamic updates persist to YAML; benchmarking snapshots to disk.

---

### 3) High-Level Topology on Fly

- Fly App: `lasso-prod` (example)
- Anycast ingress on 80/443 with TLS, HTTP and WS upgrade.
- Per-region Machines (>=2 per region) behind Fly LB.
- Per-Machine volume mounted at `/data` for writable state.
- Health checks on `/api/health` (liveness), optional metrics at `/api/status`.

Diagram:

```
Clients (global)
   │  anycast 80/443 (TLS, WS)
Fly Edge / LB (geo)
   │  routes by latency/geo
Regions (iad, sea, ams, ...)
   ├─ Machine A (+ volume /data)
   └─ Machine B (+ volume /data)
        Phoenix @ 4000 (HTTP+WS)
        Lasso Supervisor Tree
        ETS (config, benchmarking)
        Snapshots & backups in /data
```

---

### 4) State & Storage

- Chains config: `LASSO_CHAINS_PATH=/data/chains.yml`
  - On first boot, seed from image `config/chains.yml` if `/data/chains.yml` is missing (entrypoint or one-off command).
- Snapshots: `LASSO_SNAPSHOTS_DIR=/data/benchmark_snapshots`
- Config backups: `LASSO_BACKUP_DIR=/data/config_backups`
- Reasoning: Region-local behavior and metrics are desired; no cross-region DB required initially.

Volume sizing guidance:

- Start with 3–10 GB per region; monitor growth in `/data/benchmark_snapshots` and backups.

---

### 5) Container & Runtime Configuration

- Image: Built from repo `Dockerfile` (internal port 4000). Expose 4000.
- Env:
  - `PORT=4000`, `PHX_SERVER=true`, `PHX_HOST=<app>.fly.dev`
  - `LASSO_CHAINS_PATH=/data/chains.yml`
  - `LASSO_SNAPSHOTS_DIR=/data/benchmark_snapshots`
  - `LASSO_BACKUP_DIR=/data/config_backups`
  - Provider keys: `INFURA_API_KEY`, `ALCHEMY_API_KEY`, ... (used in `${VAR}` expansion within YAML)
  - `SECRET_KEY_BASE` (required)
  - Optional: `FLY_REGION` (for tagging) flows from platform

Graceful shutdown:

- Use `SIGINT` with 30s timeout to allow Phoenix/Finch to drain.

Service concurrency:

- For WS-heavy workloads, limit by connections rather than request rate:

```
"services": [{
  "protocol": "tcp",
  "internal_port": 4000,
  "ports": [ { "port": 80, "handlers": ["http"] }, { "port": 443, "handlers": ["tls","http"] } ],
  "concurrency": { "type": "connections", "soft_limit": 500, "hard_limit": 1000 }
}]
```

---

### 6) Code-First Provisioning (APIs)

We will drive provisioning with Fly GraphQL + Machines APIs (no mandatory `fly.toml`). Scripts live under `/deployment`.

Core steps:

1. Create app (GraphQL `createApp`).
2. Set secrets (GraphQL `setSecrets`): `SECRET_KEY_BASE`, provider keys, LASSO\_\* envs.
3. Per region:
   - Create volume `data_<region>`.
   - Launch N Machines (>=2) with:
     - `image`: registry ref
     - `mounts`: volume at `/data`
     - `services`: HTTP/HTTPS, WS upgrades, connections-based concurrency
     - `checks.http`: GET `/api/health` on port 4000
     - `stop`: `{ signal: SIGINT, timeout: 30s }`
     - Optional: Run smoke test suite to validate deployment

Rollout script (blue/green) handles deploys.

---

### 7) Blue/Green Rollouts (Zero-Downtime)

Per region, for each existing machine:

1. Create a new machine (Green) with the new image, same region and volume mount.
2. Wait until health check passes.
3. Cordon old machine (optional: set `machines stop --signal=SIGINT`).
4. Drain and remove old machine (Blue) after healthy Green is live.

Notes:

- If volumes hold critical state, mount the same volume when replacing. Ensure application can start with existing `/data` contents.
- For absolute zero interruption to persistent WS clients, run overlapping capacity (N→N+1), then drain old machines so WS connections naturally move over via client reconnects.

---

### 8) WebSocket Considerations

- HTTP(S) handlers on 80/443 support WS upgrades automatically.
- Use connections-based concurrency to prevent overload from long-lived sockets.
- Graceful shutdown: `SIGINT` + timeout to allow clients to re-establish on remaining machines.
- Keep upstream provider WS connections warm (default in app); avoid auto-stop on idle.

---

### 9) Scaling & Regional Expansion

- Add regions by list: e.g., `REGIONS=iad,sea,ams,cdg` to the provisioning script.
- Per region machine count: `MACHINE_COUNT=2` (increase for HA and capacity).
- Vertical sizing: adjust `guest` CPU/mem for heavy subscriptions or high concurrency.
- Autoscaling: Prefer explicit scaling for predictable WS capacity; evaluate auto-start/stop carefully (keep always-on for warm pools).

---

### 10) Routing & Geo Placement

- Fly anycast routes clients to nearest region by latency; nothing special required in app.
- If you need a control-plane “primary” region, run the dashboard/admin flows there; data-plane Machines can be identical.

---

### 11) Observability

- Logs: Use Fly logs streaming; consider external aggregator if needed. Keep sampling (`:observability` sampling) to control volume.
- Health: `/api/health` (liveness), `/api/status` (status/metrics endpoint). Configure a metrics scraper if required.
- Request metadata: optionally expose via headers/body per README for client diagnostics.

---

### 12) Security & Networking

- Secrets via GraphQL `setSecrets`.
- Consider dedicated egress IPs per app/region if upstream providers rate-limit by IP.
- TLS handled at Fly; app terminates HTTP internally.

---

### 13) Runbooks

Deploy new version (blue/green):

1. Build & push image to registry.
2. Run `/deployment/roll.mjs` with `IMAGE_REF` and `FLY_APP_NAME`.
3. Monitor health checks; confirm traffic stability.

Add a region:

1. Update `REGIONS` env and run `/deployment/provision.mjs` (idempotent volume+machine creation).
2. Verify Machines healthy in new region.

Initial staging bring-up (full runbook):

1. Prereqs
   - Install `flyctl`, authenticate, and export `FLY_API_TOKEN`.
   - Authenticate Docker to Fly registry: `flyctl auth docker`.
   - Have Node 18+ installed to run `/deployment/*.mjs`.
2. Build & push image
   - `docker build -t registry.fly.io/$FLY_APP_NAME:$TAG .`
   - `docker push registry.fly.io/$FLY_APP_NAME:$TAG`
   - `export IMAGE_REF=registry.fly.io/$FLY_APP_NAME:$TAG`
3. Provision
   - `export REGIONS=iad` (or comma list)
   - `export MACHINE_COUNT=2 VOLUME_SIZE_GB=3`
   - `export SECRET_KEY_BASE=$(mix phx.gen.secret)`
   - Optional provider keys: `INFURA_API_KEY`, `ALCHEMY_API_KEY`
   - `node /deployment/provision.mjs`
4. Seed chains.yml (if entrypoint not used)
   - `fly ssh console -a $FLY_APP_NAME`
   - `test -f /data/chains.yml || cp /app/config/chains.yml /data/chains.yml`
5. Verify
   - `curl https://$FLY_APP_NAME.fly.dev/api/health`
   - RPC: `curl -X POST https://$FLY_APP_NAME.fly.dev/rpc/cheapest/ethereum -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'`
   - WS: `wscat -c wss://$FLY_APP_NAME.fly.dev/ws/rpc/ethereum` then subscribe `newHeads`
6. Blue/green test
   - Build/push new image; set `IMAGE_REF` to new tag
   - `node /deployment/roll.mjs`
   - Observe reconnections for WS, verify health stays green
7. Region expansion test
   - `export REGIONS=iad,sea`
   - `node /deployment/provision.mjs`
   - Verify health in new region and latency from a SEA client

Rotate secrets:

1. Re-run secrets mutation via script with updated values.
2. Optionally roll machines if required by app config.

Restore chains config:

1. SSH/exec into a machine; inspect `/data/chains.yml` and `/data/config_backups`.
2. Restore file and trigger config reload via admin API (if available) or roll machines.

---

### 14) Risks & Mitigations

- Volume coupling during blue/green: Ensure new machine mounts same volume and application can handle existing snapshot files.
- WS connection churn on rollout: Overlap capacity and drain; keep rollout slow enough for reconnections.
- Provider egress limits: Allocate stable IPs or distribute requests across regions/providers.
- Disk growth: Monitor `/data/benchmark_snapshots`; prune per retention policy.

---

### 15) Appendix: Required App Knobs

At minimum, the following envs must be set via secrets or config:

- `SECRET_KEY_BASE`
- `PHX_HOST`
- `LASSO_CHAINS_PATH=/data/chains.yml`
- `LASSO_SNAPSHOTS_DIR=/data/benchmark_snapshots`
- `LASSO_BACKUP_DIR=/data/config_backups`
- Provider keys used in YAML substitutions (e.g., `INFURA_API_KEY`, `ALCHEMY_API_KEY`)
