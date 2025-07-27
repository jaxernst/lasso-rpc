defmodule LivechainWeb.StatusControllerTest do
  @moduledoc """
  Tests for the StatusController API endpoint.
  """

  use LivechainWeb.ConnCase, async: true

  describe "GET /api/status" do
    test "returns detailed system status", %{conn: conn} do
      conn = get(conn, ~p"/api/status")
      
      assert json_response(conn, 200)
      response = json_response(conn, 200)
      
      # Check system section
      assert is_map(response["system"])
      system = response["system"]
      assert system["status"] == "operational"
      assert is_binary(system["timestamp"])
      assert is_integer(system["uptime"])
      assert is_map(system["memory_usage"])
      assert is_integer(system["process_count"])
      
      # Check connections section
      assert is_map(response["connections"])
      connections = response["connections"]
      assert is_integer(connections["total"])
      assert is_integer(connections["active"])
      assert is_list(connections["details"])
    end

    test "includes all required status fields", %{conn: conn} do
      conn = get(conn, ~p"/api/status")
      response = json_response(conn, 200)
      
      # Top-level fields
      assert Map.has_key?(response, "system")
      assert Map.has_key?(response, "connections")
      
      # System fields
      system = response["system"]
      system_fields = ["status", "timestamp", "uptime", "memory_usage", "process_count"]
      Enum.each(system_fields, fn field ->
        assert Map.has_key?(system, field), "Missing system field: #{field}"
      end)
      
      # Connection fields
      connections = response["connections"]
      connection_fields = ["total", "active", "details"]
      Enum.each(connection_fields, fn field ->
        assert Map.has_key?(connections, field), "Missing connections field: #{field}"
      end)
    end
  end
end