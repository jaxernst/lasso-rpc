import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lasso, LassoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base" <> String.duplicate("a", 32),
  # Enable server for integration/HTTP testing
  server: true

# Print only warnings and errors during test
config :logger, :console,
  format: {Lasso.Logger.ChainFormatter, :format},
  level: :none,
  metadata: [
    :provider,
    :provider_id,
    :method,
    :url,
    :request_id,
    :transport,
    :context,
    :timeout,
    :retry_count,
    :error,
    :channel,
    :result,
    :chain,
    :chain_id,
    :key,
    :id,
    :connection,
    :topic,
    :params,
    :remaining_channels,
    :retriable,
    :current_status
  ]

# Email configuration removed - not needed for this application

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :lasso,
  environment: :test,
  backend_config: [
    backend: Lasso.Config.Backend.File,
    config: [
      profiles_dir: "test/support/profiles",
      legacy_config_path: "config/test_chains.yml"
    ]
  ],
  # Use real HTTP client (Finch) for integration tests
  # (can be overridden in test_helper.exs for unit tests)
  http_client: Lasso.RPC.Transport.HTTP.Client.Finch

# Configure Phoenix PubSub for testing
config :lasso, Lasso.PubSub, adapter: Phoenix.PubSub.PG

# Configure process registry for testing
config :lasso, Lasso.Core.Support.ProcessRegistry, partitions: 1
