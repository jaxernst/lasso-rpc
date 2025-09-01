# Use official Elixir image with Erlang/OTP 27
FROM elixir:1.18-otp-27-alpine

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    curl \
    nodejs \
    npm

# Set working directory
WORKDIR /app

# Set environment to production from the start
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files
COPY mix.exs mix.lock ./

# Install Elixir dependencies for production
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy assets and application code
COPY assets/ ./assets/
COPY . .

# Install any remaining dependencies
RUN mix deps.get --only prod

# Compile the application for production
RUN mix compile

# Build static assets (CSS/JS)
RUN mix tailwind.install
RUN mix esbuild.install
RUN mix tailwind livechain --minify
RUN mix esbuild livechain --minify
RUN mix phx.digest

# Expose port
EXPOSE 4000

# Start the application
CMD ["mix", "phx.server"]