defmodule LassoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :lasso

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_lasso_key",
    signing_salt: "QxjVyFyh",
    same_site: "Lax"
  ]

  # LiveView socket for real-time updates
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # JSON-RPC WebSocket endpoints with full route parity to HTTP endpoints
  # Using /ws/rpc/* paths to avoid conflicts with HTTP /rpc/* routes
  # Phoenix's WebSocket transport only accepts GET requests, so we cannot share
  # the exact same path with HTTP POST endpoints (would return 400 errors)
  # Each socket definition provides compile-time route verification and introspection
  #
  # IMPORTANT: Phoenix processes socket declarations in REVERSE order (LIFO),
  # so generic routes (with only variables) must be defined FIRST, and specific
  # routes (with literal segments) must be defined LAST

  # Supported routing strategies for provider selection
  @rpc_strategies ~w(fastest round-robin latency-weighted)

  # Socket configuration shared across all endpoints
  @socket_config [
    websocket: [
      path: "",
      connect_info: [:peer_data, :x_headers, :uri],
      # 2 hours timeout for persistent subscription connections
      timeout: 7_200_000,
      compress: false
    ],
    longpoll: false
  ]

  # =========================================================================
  # Legacy routes (without profile parameter) - use "default" profile
  # =========================================================================

  # Alternative provider override format (least specific - two variables) - defined first!
  socket("/ws/rpc/:chain_id/:provider_id", LassoWeb.RPCSocket, @socket_config)

  # Base WebSocket endpoint (less specific - single variable)
  socket("/ws/rpc/:chain_id", LassoWeb.RPCSocket, @socket_config)

  # Strategy-specific WebSocket endpoints (compile-time generation - has strategy literals)
  for strategy <- @rpc_strategies do
    socket("/ws/rpc/#{strategy}/:chain_id", LassoWeb.RPCSocket, @socket_config)
  end

  # Provider override WebSocket endpoint (most specific - has "provider" literal) - defined last!
  socket("/ws/rpc/provider/:provider_id/:chain_id", LassoWeb.RPCSocket, @socket_config)

  # =========================================================================
  # Profile-aware routes (with profile parameter)
  # =========================================================================

  # Profile-aware alternative provider override (three variables)
  socket("/ws/rpc/profile/:profile/:chain_id/:provider_id", LassoWeb.RPCSocket, @socket_config)

  # Profile-aware base WebSocket endpoint (two variables)
  socket("/ws/rpc/profile/:profile/:chain_id", LassoWeb.RPCSocket, @socket_config)

  # Profile-aware strategy-specific endpoints (has profile + strategy literals)
  for strategy <- @rpc_strategies do
    socket("/ws/rpc/profile/:profile/#{strategy}/:chain_id", LassoWeb.RPCSocket, @socket_config)
  end

  # Profile-aware provider override (has profile + "provider" literal)
  socket(
    "/ws/rpc/profile/:profile/provider/:provider_id/:chain_id",
    LassoWeb.RPCSocket,
    @socket_config
  )

  # Serve at "/" the static files from "priv/static" directory.
  plug(Plug.Static,
    at: "/",
    from: :lasso,
    gzip: false,
    only: LassoWeb.static_paths()
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

  # Capture request start time for accurate E2E latency measurement
  plug(LassoWeb.Plugs.RequestTimingPlug)

  # plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  # JSON parse error handling is now handled by LassoWeb.ErrorJSON
  # which returns proper JSON-RPC error responses instead of HTML error pages.

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  plug(CORSPlug,
    origin: "*",
    max_age: 86_400,
    methods: ["GET", "POST", "OPTIONS"],
    headers: [
      "Content-Type",
      "Authorization",
      "X-Requested-With",
      "X-Lasso-Provider",
      "X-Lasso-Transport"
    ]
  )

  plug(LassoWeb.Router)
end
