import Config

# For development, we configure the endpoint to listen on all interfaces
# PORT env var allows running multiple nodes locally for cluster testing
config :lasso, LassoWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("PORT") || "4000"),
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
  level: :info,
  metadata: :all

# Filter out Phoenix LiveView "HANDLE EVENT" debug logs
config :logger,
  compile_time_purge_matching: [
    [module: Phoenix.LiveView, level_lower_than: :info]
  ]

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
