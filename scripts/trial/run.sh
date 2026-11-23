#!/usr/bin/env bash
# Runs a scenario set REPEATS times, then analyze.mjs. See README.md.
# Usage: scripts/trial/run.sh [default|backfill|midrun|idle|all|S2,S4,...]
set -eu

KIT="$(cd "$(dirname "$0")" && pwd)"
SET="${1:-default}"
case "$SET" in
  default) SCENARIOS="S1 S2 S2m S3 S4 S5 S6 S9b S9s S9m" ;;
  backfill) SCENARIOS="B1" ;;
  midrun) SCENARIOS="S4m S4r S4n S11" ;;
  idle) SCENARIOS="S8 S10" ;;
  all) SCENARIOS="S1 S2 S2m S3 S4 S5 S6 S9b S9s S9m B1 S4m S4r S4n S11 S9a S8 S10" ;;
  *) SCENARIOS="$(printf '%s' "$SET" | tr ',' ' ')" ;;
esac

REPEATS="${REPEATS:-3}"
DURATION="${DURATION:-180}"
if [ -z "${CANDIDATES:-}" ]; then
  CANDIDATES="direct,race2,lasso,lasso-fastest,lasso-bf"
  if [ -n "${ENDPOINT_URL:-}" ]; then CANDIDATES="$CANDIDATES,endpoint"; fi
fi
OUT="${OUT:-$KIT/results/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"

echo "scenarios: $SCENARIOS"
echo "candidates: $CANDIDATES"
echo "repeats: $REPEATS, duration: ${DURATION} s, results: $OUT"

r=1
while [ "$r" -le "$REPEATS" ]; do
  for s in $SCENARIOS; do
    echo "$(date +%H:%M:%S) start $s-r$r"
    RUN_ID="$s-r$r" RESULTS_DIR="$OUT" node "$KIT/runner.mjs" "$s" "$CANDIDATES" "$DURATION"
  done
  r=$((r + 1))
done

node "$KIT/analyze.mjs" "$OUT" > /dev/null
echo "$(date +%H:%M:%S) done. Tables: $OUT/tables.md"
