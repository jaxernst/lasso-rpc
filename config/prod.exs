import Config

# Production configuration for Lasso RPC
# Runtime secrets (SECRET_KEY_BASE, PORT, etc.) are configured in runtime.exs

# Phoenix endpoint configuration
config :lasso, LassoWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true,
  code_reloader: false,
  debug_errors: false,
  check_origin: true

# Enhanced logging for production debugging (same as dev)
config :logger, :console,
  format: {Lasso.Logger.ChainFormatter, :format},
  level: :info,
  metadata: :all

# Additional logger configuration for production
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Enable detailed Phoenix logging (same as dev)
config :phoenix, :logger, true

# Telemetry-based operational logging
# These logs are NOT sampled - they always emit for important events
config :lasso, Lasso.TelemetryLogger,
  enabled: true,
  log_slow_requests: true,
  log_failovers: true,
  log_circuit_breaker: true

config :lasso, :vm_metrics_enabled, false

# Environment marker
config :lasso, environment: :prod
