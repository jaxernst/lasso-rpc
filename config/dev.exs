import Config

# Development endpoint configuration
# PORT can be overridden at runtime via env var (handled in runtime.exs)
config :lasso, LassoWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4000,
    protocol_options: [
      max_connections: 1000,
      idle_timeout: 60_000
    ]
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: false,
  secret_key_base: "FvHQmKTwY0gU9P0aH8gi9M5rO4+q2qIIhpKjLlMcOqfeN4YubVHibH/rbN3e7OMH",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:lasso, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:lasso, ~w(--watch)]}
  ]

# Enhanced logging for development debugging
config :logger, :console,
  format: {Lasso.Logger.ChainFormatter, :format},
  level: :debug,
  metadata: :all

# Silence LiveView debug logs (MOUNT, HANDLE EVENT, Replied, etc.)
config :phoenix_live_view, log: false

# Reduce Phoenix debug log spam (only log at info level)
# This removes "Processing with", "Parameters:", "Pipelines:" debug logs
config :phoenix, :logger, false
config :phoenix, :serve_endpoints, true

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :lasso,
  environment: :dev
