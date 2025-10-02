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
  # Get port from environment variable
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Get host from environment variable, defaulting to localhost for development
  host = System.get_env("PHX_HOST") || "localhost"

  config :lasso, LassoWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    url: [host: host, port: port, scheme: "http"],
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") || "YourSecretKeyBaseHere" <> String.duplicate("a", 64)
end
