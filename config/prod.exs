import Config

# Production configuration for Lasso RPC
# Runtime secrets (SECRET_KEY_BASE, PORT, etc.) are configured in runtime.exs

# Phoenix endpoint configuration
config :lasso, LassoWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Enable server in production (can be overridden by PHX_SERVER env var)
  server: true,
  # Disable code reloading in production
  code_reloader: false,
  # Disable debug errors (use JSON error responses)
  debug_errors: false,
  # Check origin to prevent CSRF attacks
  check_origin: true

# Enhanced logging for production debugging (same as dev)
config :logger, :console,
  format: {Lasso.Logger.ChainFormatter, :format},
  level: :info,
  metadata: [
    :provider,
    :provider_id,
    :method,
    :url,
    :request_id,
    :transport,
    :context,
    :timeout,
    :retry_count,
    :error,
    :channel,
    :result,
    :chain,
    :chain_id,
    :key,
    :id,
    :connection,
    :topic,
    :params,
    :remaining_channels,
    :retriable,
    :current_status
  ]

# Additional logger configuration for production
config :logger,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Enable detailed Phoenix logging (same as dev)
config :phoenix, :logger, true

# Observability in production
config :lasso, :observability,
  log_level: :info,
  include_params_digest: true,
  max_error_message_chars: 256,
  max_meta_header_bytes: 4096,
  # Sample requests in production (adjust rate as needed)
  sampling: [rate: 0.1]

# Provider health check configuration (more conservative in production)
config :lasso,
  health_check_interval: 60_000,
  health_check_timeout: 15_000,
  health_check_failure_threshold: 5,
  health_check_recovery_threshold: 3

# Connection configuration
config :lasso,
  reconnect_attempts: 20,
  heartbeat_interval: 45_000,
  reconnect_interval: 10_000

# Environment marker
config :lasso, environment: :prod

# Runtime production config (secrets) is handled by runtime.exs
