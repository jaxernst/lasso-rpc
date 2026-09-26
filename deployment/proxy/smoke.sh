#!/usr/bin/env bash
set -euo pipefail

# Run from the repository root on a Linux Docker host after the Lasso container
# has published 127.0.0.1:4000. Exercises both checked-in proxy examples.
scratch="$(mktemp -d)"

cleanup() {
  docker rm --force lasso-caddy-ci lasso-nginx-ci >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

basic_user=operator
basic_password=proxy-smoke-only
upstream_port="${LASSO_UPSTREAM_PORT:-4000}"
docker run --rm caddy:2.10 caddy hash-password --plaintext "$basic_password" > "$scratch/hash"
sed -e 's/rpc.example.com/localhost:4080/' \
  -e "s/127.0.0.1:4000/127.0.0.1:$upstream_port/" \
  deployment/proxy/Caddyfile > "$scratch/Caddyfile"
sed "s/127.0.0.1:4000/127.0.0.1:$upstream_port/" \
  deployment/proxy/nginx.conf > "$scratch/nginx.conf"

docker run --rm --network host \
  --env LASSO_BASIC_AUTH_HASH="$(cat "$scratch/hash")" \
  --mount "type=bind,source=$scratch/Caddyfile,target=/etc/caddy/Caddyfile,readonly" \
  caddy:2.10 caddy validate --config /etc/caddy/Caddyfile

docker run --detach --name lasso-caddy-ci --network host \
  --env LASSO_BASIC_AUTH_HASH="$(cat "$scratch/hash")" \
  --mount "type=bind,source=$scratch/Caddyfile,target=/etc/caddy/Caddyfile,readonly" \
  caddy:2.10 caddy run --config /etc/caddy/Caddyfile

mkdir -p "$scratch/cert"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=rpc.example.com \
  -keyout "$scratch/cert/privkey.pem" -out "$scratch/cert/fullchain.pem" \
  >/dev/null 2>&1
printf '%s:%s\n' "$basic_user" "$(openssl passwd -apr1 "$basic_password")" > "$scratch/htpasswd"

docker run --rm --network host \
  --mount "type=bind,source=$scratch/nginx.conf,target=/etc/nginx/conf.d/default.conf,readonly" \
  --mount "type=bind,source=$scratch/cert,target=/etc/letsencrypt/live/rpc.example.com,readonly" \
  --mount "type=bind,source=$scratch/htpasswd,target=/etc/nginx/lasso.htpasswd,readonly" \
  nginx:alpine nginx -t

wait_for_proxy() {
  local address="$1"
  local resolved="${2:-}"
  local status
  local -a resolve_args=()
  if [ -n "$resolved" ]; then
    resolve_args=(--resolve "$resolved")
  fi
  for _ in $(seq 1 30); do
    status="$(curl --noproxy '*' --insecure --silent --output /dev/null \
      --write-out '%{http_code}' "${resolve_args[@]}" \
      "$address/api/health" || true)"
    if [ "$status" = 401 ]; then
      return 0
    fi
    sleep 1
  done
  echo "Proxy did not enforce authentication at $address (last status $status)" >&2
  return 1
}

smoke_proxy() {
  local address="$1"
  local resolved="${2:-}"
  local response
  local code
  local headers="$scratch/websocket-headers"
  local -a resolve_args=()
  if [ -n "$resolved" ]; then
    resolve_args=(--resolve "$resolved")
  fi

  wait_for_proxy "$address" "$resolved"
  curl --noproxy '*' --insecure --fail --silent --show-error \
    "${resolve_args[@]}" --user "$basic_user:$basic_password" \
    "$address/api/health" --output "$scratch/health-response"
  grep -q '"status":"healthy"' "$scratch/health-response"
  curl --noproxy '*' --insecure --fail --silent --show-error \
    "${resolve_args[@]}" --user "$basic_user:$basic_password" \
    "$address/metrics" --output "$scratch/metrics-response"
  grep -q '^# HELP ' "$scratch/metrics-response"
  if [ -n "${LASSO_PROXY_READY_PATH:-}" ]; then
    echo "Checking readiness through $address" >&2
    curl --noproxy '*' --insecure --fail --silent --show-error \
      "${resolve_args[@]}" --user "$basic_user:$basic_password" \
      "$address$LASSO_PROXY_READY_PATH" --output "$scratch/ready-response"
    grep -q '"status":"ready"' "$scratch/ready-response" || {
      cat "$scratch/ready-response" >&2
      return 1
    }
  fi
  curl --noproxy '*' --insecure --fail --silent --show-error \
    "${resolve_args[@]}" --user "$basic_user:$basic_password" \
    "$address/dashboard" --output "$scratch/dashboard-response"
  grep -q '<html' "$scratch/dashboard-response"

  response="$scratch/rpc-response"
  code="$(curl --noproxy '*' --insecure --silent --show-error \
    "${resolve_args[@]}" --user "$basic_user:$basic_password" \
    --header 'Content-Type: application/json' \
    --data '{' --output "$response" --write-out '%{http_code}' \
    "$address/rpc/ethereum")"
  case "$code" in
    400|422) ;;
    *) echo "Unexpected RPC validation status $code at $address" >&2; return 1 ;;
  esac

  if [ -n "${LASSO_PROXY_RPC_PATH:-}" ]; then
    echo "Checking controlled RPC through $address" >&2
    curl --noproxy '*' --insecure --fail --silent --show-error \
      "${resolve_args[@]}" --user "$basic_user:$basic_password" \
      --header 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x0000000000000000000000000000000000000001","latest"],"id":42}' \
      --output "$scratch/upstream-rpc-response" \
      "$address$LASSO_PROXY_RPC_PATH"
    grep -q '"result":"0x0"' "$scratch/upstream-rpc-response" || {
      cat "$scratch/upstream-rpc-response" >&2
      return 1
    }
  fi

  curl --noproxy '*' --insecure --http1.1 --silent --show-error \
    "${resolve_args[@]}" --user "$basic_user:$basic_password" \
    --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
    --header 'Sec-WebSocket-Version: 13' \
    --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    --dump-header "$headers" --output /dev/null --max-time 2 \
    "$address${LASSO_PROXY_WS_PATH:-/ws/rpc/ethereum}" || true
  grep -Eq '^HTTP/1\.[01] 101 ' "$headers" || {
    cat "$headers" >&2
    return 1
  }
}

smoke_proxy https://localhost:4080
docker rm --force lasso-caddy-ci >/dev/null

docker run --detach --name lasso-nginx-ci --network host \
  --mount "type=bind,source=$scratch/nginx.conf,target=/etc/nginx/conf.d/default.conf,readonly" \
  --mount "type=bind,source=$scratch/cert,target=/etc/letsencrypt/live/rpc.example.com,readonly" \
  --mount "type=bind,source=$scratch/htpasswd,target=/etc/nginx/lasso.htpasswd,readonly" \
  nginx:alpine

smoke_proxy https://rpc.example.com rpc.example.com:443:127.0.0.1
