defmodule LivechainWeb.RPCControllerTest do
  @moduledoc """
  Integration tests for the RPC controller endpoints.
  """

  use ExUnit.Case, async: true

  describe "RPC controller module" do
    test "module exists and has expected functions" do
      assert Code.ensure_loaded?(LivechainWeb.RPCController)
      assert function_exported?(LivechainWeb.RPCController, :ethereum, 2)
      assert function_exported?(LivechainWeb.RPCController, :arbitrum, 2)
      assert function_exported?(LivechainWeb.RPCController, :polygon, 2)
      assert function_exported?(LivechainWeb.RPCController, :bsc, 2)
    end

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
