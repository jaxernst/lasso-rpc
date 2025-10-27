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

# Verify secrets configuration
echo ""
echo "🔐 Verifying secrets configuration..."
echo "------------------------------------"
if [ "$ENVIRONMENT" = "prod" ]; then
  # For production, verify secrets exist on Fly.io
  echo "  Checking Fly.io secrets for $FLY_APP_NAME..."

  SECRETS_OUTPUT=$(fly secrets list -a "$FLY_APP_NAME" 2>&1)
  if echo "$SECRETS_OUTPUT" | grep -q "SECRET_KEY_BASE"; then
    echo "  ✅ SECRET_KEY_BASE configured on Fly.io"
  else
    echo "  ❌ SECRET_KEY_BASE not found in Fly.io secrets!"
    echo "     Generate with: mix phx.gen.secret"
    echo "     Set with: fly secrets set SECRET_KEY_BASE=<secret> --app $FLY_APP_NAME"
    exit 1
  fi

  # List other configured secrets (without revealing values)
  echo "  📋 Configured secrets:"
  echo "$SECRETS_OUTPUT" | grep -E "^\s*[A-Z_]+" | sed 's/^/     /'
else
  # For staging, generate if not set
  if [ -z "${SECRET_KEY_BASE:-}" ]; then
    echo "  ⚠️  SECRET_KEY_BASE not set. Generating one for staging..."
    if command -v mix &> /dev/null; then
      export SECRET_KEY_BASE=$(mix phx.gen.secret)
    else
      export SECRET_KEY_BASE=$(openssl rand -base64 48)
    fi
    echo "  Generated temporary key for staging"
  else
    echo "  ✅ SECRET_KEY_BASE configured"
  fi
fi

echo ""
echo "Step 1/5: Pre-deployment validation..."
echo "---------------------------------------"

# Check current machine status
echo "  Checking current deployment status..."
MACHINE_STATUS=$(fly machines list -a "$FLY_APP_NAME" --json 2>&1)
if [ $? -eq 0 ]; then
  MACHINE_COUNT_CURRENT=$(echo "$MACHINE_STATUS" | jq -r '. | length' 2>/dev/null || echo "0")
  echo "  Current machines: $MACHINE_COUNT_CURRENT"

  # Save current image for potential rollback
  if [ "$MACHINE_COUNT_CURRENT" != "0" ]; then
    CURRENT_IMAGE=$(echo "$MACHINE_STATUS" | jq -r '.[0].config.image' 2>/dev/null || echo "unknown")
    echo "  Current image: $CURRENT_IMAGE"
    echo "$CURRENT_IMAGE" > /tmp/lasso_previous_image_${FLY_APP_NAME}.txt
    echo "  💾 Previous image saved for rollback"
  fi
else
  echo "  ℹ️  No existing machines found (first deployment)"
fi

# Verify volumes for stateful deployments
if [ "$STATEFUL" = "true" ]; then
  echo "  Checking volumes for stateful deployment..."
  VOLUMES=$(fly volumes list -a "$FLY_APP_NAME" --json 2>&1)
  if [ $? -eq 0 ]; then
    VOLUME_COUNT=$(echo "$VOLUMES" | jq -r '. | length' 2>/dev/null || echo "0")
    echo "  Found $VOLUME_COUNT volume(s)"
    if [ "$VOLUME_COUNT" = "0" ]; then
      echo "  ⚠️  No volumes found for stateful deployment"
      echo "     Volumes will be created automatically, but data won't persist from previous deployments"
    fi
  fi
fi

echo ""
echo "Step 2/5: Building image..."
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

echo "Step 3/5: Setting up multi-region..."
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
echo "Step 4/5: Deploying machines..."
echo "-------------------------------"

# Use WebSocket-friendly deployment strategies
if [ "$ENVIRONMENT" = "prod" ]; then
  echo "  Using canary strategy for production (WebSocket-friendly, zero-downtime)..."
  echo "  ℹ️  Canary deployment: gradually shifts traffic to new machines"
  echo "     This allows WebSocket connections to drain naturally"

  # Canary deployment: gradually replaces machines while maintaining availability
  if [ -n "${FLY_API_TOKEN:-}" ]; then
    fly -t "$FLY_API_TOKEN" deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy canary \
      --wait-timeout 300
  else
    fly deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy canary \
      --wait-timeout 300
  fi
