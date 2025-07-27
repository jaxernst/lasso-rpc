defmodule LivechainWeb.StatusControllerTest do
  @moduledoc """
  Tests for the StatusController API endpoint.
  """

  use ExUnit.Case, async: true

  describe "StatusController" do
    test "status endpoint returns expected structure" do
      # TODO: Implement actual HTTP test when endpoint is properly configured
      # For now, test that the module exists and has the expected function
      assert Code.ensure_loaded?(LivechainWeb.StatusController)
      assert function_exported?(LivechainWeb.StatusController, :status, 2)
    end
  end
end
