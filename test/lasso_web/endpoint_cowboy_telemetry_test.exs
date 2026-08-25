defmodule LassoWeb.EndpointCowboyTelemetryTest do
  use ExUnit.Case, async: false

  @env_name "LASSO_COWBOY_TELEMETRY_ENABLED"
  @server_ref :lasso_cowboy_telemetry_test_http
  @websocket_chain_id 99_999_993
  @cowboy_events [
    [:cowboy, :request, :start],
    [:cowboy, :request, :stop],
    [:cowboy, :request, :exception]
  ]
  @dashboard_event [:lasso, :dashboard, :event_stream, :subscribe]

  defmodule WebSocketProbe do
    def handle_connect(_connection, owner) do
      send(owner, :websocket_connected)
      {:ok, owner}
    end

    def handle_cast(:close, owner), do: {:close, owner}
    def handle_info(_message, owner), do: {:ok, owner}
    def handle_frame(_frame, owner), do: {:ok, owner}
    def handle_disconnect(_reason, owner), do: {:ok, owner}
  end

  setup do
    original_value = System.get_env(@env_name)

    on_exit(fn ->
      restore_env(@env_name, original_value)
    end)

    :ok
  end

  test "runtime configuration defaults Cowboy telemetry to enabled and parses explicit values" do
    for {value, expected} <- [
          {nil, true},
          {"true", true},
          {"1", true},
          {"false", false},
          {"0", false}
        ] do
      config = runtime_config(value)

      assert get_in(config, [:lasso, :cowboy_telemetry_enabled]) == expected

      stream_handlers =
        config
        |> get_in([:lasso, LassoWeb.Endpoint, :http])
        |> List.wrap()
        |> Keyword.get(:stream_handlers)

      assert stream_handlers == if(expected, do: nil, else: [:cowboy_stream_h])
      assert get_in(config, [:lasso, LassoWeb.Endpoint, :http, :ip]) == {127, 0, 0, 1}
      assert get_in(config, [:lasso, LassoWeb.Endpoint, :http, :port]) == 4002
    end

    dev_http_options = get_in(runtime_config("false", :dev), [:lasso, LassoWeb.Endpoint, :http])

    assert dev_http_options[:stream_handlers] == [:cowboy_stream_h]
    assert dev_http_options[:ip] == {127, 0, 0, 1}
    assert dev_http_options[:port] == 4000
    assert dev_http_options[:protocol_options] == [max_connections: 1000, idle_timeout: 60_000]
  end

  test "runtime configuration rejects ambiguous Cowboy telemetry values" do
    assert_raise RuntimeError,
                 "LASSO_COWBOY_TELEMETRY_ENABLED must be true, false, 1, or 0",
                 fn -> runtime_config("yes") end
  end

  test "default configuration emits Cowboy telemetry for a real HTTP request" do
    http_options = runtime_http_options(nil)

    with_server(http_options, fn ref, port ->
      attach_cowboy_events(ref)

      assert %{stream_handlers: [:cowboy_telemetry_h, :cowboy_stream_h]} =
               :ranch.get_protocol_options(ref)

      assert {200, body} = http_get(port, "/api/health")
      assert Jason.decode!(body)["status"] == "healthy"

      assert_receive {:cowboy_event, [:cowboy, :request, :start], ^ref}, 1_000
      assert_receive {:cowboy_event, [:cowboy, :request, :stop], ^ref}, 1_000
    end)
  end

  test "disabled configuration removes only Cowboy telemetry and preserves LiveView and WebSocket" do
    http_options = runtime_http_options("false")
    dashboard_handler_id = {__MODULE__, :dashboard, make_ref()}

    :ok =
      Lasso.Config.ConfigStore.register_chain_runtime("public", @websocket_chain_id, %{
        display_name: "Cowboy Telemetry WebSocket Test",
        url_aliases: ["cowboy-telemetry-websocket-test"],
        providers: []
      })

    on_exit(fn ->
      Lasso.Config.ConfigStore.unregister_chain_runtime("public", @websocket_chain_id)
    end)

    :ok =
      :telemetry.attach(
        dashboard_handler_id,
        @dashboard_event,
        fn event, _measurements, _metadata, pid -> send(pid, {:lasso_event, event}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(dashboard_handler_id) end)

    with_server(http_options, fn ref, port ->
      attach_cowboy_events(ref)

      assert %{stream_handlers: [:cowboy_stream_h]} = :ranch.get_protocol_options(ref)

      assert {200, health_body} = http_get(port, "/api/health")
      assert Jason.decode!(health_body)["status"] == "healthy"

      assert {200, dashboard_body} = http_get(port, "/dashboard/public")
      assert dashboard_body =~ "data-phx-main"

      websocket_url =
        "ws://127.0.0.1:#{port}/ws/rpc/cowboy-telemetry-websocket-test"

      assert {:ok, websocket} =
               Lasso.RPC.Transport.WebSocket.Client.start_link(
                 websocket_url,
                 WebSocketProbe,
                 self(),
                 owner: self()
               )

      assert_receive :websocket_connected, 1_000

      websocket_monitor = Process.monitor(websocket)
      Lasso.RPC.Transport.WebSocket.Client.cast(websocket, :close)
      assert_receive {:DOWN, ^websocket_monitor, :process, ^websocket, _reason}, 1_000

      refute_receive {:cowboy_event, _event, ^ref}, 100

      :telemetry.execute(@dashboard_event, %{}, %{profile: "public", subscriber: self()})
      assert_receive {:lasso_event, @dashboard_event}, 1_000
    end)
  end

  defp runtime_http_options(value) do
    value
    |> runtime_config()
    |> get_in([:lasso, LassoWeb.Endpoint, :http])
    |> List.wrap()
  end

  defp runtime_config(value, env \\ :test) do
    restore_env(@env_name, value)

    base_config = Config.Reader.read!(Path.expand("../../config/config.exs", __DIR__), env: env)

    runtime_config =
      Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: env)

    Config.Reader.merge(base_config, runtime_config)
  end

  defp with_server(http_options, fun) do
    options =
      Keyword.merge(http_options,
        ip: {127, 0, 0, 1},
        port: 0,
        ref: @server_ref
      )

    {:ok, _pid} = Plug.Cowboy.http(LassoWeb.Endpoint, [], options)
    port = :ranch.get_port(@server_ref)

    try do
      fun.(@server_ref, port)
    after
      Plug.Cowboy.shutdown(@server_ref)
    end
  end

  defp attach_cowboy_events(ref) do
    handler_id = {__MODULE__, :cowboy, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        @cowboy_events,
        fn event, _measurements, metadata, pid ->
          event_ref = metadata[:ref] || get_in(metadata, [:req, :ref])
          send(pid, {:cowboy_event, event, event_ref})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ref
  end

  defp http_get(port, path) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    {:ok, {{_http_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    {status, body}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
