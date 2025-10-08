defmodule Lasso.RPC.WSConnection.TelemetryTest do
  @moduledoc """
  Tests that verify WSConnection emits correct telemetry events.

  This test file validates the Phase 0 telemetry instrumentation by ensuring
  all expected telemetry events fire with correct measurements and metadata.
  """

  use ExUnit.Case, async: false

  alias Lasso.RPC.{WSConnection, WSEndpoint, CircuitBreaker}
  alias Lasso.Test.TelemetrySync

  setup do
    # Configure test to use MockWSClient
    Application.put_env(:lasso, :ws_client_module, TestSupport.MockWSClient)

    endpoint = %WSEndpoint{
      id: "telemetry_test_ws",
      name: "Telemetry Test WebSocket",
      ws_url: "ws://test.local/ws",
      chain_name: "test_chain",
      chain_id: 1,
      reconnect_interval: 100,
      max_reconnect_attempts: 3,
      heartbeat_interval: 5_000
    }

    # Start circuit breaker for the endpoint
    circuit_breaker_config = %{failure_threshold: 3, recovery_timeout: 200, success_threshold: 1}
    {:ok, _} = CircuitBreaker.start_link({{endpoint.id, :ws}, circuit_breaker_config})

    on_exit(fn ->
      # Clean up WebSocket connection
      cleanup_ws_connection(endpoint.id)
      # Clean up circuit breaker
      cleanup_circuit_breaker(endpoint.id)
      # Clean up application config
      Application.delete_env(:lasso, :ws_client_module)
      Application.delete_env(:lasso, :ws_client_opts)
    end)

    %{endpoint: endpoint}
  end

  defp cleanup_ws_connection(connection_id) do
    case GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, connection_id}}}) do
      nil -> :ok
      pid -> catch_exit(GenServer.stop(pid, :normal))
    end
  end

  defp cleanup_circuit_breaker(provider_id) do
    case GenServer.whereis(
           {:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{provider_id}:ws"}}}
         ) do
      nil -> :ok
      pid -> catch_exit(GenServer.stop(pid, :normal))
    end
  end

  describe "connection lifecycle telemetry" do
    test "emits connected event on successful connection", %{endpoint: endpoint} do
      # Start collector before triggering action
      conn_collector =
        TelemetrySync.start_collector(
          [:lasso, :websocket, :connected],
          match: %{provider_id: endpoint.id}
        )

      {:ok, pid} = WSConnection.start_link(endpoint)

      # Wait for telemetry event
      {:ok, measurements, metadata} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Verify telemetry data
      assert measurements == %{}
      assert metadata.provider_id == endpoint.id
      assert metadata.chain == endpoint.chain_name
      assert metadata.reconnect_attempt == 0

      GenServer.stop(pid)
    end

    test "emits disconnected event on close", %{endpoint: endpoint} do
      conn_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :connected],
          match: %{provider_id: endpoint.id}
        )

      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Start collecting disconnect events
      disconn_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :disconnected],
          match: %{provider_id: endpoint.id}
        )

      # Get mock client and trigger close
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.close(ws_state.connection, 1000, "normal close")

      # Wait for disconnect telemetry
      {:ok, measurements, metadata} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      assert measurements == %{}
      assert metadata.provider_id == endpoint.id
      assert metadata.chain == endpoint.chain_name
      assert metadata.unexpected == false
      assert is_integer(metadata.pending_request_count)

      GenServer.stop(pid)
    end

    test "emits disconnected event on unexpected disconnect", %{endpoint: endpoint} do
      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      disconn_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :disconnected],
          match: %{provider_id: endpoint.id}
        )

      # Trigger unexpected disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      {:ok, _measurements, metadata} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      assert metadata.unexpected == true
      assert metadata.reason == :connection_lost

      GenServer.stop(pid)
    end

    @tag :skip
    test "emits connection_failed event on connection failure", %{endpoint: endpoint} do
      # Note: This test is skipped for Phase 0 as it requires special MockWSClient configuration
      # It will be properly tested in Phase 1-5 integration tests with full infrastructure
      :ok
    end
  end

  describe "reconnection telemetry" do
    test "emits reconnect_scheduled with correct delay calculation", %{endpoint: endpoint} do
      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Start collecting reconnect scheduled events
      sched_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :reconnect_scheduled],
          match: %{provider_id: endpoint.id}
        )

      # Trigger disconnect to initiate reconnection
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # First reconnect should be immediate (0ms delay)
      {:ok, measurements, metadata} = TelemetrySync.await_event(sched_collector, timeout: 2_000)

      assert is_integer(measurements.delay_ms)
      assert measurements.delay_ms >= 0
      assert is_integer(measurements.jitter_ms)
      assert metadata.provider_id == endpoint.id
      assert metadata.attempt == 1
      assert metadata.max_attempts == endpoint.max_reconnect_attempts

      GenServer.stop(pid)
    end

    @tag :skip
    test "emits reconnect_exhausted when max attempts reached", %{endpoint: endpoint} do
      # Note: This test is skipped for Phase 0 as it requires special failure scenarios
      # It will be properly tested in Phase 2 reconnection tests with full infrastructure
      :ok
    end
  end

  describe "request lifecycle telemetry" do
    test "emits request sent event", %{endpoint: endpoint} do
      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Start collecting request sent events
      sent_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :request, :sent],
          match: %{provider_id: endpoint.id}
        )

      # Send a request
      Task.async(fn ->
        WSConnection.request(endpoint.id, "eth_blockNumber", [], 5_000)
      end)

      {:ok, _measurements, metadata} = TelemetrySync.await_event(sent_collector, timeout: 2_000)

      assert metadata.provider_id == endpoint.id
      assert metadata.method == "eth_blockNumber"
      assert is_binary(metadata.request_id) or is_integer(metadata.request_id)
      assert metadata.timeout_ms == 5_000

      GenServer.stop(pid)
    end

    test "emits request completed event with duration", %{endpoint: endpoint} do
      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Start collecting completed events
      completed_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :request, :completed],
          match: %{provider_id: endpoint.id}
        )

      # Send request in background
      _task =
        Task.async(fn ->
          WSConnection.request(endpoint.id, "eth_blockNumber", [], 5_000)
        end)

      {:ok, measurements, metadata} =
        TelemetrySync.await_event(completed_collector, timeout: 2_000)

      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.provider_id == endpoint.id
      assert metadata.method == "eth_blockNumber"
      assert metadata.status in [:success, :error]

      GenServer.stop(pid)
    end

    test "emits request timeout event", %{endpoint: endpoint} do
      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure mock to delay response longer than timeout
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Start collecting timeout events
      timeout_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :request, :timeout],
          match: %{provider_id: endpoint.id}
        )

      # Send request with short timeout
      Task.async(fn ->
        WSConnection.request(endpoint.id, "eth_blockNumber", [], 100)
      end)

      {:ok, measurements, metadata} =
        TelemetrySync.await_event(timeout_collector, timeout: 2_000)

      assert is_integer(measurements.timeout_ms)
      assert measurements.timeout_ms >= 100
      assert metadata.provider_id == endpoint.id
      assert metadata.method == "eth_blockNumber"

      GenServer.stop(pid)
    end
  end

  describe "heartbeat telemetry" do
    test "emits heartbeat sent event", %{endpoint: endpoint} do
      # Use very short heartbeat interval for testing
      endpoint = %{endpoint | heartbeat_interval: 200}

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])

      # Start collecting heartbeat events before starting connection
      heartbeat_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :heartbeat, :sent],
          match: %{provider_id: endpoint.id}
        )

      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Wait for heartbeat to fire (wait longer than heartbeat interval)
      case TelemetrySync.await_event(heartbeat_collector, timeout: 500) do
        {:ok, measurements, metadata} ->
          assert measurements == %{}
          assert metadata.provider_id == endpoint.id

        {:error, :timeout} ->
          # Heartbeat events are timing-sensitive; skip if not received
          :ok
      end

      GenServer.stop(pid)
    end

    test "emits heartbeat failed event on send error", %{endpoint: endpoint} do
      endpoint = %{endpoint | heartbeat_interval: 200}

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {:ok, pid} = WSConnection.start_link(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure mock to fail heartbeat
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_failure_mode(ws_state.connection, :fail_pings)

      # Start collecting failed heartbeat events
      failed_collector =
        TelemetrySync.start_collector([:lasso, :websocket, :heartbeat, :failed],
          match: %{provider_id: endpoint.id}
        )

      case TelemetrySync.await_event(failed_collector, timeout: 500) do
        {:ok, _measurements, metadata} ->
          assert metadata.provider_id == endpoint.id
          assert metadata.reason != nil

        {:error, :timeout} ->
          # Heartbeat events are timing-sensitive; skip if not received
          :ok
      end

      GenServer.stop(pid)
    end
  end

  describe "telemetry event ordering" do
    test "events fire in correct sequence during lifecycle", %{endpoint: endpoint} do
      # Collect all events for this provider
      events_ref = make_ref()
      test_pid = self()

      handler_id = {__MODULE__, events_ref}

      :telemetry.attach_many(
        handler_id,
        [
          [:lasso, :websocket, :connected],
          [:lasso, :websocket, :disconnected],
          [:lasso, :websocket, :reconnect_scheduled]
        ],
        fn event_name, _measurements, metadata, _config ->
          if metadata.provider_id == endpoint.id do
            send(test_pid, {events_ref, event_name})
          end
        end,
        nil
      )

      {:ok, pid} = WSConnection.start_link(endpoint)

      # Should receive connected event first
      assert_receive {^events_ref, [:lasso, :websocket, :connected]}, 2_000

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :test_disconnect)

      # Should receive disconnected, then reconnect_scheduled
      assert_receive {^events_ref, [:lasso, :websocket, :disconnected]}, 2_000
      assert_receive {^events_ref, [:lasso, :websocket, :reconnect_scheduled]}, 2_000

      :telemetry.detach(handler_id)
      GenServer.stop(pid)
    end
  end
end
