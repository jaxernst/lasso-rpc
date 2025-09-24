import Config

# For production, don't forget to configure the url host
# to something meaningful, Phoenix uses this information
# when generating URLs.
config :livechain, LivechainWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Email configuration removed - not needed for this application

# Do not print debug messages in production
config :logger, level: :info

config :livechain,
  environment: :prod

# Runtime production config is handled by runtime.exs
