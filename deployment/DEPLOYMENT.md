# Lasso RPC Deployment Guide

Simple, scalable deployments to Fly.io with staging and production environments.

## 🚀 Quick Start

### 1. Set Up Authentication

```bash
# Option A: Create a deploy token
flyctl tokens create deploy
# Copy the token (starts with "FlyV1 fm2_...") and set it:
export FLY_API_TOKEN="FlyV1 fm2_your_token_here"

# Option B: Login via browser
flyctl auth login
```

### 2. Set Up Secrets

```bash
# Generate secrets
export SECRET_KEY_BASE="$(mix phx.gen.secret)"

# Set secrets for both apps
flyctl secrets set SECRET_KEY_BASE="$SECRET_KEY_BASE" --app lasso-staging
flyctl secrets set SECRET_KEY_BASE="$SECRET_KEY_BASE" --app lasso-rpc

# Optional: Set provider keys
flyctl secrets set INFURA_API_KEY="your-key" --app lasso-staging
flyctl secrets set ALCHEMY_API_KEY="your-key" --app lasso-staging
```

### 3. Deploy

```bash
# Deploy staging (single region, minimal resources)
./deployment/deploy.sh staging

# Deploy production (multi-region, high availability)
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

- App name and regions
- Memory and CPU resources
- HTTP service configuration
- Health checks

## 🔧 Customization

### WebSocket Connection Handling

**Production deployments** use blue/green strategy to minimize WebSocket disconnections:

- New machines start first
- Old machines stop after new ones are healthy
- 60-second graceful shutdown timeout
- Clients should implement reconnection logic

**Staging deployments** use rolling strategy for faster iterations.

### Add Regions

Edit `deployment/env.prod`:

```bash
export REGIONS="sjc,iad,sea,ams"
```

### Change Resources

Edit environment file:

```bash
export MACHINE_MEMORY="4gb"
export MACHINE_COUNT="3"
```

Update corresponding `fly.toml`:

```toml
[[vm]]
  memory = '4gb'
```

### Add Secrets

```bash
flyctl secrets set NEW_SECRET="value" --app lasso-staging
flyctl secrets set NEW_SECRET="value" --app lasso-rpc
```

## 🔍 Monitoring

```bash
# Check status
flyctl status --app lasso-staging
flyctl status --app lasso-rpc

# View logs
flyctl logs --app lasso-staging
flyctl logs --app lasso-rpc

# SSH into machines
flyctl ssh console --app lasso-staging
flyctl ssh console --app lasso-rpc

# Test endpoints
curl https://lasso-staging.fly.dev/api/health
curl https://lasso-rpc.fly.dev/api/health
```

## 🚨 Troubleshooting

### Common Issues

**Missing SECRET_KEY_BASE**:

```bash
flyctl secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)" --app <app-name>
```

**Build Failures**:

```bash
# Check build logs
cat /tmp/fly_build.log

# Retry with clean build
flyctl deploy --config fly.staging.toml --no-cache --app lasso-staging
```

**Machine Issues**:

```bash
# List machines
flyctl machines list --app <app-name>

# Restart unhealthy machines
flyctl machine restart <machine-id> --app <app-name>
```

## 📁 File Structure

```
deployment/
├── deploy.sh              # Universal deployment script
├── env.staging            # Staging environment config
├── env.prod               # Production environment config
├── entrypoint.sh          # Container startup script
└── DEPLOYMENT_GUIDE.md    # This file

fly.staging.toml           # Staging app configuration
fly.prod.toml              # Production app configuration
```

## 🎯 What's Different

**Simplified Architecture**:

- ✅ Single deployment script for both environments
- ✅ Fly.io native machine management (no custom JS)
- ✅ Built-in blue/green deployments via `--strategy rolling`
- ✅ Environment-specific configurations
- ✅ Automatic health checks and rollouts

**Removed Complexity**:

- ❌ Custom machine provisioning scripts
- ❌ Manual blue/green rollout logic
- ❌ Complex configuration builders
- ❌ Separate staging/production scripts

---

**Usage**: `./deployment/deploy.sh [staging|prod]`