else
  echo "  Using rolling strategy for staging (fast iteration)..."
  # Rolling deployment for staging (faster, less resource intensive)
  if [ -n "${FLY_API_TOKEN:-}" ]; then
    fly -t "$FLY_API_TOKEN" deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy rolling \
      --wait-timeout 180
  else
    fly deploy \
      --config "$FLY_CONFIG_FILE" \
      --image "$IMAGE_REF" \
      --strategy rolling \
      --wait-timeout 180
  fi
fi

echo ""
echo "Step 5/5: Verifying deployment..."
echo "----------------------------------"

# Wait for deployment to stabilize
echo "  Waiting for deployment to stabilize..."
sleep 15

# Check HTTP health endpoint
HEALTH_URL="https://${FLY_APP_NAME}.fly.dev/api/health"
echo "  Checking HTTP health endpoint: $HEALTH_URL"

MAX_RETRIES=12
RETRY_DELAY=5
HTTP_HEALTHY=false

for i in $(seq 1 $MAX_RETRIES); do
  HTTP_CODE=$(curl -sf -w "%{http_code}" -o /tmp/health_response.txt "$HEALTH_URL" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✅ HTTP health check passed!"
    HTTP_HEALTHY=true
    break
  else
    if [ $i -eq $MAX_RETRIES ]; then
      echo "  ❌ HTTP health check failed after $MAX_RETRIES attempts"
      echo "     HTTP status code: $HTTP_CODE"
      echo "     Check logs with: fly logs -a $FLY_APP_NAME"

      # Don't fail deployment but warn
      echo "  ⚠️  Continuing despite health check failure..."
      break
    fi
    echo "  ⏳ Attempt $i/$MAX_RETRIES failed (HTTP $HTTP_CODE), retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

# Check WebSocket endpoint (best effort)
if [ "$HTTP_HEALTHY" = true ]; then
  echo "  Checking WebSocket endpoint availability..."
  WS_URL="wss://${FLY_APP_NAME}.fly.dev/ws/rpc/ethereum"

  # Try to connect to WebSocket using websocat if available
  if command -v websocat &> /dev/null; then
    if timeout 5 websocat -n1 -E "$WS_URL" 2>/dev/null; then
      echo "  ✅ WebSocket endpoint responding!"
    else
      echo "  ⚠️  WebSocket check inconclusive (this is normal)"
    fi
  else
    echo "  ℹ️  WebSocket check skipped (install 'websocat' for WS verification)"
  fi
fi

# Verify machine status
echo "  Checking machine status..."
FINAL_STATUS=$(fly machines list -a "$FLY_APP_NAME" --json 2>&1)
if [ $? -eq 0 ]; then
  HEALTHY_MACHINES=$(echo "$FINAL_STATUS" | jq -r '[.[] | select(.state == "started")] | length' 2>/dev/null || echo "unknown")
  TOTAL_MACHINES=$(echo "$FINAL_STATUS" | jq -r '. | length' 2>/dev/null || echo "unknown")
  echo "  Healthy machines: $HEALTHY_MACHINES / $TOTAL_MACHINES"

  if [ "$HEALTHY_MACHINES" != "unknown" ] && [ "$HEALTHY_MACHINES" != "0" ]; then
    echo "  ✅ Deployment successful!"
  else
    echo "  ⚠️  Warning: No healthy machines detected"
  fi
else
  echo "  ⚠️  Could not verify machine status"
fi

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
echo "📦 Deployment Info:"
echo "  New image:      $IMAGE_REF"
if [ -f "/tmp/lasso_previous_image_${FLY_APP_NAME}.txt" ]; then
  SAVED_IMAGE=$(cat "/tmp/lasso_previous_image_${FLY_APP_NAME}.txt")
  echo "  Previous image: $SAVED_IMAGE"
  echo ""
  echo "🔄 Rollback available:"
  echo "  ./deployment/rollback.sh $ENVIRONMENT"
fi
echo ""
echo "🔍 Useful commands:"
echo "  View logs:     fly logs -a $FLY_APP_NAME"
echo "  List machines: fly machines list -a $FLY_APP_NAME"
echo "  SSH console:   fly ssh console -a $FLY_APP_NAME"
echo "  Status:        fly status -a $FLY_APP_NAME"
echo ""
