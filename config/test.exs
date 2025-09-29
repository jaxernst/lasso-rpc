import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :livechain, LivechainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base" <> String.duplicate("a", 32),
  server: false

# Print only warnings and errors during test
config :logger, level: :debug

# Email configuration removed - not needed for this application

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :livechain,
  environment: :test,
  chains_config_path: "config/test_chains.yml"

# Configure Phoenix PubSub for testing
config :livechain, Livechain.PubSub, adapter: Phoenix.PubSub.PG

# Configure process registry for testing
config :livechain, Livechain.RPC.ProcessRegistry, partitions: 1
