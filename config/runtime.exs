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

data_dir = System.get_env("LASSO_DATA_DIR")

profiles_dir =
  System.get_env("LASSO_PROFILES_DIR") ||
    if(data_dir, do: Path.join(data_dir, "config/profiles"))

if profiles_dir do
  config :lasso, :backend_config,
    backend: Lasso.Config.Backend.File,
    config: [profiles_dir: profiles_dir]
end

snapshots_dir =
  System.get_env("LASSO_SNAPSHOTS_DIR") ||
    if(data_dir, do: Path.join(data_dir, "benchmark_snapshots"), else: "priv/benchmark_snapshots")

config :lasso, :snapshots_dir, snapshots_dir

# VM Metrics configuration
# Enable collection with LASSO_VM_METRICS_ENABLED=true
vm_metrics_enabled =
  case System.get_env("LASSO_VM_METRICS_ENABLED") do
    "false" -> false
    "0" -> false
    nil -> Application.get_env(:lasso, :vm_metrics_enabled, true)
    _ -> true
  end

config :lasso, :vm_metrics_enabled, vm_metrics_enabled

cowboy_telemetry_enabled =
  case System.get_env("LASSO_COWBOY_TELEMETRY_ENABLED") do
    nil -> true
    value when value in ["true", "1"] -> true
    value when value in ["false", "0"] -> false
    _value -> raise "LASSO_COWBOY_TELEMETRY_ENABLED must be true, false, 1, or 0"
  end

config :lasso, :cowboy_telemetry_enabled, cowboy_telemetry_enabled

unless cowboy_telemetry_enabled do
  config :lasso, LassoWeb.Endpoint, http: [stream_handlers: [:cowboy_stream_h]]
end

http_response_heap_tuning_enabled =
  case System.get_env("LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED") do
    nil -> false
    value when value in ["true", "1"] -> true
    value when value in ["false", "0"] -> false
    _value -> raise "LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED must be true, false, 1, or 0"
  end

config :lasso, :http_response_heap_tuning_enabled, http_response_heap_tuning_enabled

positive_integer_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _other -> raise "#{name} must be a positive integer"
      end
  end
end

config :lasso, :http_pool,
  size: positive_integer_env.("LASSO_HTTP_POOL_SIZE", 256),
  count: positive_integer_env.("LASSO_HTTP_POOL_COUNT", 1)

if value = System.get_env("LW_BETA") do
  case Float.parse(value) do
    {beta, ""} when beta > 0 -> config :lasso, :lw_beta, beta
    _ -> raise "LW_BETA must be a positive number"
  end
end

# Port configuration (runtime override for all environments)
# Allows running multiple instances locally: PORT=4001 iex -S mix phx.server
if port = System.get_env("PORT") do
  config :lasso, LassoWeb.Endpoint, http: [port: String.to_integer(port)]
end

# Node identity label
# Unique identifier for this node instance, used for state partitioning (circuit breakers,
# metrics) via {provider_id, node_id} keys. Each node in a cluster MUST have a distinct value.
# Convention: use geographic region names (e.g., "us-east-1", "iad") when deploying one node
# per region, but any unique string works.
node_id = System.get_env("LASSO_NODE_ID")

if config_env() == :prod and is_nil(node_id) do
  raise """
  LASSO_NODE_ID is required in production.

  Set it to a stable, unique identifier for this node instance.
  """
end

config :lasso, :node_id, node_id || "local"

# Clustering configuration (optional)
# Requires both CLUSTER_DNS_QUERY and CLUSTER_NODE_BASENAME to be set
# Example: CLUSTER_DNS_QUERY=myapp.internal CLUSTER_NODE_BASENAME=myapp
with dns_query when is_binary(dns_query) <- System.get_env("CLUSTER_DNS_QUERY"),
     node_basename when is_binary(node_basename) <- System.get_env("CLUSTER_NODE_BASENAME") do
  config :libcluster,
    topologies: [
      dns: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 5_000,
          query: dns_query,
          node_basename: node_basename
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
end

if config_env() != :test do
  publication_members =
    System.get_env("LASSO_BLOCK_PUBLICATION_MEMBERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  publication_url = System.get_env("LASSO_BLOCK_PUBLICATION_DATABASE_URL")

  if length(publication_members) != length(Enum.uniq(publication_members)) or
       Enum.any?(publication_members, &(&1 == "")),
     do: raise("LASSO_BLOCK_PUBLICATION_MEMBERS must contain unique nonblank instance IDs")

  if publication_members != [] and publication_url in [nil, ""],
    do: raise("Global block publication requires LASSO_BLOCK_PUBLICATION_DATABASE_URL")

  if publication_url not in [nil, ""] do
    config :lasso, Lasso.BlockPublication.Repo,
      url: publication_url,
      pool_size: 4,
      timeout: 5_000

    config :lasso, :block_publication,
      journal: Lasso.BlockPublication.Postgres,
      members: publication_members,
      interval_ms: 1_000
  end
end
