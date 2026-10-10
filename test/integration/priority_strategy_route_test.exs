defmodule LassoWeb.PriorityStrategyRouteTest do
  use Lasso.Test.LassoIntegrationCase

  import Phoenix.ConnTest
  import Plug.Conn

  alias Lasso.RPC.Transport.WebSocket.Client

  @endpoint LassoWeb.Endpoint

  defmodule Socket do
    def handle_connect(_connection, owner), do: {:ok, owner}
    def handle_cast({:send, payload}, owner), do: {:reply, {:text, Jason.encode!(payload)}, owner}
    def handle_info(_message, owner), do: {:ok, owner}
    def handle_disconnect(_reason, owner), do: {:ok, owner}

    def handle_frame({:text, body}, owner) do
      send(owner, {:frame, Jason.decode!(body)})
      {:ok, owner}
    end

    def handle_frame(_frame, owner), do: {:ok, owner}
  end

  setup do
    setup_providers([
      %{id: "fallback", behavior: :healthy, priority: 20},
      %{id: "primary", behavior: :healthy, priority: 10}
    ])

    :ok
  end

  test "HTTP priority routes send every request to the first configured provider", %{
    chain: chain
  } do
    for path <- ["/rpc/priority/#{chain}", "/rpc/profile/public/priority/#{chain}"],
        id <- 1..5 do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(path <> "?include_meta=body", Jason.encode!(balance_request(id)))
        |> json_response(200)

      assert %{"id" => ^id, "result" => _} = response

      assert %{"strategy" => "priority", "selected_provider" => %{"id" => "primary"}} =
               response["lasso_meta"]
    end
  end

  test "WebSocket priority routes connect and route to the first configured provider", %{
    chain: chain
  } do
    for path <- ["/ws/rpc/priority/#{chain}", "/ws/rpc/profile/public/priority/#{chain}"] do
      assert_socket_provider(path, 7, "primary")
    end
  end

  test "a failing primary preserves HTTP and WebSocket serving and routing owners", %{
    chain: chain
  } do
    owners =
      Map.new(
        [Lasso.Config.ConfigStore, Lasso.Providers.Catalog.Owner],
        &{&1, Process.whereis(&1)}
      )

    assert Enum.all?(owners, fn {_name, pid} -> is_pid(pid) and Process.alive?(pid) end)

    [{primary, _}] = Registry.lookup(Lasso.Registry, {:http_provider, "primary"})
    :sys.replace_state(primary, &%{&1 | behavior: :always_fail})

    for path <- ["/rpc/priority/#{chain}", "/rpc/profile/public/priority/#{chain}"] do
      response = http_request(path, 8)
      assert %{"id" => 8, "result" => _} = response
      assert response["lasso_meta"]["selected_provider"]["id"] == "fallback"
      assert response["lasso_meta"]["strategy"] == "priority"
    end

    for path <- ["/ws/rpc/priority/#{chain}", "/ws/rpc/profile/public/priority/#{chain}"] do
      assert_socket_provider(path, 9, "fallback")
    end

    assert %{"status" => "healthy"} = build_conn() |> get("/api/health") |> json_response(200)

    for {name, pid} <- owners do
      assert Process.whereis(name) == pid
      assert Process.alive?(pid)
    end
  end

  test "profile priority routes and provider pins retain their own provider configuration", %{
    chain: chain
  } do
    setup_providers([%{id: "testnet-only", behavior: :healthy, priority: 1}], profile: "testnet")

    assert http_request("/rpc/profile/testnet/priority/#{chain}", 10)["lasso_meta"][
             "selected_provider"
           ]["id"] == "testnet-only"

    assert http_request("/rpc/priority/#{chain}", 11)["lasso_meta"]["selected_provider"]["id"] ==
             "primary"

    assert http_request("/rpc/provider/fallback/#{chain}", 12)["lasso_meta"]["selected_provider"][
             "id"
           ] == "fallback"

    assert_socket_provider("/ws/rpc/profile/testnet/priority/#{chain}", 13, "testnet-only")
    assert_socket_provider("/ws/rpc/provider/fallback/#{chain}", 14, "fallback")
  end

  defp http_request(path, id) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path <> "?include_meta=body", Jason.encode!(balance_request(id)))
    |> json_response(200)
  end

  defp assert_socket_provider(path, id, provider) do
    port = @endpoint.config(:http)[:port]
    assert {:ok, socket} = Client.start_link("ws://127.0.0.1:#{port}#{path}", Socket, self())
    Client.cast(socket, {:send, Map.put(balance_request(id), "lasso_meta", "notify")})

    assert_receive {:frame, %{"id" => ^id, "result" => _}}, 5_000
    assert_receive {:frame, %{"method" => "lasso_meta", "params" => signals}}, 5_000
    assert signals["selected_provider"]["id"] == provider
    if String.contains?(path, "/priority/"), do: assert(signals["strategy"] == "priority")

    GenServer.stop(socket)
  end

  defp balance_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "eth_getBalance",
      "params" => ["0x0000000000000000000000000000000000000000", "latest"]
    }
  end
end
