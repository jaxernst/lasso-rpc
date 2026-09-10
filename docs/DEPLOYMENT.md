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

The primary distribution is `ghcr.io/jaxernst/lasso-rpc`, with native Linux AMD64
and ARM64 images. Use the Compose attachment from the release you select. It
requires Docker Compose and OpenSSL for generating local secrets:

```bash
mkdir lasso && cd lasso
curl --fail --location https://github.com/jaxernst/lasso-rpc/releases/download/v0.4.1/compose.yml --output compose.yml
(umask 077; printf 'SECRET_KEY_BASE=%s\nRELEASE_COOKIE=%s\n' "$(openssl rand -hex 64)" "$(openssl rand -hex 32)" > .env)
docker compose up -d --wait
curl --fail http://localhost:4000/api/health
curl --fail http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Open <http://localhost:4000/dashboard>. Preserve `.env` across restarts and keep it
private; it contains the signing and Erlang distribution secrets. Compose passes
its values into the container, including provider credentials you add. Changing
`.env` requires container recreation with `docker compose up -d --force-recreate
--wait`; reloading YAML does not change a running container's environment.

Compose binds port 4000 to localhost, runs as UID/GID `10001:10001`, and keeps the
root filesystem read-only. `/tmp` is temporary; the named `/data` volume retains
profiles and benchmark history. `docker compose down` retains that volume;
`docker compose down --volumes` deletes it. Set `LASSO_PORT` in `.env` to choose
another local port and `LASSO_NODE_ID` to give the instance a stable identity.

#### Verify or pin the image

Each release attaches `container-release.json`, native verification reports, and
`container-verification.md` with its immutable image digest. Version tags are
never replaced with different contents. For a digest-pinned installation, set
this in `.env`, using the digest from the selected release:

```dotenv
LASSO_IMAGE=ghcr.io/jaxernst/lasso-rpc@sha256:DIGEST
```

Then run `docker compose pull` and `docker compose up -d --wait`. To verify the
signed publication attestation, install the GitHub CLI and run:

```bash
gh attestation verify oci://ghcr.io/jaxernst/lasso-rpc@sha256:DIGEST \
  --repo jaxernst/lasso-rpc
```

The signed attestation identifies the publication workflow. Platform BuildKit
provenance records the pinned public source used for the build; the index also
contains SBOMs. Source and publication-tooling revisions are recorded separately
in `container-release.json`. See [Releasing](RELEASING.md) for the verification
scope, first-publication access setup, and retry behavior.

#### Custom profiles and credentials

An empty data volume is seeded with bundled profiles in
`/data/config/profiles`. Existing files are preserved on restart and upgrade.
Benchmark snapshots use `/data/benchmark_snapshots`.

To maintain profiles on the host, copy the starting configuration from the
running container:

```bash
mkdir profiles
docker compose cp lasso:/data/config/profiles/. ./profiles
```

Create `compose.override.yml` next to `compose.yml`:

```yaml
services:
  lasso:
    environment:
      LASSO_PROFILES_DIR: /profiles
    volumes:
      - type: bind
        source: ./profiles
        target: /profiles
        read_only: true
