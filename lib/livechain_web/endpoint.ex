defmodule LivechainWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :livechain

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_livechain_key",
    signing_salt: Application.compile_env(:livechain, LivechainWeb.Endpoint)[:secret_key_base],
    same_site: "Lax"
  ]

  # LiveView socket for real-time updates
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # JSON-RPC WebSocket endpoints with route parameters
  # Using /ws/rpc/:chain_id path to avoid conflicts with HTTP /rpc/:chain_id
  socket("/ws/rpc/:chain_id", LivechainWeb.RPCSocket,
    websocket: [
      path: "",
      # 2 hours for subscription connections (standard for persistent WebSocket connections)
      timeout: 7_200_000,
      compress: false
    ],
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
  # plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

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
