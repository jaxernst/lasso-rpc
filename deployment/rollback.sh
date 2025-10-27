#!/usr/bin/env bash
set -euo pipefail

# Lasso RPC Rollback Script
# Usage: ./deployment/rollback.sh [staging|prod] [optional-image]

ENVIRONMENT="${1:-}"
ROLLBACK_IMAGE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$ENVIRONMENT" ]; then
  echo "❌ Environment required"
  echo "Usage: ./deployment/rollback.sh [staging|prod] [optional-image]"
  exit 1
fi

echo "🔄 Lasso RPC $ENVIRONMENT Rollback"
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

# Check authentication
if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo "⚠️  FLY_API_TOKEN not set. Checking fly auth login..."
  if ! fly auth whoami >/dev/null 2>&1; then
    echo "❌ Not authenticated. Please run: fly auth login"
    exit 1
  fi
  echo "✅ Using fly auth login authentication"
else
  echo "✅ Using FLY_API_TOKEN authentication"
fi

# Determine rollback image
if [ -z "$ROLLBACK_IMAGE" ]; then
  # Try to load saved previous image
  SAVED_IMAGE_FILE="/tmp/lasso_previous_image_${FLY_APP_NAME}.txt"
  if [ -f "$SAVED_IMAGE_FILE" ]; then
    ROLLBACK_IMAGE=$(cat "$SAVED_IMAGE_FILE")
    echo "📦 Found saved previous image: $ROLLBACK_IMAGE"
  else
    # List recent images and let user choose
    echo "📋 No saved image found. Fetching recent images..."
    echo ""
    echo "Recent deployments:"

    MACHINES=$(fly machines list -a "$FLY_APP_NAME" --json 2>&1)
    if [ $? -eq 0 ]; then
      echo "$MACHINES" | jq -r '.[] | "  Machine: \(.id) | Image: \(.config.image) | State: \(.state)"' 2>/dev/null || echo "  Could not parse machine list"
    fi

    echo ""
    echo "❌ No rollback image specified and no saved image found."
    echo "   Please specify an image to rollback to:"
    echo "   Usage: ./deployment/rollback.sh $ENVIRONMENT <image>"
    echo ""
    echo "   Example: ./deployment/rollback.sh $ENVIRONMENT registry.fly.io/$FLY_APP_NAME:prod-20250127-120000"
    exit 1
  fi
fi

echo ""
echo "⚠️  WARNING: This will rollback $FLY_APP_NAME to:"
echo "   $ROLLBACK_IMAGE"
echo ""
read -p "Continue? (yes/no): " -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "❌ Rollback cancelled"
  exit 0
fi

echo ""
echo "🔄 Rolling back to previous image..."
echo "------------------------------------"

# Perform rollback using fly deploy with the previous image
if [ -n "${FLY_API_TOKEN:-}" ]; then
  fly -t "$FLY_API_TOKEN" deploy \
    --config "$FLY_CONFIG_FILE" \
    --image "$ROLLBACK_IMAGE" \
    --strategy rolling
else
  fly deploy \
    --config "$FLY_CONFIG_FILE" \
    --image "$ROLLBACK_IMAGE" \
    --strategy rolling
fi

echo ""
echo "🔍 Verifying rollback..."
echo "------------------------"

# Wait for rollback to complete
sleep 10

# Check health endpoint
HEALTH_URL="https://${FLY_APP_NAME}.fly.dev/api/health"
echo "  Checking health endpoint: $HEALTH_URL"

MAX_RETRIES=10
RETRY_DELAY=5
for i in $(seq 1 $MAX_RETRIES); do
  if curl -sf "$HEALTH_URL" > /dev/null; then
    echo "  ✅ Health check passed!"
    break
  else
    if [ $i -eq $MAX_RETRIES ]; then
      echo "  ❌ Health check failed after $MAX_RETRIES attempts"
      echo "     Check logs with: fly logs -a $FLY_APP_NAME"
      exit 1
    fi
    echo "  ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

# Verify machine status
FINAL_STATUS=$(fly machines list -a "$FLY_APP_NAME" --json 2>&1)
if [ $? -eq 0 ]; then
  HEALTHY_MACHINES=$(echo "$FINAL_STATUS" | jq -r '[.[] | select(.state == "started")] | length' 2>/dev/null || echo "unknown")
  TOTAL_MACHINES=$(echo "$FINAL_STATUS" | jq -r '. | length' 2>/dev/null || echo "unknown")
  echo "  Healthy machines: $HEALTHY_MACHINES / $TOTAL_MACHINES"
fi

echo ""
echo "✅ Rollback complete!"
echo "====================="
echo ""
echo "📍 App URL: https://${FLY_APP_NAME}.fly.dev"
echo "📦 Image: $ROLLBACK_IMAGE"
echo ""
echo "🔍 Useful commands:"
echo "  View logs:     fly logs -a $FLY_APP_NAME"
echo "  List machines: fly machines list -a $FLY_APP_NAME"
echo "  Status:        fly status -a $FLY_APP_NAME"
echo ""
