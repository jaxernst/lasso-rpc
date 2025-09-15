import Config

# Configure Phoenix
config :livechain, LivechainWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: LivechainWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Livechain.PubSub,
  live_view: [signing_salt: "QxjVyFyh"],
  secret_key_base: "YourSecretKeyBaseHere" <> String.duplicate("a", 32)

# Default provider selection strategy
config :livechain, :provider_selection_strategy, :cheapest

# Default HTTP client adapter
config :livechain, :http_client, Livechain.RPC.HttpClient.Finch

# Health check and provider management defaults
config :livechain, :health_check_interval, 30_000
config :livechain, :health_check_timeout, 10_000
config :livechain, :health_check_failure_threshold, 3
config :livechain, :health_check_recovery_threshold, 2

# Provider management defaults
config :livechain, :auto_failover, true
config :livechain, :load_balancing, "priority"

# Connection defaults
config :livechain, :reconnect_attempts, 10
config :livechain, :heartbeat_interval, 30_000
config :livechain, :reconnect_interval, 5_000

# Failover defaults
config :livechain, :failover_enabled, true
config :livechain, :max_backfill_blocks, 100
config :livechain, :backfill_timeout, 30_000

# Configure JSON library
config :phoenix, :json_library, Jason

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  livechain: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  livechain: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: :all

# Environment specific configs
import_config "#{config_env()}.exs"

# Runtime configuration (loaded at runtime, not compile time)
if File.exists?("config/runtime.exs") do
  import_config "runtime.exs"
end