```

Edit the YAML in `profiles/`, retaining a valid `public.yml`. Additional profiles
need matching filenames and frontmatter slugs. See [Configuration](CONFIGURATION.md)
for supported settings. Files must be readable by UID 10001 and directories
traversable by that UID; host directories used for writable history must also be
writable by UID 10001. Keep credential values in `.env` and reference them as
`${VARIABLE_NAME}` in provider URLs or headers.

Apply mount changes or environment changes:

```bash
docker compose up -d --force-recreate --wait
```

In v0.3.5, new profiles can reuse connected WebSocket upstreams after reload.
If you remain on v0.3.4, recreate the container after adding profiles to avoid
unavailable subscriptions. For new profiles and YAML-only edits in v0.3.5, reload
the running node:

```bash
docker compose exec -T lasso /app/bin/lasso rpc 'IO.inspect(Lasso.Config.ConfigStore.reload())'
```

A successful reload prints `:ok`. A rejected reload reports its error and keeps
the active configuration. Fix the file before restarting: a cold start cannot
recover the prior in-memory configuration. Invalid files are logged during startup
retries and prevent the service becoming ready. Use `docker compose logs lasso`
to see the specific rejected field. A read-only mount supports loading
and reloading; application-side configuration saves need a writable mount.
`LASSO_PROFILES_DIR` overrides profile seeding and selection.
`LASSO_SNAPSHOTS_DIR` independently overrides the history directory at runtime.

#### Upgrade and rollback

1. Preserve `.env` and back up profiles and any history you need. For the default
   volume layout, `docker compose cp lasso:/data/config/profiles ./profiles-backup`
   and `docker compose cp lasso:/data/benchmark_snapshots ./history-backup` copy
   them out of the running container.
2. Read the target release's compatibility notes. Select its exact image tag or
   digest using `LASSO_IMAGE` in `.env`, and retain the previous value for rollback.
3. Run `docker compose pull`, then `docker compose up -d --wait`. Check health,
   an upstream-backed RPC request, and the dashboard.
4. Existing volume profiles are not replaced by newer bundled defaults. Compare
   provider changes with the target release's example profiles and merge them
   deliberately. YAML validation rejects unknown settings; check custom profiles
   before an upgrade rather than relying on formerly ignored options.
5. To roll back, restore the previous `LASSO_IMAGE`, pull, and recreate the
   container with the same environment. If the release changed the storage
   format, restore the matching backup according to its compatibility notes.

Do not run `down --volumes` as an upgrade step.

When migrating the v0.3.3 example profiles to v0.3.4, remove the ignored provider
fields `type` and `api_key_required`. Replace the old
`adapter_config.max_block_range` with `capabilities.limits.max_block_range`.
Preserve your own provider URLs, credentials, and supported settings. The target
release's bundled profiles show the supported shape.

Images built before the persistent `/data` layout used `/app/config/profiles`
and `/app/priv/benchmark_snapshots`. Copy customized configuration and history
out of the old container before replacing it; a new empty volume cannot recover
files from a deleted container. Restore the profiles into a readable host mount
and the history into the new data volume, with ownership suitable for UID/GID
`10001:10001`. Keep the old container/data and backups until the new deployment
passes verification.

#### Building locally

The source repository's `compose.yml` builds from its checkout. From the selected
Git tag, set `SECRET_KEY_BASE` and run `docker compose up --build -d`. Its local
image is `lasso-rpc:local`; the downloadable Compose attachment uses the registry
image instead. The foreground helper `./run-docker.sh` also builds locally and
persists data in its own `lasso-rpc-data` volume. These source-build paths are
useful for development or independently rebuilding a release.

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

- A private DNS A record that resolves to every node's reachable IP address.
- Named Erlang nodes in the form `lasso@<IP>`, with the same private cookie.
- Connectivity between nodes on EPMD port 4369 and Erlang distribution ports.
  Keep these ports private; Docker HTTP port mappings alone do not provide it.
- A unique, stable `LASSO_NODE_ID` for each instance.

### Configuration

For each release/container instance, set:

| Variable | Example | Meaning |
|----------|---------|---------|
| `RELEASE_DISTRIBUTION` | `name` | Enable long node names |
| `RELEASE_NODE` | `lasso@10.0.0.11` | This node's name, using its reachable private IP |
| `RELEASE_COOKIE` | Shared secret | Same private value on every node |
| `CLUSTER_DNS_QUERY` | `lasso.internal` | DNS A record containing all node IPs |
| `CLUSTER_NODE_BASENAME` | `lasso` | Must match the name before `@` |
| `LASSO_NODE_ID` | `us-east-1` | Unique observability identity |

Replace the example IP and DNS name with your network's values. For a second
node at `10.0.0.12`, use `RELEASE_NODE=lasso@10.0.0.12` and a different
`LASSO_NODE_ID`; keep the cookie, DNS query, and basename the same. Supply matching
profile YAML to every node. Reload each node after adding or editing profiles.

In Compose, put these values in each instance's `.env` and recreate its container
with `docker compose up -d --force-recreate --wait`. Nodes poll DNS every five
seconds. The deployment network must allow direct access to the IPs in DNS.

Check the running node's name and peers:

```bash
docker compose exec -T lasso /app/bin/lasso rpc 'IO.inspect({node(), Node.list()})'
```

Each node should list the other members. An empty peer list means the node has
not joined; check names, cookie equality, DNS results, and private connectivity.
Setting discovery variables alone does not name a VM launched with plain
`mix phx.server`; the release settings above apply to release/container startup.

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
| `RELEASE_DISTRIBUTION` | For clustering | Set to `name` for long node names |
| `RELEASE_NODE` | For clustering | `<basename>@<reachable-private-IP>` |
| `RELEASE_COOKIE` | Release/container | Private distribution secret; identical across cluster members |

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
- [ ] If clustering: named nodes, shared cookie, DNS discovery, and private distribution connectivity configured; peers visible in `Node.list()`
