import Config

# For development, we configure the endpoint to listen on all interfaces
config :livechain, LivechainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "FvHQmKTwY0gU9P0aH8gi9M5rO4+q2qIIhpKjLlMcOqfeN4YubVHibH/rbN3e7OMH",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:livechain, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:livechain, ~w(--watch)]}
  ]

# Enhanced logging for development debugging
config :logger, :console,
  format: "[$level] $message\n",
  level: :info,
  metadata: :all

# Enable detailed Phoenix logging
config :phoenix, :logger, true
config :phoenix, :serve_endpoints, true

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Enable simulator in development for demos and testing
config :livechain,
  enable_simulator: true,
  environment: :dev
