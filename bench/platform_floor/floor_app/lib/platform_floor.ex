defmodule PlatformFloor.JSON do
  @moduledoc false

  def decode!(body), do: :json.decode(body)
  def encode!(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end

defmodule PlatformFloor.Handler do
  @moduledoc false

  import Plug.Conn

  def echo(conn, request) do
    send_json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "0x1"})
  end

  def proxy(conn, request) do
    body = PlatformFloor.JSON.encode!(request)

    {:ok, %Finch.Response{status: 200, body: response_body}} =
      :post
      |> Finch.build(upstream_url(), [{"content-type", "application/json"}], body)
      |> Finch.request(PlatformFloor.Finch, receive_timeout: 5_000, pool_timeout: 5_000)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response_body)
  end

  defp send_json(conn, value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, PlatformFloor.JSON.encode!(value))
  end

  defp upstream_url do
    :persistent_term.get({PlatformFloor, :upstream_url})
  end
end

defmodule PlatformFloor.BarePlug do
  @moduledoc false

  import Plug.Conn

  def init(options), do: options

  def call(%Plug.Conn{method: "POST", path_info: ["echo"]} = conn, _options) do
    {request, conn} = read_request(conn)
    PlatformFloor.Handler.echo(conn, request)
  end

  def call(%Plug.Conn{method: "POST", path_info: ["proxy"]} = conn, _options) do
    {request, conn} = read_request(conn)
    PlatformFloor.Handler.proxy(conn, request)
  end

  def call(conn, _options), do: send_resp(conn, 404, "")

  defp read_request(conn) do
    {:ok, body, conn} = read_body(conn, length: 8_000_000, read_length: 1_000_000)
    {PlatformFloor.JSON.decode!(body), conn}
  end
end

defmodule PlatformFloor.Router do
  @moduledoc false

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/" do
    pipe_through(:api)
    post("/echo", PlatformFloor.Controller, :echo)
    post("/proxy", PlatformFloor.Controller, :proxy)
  end
end

defmodule PlatformFloor.Controller do
  @moduledoc false

  def init(action), do: action

  def call(conn, action), do: apply(__MODULE__, action, [conn, conn.params])

  def echo(conn, request), do: PlatformFloor.Handler.echo(conn, request)
  def proxy(conn, request), do: PlatformFloor.Handler.proxy(conn, request)
end

defmodule PlatformFloor.PhoenixEndpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :platform_floor

  @session_options [
    store: :cookie,
    key: "_platform_floor_key",
    signing_salt: "platform-floor"
  ]

  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: PlatformFloor.JSON
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(CORSPlug, origin: "*", methods: ["GET", "POST", "OPTIONS"])
  plug(PlatformFloor.Router)
end

defmodule PlatformFloor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4200") |> String.to_integer()
    mode = System.get_env("FLOOR_MODE", "bare")

    :persistent_term.put(
      {PlatformFloor, :upstream_url},
      System.get_env("UPSTREAM_URL", "http://127.0.0.1:4100")
    )

    Application.put_env(:phoenix, :json_library, PlatformFloor.JSON)

    Application.put_env(:platform_floor, PlatformFloor.PhoenixEndpoint,
      adapter: Phoenix.Endpoint.Cowboy2Adapter,
      http: [ip: {0, 0, 0, 0}, port: port],
      secret_key_base: String.duplicate("platform-floor-secret-", 4),
      server: true,
      url: [host: "localhost"]
    )

    children = [
      {Finch,
       name: PlatformFloor.Finch,
       pools: %{
         :default => [
           protocols: [:http1],
           size: System.get_env("POOL_SIZE", "256") |> String.to_integer(),
           count: 1
         ]
       }},
      server_child(mode, port)
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PlatformFloor.Supervisor)
  end

  defp server_child("bare", port) do
    {Plug.Cowboy,
     scheme: :http, plug: PlatformFloor.BarePlug, options: [ip: {0, 0, 0, 0}, port: port]}
  end

  defp server_child("phoenix", _port), do: PlatformFloor.PhoenixEndpoint

  defp server_child(mode, _port),
    do: raise("FLOOR_MODE must be bare or phoenix, got #{inspect(mode)}")
end
