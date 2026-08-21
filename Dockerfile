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
FROM hexpm/elixir:1.18.4-erlang-28.0-debian-bookworm-20260610-slim@sha256:0e0f0fc71e298dc9517f825d4076af5235617b70a48b6394a055dd1800fe34ef

# Install runtime dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    nodejs && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Set environment
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Copy built release from builder stage
COPY --from=builder /app/_build/prod/rel/lasso ./
# Copy config/profiles for runtime (seeded to /data/config/profiles by entrypoint if needed)
COPY --from=builder /app/config/profiles ./config/profiles
# Copy entrypoint script
COPY deployment/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Expose port
EXPOSE 4000

# Use entrypoint script to handle profile seeding before starting the app
ENTRYPOINT ["/app/entrypoint.sh"]
