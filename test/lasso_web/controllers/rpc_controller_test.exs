defmodule LassoWeb.RPCControllerTest do
  @moduledoc """
  Integration tests for the RPC controller endpoints.
  """

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
    test "empty batch returns Invalid Request", %{chain: chain} do
      setup_providers([%{id: "batch-local", behavior: :healthy, profile: "public"}])
      conn = post_json("/rpc/#{chain}", [])

      assert conn.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600, "message" => "Invalid Request"}
             } = json_response(conn, 200)
    end

    test "notification-only batch executes without a response body", %{chain: chain} do
      setup_providers([%{id: "batch-local", behavior: :healthy, profile: "public"}])

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_chainId",
        "params" => []
      }

      conn = post_json("/rpc/#{chain}", [notification, notification])

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "single notification executes without a response body", %{chain: chain} do
      setup_providers([%{id: "single-notification", behavior: :healthy, profile: "public"}])

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => []
      }

      conn = post_json("/rpc/#{chain}", notification)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "single explicit null ID receives a response", %{chain: chain} do
      setup_providers([%{id: "single-null", behavior: :healthy, profile: "public"}])

      request = %{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => [],
        "id" => nil
      }

      conn = post_json("/rpc/#{chain}", request)

      assert conn.status == 200
      assert %{"jsonrpc" => "2.0", "id" => nil, "result" => result} = json_response(conn, 200)
      assert is_binary(result)
    end

    test "missing IDs are omitted while an explicit null ID receives a response", %{chain: chain} do
      setup_providers([%{id: "batch-local", behavior: :healthy, profile: "public"}])

      batch = [
        %{"jsonrpc" => "2.0", "method" => "eth_chainId", "params" => []},
        %{"jsonrpc" => "2.0", "method" => "eth_chainId", "params" => [], "id" => nil}
      ]

      conn = post_json("/rpc/#{chain}", batch)

      assert conn.status == 200
      assert [%{"jsonrpc" => "2.0", "id" => nil, "result" => result}] = json_response(conn, 200)
      assert is_binary(result)
    end

    test "forwarded notification and explicit null ID remain distinct", %{chain: chain} do
      setup_providers([%{id: "batch-forwarded", behavior: :healthy, profile: "public"}])

      batch = [
        %{"jsonrpc" => "2.0", "method" => "eth_blockNumber", "params" => []},
        %{"jsonrpc" => "2.0", "method" => "eth_blockNumber", "params" => [], "id" => nil}
      ]

      conn = post_json("/rpc/#{chain}", batch)

      assert conn.status == 200
      assert [%{"jsonrpc" => "2.0", "id" => nil, "result" => result}] = json_response(conn, 200)
      assert is_binary(result)
    end

    test "invalid batch members receive null-ID errors", %{chain: chain} do
      setup_providers([%{id: "batch-local", behavior: :healthy, profile: "public"}])
      conn = post_json("/rpc/#{chain}", [%{}, 42])

      assert conn.status == 200

      assert [
               %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600}},
               %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600}}
             ] = json_response(conn, 200)
    end

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

  defp post_json(path, body) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
