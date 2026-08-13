defmodule LassoWeb.RPCControllerTest do
  @moduledoc """
  Integration tests for the RPC controller endpoints.
  """

  # TODO: Expand cases to test that RPC requests can be made for chains configured in ChainConfig

  use ExUnit.Case, async: true

  # Deleted meaningless test that only validates test data

  describe "health endpoints" do
    test "health controller exists" do
      assert Code.ensure_loaded?(LassoWeb.HealthController)
      assert function_exported?(LassoWeb.HealthController, :health, 2)
    end

    # StatusController was removed - status endpoint functionality moved elsewhere
  end
end

defmodule LassoWeb.RPCControllerWireContractTest do
  use Lasso.Test.LassoIntegrationCase

  import Phoenix.ConnTest

  @endpoint LassoWeb.Endpoint

  describe "JSON-RPC wire contract" do
    test "provider exhaustion returns an HTTP 200 JSON-RPC error with the client ID", %{
      chain: chain
    } do
      setup_providers([
        %{id: "unavailable", priority: 10, behavior: :healthy, profile: "public"}
      ])

      instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "unavailable")
      Lasso.Test.CircuitBreakerHelper.force_open({instance_id, :http})

      request = %{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => [],
        "id" => "client-request-42"
      }

      conn = post(build_conn(), "/rpc/#{chain}", request)

      assert conn.status == 200

      body = json_response(conn, 200)

      assert Map.keys(body) |> Enum.sort() == ["error", "id", "jsonrpc"]
      assert Map.keys(body["error"]) |> Enum.sort() == ["code", "data", "message"]
      assert Map.keys(body["error"]["data"]) == ["retry_after_ms"]

      assert %{
               "jsonrpc" => "2.0",
               "id" => "client-request-42",
               "error" => %{
                 "code" => -32_000,
                 "message" => message,
                 "data" => %{"retry_after_ms" => retry_after_ms}
               }
             } = body

      assert is_integer(retry_after_ms) and retry_after_ms > 0

      assert message ==
               "No available channels for method: eth_blockNumber. All circuits open, " <>
                 "retry after #{div(retry_after_ms, 1_000)}s"
    end
  end
end
