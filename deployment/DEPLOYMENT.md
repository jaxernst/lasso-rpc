# Lasso RPC Deployment Guide

Production-grade, WebSocket-optimized deployments to Fly.io with staging and production environments.

## 🚀 Quick Start

### 1. Set Up Authentication

```bash
# Option A: Create a deploy token (recommended for CI/CD)
fly tokens create deploy
# Copy the token (starts with "FlyV1 fm2_...") and set it:
export FLY_API_TOKEN="FlyV1 fm2_your_token_here"

# Option B: Login via browser (recommended for local dev)
fly auth login
```

### 2. Configure Secrets (Production Only)

```bash
# Generate and set SECRET_KEY_BASE for production
mix phx.gen.secret
fly secrets set SECRET_KEY_BASE=<generated-secret> --app lasso-rpc

# Set any additional API keys
fly secrets set INFURA_API_KEY=<your-key> --app lasso-rpc
fly secrets set ALCHEMY_API_KEY=<your-key> --app lasso-rpc
```

### 3. Run Deployment Script

```bash
# Deploy staging (auto-generates secrets)
./deployment/deploy.sh staging

# Deploy production (validates secrets first)
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

# Rollback if issues occur
./deployment/rollback.sh prod
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

## Deployment Features

1. **Secrets Validation**: Verifies all required secrets exist on Fly.io before deploying
2. **Pre-deployment Checks**: Validates machine status, volumes, and current deployment state
3. **Rollback Capability**: Automatically saves previous image for easy rollback
4. **Health Verification**: Tests both HTTP and WebSocket endpoints after deployment
5. **Machine Status Monitoring**: Verifies healthy machine count post-deployment

### WebSocket-Optimized Deployments

- **Staging**: Rolling strategy for fast iteration
- **Production**: Canary strategy for zero-downtime deployments
  - Gradually shifts traffic to new machines
  - Allows WebSocket connections to drain naturally
  - Maintains availability throughout deployment

### Deployment Stages

Each deployment runs through 5 stages:

1. **Pre-deployment Validation**: Checks secrets, machine status, volumes
2. **Image Building**: Builds and pushes Docker image to Fly.io registry
3. **Multi-region Setup**: Configures regions for deployment
4. **Machine Deployment**: Deploys using appropriate strategy
5. **Verification**: Tests endpoints and confirms healthy machines

## 🔄 Rollback

If issues occur after deployment, use the rollback script:

```bash
# Rollback to previous deployment
./deployment/rollback.sh prod

# Rollback to specific image
./deployment/rollback.sh prod registry.fly.io/lasso-rpc:prod-20250127-120000
```

The deployment script automatically saves the previous image for easy rollback.

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
├── deploy.sh              # Main deployment script (5-stage process)
├── rollback.sh            # Rollback to previous deployment
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
