#!/usr/bin/env bash
set -euo pipefail

# Lasso RPC Multi-Region Setup Helper
# Run this ONCE after your first deployment to scale machines

ENVIRONMENT="${1:-prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔧 Lasso RPC Multi-Region Setup"
echo "================================"
echo ""
echo "This script scales machines across regions."
echo "Run this ONCE after your first deployment."
echo ""

# Load environment configuration
ENV_FILE="$SCRIPT_DIR/env.$ENVIRONMENT"
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
else
  echo "❌ $ENV_FILE not found."
  exit 1
fi

echo "📋 Configuration:"
echo "  App: $FLY_APP_NAME"
echo "  Regions: $REGIONS"
echo "  Machines per region: $MACHINE_COUNT"
echo ""

# Parse regions
IFS=',' read -ra REGION_ARRAY <<< "$REGIONS"

# Scale machines in each region
echo "Scaling machines..."
for region in "${REGION_ARRAY[@]}"; do
  echo "  → Scaling to $MACHINE_COUNT machines in $region"
  fly scale count "$MACHINE_COUNT" -a "$FLY_APP_NAME" --region "$region"
done

echo ""
echo "✅ Multi-region setup complete!"
echo ""
echo "Verify with: fly machines list -a $FLY_APP_NAME"
echo ""
