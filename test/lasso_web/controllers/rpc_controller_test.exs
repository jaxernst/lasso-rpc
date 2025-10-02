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

    test "status controller exists" do
      assert Code.ensure_loaded?(LassoWeb.StatusController)
      assert function_exported?(LassoWeb.StatusController, :status, 2)
    end
  end
end
