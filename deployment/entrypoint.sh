#!/bin/sh
set -eu

# Seed bundled profiles only when using the managed data directory.
if [ -n "${LASSO_DATA_DIR:-}" ] && [ -z "${LASSO_PROFILES_DIR:-}" ]; then
  profile_dir="${LASSO_DATA_DIR}/config/profiles"
  mkdir -p "$profile_dir"
  if [ -z "$(ls -A "$profile_dir")" ]; then
    cp /app/config/profiles/*.yml "$profile_dir/"
  fi
fi

exec /app/bin/lasso "$@"
