import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases (Elixir v1.9+)
#
# If you are doing OTP releases, you need to instruct Phoenix
# to start each relevant endpoint:
#
#     config :lasso, LassoWeb.Endpoint, server: true
#
# Then you can assemble a release by calling `mix release`.
# See `mix help release` for more information.

# Configure Phoenix endpoint from environment variables
if System.get_env("PHX_SERVER") do
  config :lasso, LassoWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Get port from environment variable (internal port the app listens on)
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Get host from environment variable, defaulting to localhost for development
  host = System.get_env("PHX_HOST") || "localhost"

  # External URL scheme (HTTPS in production behind Fly.io proxy)
  scheme = System.get_env("PHX_SCHEME") || "https"

  config :lasso, LassoWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    # URL config is for external access - use HTTPS and standard port (443 is omitted from URLs)
    url: [host: host, scheme: scheme],
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") || "YourSecretKeyBaseHere" <> String.duplicate("a", 64)

  # Chains configuration path (supports mounting to a volume like /data/chains.yml)
  chains_path = System.get_env("LASSO_CHAINS_PATH") || "config/chains.yml"
  config :lasso, :chains_config_path, chains_path

  # Optional: surface Fly region to the app for tagging
  if System.get_env("FLY_REGION") do
    config :lasso, :region, System.get_env("FLY_REGION")
  end
end
