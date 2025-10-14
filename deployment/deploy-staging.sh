#!/usr/bin/env bash
set -euo pipefail

# Lasso RPC Staging Deployment Script
# Uses Fly remote builder to avoid cross-compilation issues on Apple Silicon
# Then provisions machines via provision.mjs as per DEPLOYMENT_FLY_MACHINES_SPEC.md

echo "🚀 Lasso RPC Staging Deployment"
echo "================================"

# Configuration
export FLY_APP_NAME="${FLY_APP_NAME:-lasso-staging}"
export REGIONS="${REGIONS:-iad}"
export MACHINE_COUNT="${MACHINE_COUNT:-2}"
export VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-3}"
export STATEFUL="${STATEFUL:-false}"

# Generate timestamp-based tag
TAG="stg-$(date +%Y%m%d-%H%M%S)"
export IMAGE_REF="registry.fly.io/${FLY_APP_NAME}:${TAG}"

echo "📋 Configuration:"
echo "  App: $FLY_APP_NAME"
echo "  Regions: $REGIONS"
echo "  Machines per region: $MACHINE_COUNT"
echo "  Volume size: ${VOLUME_SIZE_GB}GB"
echo "  Stateful: $STATEFUL"
echo "  Image tag: $TAG"
echo ""

# Check required environment variables
if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo "❌ FLY_API_TOKEN not set. Run: export FLY_API_TOKEN=\$(flyctl auth token)"
  exit 1
fi

if [ -z "${SECRET_KEY_BASE:-}" ]; then
  echo "⚠️  SECRET_KEY_BASE not set. Generating one..."
  if command -v mix &> /dev/null; then
    export SECRET_KEY_BASE=$(mix phx.gen.secret)
  else
    export SECRET_KEY_BASE=$(openssl rand -base64 48)
  fi
  echo "  Generated: $SECRET_KEY_BASE"
  echo "  💡 Save this for future deploys!"
fi

echo ""
echo "Step 1/3: Building image on Fly remote builder (amd64)..."
echo "-----------------------------------------------------------"

# Use Fly's remote builder to avoid cross-compilation issues
# This builds on native amd64 infrastructure and pushes to registry
# --no-cache ensures we don't use stale Docker layer cache for config files
flyctl -t "$FLY_API_TOKEN" deploy \
  --app "$FLY_APP_NAME" \
  --image-label "$TAG" \
  --push \
  --depot=false \
  --build-only \
  --remote-only 2>&1 | tee /tmp/fly_build.log

echo ""
echo "✅ Image built and pushed: $IMAGE_REF"
echo ""
echo "🔎 Using tag reference for image pulls."
echo ""
echo "Step 2/3: Deploying machines..."
echo "--------------------------------"

echo "Using freshly built image: $IMAGE_REF"

# Decide whether to roll existing machines or provision fresh
EXISTING_COUNT=$(flyctl -t "$FLY_API_TOKEN" machines list -a "$FLY_APP_NAME" --json | jq 'length')
if [ "${EXISTING_COUNT}" -gt 0 ]; then
  echo "Existing machines detected (${EXISTING_COUNT}). Performing blue/green roll..."
  node deployment/roll.mjs
else
  echo "No existing machines. Provisioning new machines..."
  node deployment/provision.mjs
fi

echo ""
echo "Step 3/3: Verifying deployment..."
echo "-----------------------------------------------------------"

# Wait a bit for machines to start
sleep 5

# Check health endpoint
HEALTH_URL="https://${FLY_APP_NAME}.fly.dev/api/health"
echo "  Checking health endpoint: $HEALTH_URL"

MAX_RETRIES=12
RETRY_DELAY=5
for i in $(seq 1 $MAX_RETRIES); do
  if curl -sf "$HEALTH_URL" > /dev/null; then
    echo "  ✅ Health check passed!"
    break
  else
    if [ $i -eq $MAX_RETRIES ]; then
      echo "  ❌ Health check failed after $MAX_RETRIES attempts"
      echo "  Check logs with: flyctl logs -a $FLY_APP_NAME"
      exit 1
    fi
    echo "  ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

echo ""
echo "🎉 Deployment complete!"
echo "======================"
echo ""
echo "📍 Endpoints:"
echo "  Health: https://${FLY_APP_NAME}.fly.dev/api/health"
echo "  Status: https://${FLY_APP_NAME}.fly.dev/api/status"
echo "  RPC:    https://${FLY_APP_NAME}.fly.dev/rpc/cheapest/ethereum"
echo "  WS:     wss://${FLY_APP_NAME}.fly.dev/ws/rpc/ethereum"
echo ""
echo "🔍 Useful commands:"
echo "  View logs:     flyctl logs -a $FLY_APP_NAME"
echo "  List machines: flyctl machines list -a $FLY_APP_NAME"
echo "  SSH console:   flyctl ssh console -a $FLY_APP_NAME"
echo "  Status:        flyctl status -a $FLY_APP_NAME"
echo ""
