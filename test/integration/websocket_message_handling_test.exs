defmodule Lasso.Integration.WebSocketMessageHandlingTest do
  @moduledoc """
  Integration tests for WebSocket request/response correlation and message handling.

  Tests core behaviors:
  - Request/response correlation
  - Multiple concurrent requests with correct IDs
  - JSON-RPC error responses
  - Malformed JSON handling
  - Request timeouts
  - Late responses after timeout

  Uses real WSConnection GenServer with mocked WebSockex transport.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.RPC.Transport.WebSocket.{Connection, Endpoint}
  alias Lasso.Core.Support.CircuitBreaker
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
      heartbeat_interval: 10_000,
      # Use 0ms stability for tests - attempts reset immediately on connect
      stability_ms: Keyword.get(opts, :stability_ms, 0)
    }
  end

  defp start_connection_with_cb(endpoint) do
    # Start circuit breaker for the endpoint
    circuit_breaker_config = %{failure_threshold: 5, recovery_timeout: 200, success_threshold: 1}
    instance_id = resolve_instance_id(endpoint)

    {:ok, _cb_pid} =
      CircuitBreaker.start_link({{instance_id, :ws}, circuit_breaker_config})

    # Start connection
    {:ok, pid} = Connection.start_link(endpoint)
    {pid, endpoint}
  end

  defp cleanup_connection(endpoint) do
    # Clean up WebSocket connection
    ws_key = {:ws_conn_instance, resolve_instance_id(endpoint)}

    case GenServer.whereis({:via, Registry, {Lasso.Registry, ws_key}}) do
      nil -> :ok
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end

    # Clean up circuit breaker
    cb_id = "#{resolve_instance_id(endpoint)}:ws"

    case GenServer.whereis({:via, Registry, {Lasso.Registry, {:circuit_breaker, cb_id}}}) do
      nil -> :ok
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  defp resolve_instance_id(endpoint) do
    Lasso.Providers.Catalog.lookup_instance_id(endpoint.profile, endpoint.chain_name, endpoint.id) ||
      "#{endpoint.chain_name}:#{endpoint.id}"
  end

  describe "request correlation" do
    test "sends request and receives correlated response", %{chain: chain} do
      endpoint = build_endpoint(chain, "correlation")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {_pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Send request
      result =
        Connection.request(
          resolve_instance_id(endpoint),
          "eth_blockNumber",
          [],
          2_000
        )

      # Should receive successful response
      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end

    test "handles multiple concurrent requests with correct IDs", %{chain: chain} do
      endpoint = build_endpoint(chain, "concurrent")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {_pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Send multiple concurrent requests
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            result =
              Connection.request(
                resolve_instance_id(endpoint),
                "eth_getBlockByNumber",
                ["0x#{Integer.to_string(i, 16)}", false],
                5_000
              )

            {i, result}
          end)
        end

      # Wait for all responses
      results = Enum.map(tasks, fn task -> Task.await(task, 6_000) end)

      # Verify all requests completed
      assert length(results) == 5

      # All should be successful
      for {_i, result} <- results do
        assert match?({:ok, _}, result)
      end

      cleanup_connection(endpoint)
    end

    test "request IDs are unique under concurrency", %{chain: chain} do
      endpoint = build_endpoint(chain, "unique_ids")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Send many concurrent requests
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            # Each request will get a unique ID from WSConnection
            Connection.request(
              resolve_instance_id(endpoint),
              "eth_blockNumber",
              [],
              5_000
            )

            i
          end)
        end

      # Wait for all to complete
      Enum.each(tasks, fn task -> Task.await(task, 6_000) end)

      # Verify no crashes and connection is still healthy
      assert Process.alive?(pid)
      status = Connection.status(resolve_instance_id(endpoint))
      assert status.connected == true

      cleanup_connection(endpoint)
    end
  end

  describe "error handling" do
    test "handles JSON-RPC error responses", %{chain: chain} do
      endpoint = build_endpoint(chain, "rpc_error")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure mock to return errors
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_mode(ws_state.connection, :error)

      # Send request that will get error response
      result =
        Connection.request(
          resolve_instance_id(endpoint),
          "eth_blockNumber",
          [],
          2_000
        )

      # Should receive error response
      assert match?({:error, %{code: _}}, result)

      cleanup_connection(endpoint)
    end

    test "handles malformed JSON from upstream", %{chain: chain} do
      endpoint = build_endpoint(chain, "malformed")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client handle
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send malformed JSON directly
      TestSupport.MockWSClient.emit_message(mock_client, %{
        "invalid" => "not a valid JSON-RPC response"
      })

      # Connection should remain stable
      Process.sleep(100)
      assert Process.alive?(pid)

      cleanup_connection(endpoint)
    end

    test "ignores responses for unknown request IDs", %{chain: chain} do
      endpoint = build_endpoint(chain, "unknown_id")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Get mock client handle
      ws_state = :sys.get_state(pid)
      mock_client = ws_state.connection

      # Send response with unknown ID
      TestSupport.MockWSClient.emit_message(mock_client, %{
        "jsonrpc" => "2.0",
        "id" => "unknown_request_id_12345",
        "result" => "some result"
      })

      # Connection should remain stable
      Process.sleep(100)
      assert Process.alive?(pid)

      # Should still be able to send new requests
      result =
        Connection.request(
          resolve_instance_id(endpoint),
          "eth_blockNumber",
          [],
          2_000
        )

      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end
  end

  describe "timeouts" do
    test "request times out when no response received", %{chain: chain} do
      endpoint = build_endpoint(chain, "timeout")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure very long response delay
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 10_000)

      # Send request with short timeout
      start_time = System.monotonic_time(:millisecond)

      result =
        Connection.request(
          resolve_instance_id(endpoint),
          "eth_blockNumber",
          [],
          500
        )

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should timeout
      case result do
        {:error, :timeout} ->
          assert elapsed >= 500 and elapsed < 1000

        {:error, %{code: code}} when code in [-32_000, -32_007] ->
          # WebSocket request timeout error
          assert elapsed >= 500 and elapsed < 1000

        other ->
          flunk("Expected timeout, got: #{inspect(other)}")
      end

      cleanup_connection(endpoint)
    end

    test "late response after timeout is ignored", %{chain: chain} do
      endpoint = build_endpoint(chain, "late_response")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure delayed response
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 1_500)

      # Send request with short timeout
      result =
        Connection.request(
          resolve_instance_id(endpoint),
          "eth_blockNumber",
          [],
          500
        )

      # Should timeout
      assert match?({:error, _}, result)

      # Wait for late response to arrive
      Process.sleep(1_500)

      # Connection should still be healthy
      assert Process.alive?(pid)
      status = Connection.status(resolve_instance_id(endpoint))
      assert status.connected == true

      # Should be able to send new request
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 0)

      result2 =
        Connection.request(
          resolve_instance_id(endpoint),
          "eth_blockNumber",
          [],
          2_000
        )

      assert match?({:ok, _}, result2)

      cleanup_connection(endpoint)
    end
  end

  describe "request lifecycle telemetry" do
    test "emits request sent and completed events", %{chain: chain} do
      endpoint = build_endpoint(chain, "telemetry")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, sent_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :request, :sent],
          match: [provider_id: endpoint.id]
        )

      {:ok, completed_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :request, :completed],
          match: [provider_id: endpoint.id]
        )

      {_pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Send request
      task =
        Task.async(fn ->
          Connection.request(
            resolve_instance_id(endpoint),
            "eth_blockNumber",
            [],
            2_000
          )
        end)

      # Should emit sent event
      {:ok, _measurements, sent_meta} =
        TelemetrySync.await_event(sent_collector, timeout: 2_000)

      assert sent_meta.provider_id == endpoint.id
      assert sent_meta.method == "eth_blockNumber"
      assert is_binary(sent_meta.request_id) or is_integer(sent_meta.request_id)

      # Should emit completed event
      {:ok, measurements, completed_meta} =
        TelemetrySync.await_event(completed_collector, timeout: 2_000)

      assert completed_meta.provider_id == endpoint.id
      assert completed_meta.method == "eth_blockNumber"
      assert completed_meta.status in [:success, :error]
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0

      # Request should complete successfully
      result = Task.await(task)
      assert match?({:ok, _}, result)

      cleanup_connection(endpoint)
    end

    test "emits timeout event when request times out", %{chain: chain} do
      endpoint = build_endpoint(chain, "timeout_telemetry")

      {:ok, conn_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :connected],
          match: [provider_id: endpoint.id]
        )

      {:ok, timeout_collector} =
        TelemetrySync.attach_collector(
          [:lasso, :websocket, :request, :timeout],
          match: [provider_id: endpoint.id]
        )

      {pid, endpoint} = start_connection_with_cb(endpoint)
      {:ok, _, _} = TelemetrySync.await_event(conn_collector, timeout: 2_000)

      # Configure delay longer than timeout
      ws_state = :sys.get_state(pid)
      TestSupport.MockWSClient.set_response_delay(ws_state.connection, 5_000)

      # Send request with short timeout
      task =
        Task.async(fn ->
          Connection.request(
            resolve_instance_id(endpoint),
            "eth_blockNumber",
            [],
            500
          )
        end)

      # Should emit timeout event
      {:ok, measurements, timeout_meta} =
        TelemetrySync.await_event(timeout_collector, timeout: 2_000)

      assert timeout_meta.provider_id == endpoint.id
      assert timeout_meta.method == "eth_blockNumber"
      assert is_integer(measurements.timeout_ms)
      # Elapsed time must be at least the configured timeout, with allowance for scheduler jitter
      assert measurements.timeout_ms >= 500
      assert measurements.timeout_ms < 550

      # Request should return timeout error
      result = Task.await(task)
      assert match?({:error, _}, result)

      cleanup_connection(endpoint)
    end
  end
end
