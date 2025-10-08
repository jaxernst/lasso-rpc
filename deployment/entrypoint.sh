#!/usr/bin/env sh
set -e

# Seed /data/chains.yml from image if not present
if [ ! -f /data/chains.yml ] && [ -f /app/config/chains.yml ]; then
  mkdir -p /data
  cp /app/config/chains.yml /data/chains.yml
fi

exec mix phx.server


