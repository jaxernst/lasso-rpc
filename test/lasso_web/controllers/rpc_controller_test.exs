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
