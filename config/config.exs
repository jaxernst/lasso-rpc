import Config

# Configure Phoenix
config :lasso, LassoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: LassoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Lasso.PubSub,
  live_view: [signing_salt: "QxjVyFyh"],
  secret_key_base: "YourSecretKeyBaseHere" <> String.duplicate("a", 32)

# Default provider selection strategy
# Options: :fastest, :round_robin, :latency_weighted
config :lasso, :provider_selection_strategy, :round_robin

# Default HTTP client adapter
config :lasso, :http_client, Lasso.RPC.HttpClient.Finch

# Health check and provider management defaults
config :lasso, :health_check_interval, 30_000
config :lasso, :health_check_timeout, 10_000
config :lasso, :health_check_failure_threshold, 3
config :lasso, :health_check_recovery_threshold, 2

# Provider management defaults
config :lasso, :auto_failover, true
config :lasso, :load_balancing, "priority"

# Connection defaults
config :lasso, :reconnect_attempts, 10
config :lasso, :heartbeat_interval, 30_000
config :lasso, :reconnect_interval, 5_000

# Failover defaults
config :lasso, :failover_enabled, true
config :lasso, :max_backfill_blocks, 100
config :lasso, :backfill_timeout, 30_000

# Observability configuration
config :lasso, :observability,
  log_level: :info,
  include_params_digest: true,
  max_error_message_chars: 256,
  max_meta_header_bytes: 4096,
  sampling: [rate: 1.0]

# Dashboard LiveView event buffering configuration
config :lasso, :dashboard,
  # Event batch flush interval in milliseconds
  batch_interval: 100,
  # Maximum events in buffer before early flush
  max_buffer_size: 50,
  # Mailbox backpressure thresholds
  mailbox_thresholds: %{
    throttle: 500,
    drop: 1000
  },
  # Metrics recalculation debounce interval in milliseconds
  metrics_debounce: 2_000

# Dashboard status configuration
config :lasso, :dashboard_status,
  # Maximum blocks a provider can lag behind before showing as "syncing"
  # instead of "healthy". Set to 0 to disable lag-based status.
  lag_threshold_blocks: 2

# Configure JSON library
config :phoenix, :json_library, Jason

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  lasso: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  lasso: [
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
  metadata: [
    :request_id,
    :chain,
    :provider_id,
    :circuit_breaker_id,
    :reason,
    :error_category,
    :channels,
    :retry_after_ms,
    :height,
    :staleness_threshold_ms,
    :lag_blocks,
    :threshold,
    :duration_ms,
    :providers_probed,
    :successful,
    :elapsed_ms,
    :deadline_ms,
    :refresh_interval_ms,
    :lag_threshold_blocks
  ]

# Environment specific configs
import_config "#{config_env()}.exs"

# Runtime configuration (loaded at runtime, not compile time)
if File.exists?("config/runtime.exs") do
  import_config "runtime.exs"
end
