# Build stage
FROM hexpm/elixir:1.18.4-erlang-28.0-debian-bookworm-20260610@sha256:d9d55d4eda71e49ee175d170a62d4a25f3581e59dd196e3407ff0aaadfa292ea AS builder

# Install build dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    ca-certificates \
    nodejs \
    npm && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Set environment to production
ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first (avoid copying host _build/deps)
COPY mix.exs mix.lock ./
COPY config/ ./config/

# Install dependencies (prod only)
RUN mix deps.get --only prod

# Copy application source (explicit directories)
COPY lib/ ./lib/
COPY assets/ ./assets/
COPY priv/ ./priv/

# Compile application
RUN mix compile

# Build static assets
RUN mix tailwind.install && \
    mix esbuild.install && \
    mix tailwind lasso --minify && \
    mix esbuild lasso --minify && \
    mix phx.digest

# Create release
RUN mix release

# Runtime stage
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl libstdc++6 libtinfo6 libssl3 && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --gid 10001 lasso && \
    useradd --uid 10001 --gid 10001 --no-create-home --home-dir /data --shell /usr/sbin/nologin lasso && \
    mkdir -p /data && chown 10001:10001 /data

LABEL org.opencontainers.image.source="https://github.com/jaxernst/lasso-rpc" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.title="Lasso RPC" \
      org.opencontainers.image.description="Ethereum JSON-RPC routing, provider failover, and operational observability"

WORKDIR /app
ENV MIX_ENV=prod PHX_SERVER=true LASSO_DATA_DIR=/data RELEASE_TMP=/tmp/lasso LANG=C.UTF-8

COPY --from=builder /app/_build/prod/rel/lasso ./
COPY --from=builder /app/config/profiles ./config/profiles
COPY --chmod=755 deployment/entrypoint.sh /app/entrypoint.sh

USER 10001:10001
EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl --fail --silent "http://127.0.0.1:${PORT:-4000}/api/health" > /dev/null || exit 1
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
