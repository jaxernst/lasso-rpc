import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load .env file if present (system env vars take precedence)
if File.exists?(".env") and Code.ensure_loaded?(Dotenvy) do
  vars = Dotenvy.source!([".env", System.get_env()])
  Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

  require Logger
  Logger.info("Loaded #{map_size(vars)} environment variables from .env")
end

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

# VM Metrics configuration
# Disable in production SaaS by setting LASSO_VM_METRICS_ENABLED=false
vm_metrics_enabled =
  case System.get_env("LASSO_VM_METRICS_ENABLED") do
    "false" -> false
    "0" -> false
    nil -> Application.get_env(:lasso, :vm_metrics_enabled, true)
    _ -> true
  end

config :lasso, :vm_metrics_enabled, vm_metrics_enabled

# Cluster region identification
# If not explicitly set, generate a random region ID for this node
# This ensures each node has a unique identifier for dashboard region views
cluster_region =
  case System.get_env("CLUSTER_REGION") do
    nil ->
      random_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      region = "node-#{random_id}"
      System.put_env("CLUSTER_REGION", region)
      region

    region ->
      region
  end

config :lasso, :cluster_region, cluster_region

# Clustering configuration (optional - only enabled when CLUSTER_NODE_BASENAME is set)
if dns_query = System.get_env("CLUSTER_DNS_QUERY") do
  config :libcluster,
    topologies: [
      dns: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 5_000,
          query: dns_query,
          node_basename: System.fetch_env!("CLUSTER_NODE_BASENAME")
        ]
      ]
    ]
end

if config_env() == :prod do
  # Get port from environment variable (internal port the app listens on)
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Get host from environment variable, defaulting to localhost for development
  host = System.get_env("PHX_HOST") || "localhost"

  # External URL scheme (HTTPS in production behind Fly.io proxy)
  scheme = System.get_env("PHX_SCHEME") || "https"

  # Require SECRET_KEY_BASE in production for security
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :lasso, LassoWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    # URL config is for external access - use HTTPS and standard port (443 is omitted from URLs)
    url: [host: host, scheme: scheme],
    secret_key_base: secret_key_base

  # Optional: surface Fly region to the app for tagging
  if System.get_env("FLY_REGION") do
    config :lasso, :region, System.get_env("FLY_REGION")
  end
end
