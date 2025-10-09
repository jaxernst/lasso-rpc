# Build stage
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bullseye-20241202 AS builder

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
COPY deployment/ ./deployment/

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
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bullseye-20241202-slim

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
COPY --from=builder /app/deployment ./deployment
# Copy config/chains.yml for runtime (fallback if no volume mounted)
COPY --from=builder /app/config/chains.yml ./config/chains.yml

# Make entrypoint executable
RUN chmod +x ./deployment/entrypoint.sh

# Expose port
EXPOSE 4000

# Use entrypoint to seed /data/chains.yml on first boot, then start Phoenix
CMD ["/app/deployment/entrypoint.sh"]