import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :livechain, LivechainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base" <> String.duplicate("a", 32),
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Email configuration removed - not needed for this application

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable simulator in test environment
config :livechain,
  enable_simulator: true,
  environment: :test
