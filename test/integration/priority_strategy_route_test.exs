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

  test "the WebSocket priority route connects and routes to the first configured provider", %{
    chain: chain
  } do
    port = @endpoint.config(:http)[:port]

    assert {:ok, socket} =
             Client.start_link("ws://127.0.0.1:#{port}/ws/rpc/priority/#{chain}", Socket, self())

    Client.cast(socket, {:send, Map.put(balance_request(7), "lasso_meta", "notify")})

    assert_receive {:frame, %{"id" => 7, "result" => _}}, 5_000

    assert_receive {:frame,
                    %{
                      "method" => "lasso_meta",
                      "params" => %{
                        "strategy" => "priority",
                        "selected_provider" => %{"id" => "primary"}
                      }
                    }},
                   5_000
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
