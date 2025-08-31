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

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files
COPY mix.exs mix.lock ./

# Install Elixir dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy Phoenix assets
COPY assets/ ./assets/

# Install Node.js dependencies and build assets
RUN cd assets && npm ci --production=false && npm run build

# Copy application code
COPY . .

# Compile the application
RUN mix compile

# Create release build
RUN mix phx.digest

# Expose port
EXPOSE 4000

# Set environment to production
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Start the application
CMD ["mix", "phx.server"]