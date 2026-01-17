#!/bin/bash
set -e

# Entrypoint script for Lasso RPC Docker container
# Handles profile seeding and starts the Elixir release

echo "Lasso RPC starting..."

# Optional: Seed profiles to a data directory if LASSO_DATA_DIR is set
if [ -n "$LASSO_DATA_DIR" ]; then
  PROFILE_DIR="${LASSO_DATA_DIR}/config/profiles"

  # Create directory if it doesn't exist
  mkdir -p "$PROFILE_DIR"

  # Copy default profiles if they don't exist in the data directory
  if [ -z "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]; then
    echo "Seeding profiles to $PROFILE_DIR"
    cp -r /app/config/profiles/* "$PROFILE_DIR/"
  else
    echo "Using existing profiles from $PROFILE_DIR"
  fi
fi

# Start the Elixir release
# Use 'start' for foreground execution (required for Docker containers)
exec /app/bin/lasso start
