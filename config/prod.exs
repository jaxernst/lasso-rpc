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
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Enable detailed Phoenix logging (same as dev)
config :phoenix, :logger, true

# Observability in production
config :lasso, :observability,
  log_level: :debug,
  max_error_message_chars: 256,
  max_meta_header_bytes: 4096,
  # Request completion log sampling rate
  # 1.0 = log all requests, 0.1 = log 10% of requests
  # Note: Error responses are always logged regardless of sampling
  sampling: [rate: 1]

# Telemetry-based operational logging
# These logs are NOT sampled - they always emit for important events
config :lasso, Lasso.TelemetryLogger,
  enabled: true,
  log_slow_requests: true,
  log_failovers: true,
  log_circuit_breaker: true

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

config :lasso, :vm_metrics_enabled, false

# Environment marker
config :lasso, environment: :prod
