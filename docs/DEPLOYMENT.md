# Deployment Guide

## Local Development

### Prerequisites

- **Elixir**: 1.17+
- **Erlang/OTP**: 26+
- **Node.js**: 18+ (asset compilation)

### Setup

```bash
git clone https://github.com/jaxernst/lasso-rpc
cd lasso-rpc
mix deps.get
mix phx.server
```

Available at `http://localhost:4000`. Dashboard at `http://localhost:4000/dashboard`.

The default profile includes free public providers — no API keys required.

### `.env` File

Lasso loads a `.env` file from the project root if present (via Dotenvy). System environment variables take precedence over `.env` values.

```bash
# .env
LASSO_NODE_ID=local-dev
ALCHEMY_API_KEY=your-key-here
```

### Docker

```bash
./run-docker.sh
```

See the `Dockerfile` for build customization.

---

## Production Deployment

Lasso is a standard Elixir/Phoenix release. It runs anywhere you can deploy an OTP release: containers, VMs, bare metal, or PaaS platforms.

### Building a Release

```bash
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

### HTTPS

Lasso serves HTTP. Terminate TLS at your reverse proxy or load balancer. Set `PHX_HOST` to your public hostname so generated URLs use the correct scheme.

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
| `PHX_SERVER` | Prod | Set to `true` to start HTTP server | - |
| `PORT` | No | HTTP listener port | `4000` |
| `LASSO_NODE_ID` | Prod | Unique node identifier | `"local"` in dev |
| `LASSO_VM_METRICS_ENABLED` | No | Set to `false` to disable VM metrics | `true` |

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
- [ ] Provider API keys set if using BYOK providers
- [ ] Health check (`GET /api/health`) monitored by orchestrator
- [ ] Profile YAML validated (startup crashes on unresolved `${ENV_VAR}`)
- [ ] Rate limits configured in profile frontmatter
- [ ] TLS terminated at reverse proxy / load balancer
- [ ] Structured JSON log drain configured
- [ ] If clustering: `CLUSTER_DNS_QUERY` and `CLUSTER_NODE_BASENAME` set, Erlang distribution ports open between nodes
