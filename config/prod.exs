import Config

# For production, don't forget to configure the url host
# to something meaningful, Phoenix uses this information
# when generating URLs.
config :livechain, LivechainWeb.Endpoint,
  url: [host: "example.com", port: 80],
  cache_static_manifest: "priv/static/cache_manifest.json"

# Email configuration removed - not needed for this application

# Do not print debug messages in production
config :logger, level: :info

# Disable simulator in production - use real providers only
config :livechain,
  enable_simulator: false,
  environment: :prod

# Runtime production config is handled by runtime.exs
