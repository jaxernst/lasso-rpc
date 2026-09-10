import Config

config :lasso, :block_publication_repo, Lasso.BlockPublication.Repo

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
# Options: :fastest, :load_balanced, :latency_weighted
config :lasso, :provider_selection_strategy, :load_balanced

config :lasso, :profile_aliases, %{"default" => "public"}

config :lasso,
  inflight_request_byte_limit: 128 * 1_024 * 1_024,
  inflight_request_byte_budget_buckets: 256,
  inflight_request_minimum_charge_bytes: 4_096,
  ws_connection_inflight_byte_limit: 32 * 1_024 * 1_024,
  http_pool: [size: 256, count: 1]

# Default HTTP client adapter
config :lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch

# Encoded response metadata header limit
config :lasso, :observability, max_meta_header_bytes: 4096

# Dashboard status configuration
config :lasso, :dashboard_status,
  # Maximum blocks a provider can lag behind before showing as "syncing"
  # instead of "healthy". Set to 0 to disable lag-based status.
  lag_threshold_blocks: 2

# VM Metrics Configuration
# Enable/disable BEAM VM metrics collection and the System Metrics tab.
# When disabled, no VM statistics are collected and the tab is hidden.
# Disable for production deployments where exposing VM internals is not desired.
config :lasso, :vm_metrics_enabled, false

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
    :new_heads_staleness_threshold_ms,
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
