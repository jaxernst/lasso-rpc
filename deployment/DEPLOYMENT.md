# Lasso RPC Deployment Guide

Simple, scalable deployments to Fly.io with staging and production environments.

## 🚀 Quick Start

### 1. Set Up Authentication

```bash
# Option A: Create a deploy token
fly tokens create deploy
# Copy the token (starts with "FlyV1 fm2_...") and set it:
export FLY_API_TOKEN="FlyV1 fm2_your_token_here"

# Option B: Login via browser (recommended for local dev)
fly auth login
```

### 2. Run Deployment Script:

```bash
# Deploy staging
./deployment/deploy.sh staging

# Deploy production
./deployment/deploy.sh prod
```

### 3. Scale Machines (First Time Only)

After your first deployment, scale machines across regions:

```bash
# Automated scaling script
./deployment/scale-regions.sh prod

# Or manually:
fly scale count 2 -a lasso-rpc --region sjc
fly scale count 2 -a lasso-rpc --region iad
```

### 4. Subsequent Deployments

```bash
# Just deploy - no scaling needed
./deployment/deploy.sh prod
```

## 📋 Configuration

### Environment Files

**`deployment/env.staging`** - Staging configuration:

- Single region: `sjc`
- Memory: `1gb`
- Stateless (no volumes)

**`deployment/env.prod`** - Production configuration:

- Multi-region: `sjc,iad`
- Memory: `2gb`
- Stateful (with volumes)

### Fly.toml Files

**`fly.staging.toml`** - Staging app config
**`fly.prod.toml`** - Production app config

Both define:

- App name and primary region
- Memory and CPU resources
- HTTP service configuration
- Health checks
- WebSocket support

## 🔧 Multi-Region Setup

See [`deployment/MULTI_REGION.md`](deployment/MULTI_REGION.md) for detailed multi-region documentation.

**TL;DR:**

1. Deploy once: `./deployment/deploy.sh prod`
2. Scale once: `./deployment/scale-regions.sh prod`
3. Deploy again: `./deployment/deploy.sh prod` (no scaling needed)

## 🔍 Monitoring

```bash
# Check status
fly status --app lasso-staging
fly status --app lasso-rpc

# View logs
fly logs --app lasso-staging
fly logs --app lasso-rpc

# List machines
fly machines list --app lasso-staging
fly machines list --app lasso-rpc

# SSH into machines
fly ssh console --app lasso-staging
fly ssh console --app lasso-rpc

# Test endpoints
curl https://lasso-staging.fly.dev/api/health
curl https://lasso-rpc.fly.dev/api/health
```

## 🚨 Troubleshooting

### Authentication Issues

```bash
# Check who you're logged in as
fly auth whoami

# Re-login if needed
fly auth login
```

### Machine Issues

```bash
# Restart stopped machines
fly machines start <machine-id> --app <app-name>

# Check machine status
fly machines list --app <app-name>

# View detailed logs
fly logs --app <app-name>
```

### Deployment Failures

```bash
# Check build logs
cat /tmp/fly_build.log

# Retry deployment
./deployment/deploy.sh staging
```

## 📁 File Structure

```
deployment/
├── deploy.sh              # Main deployment script
├── scale-regions.sh       # One-time scaling helper
├── env.staging            # Staging environment config
├── env.prod               # Production environment config
├── entrypoint.sh          # Container startup script
└── MULTI_REGION.md        # Multi-region documentation

fly.staging.toml           # Staging app configuration
fly.prod.toml              # Production app configuration
```

---

**Usage**: `./deployment/deploy.sh [staging|prod]`
