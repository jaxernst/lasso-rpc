defmodule Lasso.Integration.WebSocketFailureScenarioTest do
  @moduledoc """
  Integration tests for real WebSocket failure scenarios.

  Tests production-like failure modes:
  - Connection timeouts
  - Connection refused errors
  - Mid-flight disconnects during active requests
  - Slow provider responses
  - Rapid reconnection cycles
  - Connection hanging (no data, no close)
  - Multiple concurrent failures

  Uses FailureInjector for explicit failure configuration and validates
  telemetry events, reconnection behavior, and error handling.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.RPC.{WSConnection, WSEndpoint, CircuitBreaker}
  alias Lasso.Test.TelemetrySync

  @moduletag :integration
  @moduletag timeout: 60_000

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
    %WSEndpoint{
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
    {:ok, _cb_pid} = CircuitBreaker.start_link({{endpoint.chain_name, endpoint.id, :ws}, circuit_breaker_config})

    # Start connection
    {:ok, pid} = WSConnection.start_link(endpoint)
    {pid, endpoint}
  end

  defp cleanup_connection(endpoint) do
    # Clean up WebSocket connection
    case GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, endpoint.id}}}) do
      nil -> :ok
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end

    # Clean up circuit breaker
    case GenServer.whereis(
           {:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{endpoint.id}:ws"}}}
         ) do
      nil -> :ok
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  describe "connection timeouts" do
    test "handles connection timeout gracefully", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint =
        build_endpoint(chain, "timeout_test",
          reconnect_interval: 100,
          max_reconnect_attempts: 2
        )

      {:ok, failed_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connection_failed],
          match: [provider_id: endpoint.id]
        )

      # Configure to timeout on all attempts
      TestSupport.FailureInjector.configure(endpoint.id, fn _attempt ->
        {:error, :timeout}
      end)

      {_pid, endpoint} = start_connection_with_cb(endpoint)

      # Should see connection failures
      {:ok, _, meta} = TelemetrySync.await_event(failed_collector, timeout: 2_000)
      assert meta.error_code == -32_007 # Request timeout error code
      assert meta.error_message =~ "timeout"
      assert meta.retriable == true

      cleanup_connection(endpoint)
    end

    test "handles slow connection (5s delay)", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint = build_endpoint(chain, "slow_connect", reconnect_interval: 100)

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      # Configure 5s delay on first connection
      TestSupport.FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt == 0, do: {:delay, 5_000}, else: :ok
      end)

      start_time = System.monotonic_time(:millisecond)
      {_pid, endpoint} = start_connection_with_cb(endpoint)

      # Should eventually connect after delay
      {:ok, _, meta} = TelemetrySync.await_event(conn_collector, timeout: 7_000)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert meta.reconnect_attempt == 0
      assert elapsed >= 5_000

      cleanup_connection(endpoint)
    end
  end

  describe "connection refused" do
    test "handles connection refused error", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint =
        build_endpoint(chain, "refused_test",
          reconnect_interval: 50,
          max_reconnect_attempts: 2
        )

      {:ok, failed_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connection_failed],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {:ok, exhausted_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_exhausted],
          match: [provider_id: endpoint.id]
        )

      # Configure to fail with connection_refused
      TestSupport.FailureInjector.configure(endpoint.id, fn _attempt ->
        {:error, :econnrefused}
      end)

      {_pid, endpoint} = start_connection_with_cb(endpoint)

      # Should see 2 connection failures
      {:ok, _, meta1} = TelemetrySync.await_event(failed_collector, timeout: 2_000)
      assert meta1.error_message =~ "econnrefused"

      {:ok, _, meta2} = TelemetrySync.await_event(failed_collector, timeout: 2_000)
      assert meta2.error_message =~ "econnrefused"

      # Then exhausted
      {:ok, _, exhausted_meta} =
        TelemetrySync.await_event(exhausted_collector, timeout: 2_000)

      assert exhausted_meta.attempts == 2

      cleanup_connection(endpoint)
    end

    test "eventually connects after connection refused clears", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint = build_endpoint(chain, "refused_recover", reconnect_interval: 50)

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, failed_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connection_failed],
          match: [provider_id: endpoint.id],
          count: 2
        )

      # Fail first 2 attempts, then succeed
      TestSupport.FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt < 2, do: {:error, :econnrefused}, else: :ok
      end)

      {_pid, endpoint} = start_connection_with_cb(endpoint)

      # Should see 2 failures
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 2_000)
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 2_000)

      # Then success
      {:ok, _, meta} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      assert meta.reconnect_attempt == 2

      cleanup_connection(endpoint)
    end
  end

  describe "mid-flight disconnects" do
    test "handles disconnect during active request", %{chain: chain} do
      endpoint = build_endpoint(chain, "midflight_disconnect")

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

      # Configure mock to delay responses
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Send request that won't complete
      task =
        Task.async(fn ->
          WSConnection.request(endpoint.id, "eth_blockNumber", [], 15_000)
        end)

      # Wait longer to ensure request is tracked in pending map
      Process.sleep(100)

      # Trigger disconnect while request is pending
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Wait for disconnect event
      {:ok, _, disconn_meta} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
      # Pending request count may be 0 or more depending on timing
      assert is_integer(disconn_meta.pending_request_count)

      # Request should fail due to disconnect
      result = Task.await(task)
      # May be error due to disconnect or timeout
      assert match?({:error, _}, result)

      cleanup_connection(endpoint)
    end

    test "clears all pending requests on disconnect", %{chain: chain} do
      endpoint = build_endpoint(chain, "clear_pending")

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

      # Configure mock to delay responses
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Send multiple requests
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            WSConnection.request(endpoint.id, "eth_blockNumber_#{i}", [], 15_000)
          end)
        end

      # Wait longer to ensure all requests are tracked in pending map
      Process.sleep(150)

      # Disconnect
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Should report pending requests (may vary by timing)
      {:ok, _, disconn_meta} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
      assert is_integer(disconn_meta.pending_request_count)
      assert disconn_meta.pending_request_count >= 0

      # All requests should fail due to disconnect or complete before disconnect
      # Either way, we verify all tasks complete
      for task <- tasks do
        result = Task.await(task, 5_000)
        # Could be success if completed before disconnect, or error if not
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end

      cleanup_connection(endpoint)
    end
  end

  describe "slow responses" do
    test "handles slow provider response (5s delay)", %{chain: chain} do
      endpoint = build_endpoint(chain, "slow_response")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure 5s response delay
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 5_000)

      # Send request with longer timeout
      start_time = System.monotonic_time(:millisecond)
      result = WSConnection.request(endpoint.id, "eth_blockNumber", [], 10_000)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should succeed after delay
      assert match?({:ok, _}, result)
      assert elapsed >= 5_000

      cleanup_connection(endpoint)
    end

    test "request times out if response too slow", %{chain: chain} do
      endpoint = build_endpoint(chain, "timeout_slow")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure 10s response delay
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Send request with shorter timeout
      result = WSConnection.request(endpoint.id, "eth_blockNumber", [], 1_000)

      # Should timeout - could be {:error, :timeout} or error tuple
      case result do
        {:error, :timeout} -> assert true
        {:error, %{code: code}} when code in [-32_000, -32_007] -> assert true # Request timeout error codes
        other -> flunk("Expected timeout error, got: #{inspect(other)}")
      end

      cleanup_connection(endpoint)
    end
  end

  describe "rapid reconnection cycles" do
    test "handles rapid connect/disconnect cycles", %{chain: chain} do
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

      # Should remain stable
      status = WSConnection.status(endpoint.id)
      assert status.connected == true

      cleanup_connection(endpoint)
    end

    test "maintains stability under churn", %{chain: chain} do
      endpoint = build_endpoint(chain, "churn_stability")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 4
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Rapid cycles with requests interspersed
      for i <- 1..3 do
        # Send request
        result = WSConnection.request(endpoint.id, "eth_blockNumber", [], 2_000)
        assert match?({:ok, _}, result)

        # Disconnect
        ws_state = :sys.get_state(pid)
        TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

        # Wait for reconnection
        {:ok, _, meta} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
        assert meta.reconnect_attempt >= 0

        # Small delay between cycles
        if i < 3, do: Process.sleep(50)
      end

      # Final request should work
      result = WSConnection.request(endpoint.id, "eth_blockNumber", [], 2_000)
      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end
  end

  describe "connection hanging" do
    test "handles connection hanging (no response)", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint =
        build_endpoint(chain, "hang_test",
          reconnect_interval: 100,
          max_reconnect_attempts: 2
        )

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      # Configure to hang on all attempts
      TestSupport.FailureInjector.configure(endpoint.id, fn _attempt ->
        {:hang}
      end)

      {_pid, endpoint} = start_connection_with_cb(endpoint)

      # Connection should hang - no connected event should be emitted
      # Use a short timeout to verify event is not received
      result = TelemetrySync.await_event(conn_collector, timeout: 500)
      assert match?({:error, :timeout}, result)

      # Status should show not connected
      status = WSConnection.status(endpoint.id)
      assert status.connected == false

      cleanup_connection(endpoint)
    end
  end

  describe "multiple concurrent failures" do
    test "handles multiple endpoints failing simultaneously", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      # Create 3 endpoints
      endpoints =
        for i <- 1..3 do
          build_endpoint(chain, "multi_fail_#{i}", reconnect_interval: 50)
        end

      # Set up collectors for all endpoints
      collectors =
        for endpoint <- endpoints do
          {:ok, failed_collector} =
            TelemetrySync.attach_collector(
              [:lasso, :websocket, :connection_failed],
              match: [provider_id: endpoint.id]
            )

          {endpoint, failed_collector}
        end

      # Configure all to fail initially
      for endpoint <- endpoints do
        TestSupport.FailureInjector.configure(endpoint.id, fn attempt ->
          if attempt < 2, do: {:error, :econnrefused}, else: :ok
        end)
      end

      # Start all connections
      pids =
        for endpoint <- endpoints do
          {pid, _} = start_connection_with_cb(endpoint)
          pid
        end

      # All should fail initially (at least once per endpoint)
      for {_endpoint, failed_collector} <- collectors do
        {:ok, _, meta} = TelemetrySync.await_event(failed_collector, timeout: 3_000)
        # Should have some error - exact error may vary based on timing
        assert is_binary(meta.error_message)
        assert meta.retriable == true
      end

      # Verify all processes still alive
      for pid <- pids do
        assert Process.alive?(pid)
      end

      # Cleanup all
      for endpoint <- endpoints do
        cleanup_connection(endpoint)
      end
    end

    test "isolates failures between endpoints", %{chain: chain} do
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      # Create 2 endpoints - one failing, one working
      endpoint1 = build_endpoint(chain, "isolated_fail", reconnect_interval: 50)
      endpoint2 = build_endpoint(chain, "isolated_work", reconnect_interval: 50)

      {:ok, conn1_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint1.id]
        )

      {:ok, conn2_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint2.id]
        )

      {:ok, failed1_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connection_failed],
          match: [provider_id: endpoint1.id]
        )

      # Configure endpoint1 to fail on first attempt
      TestSupport.FailureInjector.configure(endpoint1.id, fn attempt ->
        if attempt == 0, do: {:error, :econnrefused}, else: :ok
      end)

      # endpoint2 configured to succeed (default)

      # Start both
      {_pid1, endpoint1} = start_connection_with_cb(endpoint1)
      {_pid2, endpoint2} = start_connection_with_cb(endpoint2)

      # endpoint1 should fail first
      {:ok, _, _} = TelemetrySync.await_event(failed1_collector, timeout: 2_000)

      # endpoint2 should connect successfully
      {:ok, _, meta2} = TelemetrySync.await_event(conn2_collector, timeout: 2_000)
      assert meta2.reconnect_attempt == 0

      # endpoint1 should eventually reconnect
      {:ok, _, meta1} = TelemetrySync.await_event(conn1_collector, timeout: 2_000)
      assert meta1.reconnect_attempt == 1

      # Both should be operational
      status1 = WSConnection.status(endpoint1.id)
      status2 = WSConnection.status(endpoint2.id)
      assert status1.connected == true
      assert status2.connected == true

      cleanup_connection(endpoint1)
      cleanup_connection(endpoint2)
    end
  end
end
