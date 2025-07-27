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

# Configure JSON library
config :phoenix, :json_library, Jason

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Environment specific configs
import_config "#{config_env()}.exs"