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

# Generate timestamp-based tag
TAG="stg-$(date +%Y%m%d-%H%M%S)"
export IMAGE_REF="registry.fly.io/${FLY_APP_NAME}:${TAG}"

echo "📋 Configuration:"
echo "  App: $FLY_APP_NAME"
echo "  Regions: $REGIONS"
echo "  Machines per region: $MACHINE_COUNT"
echo "  Volume size: ${VOLUME_SIZE_GB}GB"
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
echo "🔎 Using tag reference for image pulls (auth-aligned)."
echo ""
echo "Step 2/3: Provisioning infrastructure via provision.mjs..."
echo "-----------------------------------------------------------"

# Attach the built image to the app as the current image (creates a proper release alias)
echo "Linking image to app via release alias..."
flyctl -t "$FLY_API_TOKEN" image update -a "$FLY_APP_NAME" --image "$IMAGE_REF" -y

# Read back the latest release ImageRef and use that for provisioning (usually a deployment-* alias)
set +e
LATEST_REF=$(flyctl -t "$FLY_API_TOKEN" releases -a "$FLY_APP_NAME" --json | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const arr=JSON.parse(d);if(Array.isArray(arr)&&arr.length&&arr[0].ImageRef){console.log(arr[0].ImageRef)}else{process.exit(1)}}catch(e){process.exit(1)}})')
set -e
if [ -n "${LATEST_REF:-}" ]; then
  export IMAGE_REF="$LATEST_REF"
  echo "  Using release image ref: $IMAGE_REF"
else
  echo "  ⚠️ Could not determine release ImageRef; proceeding with $IMAGE_REF"
fi

# Run the infrastructure-as-code provisioning script with a known-good image reference
node deployment/provision.mjs

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
