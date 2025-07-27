defmodule LivechainWeb.HealthControllerTest do
  @moduledoc """
  Tests for the HealthController API endpoint.
  """

  use ExUnit.Case, async: true

  describe "HealthController" do
    test "health endpoint returns expected structure" do
      # TODO: Implement actual HTTP test when endpoint is properly configured
      # For now, test that the module exists and has the expected function
      assert Code.ensure_loaded?(LivechainWeb.HealthController)
      assert function_exported?(LivechainWeb.HealthController, :health, 2)
    end
  end
end
