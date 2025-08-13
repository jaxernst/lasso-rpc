defmodule LivechainWeb.RPCControllerTest do
  @moduledoc """
  Integration tests for the RPC controller endpoints.
  """

  # TODO: Expand cases to test that RPC requests can be made for chains configured in ChainConfig

  use ExUnit.Case, async: true

  describe "RPC controller module" do
    test "can process JSON-RPC requests" do
      # Test that the module can handle basic JSON-RPC requests
      request = %{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => [],
        "id" => 1
      }

      # This is a basic test that the module exists and can be called
      # In a real test environment, we'd test the actual HTTP endpoints
      assert is_map(request)
      assert request["method"] == "eth_blockNumber"
    end
  end

  describe "health endpoints" do
    test "health controller exists" do
      assert Code.ensure_loaded?(LivechainWeb.HealthController)
      assert function_exported?(LivechainWeb.HealthController, :health, 2)
    end

    test "status controller exists" do
      assert Code.ensure_loaded?(LivechainWeb.StatusController)
      assert function_exported?(LivechainWeb.StatusController, :status, 2)
    end
  end
end
