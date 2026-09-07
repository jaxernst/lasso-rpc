# Deployment Guide

## Local Development

### Prerequisites

- **Elixir**: 1.18.4 (CI version)
- **Erlang/OTP**: 28 (CI version)
- **Node.js**: 18+ (asset compilation)

### Setup

```bash
git clone https://github.com/jaxernst/lasso-rpc
cd lasso-rpc
mix deps.get
mix assets.setup
mix assets.build
mix phx.server
```

Available at `http://localhost:4000`. Dashboard at `http://localhost:4000/dashboard`.

The included `public` profile includes free public providers — no API keys required.

### `.env` File

Lasso loads a `.env` file from the project root if present (via Dotenvy). System environment variables take precedence over `.env` values.

```bash
# .env
LASSO_NODE_ID=local-dev
ALCHEMY_API_KEY=your-key-here
```

### Docker

From a checkout of the release you intend to run:

```bash
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
docker compose up --build -d
curl --fail http://localhost:4000/api/health
```

Open <http://localhost:4000/dashboard>. The included Compose file builds the image
locally; it does not pull an officially published registry image. Keep the same
secret in your deployment's environment or secret manager across restarts.

Compose binds port 4000 to localhost, runs as UID/GID `10001:10001`, and keeps the
root filesystem read-only. `/tmp` is temporary; the named `/data` volume retains
profiles and benchmark history. `docker compose down` retains that volume;
`docker compose down --volumes` deletes it.

The foreground helper `./run-docker.sh` also builds locally, generates a secret
when one is not supplied, and persists data in its own `lasso-rpc-data` volume.
It sets `LASSO_NODE_ID=docker-local` unless you provide one.

#### Profile and history storage

The image defaults `LASSO_DATA_DIR` to `/data`. An empty data volume is seeded
with bundled profiles in `/data/config/profiles`. Existing files are preserved
on restart and upgrade. Benchmark snapshots use `/data/benchmark_snapshots`.

To use configuration maintained on the host instead, mount an existing directory
containing profile YAML files and set `LASSO_PROFILES_DIR`:

```bash
docker run --rm --name lasso-rpc \
  --publish 127.0.0.1:4000:4000 \
  --env SECRET_KEY_BASE --env LASSO_NODE_ID=docker-local \
  --env PHX_HOST=localhost --env PHX_SCHEME=http \
  --env LASSO_PROFILES_DIR=/profiles \
  --mount type=bind,source="$(pwd)/config/profiles",target=/profiles,readonly \
  --volume lasso-rpc-history:/data \
  lasso-rpc:local
```

The `lasso-rpc:local` image is produced by the Compose build above. Mounted files
must be readable by UID 10001; host directories used for writable storage must
also be writable by that UID. `LASSO_PROFILES_DIR` overrides profile seeding and
selection. `LASSO_SNAPSHOTS_DIR` independently overrides the history directory at
runtime. A read-only profile mount supports loading/reloading configuration;
application-side configuration saves require a writable mount.

Reload after editing YAML:

```bash
docker compose exec lasso /app/bin/lasso rpc 'Lasso.Config.ConfigStore.reload()'
```

#### Upgrade and rollback

1. Back up the profile files and any history you intend to retain.
2. Read the target release's changelog and select its Git tag before rebuilding.
3. Run `docker compose up --build -d` and verify health, a real RPC request, and the dashboard.
4. Existing volume profiles are not replaced by newer bundled defaults. Compare
   provider changes with `config/profiles/` in the target release and merge them deliberately.
5. To roll back, select the previous release's Git tag and rebuild with the same
   environment. Review its storage layout and restore the corresponding backup
   if the target release changed that layout.

Images built before the persistent `/data` layout used `/app/config/profiles`
and `/app/priv/benchmark_snapshots`. Copy any customized configuration or history
out of the old container before replacing it; a new empty volume cannot recover
files from a deleted container. Existing volumes created by a root-running image
may also need their writable directories assigned to UID/GID `10001:10001` before
upgrading. Preserve a backup before changing volume contents or ownership.

---

## Production Deployment

Lasso is a standard Elixir/Phoenix release. It runs anywhere you can deploy an OTP release: containers, VMs, bare metal, or PaaS platforms.

### Building a Release

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Or build a Docker image using the included `Dockerfile`.

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `SECRET_KEY_BASE` | Phoenix signing/encryption secret. Generate with `mix phx.gen.secret` (64+ bytes) |
| `PHX_HOST` | Public hostname for URL generation (e.g., `rpc.example.com`) |
| `PHX_SERVER` | Set to `true` to start the HTTP server (required for releases) |
| `LASSO_NODE_ID` | Unique, stable identifier for this node. Required in production. Convention: use region names (e.g., `us-east-1`) for geo-distributed deployments |
| `PORT` | HTTP listener port (default: `4000`) |

### Provider API Keys

Provider URLs in profile YAML support `${ENV_VAR}` substitution. Unresolved placeholders crash at startup.

```yaml
providers:
  - id: "alchemy_ethereum"
    url: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
```

Set the variable in your environment or secrets manager:

```bash
export ALCHEMY_API_KEY="your-key-here"
```

### Health Check

Lasso exposes `GET /api/health` for liveness/readiness probes. Configure your orchestrator or load balancer to poll this endpoint.

The health endpoint confirms that the application is running and reports cluster topology. It does not make live upstream RPC requests, so pair it with your normal provider and routing monitoring.

### HTTPS

