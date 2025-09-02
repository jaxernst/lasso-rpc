defmodule LivechainWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :livechain

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_livechain_key",
    # TODO: Put in env var
    signing_salt: "FvHQmKTwY0gU9P0aH8gi9M5rO4+q2qIIhpKjLlMcOqfeN4YubVHibH/rbN3e7OMH",
    same_site: "Lax"
  ]

  # LiveView socket for real-time updates
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # WebSocket configuration
  socket("/socket", LivechainWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  # JSON-RPC WebSocket endpoints with route parameters
  # Using /ws/rpc/:chain_id path to avoid conflicts with HTTP /rpc/:chain_id
  socket("/ws/rpc/:chain_id", LivechainWeb.RPCSocket,
    websocket: true,
    longpoll: false
  )

  # Serve at "/" the static files from "priv/static" directory.
  plug(Plug.Static,
    at: "/",
    from: :livechain,
    gzip: false,
    only: LivechainWeb.static_paths()
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  if Mix.env() == :dev do
    plug(Phoenix.LiveDashboard.RequestLogger,
      param_key: "request_logger",
      cookie_key: "request_logger"
    )
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(LivechainWeb.Router)
end
