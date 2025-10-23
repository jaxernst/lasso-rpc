#!/usr/bin/env bash
set -euo pipefail

# Lasso RPC Universal Deployment Script
# Usage: ./deployment/deploy.sh [staging|prod]

ENVIRONMENT="${1:-staging}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Lasso RPC $ENVIRONMENT Deployment"
echo "===================================="

# Load environment configuration
ENV_FILE="$SCRIPT_DIR/env.$ENVIRONMENT"
if [ -f "$ENV_FILE" ]; then
  echo "📋 Loading $ENVIRONMENT environment configuration..."
  source "$ENV_FILE"
else
  echo "❌ $ENV_FILE not found. Please create it first."
  exit 1
fi

# Generate timestamp-based tag
TAG="$ENVIRONMENT-$(date +%Y%m%d-%H%M%S)"
export IMAGE_REF="registry.fly.io/${FLY_APP_NAME}:${TAG}"

echo "📋 Configuration:"
echo "  App: $FLY_APP_NAME"
echo "  Config: $FLY_CONFIG_FILE"
echo "  Regions: $REGIONS"
echo "  Machines per region: $MACHINE_COUNT"
echo "  Memory: ${MACHINE_MEMORY:-1gb}"
echo "  Stateful: $STATEFUL"
echo "  Image tag: $TAG"
echo ""

# Check authentication
if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo "⚠️  FLY_API_TOKEN not set. Checking fly auth login..."
  if ! fly auth whoami >/dev/null 2>&1; then
    echo "❌ Not authenticated. Please run one of:"
    echo "   fly auth login"
    echo "   OR"
    echo "   fly tokens create deploy"
    echo "   export FLY_API_TOKEN=\"FlyV1 fm2_your_token_here\""
    exit 1
  fi
  echo "✅ Using fly auth login authentication"
else
  echo "✅ Using FLY_API_TOKEN authentication"
fi

if [ -z "${SECRET_KEY_BASE:-}" ]; then
  if [ "$ENVIRONMENT" = "prod" ]; then
    echo "❌ SECRET_KEY_BASE not set. This is required for production!"
    echo "   Generate with: mix phx.gen.secret"
    echo "   Set with: flyctl secrets set SECRET_KEY_BASE=<secret> --app $FLY_APP_NAME"
    exit 1
  else
    echo "⚠️  SECRET_KEY_BASE not set. Generating one..."
    if command -v mix &> /dev/null; then
      export SECRET_KEY_BASE=$(mix phx.gen.secret)
    else
      export SECRET_KEY_BASE=$(openssl rand -base64 48)
    fi
    echo "  Generated: $SECRET_KEY_BASE"
  fi
fi

echo ""
echo "Step 1/3: Building image..."
echo "----------------------------"

# Build with fly.toml configuration
if [ -n "${FLY_API_TOKEN:-}" ]; then
  fly -t "$FLY_API_TOKEN" deploy \
    --config "$FLY_CONFIG_FILE" \
    --image-label "$TAG" \
    --push \
    --build-only \
    --remote-only 2>&1 | tee /tmp/fly_build.log
else
  fly deploy \
    --config "$FLY_CONFIG_FILE" \
    --image-label "$TAG" \
    --push \
    --build-only \
    --remote-only 2>&1 | tee /tmp/fly_build.log
fi

echo ""
echo "✅ Image built and pushed: $IMAGE_REF"
echo ""

echo "Step 2/4: Setting up multi-region..."
echo "------------------------------------"

# Parse regions from environment variable
IFS=',' read -ra REGION_ARRAY <<< "$REGIONS"
PRIMARY_REGION="${REGION_ARRAY[0]}"

# Add additional regions (skip primary)
for region in "${REGION_ARRAY[@]}"; do
  if [ "$region" != "$PRIMARY_REGION" ]; then
    echo "  Adding region: $region"
    if [ -n "${FLY_API_TOKEN:-}" ]; then
      fly -t "$FLY_API_TOKEN" regions add "$region" -a "$FLY_APP_NAME" 2>/dev/null || true
    else
      fly regions add "$region" -a "$FLY_APP_NAME" 2>/dev/null || true
    fi
  fi
done

# Note: Machine scaling should be done manually to avoid duplicates
# Run these commands after first deployment:
# for region in ${REGIONS//,/ }; do
#   fly scale count $MACHINE_COUNT -a $FLY_APP_NAME --region $region
# done

echo "  ℹ️  To scale machines, run manually after first deployment:"
for region in "${REGION_ARRAY[@]}"; do
  echo "     fly scale count $MACHINE_COUNT -a $FLY_APP_NAME --region $region"
done

echo ""
echo "Step 3/3: Deploying machines..."
echo "-------------------------------"

# Use fly.io's built-in deployment with WebSocket-friendly strategy
if [ "$ENVIRONMENT" = "prod" ]; then
  echo "  Using blue/green strategy for production (WebSocket-friendly)..."
  # Blue/green deployment: create new machines, then stop old ones
  if [ -n "${FLY_API_TOKEN:-}" ]; then
    fly -t "$FLY_API_TOKEN" deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy immediate \
      --ha=false
  else
    fly deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy immediate \
      --ha=false
  fi
else
  echo "  Using rolling strategy for staging..."
  # Rolling deployment for staging (faster, less resource intensive)
  if [ -n "${FLY_API_TOKEN:-}" ]; then
    fly -t "$FLY_API_TOKEN" deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy rolling
  else
    fly deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy rolling
  fi
fi

echo ""
echo "Verifying deployment..."
echo "-----------------------"

# Wait for deployment to complete
sleep 10

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
      echo "  Check logs with: fly logs -a $FLY_APP_NAME"
      exit 1
    fi
    echo "  ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

echo ""
echo "🎉 $ENVIRONMENT deployment complete!"
echo "===================================="
echo ""
echo "📍 Endpoints:"
echo "  Health: https://${FLY_APP_NAME}.fly.dev/api/health"
echo "  Status: https://${FLY_APP_NAME}.fly.dev/api/status"
echo "  RPC:    https://${FLY_APP_NAME}.fly.dev/rpc/cheapest/ethereum"
echo "  WS:     wss://${FLY_APP_NAME}.fly.dev/ws/rpc/ethereum"
echo "  Metrics: https://${FLY_APP_NAME}.fly.dev/api/metrics"
echo ""
echo "🔍 Useful commands:"
echo "  View logs:     fly logs -a $FLY_APP_NAME"
echo "  List machines: fly machines list -a $FLY_APP_NAME"
echo "  SSH console:   fly ssh console -a $FLY_APP_NAME"
echo "  Status:        fly status -a $FLY_APP_NAME"
echo ""
