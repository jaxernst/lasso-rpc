defmodule Lasso.Integration.WebSocketLifecycleTest do
  @moduledoc """
  Integration tests for WebSocket connection lifecycle.

  Tests core behaviors:
  - Connection establishment
  - Disconnection handling (graceful and unexpected)
  - Status reporting
  - Process cleanup

  Uses real WSConnection GenServer with mocked WebSockex transport.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.RPC.{WSConnection, WSEndpoint, CircuitBreaker}
  alias Lasso.Test.TelemetrySync

  @moduletag :integration
  @moduletag timeout: 10_000

  setup do
    # Configure test to use MockWSClient
    Application.put_env(:lasso, :ws_client_module, TestSupport.MockWSClient)

    on_exit(fn ->
      Application.delete_env(:lasso, :ws_client_module)
    end)

    :ok
  end

  # Helper to build test endpoint
  defp build_endpoint(chain, id_suffix) do
    %WSEndpoint{
      id: "ws_#{chain}_#{id_suffix}",
      name: "Test WebSocket #{id_suffix}",
      ws_url: "ws://test.local/ws",
      chain_name: chain,
      chain_id: 1,
      reconnect_interval: 100,
      max_reconnect_attempts: 3,
      heartbeat_interval: 5_000
    }
  end

  defp start_connection_with_cb(endpoint) do
    # Start circuit breaker for the endpoint
    circuit_breaker_config = %{failure_threshold: 3, recovery_timeout: 200, success_threshold: 1}
    {:ok, _cb_pid} = CircuitBreaker.start_link({{endpoint.chain_name, endpoint.id, :ws}, circuit_breaker_config})

    # Start connection
    {:ok, pid} = WSConnection.start_link(endpoint)
    {pid, endpoint}
  end

  defp cleanup_connection(endpoint) do
    # Clean up WebSocket connection
    case GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, endpoint.id}}}) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
    end

    # Clean up circuit breaker
    case GenServer.whereis(
           {:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{endpoint.id}:ws"}}}
         ) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  describe "connection initialization" do
    test "connects to WebSocket provider on start", %{chain: chain} do
      endpoint = build_endpoint(chain, "init")

      # Attach telemetry collector BEFORE starting connection
      conn_collector =
        TelemetrySync.start_collector(
          [:lasso, :websocket, :connected],
          match: %{provider_id: endpoint.id}
        )

      # Subscribe to PubSub for verification
      Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain}")

      {pid, endpoint} = start_connection_with_cb(endpoint)

      # Wait for telemetry event (event-driven)
      {:ok, measurements, metadata} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Verify telemetry data
      assert measurements == %{}
      assert metadata.provider_id == endpoint.id
      assert metadata.chain == chain
      assert metadata.reconnect_attempt == 0

      # Verify PubSub event also fired (backward compatibility)
      assert_receive {:ws_connected, provider_id}, 100
      assert provider_id == endpoint.id

      # Verify status
      status = WSConnection.status(endpoint.id)
      assert status.connected == true
      assert status.reconnect_attempts == 0
      assert status.endpoint_id == endpoint.id

      cleanup_connection(endpoint)
    end

    test "reports correct initial status after connection", %{chain: chain} do
      endpoint = build_endpoint(chain, "status")

      conn_collector =
        TelemetrySync.start_collector(
          [:lasso, :websocket, :connected],
          match: %{provider_id: endpoint.id}
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Check detailed status
      status = WSConnection.status(endpoint.id)

      assert status.connected == true
      assert status.endpoint_id == endpoint.id
      assert status.reconnect_attempts == 0

      cleanup_connection(endpoint)
    end

    test "registers in Registry with correct name", %{chain: chain} do
      endpoint = build_endpoint(chain, "registry")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Verify registry entry
      registry_pid =
        GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, endpoint.id}}})

      assert registry_pid == pid

      cleanup_connection(endpoint)
    end
  end

  describe "disconnection handling" do
    test "handles graceful WebSocket close (1000)", %{chain: chain} do
      endpoint = build_endpoint(chain, "graceful")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      disconn_collector =
        TelemetrySync.start_collector(
          [:lasso, :websocket, :disconnected],
          match: %{provider_id: endpoint.id}
        )

      Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain}")

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client handle
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Trigger graceful close
      TestSupport.MockWSClient.close(mock_client, 1000, "normal close")

      # Wait for disconnect telemetry
      {:ok, measurements, metadata} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      assert measurements == %{}
      assert metadata.provider_id == endpoint.id
      assert metadata.reason == "normal close"
      assert metadata.unexpected == false

      # Verify PubSub event
      endpoint_id = endpoint.id
      assert_receive {:ws_closed, ^endpoint_id, 1000, _jerr}, 100

      # Verify status
      status = WSConnection.status(endpoint.id)
      assert status.connected == false

      cleanup_connection(endpoint)
    end

    test "handles unexpected disconnect (connection_lost)", %{chain: chain} do
      endpoint = build_endpoint(chain, "unexpected")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      disconn_collector =
        TelemetrySync.start_collector(
          [:lasso, :websocket, :disconnected],
          match: %{provider_id: endpoint.id}
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Simulate unexpected disconnect
      TestSupport.MockWSClient.disconnect(mock_client, :connection_lost)

      # Wait for disconnect telemetry
      {:ok, _measurements, metadata} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      assert metadata.provider_id == endpoint.id
      assert metadata.reason == :connection_lost
      assert metadata.unexpected == true

      cleanup_connection(endpoint)
    end

    test "handles WebSocket process crash", %{chain: chain} do
      endpoint = build_endpoint(chain, "crash")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      disconn_collector = TelemetrySync.start_collector([:lasso, :websocket, :reconnect_scheduled])

      # Start with circuit breaker
      circuit_breaker_config = %{failure_threshold: 3, recovery_timeout: 200, success_threshold: 1}
      {:ok, cb_pid} = CircuitBreaker.start_link({{endpoint.chain_name, endpoint.id, :ws}, circuit_breaker_config})

      # Start connection
      {:ok, pid} = WSConnection.start_link(endpoint)

      # Unlink from both processes to prevent EXIT signal propagation during crash test
      # We still want to test crash handling, but not have the test process crash
      Process.unlink(pid)
      Process.unlink(cb_pid)

      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Monitor the mock client to detect when it crashes
      ref = Process.monitor(mock_client)

      # Kill the mock client from outside using Process.exit/2
      # This is safer than calling exit/1 from within the process
      # and avoids propagating EXIT signals through linked processes
      Process.exit(mock_client, :simulated_crash)

      # Wait for the DOWN message
      assert_receive {:DOWN, ^ref, :process, ^mock_client, :simulated_crash}, 1_000

      # Verify the mock client is indeed dead
      refute Process.alive?(mock_client)

      # Verify WSConnection handles the crash by scheduling reconnection
      {:ok, _, metadata} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
      assert metadata.provider_id == endpoint.id
      assert metadata.attempt == 1

      # Verify the WSConnection process is still alive and handling the crash gracefully
      assert Process.alive?(pid)

      # Verify connection is marked as disconnected
      status = WSConnection.status(endpoint.id)
      assert status.connected == false

      cleanup_connection(endpoint)
    end
  end

  describe "status reporting" do
    test "status reflects connected state accurately", %{chain: chain} do
      endpoint = build_endpoint(chain, "status_conn")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      status = WSConnection.status(endpoint.id)

      assert status.connected == true
      assert status.endpoint_id == endpoint.id
      assert status.reconnect_attempts == 0

      cleanup_connection(endpoint)
    end

    test "status reflects disconnected state with error", %{chain: chain} do
      endpoint = build_endpoint(chain, "status_disconn")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      disconn_collector = TelemetrySync.start_collector([:lasso, :websocket, :disconnected])

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :test_disconnect)

      {:ok, _, _} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      status = WSConnection.status(endpoint.id)
      assert status.connected == false

      cleanup_connection(endpoint)
    end

    test "status includes reconnect attempt count", %{chain: chain} do
      endpoint = build_endpoint(chain, "status_attempts")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])
      sched_collector = TelemetrySync.start_collector([:lasso, :websocket, :reconnect_scheduled])

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Trigger disconnect to start reconnection
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :test)

      # Wait for reconnect scheduled
      {:ok, _, meta} = TelemetrySync.await_event(sched_collector, timeout: 2_000)

      # Check status shows attempt count
      status = WSConnection.status(endpoint.id)
      assert status.reconnect_attempts >= 1

      cleanup_connection(endpoint)
    end
  end

  describe "process lifecycle" do
    test "cleans up on manual stop", %{chain: chain} do
      endpoint = build_endpoint(chain, "cleanup")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])

      Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain}")

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Stop connection
      GenServer.stop(pid, :normal)

      # Verify process is gone
      refute Process.alive?(pid)

      # Verify registry entry is removed
      Process.sleep(50)

      registry_pid =
        GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, endpoint.id}}})

      assert registry_pid == nil

      cleanup_connection(endpoint)
    end

    test "broadcasts terminated status on stop", %{chain: chain} do
      endpoint = build_endpoint(chain, "terminated")

      conn_collector = TelemetrySync.start_collector([:lasso, :websocket, :connected])

      Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain}")

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Stop process
      GenServer.stop(pid, :normal)

      # Should receive disconnection notification
      endpoint_id = endpoint.id
      assert_receive {:ws_disconnected, ^endpoint_id, _jerr}, 200

      # Status should fail since process is gone
      Process.sleep(50)

      assert catch_exit(WSConnection.status(endpoint.id))

      cleanup_connection(endpoint)
    end
  end
end
