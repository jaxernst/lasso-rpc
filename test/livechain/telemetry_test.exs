defmodule Livechain.TelemetryTest do
  @moduledoc """
  Tests for the Livechain.Telemetry module.
  """

  use ExUnit.Case, async: true

  alias Livechain.Telemetry

  describe "telemetry event emission" do
    test "emit_rpc_call/4 executes without error" do
      assert :ok = Telemetry.emit_rpc_call("test_provider", "eth_blockNumber", 150, :ok)
    end

    test "emit_message_aggregation/4 executes without error" do
      assert :ok = Telemetry.emit_message_aggregation("ethereum", "block", 75, :success)
    end

    test "emit_provider_health_change/3 executes without error" do
      assert :ok = Telemetry.emit_provider_health_change("test_provider", :healthy, :unhealthy)
    end

    test "emit_circuit_breaker_change/3 executes without error" do
      assert :ok = Telemetry.emit_circuit_breaker_change("test_provider", :closed, :open)
    end

    test "emit_websocket_lifecycle/3 executes without error" do
      assert :ok =
               Telemetry.emit_websocket_lifecycle("conn_123", :connected, %{chain: "ethereum"})
    end

    test "emit_cache_operation/4 executes without error" do
      assert :ok = Telemetry.emit_cache_operation("ethereum", :hit, 1000, 5)
    end

    test "emit_failover/4 executes without error" do
      assert :ok = Telemetry.emit_failover("ethereum", "provider1", "provider2", :timeout)
    end

    test "emit_error/3 executes without error" do
      assert :ok = Telemetry.emit_error(:rpc, "connection_failed", %{provider_id: "test"})
    end

    test "emit_performance_metric/3 executes without error" do
      assert :ok = Telemetry.emit_performance_metric(:latency, 150, %{chain: "ethereum"})
    end
  end

  describe "telemetry handlers" do
    test "attach_default_handlers/0 succeeds" do
      # Detach first in case they're already attached
      Telemetry.detach_handlers()

      assert :ok = Telemetry.attach_default_handlers()

      # Clean up
      Telemetry.detach_handlers()
    end

    test "detach_handlers/0 succeeds" do
      # Attach first to have something to detach
      Telemetry.attach_default_handlers()

      assert :ok = Telemetry.detach_handlers()
    end
  end
end
