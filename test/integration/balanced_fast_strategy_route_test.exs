defmodule LassoWeb.BalancedFastStrategyRouteTest do
  use Lasso.Test.LassoIntegrationCase

  import Phoenix.ConnTest
  import Plug.Conn

  alias Lasso.RPC.Transport.WebSocket.Client

  @endpoint LassoWeb.Endpoint

  defmodule Socket do
    def handle_connect(_connection, owner), do: {:ok, owner}
    def handle_cast({:send, payload}, owner), do: {:reply, {:text, Jason.encode!(payload)}, owner}
    def handle_cast(:close, owner), do: {:close, owner}
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
      %{id: "first", behavior: :healthy},
      %{id: "second", behavior: :healthy}
    ])

    :ok
  end

  test "balanced-fast and its latency-weighted alias route the same strategy over HTTP", %{
    chain: chain
  } do
    for strategy <- ["balanced-fast", "latency-weighted"],
        path <- ["/rpc/#{strategy}/#{chain}", "/rpc/profile/public/#{strategy}/#{chain}"] do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(path <> "?include_meta=body", Jason.encode!(balance_request(1)))
        |> json_response(200)

      assert %{"id" => 1, "result" => _} = response
      assert response["lasso_meta"]["strategy"] == "balanced_fast"
    end
  end

  test "balanced-fast and its latency-weighted alias route the same strategy over WebSocket", %{
    chain: chain
  } do
    port = @endpoint.config(:http)[:port]

    for path <- [
          "/ws/rpc/balanced-fast/#{chain}",
          "/ws/rpc/latency-weighted/#{chain}",
          "/ws/rpc/#{chain}?strategy=latency_weighted"
        ] do
      assert {:ok, socket} = Client.start_link("ws://127.0.0.1:#{port}#{path}", Socket, self())
      Client.cast(socket, {:send, Map.put(balance_request(3), "lasso_meta", "notify")})

      assert_receive {:frame, %{"id" => 3, "result" => _}}, 5_000

      assert_receive {:frame,
                      %{"method" => "lasso_meta", "params" => %{"strategy" => "balanced_fast"}}},
                     5_000

      Client.cast(socket, :close)
    end
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
