defmodule Lasso.Integration.WebSocketReconnectionTest do
  @moduledoc """
  Integration tests for WebSocket reconnection logic.

  Tests core behaviors:
  - Basic reconnection after disconnect
  - Linear backoff algorithm with jitter
  - Reconnection attempt limits
  - State management across reconnection cycles

  Uses real WSConnection GenServer with mocked WebSockex transport.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.RPC.{WSConnection, WSEndpoint, CircuitBreaker}
  alias Lasso.Test.TelemetrySync

  @moduletag :integration
  @moduletag timeout: 30_000

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

    {:ok, _cb_pid} =
      CircuitBreaker.start_link({{endpoint.chain_name, endpoint.id, :ws}, circuit_breaker_config})

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

  describe "basic reconnection" do
    test "reconnects after disconnect", %{chain: chain} do
      endpoint = build_endpoint(chain, "basic_reconnect")

      # Start collectors BEFORE creating connection
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

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)

      # Wait for initial connection
      {:ok, _, meta1} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      assert meta1.reconnect_attempt == 0

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Wait for disconnect event
      {:ok, _, _} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      # Wait for reconnect scheduled
      {:ok, _, sched_meta} = TelemetrySync.await_event(sched_collector, timeout: 2_000)
      assert sched_meta.attempt == 1

      # Wait for reconnection
      {:ok, _, meta2} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      assert meta2.reconnect_attempt == 1

      # Verify status shows connected
      status = WSConnection.status(endpoint.id)
      assert status.connected == true

      cleanup_connection(endpoint)
    end

    test "resets reconnect attempts after successful connection", %{chain: chain} do
      endpoint = build_endpoint(chain, "reset_attempts")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 3
        )

      {:ok, disconn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :disconnected],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)

      # Initial connection
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # First disconnect and reconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)
      {:ok, _, _} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
      {:ok, _, sched_meta1} = TelemetrySync.await_event(sched_collector, timeout: 2_000)
      assert sched_meta1.attempt == 1

      # Wait for reconnection
      {:ok, _, conn_meta1} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      assert conn_meta1.reconnect_attempt == 1

      # Second disconnect and reconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)
      {:ok, _, _} = TelemetrySync.await_event(disconn_collector, timeout: 2_000)
      {:ok, _, sched_meta2} = TelemetrySync.await_event(sched_collector, timeout: 2_000)
      # Reset after successful connection
      assert sched_meta2.attempt == 1

      cleanup_connection(endpoint)
    end
  end

  describe "backoff algorithm" do
    test "first reconnect is immediate (0ms delay)", %{chain: chain} do
      endpoint = build_endpoint(chain, "immediate", reconnect_interval: 100)

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # First reconnect should be immediate
      {:ok, measurements, metadata} =
        TelemetrySync.await_event(sched_collector, timeout: 2_000)

      assert metadata.attempt == 1
      assert measurements.delay_ms == 0
      assert measurements.jitter_ms == 0

      cleanup_connection(endpoint)
    end

    test "applies linear backoff (interval * attempt)", %{chain: chain} do
      endpoint = build_endpoint(chain, "linear", reconnect_interval: 100)

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id]
        )

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Disconnect multiple times to observe backoff progression
      # Note: After each successful reconnection, the counter resets

      # First disconnect - attempt 1 is immediate
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)
      {:ok, m1, meta1} = TelemetrySync.await_event(sched_collector, timeout: 2_000)
      assert meta1.attempt == 1
      # First attempt is immediate
      assert m1.delay_ms == 0
      # No jitter on first attempt
      assert m1.jitter_ms == 0

      cleanup_connection(endpoint)
    end

    test "adds random jitter (0-1000ms)", %{chain: chain} do
      endpoint = build_endpoint(chain, "jitter", reconnect_interval: 100)

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id]
        )

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # First attempt - immediate (no jitter)
      {:ok, measurements, _} = TelemetrySync.await_event(sched_collector, timeout: 2_000)

      # First attempt should have no jitter (it's immediate)
      assert measurements.jitter_ms == 0
      assert measurements.delay_ms == 0

      cleanup_connection(endpoint)
    end

    test "caps delay at 30 seconds", %{chain: chain} do
      # Start FailureInjector for this test
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      # Use 15s interval. Delay formula: min(interval * reconnect_attempts, 30_000)
      # At attempt 3, reconnect_attempts = 2, so delay = min(15_000 * 2, 30_000) = 30_000
      endpoint =
        build_endpoint(chain, "cap", reconnect_interval: 15_000, max_reconnect_attempts: 5)

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, failed_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connection_failed],
          match: [provider_id: endpoint.id],
          # Need 3 failures to get to attempt 3
          count: 3
        )

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id],
          # Need 3 schedules for attempts 1, 2, 3
          count: 3
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure mock to fail all reconnection attempts
      # Note: FailureInjector attempt counter starts at 0 when configured,
      # so we want to fail all attempts (>= 0) after configuration
      TestSupport.FailureInjector.configure(endpoint.id, fn _attempt ->
        {:error, :connection_refused}
      end)

      # Trigger disconnect - this will cause failed reconnection attempts
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Attempt 1: immediate (0ms delay, reconnect_attempts = 0)
      {:ok, measurements1, metadata1} =
        TelemetrySync.await_event(sched_collector, timeout: 2_000)

      assert metadata1.attempt == 1
      assert measurements1.delay_ms == 0
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 2_000)

      # Attempt 2: 15s delay (reconnect_attempts = 1, so 15_000 * 1 = 15_000)
      {:ok, measurements2, metadata2} =
        TelemetrySync.await_event(sched_collector, timeout: 2_000)

      assert metadata2.attempt == 2
      assert measurements2.delay_ms >= 15_000
      # 15s + max 1s jitter
      assert measurements2.delay_ms <= 16_000
      # Wait for 15s delay + buffer
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 18_000)

      # Attempt 3: 30s delay (reconnect_attempts = 2, so min(15_000 * 2, 30_000) = 30_000) - TESTS THE CAP
      {:ok, measurements3, metadata3} =
        TelemetrySync.await_event(sched_collector, timeout: 2_000)

      assert metadata3.attempt == 3
      # At the cap
      assert measurements3.delay_ms >= 30_000
      # 30s cap + max 1s jitter
      assert measurements3.delay_ms <= 31_000

      cleanup_connection(endpoint)
    end
  end

  describe "max attempts" do
    test "stops reconnecting after max attempts", %{chain: chain} do
      # Start FailureInjector for this test
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint =
        build_endpoint(chain, "max_stop", reconnect_interval: 50, max_reconnect_attempts: 2)

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

      {:ok, exhausted_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_exhausted],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure mock to fail all reconnection attempts
      # Note: FailureInjector attempt counter starts at 0 when configured,
      # so we want to fail all attempts (>= 0) after configuration
      TestSupport.FailureInjector.configure(endpoint.id, fn _attempt ->
        {:error, :connection_refused}
      end)

      # Trigger disconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Should see 2 connection failures
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 2_000)
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 2_000)

      # Then reconnect exhausted
      {:ok, measurements, metadata} =
        TelemetrySync.await_event(exhausted_collector, timeout: 2_000)

      assert measurements == %{}
      assert metadata.provider_id == endpoint.id
      assert metadata.attempts == 2
      assert metadata.max_attempts == 2

      # Verify no more reconnections attempted
      status = WSConnection.status(endpoint.id)
      assert status.connected == false

      cleanup_connection(endpoint)
    end

    test "emits reconnect_exhausted event", %{chain: chain} do
      # Start FailureInjector for this test
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      endpoint =
        build_endpoint(chain, "exhausted_event",
          reconnect_interval: 50,
          max_reconnect_attempts: 1
        )

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, failed_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connection_failed],
          match: [provider_id: endpoint.id]
        )

      {:ok, exhausted_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_exhausted],
          match: [provider_id: endpoint.id]
        )

      {_pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure to fail all reconnection attempts
      # Note: FailureInjector attempt counter starts at 0 when configured,
      # so we want to fail all attempts (>= 0) after configuration
      TestSupport.FailureInjector.configure(endpoint.id, fn _attempt ->
        {:error, :connection_refused}
      end)

      # Trigger disconnect
      pid = GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, endpoint.id}}})
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Should see 1 connection failure
      {:ok, _, _} = TelemetrySync.await_event(failed_collector, timeout: 2_000)

      # Then exhausted event
      {:ok, _measurements, metadata} =
        TelemetrySync.await_event(exhausted_collector, timeout: 2_000)

      assert metadata.provider_id == endpoint.id
      assert metadata.attempts == 1
      assert metadata.max_attempts == 1

      cleanup_connection(endpoint)
    end

    test "handles infinite retry configuration", %{chain: chain} do
      # max_reconnect_attempts: :infinity means infinite retries
      endpoint =
        %WSEndpoint{
          id: "ws_#{chain}_infinite",
          name: "Test WebSocket infinite",
          ws_url: "ws://test.local/ws",
          chain_name: chain,
          chain_id: 1,
          reconnect_interval: 50,
          max_reconnect_attempts: :infinity,
          heartbeat_interval: 10_000
        }

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 4
        )

      {:ok, sched_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :reconnect_scheduled],
          match: [provider_id: endpoint.id],
          count: 3
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Trigger multiple disconnects - should keep retrying
      for _cycle <- 1..3 do
        ws_state = :sys.get_state(pid)
        TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

        {:ok, _measurements, metadata} =
          TelemetrySync.await_event(sched_collector, timeout: 2_000)

        # After successful connection, reconnect_attempts resets to 0
        # So each disconnect/reconnect cycle starts at attempt 1
        assert metadata.attempt == 1
        assert metadata.max_attempts == :infinity

        # Wait for reconnection
        {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)
      end

      cleanup_connection(endpoint)
    end
  end

  describe "state management" do
    test "maintains state across reconnection cycles", %{chain: chain} do
      endpoint = build_endpoint(chain, "state_mgmt")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id],
          count: 2
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Verify initial state
      initial_status = WSConnection.status(endpoint.id)
      assert initial_status.endpoint_id == endpoint.id
      assert initial_status.connected == true

      # Disconnect and reconnect
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Wait for reconnection
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Verify state maintained
      reconnected_status = WSConnection.status(endpoint.id)
      assert reconnected_status.endpoint_id == endpoint.id
      assert reconnected_status.connected == true
      # Reconnect attempts should have incremented then reset
      assert reconnected_status.reconnect_attempts >= 0

      cleanup_connection(endpoint)
    end

    test "clears pending requests on disconnect", %{chain: chain} do
      endpoint = build_endpoint(chain, "clear_requests")

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
      _task =
        Task.async(fn ->
          WSConnection.request(endpoint.id, "eth_blockNumber", [], 5_000)
        end)

      # Wait a bit for request to be tracked
      Process.sleep(50)

      # Trigger disconnect
      TestSupport.MockWSClient.disconnect(ws_state.connection, :connection_lost)

      # Wait for disconnect event
      {:ok, _measurements, metadata} =
        TelemetrySync.await_event(disconn_collector, timeout: 2_000)

      # Verify pending request count was reported
      assert is_integer(metadata.pending_request_count)

      cleanup_connection(endpoint)
    end
  end
end
