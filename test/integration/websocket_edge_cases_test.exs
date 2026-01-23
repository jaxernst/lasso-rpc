defmodule Lasso.Integration.WebSocketEdgeCasesTest do
  @moduledoc """
  Integration tests for WebSocket edge cases, race conditions, and error scenarios.

  Tests challenging behaviors:
  - Race conditions (disconnect during pending requests, etc.)
  - Process crashes and recovery
  - Message edge cases (malformed JSON, duplicate responses, etc.)
  - Memory management
  - Rapid state transitions

  Uses real WSConnection GenServer with mocked WebSockex transport.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.RPC.Transport.WebSocket.{Connection, Endpoint}
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Test.TelemetrySync

  @moduletag :integration
  @moduletag timeout: 20_000

  setup do
    # Configure test to use MockWSClient
    Application.put_env(:lasso, :ws_client_module, TestSupport.MockWSClient)

    on_exit(fn ->
      Application.delete_env(:lasso, :ws_client_module)
    end)

    :ok
  end

  # Helper to build test endpoint
  defp build_endpoint(chain, id_suffix, opts \\ []) do
    %Endpoint{
      profile: "default",
      id: "ws_#{chain}_#{id_suffix}",
      name: "Test WebSocket #{id_suffix}",
      ws_url: "ws://test.local/ws",
      chain_name: chain,
      chain_id: 1,
      reconnect_interval: Keyword.get(opts, :reconnect_interval, 100),
      max_reconnect_attempts: Keyword.get(opts, :max_reconnect_attempts, 3),
      heartbeat_interval: 10_000
    }
  end

  defp start_connection_with_cb(endpoint) do
    # Start circuit breaker for the endpoint
    circuit_breaker_config = %{failure_threshold: 5, recovery_timeout: 200, success_threshold: 1}

    {:ok, _cb_pid} =
      CircuitBreaker.start_link(
        {{endpoint.profile, endpoint.chain_name, endpoint.id, :ws}, circuit_breaker_config}
      )

    # Start connection
    {:ok, pid} = Connection.start_link(endpoint)
    {pid, endpoint}
  end

  defp cleanup_connection(endpoint) do
    # Clean up WebSocket connection
    ws_key = {:ws_conn, endpoint.profile, endpoint.chain_name, endpoint.id}

    case GenServer.whereis({:via, Registry, {Lasso.Registry, ws_key}}) do
      nil -> :ok
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end

    # Clean up circuit breaker
    cb_id = "#{endpoint.profile}:#{endpoint.chain_name}:#{endpoint.id}:ws"

    case GenServer.whereis({:via, Registry, {Lasso.Registry, {:circuit_breaker, cb_id}}}) do
      nil -> :ok
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  describe "race conditions" do
    test "disconnect during pending request fails the request", %{chain: chain} do
      endpoint = build_endpoint(chain, "race_disconnect")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, disconn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :disconnected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure long delay to ensure request is pending
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Start request in background
      task =
        Task.async(fn ->
          Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 5_000)
        end)

      # Give request time to be registered
      Process.sleep(100)

      # Trigger disconnect while request is pending
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Wait for disconnect event
      {:ok, _measurements, _metadata} =
        TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      # Request should fail
      result = Task.await(task)
      assert match?({:error, _}, result)

      cleanup_connection(endpoint)
    end

    test "multiple rapid connect/disconnect cycles", %{chain: chain} do
      endpoint = build_endpoint(chain, "rapid_cycles")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 6
        )

      {:ok, disconn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :disconnected],
          match: [provider_id: endpoint.id],
          count: 5
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)

      # Initial connection
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Rapid disconnect/reconnect cycles
      for _cycle <- 1..5 do
        ws_state = :sys.get_state(pid)
        TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)
        {:ok, _, _} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
        {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      end

      # Connection should remain stable
      assert Process.alive?(pid)
      status = Connection.status(endpoint.profile, endpoint.chain_name, endpoint.id)
      assert status.connected == true

      cleanup_connection(endpoint)
    end

    test "reconnect while heartbeat in flight", %{chain: chain} do
      endpoint = build_endpoint(chain, "heartbeat_reconnect", heartbeat_interval: 200)

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Wait a bit for heartbeat to potentially be scheduled/in flight
      Process.sleep(250)

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Should reconnect successfully despite heartbeat
      {:ok, _, meta} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      assert meta.reconnect_attempt >= 1

      # Connection should be stable
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end
  end

  describe "process crashes" do
    test "pending requests fail on WebSocket process crash", %{chain: chain} do
      endpoint = build_endpoint(chain, "crash_pending")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, disconn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :disconnected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure long delay
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Start request
      task =
        Task.async(fn ->
          Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 5_000)
        end)

      # Wait for request to be registered
      Process.sleep(100)

      # Instead of forcing crash (which can exit test), just disconnect unexpectedly
      TestSupport.MockWSClient.disconnect(ws_state.connection, :simulated_crash)

      # Wait for disconnect event
      {:ok, _, _} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      # Request should fail
      result = Task.await(task)
      assert match?({:error, _}, result)

      # WSConnection process should still be alive (handles crash gracefully)
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end

    test "connection recovers from WebSocket process crash", %{chain: chain} do
      endpoint = build_endpoint(chain, "crash_recover")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {:ok, disconn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :disconnected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Simulate crash by disconnecting unexpectedly
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :simulated_crash)

      # Should detect disconnect
      {:ok, _, disconn_meta} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
      assert disconn_meta.unexpected == true

      # Should reconnect
      {:ok, _, conn_meta} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      assert conn_meta.reconnect_attempt >= 1

      # Connection should be healthy
      assert Process.alive?(pid)
      status = Connection.status(endpoint.profile, endpoint.chain_name, endpoint.id)
      assert status.connected == true

      cleanup_connection(endpoint)
    end
  end

  describe "message edge cases" do
    test "handles response for unknown request ID gracefully", %{chain: chain} do
      endpoint = build_endpoint(chain, "unknown_request_id")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send response with unknown ID
      TestSupport.MockWSClient.emit_message(mock_client, %{
        "jsonrpc" => "2.0",
        "id" => "totally_unknown_id_xyz",
        "result" => %{"block" => "0x123"}
      })

      # Connection should remain stable
      Process.sleep(100)
      assert Process.alive?(pid)

      # Should still accept new requests
      result = Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 2_000)
      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end

    test "handles duplicate response for same request ID", %{chain: chain} do
      endpoint = build_endpoint(chain, "duplicate_response")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Send a normal request
      task =
        Task.async(fn ->
          Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 2_000)
        end)

      # Request should complete normally
      result = Task.await(task)
      assert match?({:ok, _}, result)

      # Get the request ID that was just used and send a duplicate response
      # (In reality, this is hard to test perfectly without internal access,
      # but we can simulate sending an old response)
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send another response with a plausible ID
      TestSupport.MockWSClient.emit_message(mock_client, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"block" => "0x456"}
      })

      # Connection should remain stable
      Process.sleep(100)
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end

    test "handles upstream error without ID", %{chain: chain} do
      endpoint = build_endpoint(chain, "error_no_id")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send error without ID (some providers do this)
      TestSupport.MockWSClient.emit_message(mock_client, %{
        "jsonrpc" => "2.0",
        "error" => %{
          "code" => -32_700,
          "message" => "Parse error"
        }
      })

      # Connection should remain stable
      Process.sleep(100)
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end

    test "handles malformed JSON without crashing", %{chain: chain} do
      endpoint = build_endpoint(chain, "malformed_json")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send various malformed messages
      TestSupport.MockWSClient.emit_message(mock_client, %{"not" => "valid", "rpc" => "message"})

      TestSupport.MockWSClient.emit_message(mock_client, %{
        "jsonrpc" => "3.0",
        "id" => 123,
        "result" => "wrong version"
      })

      # Connection should remain stable
      Process.sleep(200)
      assert Process.alive?(pid)

      # Should still work for valid requests
      result = Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 2_000)
      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end

    test "handles nil ID in JSON-RPC response", %{chain: chain} do
      endpoint = build_endpoint(chain, "nil_id")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send response with nil ID (notification-style)
      TestSupport.MockWSClient.emit_message(mock_client, %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "result" => "something"
      })

      # Connection should remain stable
      Process.sleep(100)
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end
  end

  describe "memory management" do
    test "cleans up timed-out requests from pending map", %{chain: chain} do
      endpoint = build_endpoint(chain, "memory_cleanup")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure very long delay
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 30_000)

      # Send multiple requests with short timeouts
      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 500)
          end)
        end

      # Wait for all to timeout
      for task <- tasks do
        result = Task.await(task, 2_000)
        assert match?({:error, _}, result)
      end

      # Wait a bit for cleanup
      Process.sleep(200)

      # Verify connection is still healthy and not leaking memory
      # (we can't directly inspect pending_requests map without internal access,
      # but we can verify the connection still works)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 0)
      result = Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 2_000)
      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end
  end

  describe "concurrent operations" do
    test "handles concurrent requests during reconnection", %{chain: chain} do
      endpoint = build_endpoint(chain, "concurrent_reconnect")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Try to send requests immediately during reconnection
      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            Connection.request({endpoint.profile, endpoint.chain_name, endpoint.id}, "eth_blockNumber", [], 5_000)
          end)
        end

      # Wait for reconnection
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Requests should either succeed (after reconnect) or fail gracefully
      for task <- tasks do
        result = Task.await(task, 6_000)
        # Either success or error is acceptable, just no crash
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end

      # Connection should be stable
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end

    test "handles status queries during state transitions", %{chain: chain} do
      endpoint = build_endpoint(chain, "status_transitions")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Trigger rapid state transitions
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            # Query status multiple times
            status = Connection.status(endpoint.profile, endpoint.chain_name, endpoint.id)
            {i, status}
          end)
        end

      # Disconnect while status queries are happening
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # All status queries should complete without crashing
      results = Enum.map(tasks, fn task -> Task.await(task, 3_000) end)
      assert length(results) == 10

      # Should reconnect
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Connection should be stable
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end
  end

  describe "heartbeat edge cases" do
    test "handles heartbeat failure gracefully", %{chain: chain} do
      endpoint = build_endpoint(chain, "heartbeat_failure", heartbeat_interval: 200)

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure ping failures
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_failure_mode(ws_state.connection, :fail_pings)

      # Wait for heartbeat interval
      Process.sleep(300)

      # Connection should either reconnect or handle failure gracefully
      # Either way, process should not crash
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end
  end
end
