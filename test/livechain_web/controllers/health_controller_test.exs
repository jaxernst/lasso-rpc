defmodule LivechainWeb.HealthControllerTest do
  @moduledoc """
  Tests for the HealthController API endpoint.
  """

  use LivechainWeb.ConnCase, async: true

  describe "GET /api/health" do
    test "returns health status", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      
      assert json_response(conn, 200)
      response = json_response(conn, 200)
      
      assert response["status"] == "healthy"
      assert is_binary(response["timestamp"])
      assert is_integer(response["uptime"])
      assert is_binary(response["version"])
    end

    test "includes required health check fields", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      response = json_response(conn, 200)
      
      required_fields = ["status", "timestamp", "uptime", "version"]
      
      Enum.each(required_fields, fn field ->
        assert Map.has_key?(response, field), "Missing required field: #{field}"
      end)
    end
  end
end