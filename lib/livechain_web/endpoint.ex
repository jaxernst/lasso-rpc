defmodule LivechainWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :livechain

  # WebSocket configuration
  socket "/socket", LivechainWeb.UserSocket,
    websocket: true,
    longpoll: false

  # JSON-RPC WebSocket endpoints for Viem compatibility
  socket "/rpc/ethereum", LivechainWeb.RPCSocket,
    websocket: [path: "/", params: %{"chain" => "ethereum"}],
    longpoll: false

  socket "/rpc/arbitrum", LivechainWeb.RPCSocket,
    websocket: [path: "/", params: %{"chain" => "arbitrum"}],
    longpoll: false

  socket "/rpc/polygon", LivechainWeb.RPCSocket,
    websocket: [path: "/", params: %{"chain" => "polygon"}],
    longpoll: false

  socket "/rpc/bsc", LivechainWeb.RPCSocket,
    websocket: [path: "/", params: %{"chain" => "bsc"}],
    longpoll: false

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_livechain_key",
    signing_salt: "QxjVyFyh",
    same_site: "Lax"
  ]

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LivechainWeb.Router
end