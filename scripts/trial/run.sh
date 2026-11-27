#!/usr/bin/env bash
# Runs a scenario set REPEATS times, then analyze.mjs. See README.md.
# Usage: scripts/trial/run.sh [default|backfill|midrun|degraded|learning|idle|all|S2,S4,...]
# Without LASSO_REL it downloads and checks this checkout's release archive from GitHub.
# Exits nonzero when any run failed or any expected outcome failed; the remaining runs still go ahead.
set -eu

KIT="$(cd "$(dirname "$0")" && pwd)"
SET="${1:-default}"
case "$SET" in
  default) SCENARIOS="S1 S2 S2m S3 S4 S5 S6 S9b S9s S9m" ;;
  backfill) SCENARIOS="B1" ;;
  midrun) SCENARIOS="S4m S4r S4n S11" ;;
  degraded) SCENARIOS="S12" ;;
  learning) SCENARIOS="L1 L2 S5 S12 B1" ;;
  idle) SCENARIOS="S8 S10" ;;
  all) SCENARIOS="S1 S2 S2m S3 S4 S5 S6 S9b S9s S9m B1 S4m S4r S4n S11 S12 L1 L2 S9a S8 S10" ;;
  *) SCENARIOS="$(printf '%s' "$SET" | tr ',' ' ')" ;;
esac

REPEATS="${REPEATS:-3}"
DURATION="${DURATION:-180}"
if [ -z "${CANDIDATES:-}" ] && [ "$SET" = learning ]; then
  CANDIDATES="lasso-learned,lasso-unlearned"
elif [ -z "${CANDIDATES:-}" ]; then
  CANDIDATES="direct,race2,lasso,lasso-fastest,lasso-bf"
  if [ -n "${ENDPOINT_URL:-}" ]; then CANDIDATES="$CANDIDATES,endpoint"; fi
fi
OUT="${OUT:-$KIT/results/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$(dirname "$OUT")"
if ! mkdir "$OUT" 2>/dev/null; then
  echo "results directory already exists: $OUT (set OUT to a new path)" >&2
  exit 1
fi
case "$CANDIDATES" in
  *lasso*)
    if [ -z "${LASSO_REL:-}" ]; then
      VERSION="$(sed -n 's/^ *version: "\(.*\)",$/\1/p' "$KIT/../../mix.exs" | head -n 1)"
      case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) PLATFORM=macos-aarch64 ;;
        Linux-x86_64) PLATFORM=linux-x86_64 ;;
        Linux-aarch64 | Linux-arm64) PLATFORM=linux-aarch64 ;;
        *) echo "no Lasso $VERSION archive for $(uname -s) $(uname -m); build one and set LASSO_REL" >&2; exit 1 ;;
      esac
      NAME="lasso-$VERSION-$PLATFORM"
      URL="https://github.com/jaxernst/lasso-rpc/releases/download/v$VERSION"
      echo "downloading $NAME from $URL"
      mkdir "$OUT/release"
      if ! curl -fsSL -o "$OUT/release/$NAME.tar.gz" "$URL/$NAME.tar.gz" || ! curl -fsSL -o "$OUT/release/$NAME.sha256" "$URL/$NAME.sha256"; then
        echo "could not download $NAME from the v$VERSION release; set LASSO_REL to a release directory" >&2
        exit 1
      fi
      if command -v sha256sum > /dev/null; then sum="$(sha256sum "$OUT/release/$NAME.tar.gz")"; else sum="$(shasum -a 256 "$OUT/release/$NAME.tar.gz")"; fi
      if [ "${sum%% *}" != "$(cut -d ' ' -f 1 "$OUT/release/$NAME.sha256")" ]; then
        echo "checksum mismatch for $NAME.tar.gz" >&2
        exit 1
      fi
      tar -xzf "$OUT/release/$NAME.tar.gz" -C "$OUT/release"
      LASSO_REL="$OUT/release/lasso"
      export LASSO_REL
    fi
    echo "lasso: $LASSO_REL"
    ;;
esac
json_list() { printf '%s' "$1" | tr ', ' '\n\n' | sed '/^$/d; s/.*/"&"/' | paste -sd, -; }
printf '{"scenarios": [%s], "candidates": [%s], "repeats": %s, "duration_s": %s}\n' \
  "$(json_list "$SCENARIOS")" "$(json_list "$CANDIDATES")" "$REPEATS" "$DURATION" > "$OUT/plan.json"

echo "scenarios: $SCENARIOS"
echo "candidates: $CANDIDATES"
echo "repeats: $REPEATS, duration: ${DURATION} s, results: $OUT"

failed=""
r=1
while [ "$r" -le "$REPEATS" ]; do
  for s in $SCENARIOS; do
    echo "$(date +%H:%M:%S) start $s-r$r"
    RUN_ID="$s-r$r" RESULTS_DIR="$OUT" node "$KIT/runner.mjs" "$s" "$CANDIDATES" "$DURATION" || failed="$failed $s-r$r"
  done
  r=$((r + 1))
done

status=0
node "$KIT/analyze.mjs" "$OUT" > /dev/null || status=$?
case "$status" in 0 | 2) ;; *) exit "$status" ;; esac
echo "$(date +%H:%M:%S) done. Tables: $OUT/tables.md"
if [ -n "$failed" ]; then echo "failed runs:$failed" >&2; fi
if [ "$status" -eq 2 ]; then echo "expected outcomes failed; see Expected outcomes in $OUT/tables.md" >&2; fi
if [ -n "$failed" ] || [ "$status" -eq 2 ]; then exit 1; fi