Lasso serves HTTP. Terminate TLS at your reverse proxy or load balancer. Set `PHX_HOST` to your public hostname. Production URL generation defaults to HTTPS; set `PHX_SCHEME=http` when serving locally without a TLS proxy.

---

## Multi-Node Clustering

Clustering is optional. A single node works standalone. Clustering enables:

- Dashboard aggregates metrics across all nodes
- Per-region drill-down for provider performance comparison
- Cluster health monitoring (node status, region discovery)

Clustering does **not** affect routing. Each node makes independent routing decisions based on local latency measurements. There is no cross-node coordination in the request hot path.

### Requirements

Clustering uses Erlang distribution with DNS-based node discovery (`libcluster`). You need:

1. **DNS service discovery**: A DNS name that resolves to all node IPs (e.g., internal DNS in your orchestrator, Consul, or a headless Kubernetes service)
2. **Erlang distribution port access**: Nodes must be able to reach each other on the EPMD port (4369) and distribution ports
3. **Unique node IDs**: Each node needs a distinct `LASSO_NODE_ID`
4. **Distribution secret**: Set the same private `RELEASE_COOKIE` on the nodes in your cluster; do not rely on a cookie bundled in a distributed image

### Configuration

| Variable | Description |
|----------|-------------|
| `CLUSTER_DNS_QUERY` | DNS name resolving to all node IPs (e.g., `lasso.internal`) |
| `CLUSTER_NODE_BASENAME` | Erlang node basename for distribution (e.g., `lasso`) |
| `LASSO_NODE_ID` | Unique node identifier (typically region name) |

Both `CLUSTER_DNS_QUERY` and `CLUSTER_NODE_BASENAME` must be set for clustering to activate. If either is missing, the node runs standalone.

```bash
# Node in us-east
export CLUSTER_DNS_QUERY="lasso.internal"
export CLUSTER_NODE_BASENAME="lasso"
export LASSO_NODE_ID="us-east-1"

# Node in eu-west
export CLUSTER_DNS_QUERY="lasso.internal"
export CLUSTER_NODE_BASENAME="lasso"
export LASSO_NODE_ID="eu-west-1"
```

Nodes poll the DNS name every 5 seconds and automatically join the cluster.

### Geo-Distributed Deployment

For optimal performance, deploy one Lasso node per region and route application traffic to the nearest node (via GeoDNS, anycast, or your load balancer's geographic routing).

Each node independently:
- Measures latency to upstream providers from its region
- Routes requests to the fastest provider for that region
- Maintains independent circuit breaker state

The dashboard aggregates data across all nodes for unified observability with regional drill-down.

---

## Environment Variables Reference

### Core

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `SECRET_KEY_BASE` | Prod | Phoenix signing secret (64+ bytes) | - |
| `PHX_HOST` | Prod | Public hostname | `localhost` |
| `PHX_SCHEME` | No | External URL scheme | `https` in production |
| `PHX_SERVER` | Prod | Set to `true` to start HTTP server | - |
| `PORT` | No | HTTP listener port | `4000` |
| `LASSO_NODE_ID` | Prod | Unique node identifier | `"local"` in dev |
| `LASSO_DATA_DIR` | No | Base directory for profiles and snapshots | `/data` in Docker; unset outside Docker |
| `LASSO_PROFILES_DIR` | No | Profile YAML directory; overrides the data directory | `config/profiles` outside Docker |
| `LASSO_SNAPSHOTS_DIR` | No | Snapshot directory, selected at runtime | `priv/benchmark_snapshots` outside Docker |
| `LASSO_VM_METRICS_ENABLED` | No | Set to `true` to enable VM metrics | `false` |
| `LASSO_COWBOY_TELEMETRY_ENABLED` | No | Set to `false` to disable Cowboy per-request telemetry; Lasso application and dashboard events remain enabled | `true` |
| `LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED` | No | Use a larger short-lived heap while validating completed HTTP upstream responses; benchmark before enabling for latency-bound traffic | `false` |
| `LASSO_HTTP_POOL_SIZE` | No | Maximum HTTP/1 connections per upstream host and pool | `256` |
| `LASSO_HTTP_POOL_COUNT` | No | Independent Finch pools per upstream host | `1` |

### Clustering

| Variable | Required | Description |
|----------|----------|-------------|
| `CLUSTER_DNS_QUERY` | For clustering | DNS name for node discovery |
| `CLUSTER_NODE_BASENAME` | For clustering | Erlang distribution node basename |

### Provider Keys

Any `${VAR_NAME}` in profile YAML is resolved from environment variables at startup.

---

## Production Checklist

- [ ] `SECRET_KEY_BASE` set (64+ bytes)
- [ ] `PHX_HOST` set to public hostname
- [ ] `PHX_SERVER=true` set
- [ ] `LASSO_NODE_ID` set to a unique, stable value
- [ ] Provider credentials set when referenced by profile configuration
- [ ] Health check (`GET /api/health`) monitored by orchestrator
- [ ] Profile YAML validated (startup crashes on unresolved `${ENV_VAR}`)
- [ ] Client request limits enforced at the reverse proxy; profile rate settings only configure the dashboard tester
- [ ] TLS terminated at reverse proxy / load balancer
- [ ] Structured JSON log drain configured
- [ ] RPC and dashboard protected by reverse-proxy authentication or a private network boundary (Lasso OSS has no built-in client authentication)
- [ ] If clustering: `CLUSTER_DNS_QUERY` and `CLUSTER_NODE_BASENAME` set, Erlang distribution ports open between nodes
