defmodule Lasso.Observability.TelemetryContractTest do
  @moduledoc """
  Verifies telemetry events match the metadata schemas expected by
  Lasso.Telemetry metrics and Lasso.TelemetryLogger handlers.

  Prevents regressions where event names or metadata fields drift
  between emitters and consumers.
  """
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Testing.TelemetrySync

  @moduletag :telemetry_contract

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  describe "circuit breaker :failure event" do
    test "includes required metadata" do
      id = {"default", "telemetry_contract", "cb_failure_test", :http}

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {id, %{failure_threshold: 100, recovery_timeout: 60_000, success_threshold: 2}}
        )

      {:ok, measurements, metadata} =
        TelemetrySync.collect_event(
          [:lasso, :circuit_breaker, :failure],
          fn -> CircuitBreaker.call(id, fn -> raise "boom" end) end,
          timeout: 2_000
        )

      assert Map.has_key?(measurements, :count)
      assert metadata.chain == "telemetry_contract"
      assert metadata.provider_id == "cb_failure_test"
      assert metadata.transport == :http
      assert Map.has_key?(metadata, :error_category)
      assert Map.has_key?(metadata, :circuit_state)
    end
  end

  describe "circuit breaker :open event" do
    test "includes required metadata with reason and error context" do
      id = {"default", "telemetry_contract", "cb_open_test", :http}

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {id, %{failure_threshold: 1, recovery_timeout: 60_000, success_threshold: 2}}
        )

      {:ok, collector} =
        TelemetrySync.attach_collector([:lasso, :circuit_breaker, :open])

      CircuitBreaker.call(id, fn -> raise "boom" end)
      Process.sleep(20)

      {:ok, measurements, metadata} =
        TelemetrySync.await_event(collector, timeout: 2_000)

      assert Map.has_key?(measurements, :count)
      assert metadata.chain == "telemetry_contract"
      assert metadata.provider_id == "cb_open_test"
      assert metadata.transport == :http
      assert metadata.from_state == :closed
      assert metadata.to_state == :open
      assert metadata.reason == :failure_threshold_exceeded
      assert Map.has_key?(metadata, :error_category)
      assert Map.has_key?(metadata, :failure_count)
      assert Map.has_key?(metadata, :recovery_timeout_ms)
    end
  end

  describe "circuit breaker :half_open event" do
    test "via proactive recovery includes required metadata" do
      id = {"default", "telemetry_contract", "cb_half_open_test", :http}

      # Attach collector BEFORE starting the breaker to catch proactive recovery
      {:ok, collector} =
        TelemetrySync.attach_collector([:lasso, :circuit_breaker, :proactive_recovery])

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {id, %{failure_threshold: 1, recovery_timeout: 50, success_threshold: 2}}
        )

      # Trip the breaker - proactive recovery timer fires after ~50ms + jitter
      CircuitBreaker.call(id, fn -> raise "boom" end)
      Process.sleep(20)
      assert CircuitBreaker.get_state(id).state == :open

      {:ok, measurements, metadata} =
        TelemetrySync.await_event(collector, timeout: 2_000)

      assert Map.has_key?(measurements, :count)
      assert metadata.chain == "telemetry_contract"
      assert metadata.provider_id == "cb_half_open_test"
      assert metadata.transport == :http
      assert metadata.from_state == :open
      assert metadata.to_state == :half_open
      assert metadata.reason == :proactive_recovery
    end

    test "via traffic recovery includes required metadata" do
      id = {"default", "telemetry_contract", "cb_half_open_traffic", :http}

      {:ok, pid} =
        CircuitBreaker.start_link(
          {id, %{failure_threshold: 1, recovery_timeout: 5_000, success_threshold: 2}}
        )

      # Trip the breaker with a long recovery timeout so proactive timer doesn't fire
      CircuitBreaker.call(id, fn -> raise "boom" end)
      Process.sleep(20)
      assert CircuitBreaker.get_state(id).state == :open

      :sys.replace_state(pid, fn state ->
        %{state | recovery_deadline_ms: System.monotonic_time(:millisecond) - 1}
      end)

      {:ok, collector} =
        TelemetrySync.attach_collector([:lasso, :circuit_breaker, :half_open])

      CircuitBreaker.call(id, fn -> :ok end)

      {:ok, measurements, metadata} =
        TelemetrySync.await_event(collector, timeout: 2_000)

      assert Map.has_key?(measurements, :count)
      assert metadata.chain == "telemetry_contract"
      assert metadata.provider_id == "cb_half_open_traffic"
      assert metadata.transport == :http
      assert metadata.from_state == :open
      assert metadata.to_state == :half_open
      assert metadata.reason == :attempt_recovery
    end
  end

  describe "circuit breaker :close event" do
    test "includes required metadata" do
      id = {"default", "telemetry_contract", "cb_close_test", :http}

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {id, %{failure_threshold: 1, recovery_timeout: 50, success_threshold: 1}}
        )

      # Trip the breaker
      CircuitBreaker.call(id, fn -> raise "boom" end)
      Process.sleep(20)
      assert CircuitBreaker.get_state(id).state == :open

      # Wait for recovery timeout
      Process.sleep(80)

      {:ok, collector} =
        TelemetrySync.attach_collector([:lasso, :circuit_breaker, :close])

      # Success in half_open → closed
      CircuitBreaker.call(id, fn -> :ok end)
      Process.sleep(20)

      {:ok, measurements, metadata} =
        TelemetrySync.await_event(collector, timeout: 2_000)

      assert Map.has_key?(measurements, :count)
      assert metadata.chain == "telemetry_contract"
      assert metadata.provider_id == "cb_close_test"
      assert metadata.transport == :http
      assert metadata.from_state in [:half_open, :open]
      assert metadata.to_state == :closed
      assert metadata.reason == :recovered
    end
  end

  describe "metrics alignment" do
    test "all Lasso.Telemetry metrics reference events that have defined emitters" do
      known_emitted_events =
        MapSet.new([
          [:lasso, :circuit_breaker, :admit],
          [:lasso, :circuit_breaker, :open],
          [:lasso, :circuit_breaker, :close],
          [:lasso, :circuit_breaker, :half_open],
          [:lasso, :circuit_breaker, :proactive_recovery],
          [:lasso, :circuit_breaker, :failure],
          [:lasso, :circuit_breaker, :timeout],
          [:lasso, :http, :request, :io],
          [:lasso, :ws, :request, :io],
          [:lasso, :rpc, :request, :stop],
          [:lasso, :websocket, :connected],
          [:lasso, :websocket, :disconnected],
          [:lasso, :websocket, :request, :completed],
          [:lasso, :websocket, :pending_cleanup],
          [:lasso, :provider, :status],
          [:lasso, :failover, :fast_fail],
          [:lasso, :failover, :circuit_open],
          [:lasso, :failover, :degraded_mode],
          [:lasso, :failover, :degraded_success],
          [:lasso, :failover, :exhaustion],
          [:lasso, :cluster, :topology, :node_connected],
          [:lasso, :cluster, :topology, :node_disconnected],
          [:lasso, :stream, :dropped_event],
          [:lasso, :upstream_subscriptions, :orphaned_event],
          [:lasso_web, :dashboard, :cache],
          [:lasso_web, :dashboard, :cluster_rpc],
          [:vm, :memory],
          [:vm, :total_run_queue_lengths]
        ])

      metrics = Lasso.Telemetry.metrics()

      for metric <- metrics do
        event_name = metric.event_name

        assert MapSet.member?(known_emitted_events, event_name),
               "Metric #{inspect(metric.name)} references event #{inspect(event_name)} which is not in the known emitter set. " <>
                 "Either add the event to known_emitted_events or fix the metric's event_name."
      end
    end

    test "TelemetryLogger handlers reference events that have defined emitters" do
      known_emitted_events =
        MapSet.new([
          [:lasso, :failover, :fast_fail],
          [:lasso, :failover, :circuit_open],
          [:lasso, :failover, :degraded_mode],
          [:lasso, :failover, :degraded_success],
          [:lasso, :failover, :exhaustion],
          [:lasso, :request, :slow],
          [:lasso, :request, :very_slow],
          [:lasso, :circuit_breaker, :open],
          [:lasso, :circuit_breaker, :close],
          [:lasso, :circuit_breaker, :half_open],
          [:lasso, :circuit_breaker, :proactive_recovery]
        ])

      # TelemetryLogger.attach/0 attaches handlers; verify it doesn't crash
      # (would crash if handler references a non-existent event format)
      Lasso.TelemetryLogger.detach()
      assert :ok = Lasso.TelemetryLogger.attach()

      # Verify the handler IDs are attached (they reference real events)
      expected_handler_ids = [
        "lasso_telemetry_logger_fast_fail",
        "lasso_telemetry_logger_circuit_open",
        "lasso_telemetry_logger_degraded_mode",
        "lasso_telemetry_logger_degraded_success",
        "lasso_telemetry_logger_exhaustion",
        "lasso_telemetry_logger_slow_request",
        "lasso_telemetry_logger_very_slow_request",
        "lasso_telemetry_logger_cb_open",
        "lasso_telemetry_logger_cb_close",
        "lasso_telemetry_logger_cb_half_open",
        "lasso_telemetry_logger_cb_recovery"
      ]

      handlers = :telemetry.list_handlers([])

      attached_ids =
        handlers
        |> Enum.map(& &1.id)
        |> MapSet.new()

      for handler_id <- expected_handler_ids do
        assert MapSet.member?(attached_ids, handler_id),
               "Expected TelemetryLogger handler #{handler_id} to be attached"
      end

      # Verify each handler's event exists in known emitters
      for handler <- handlers,
          handler.id in expected_handler_ids do
        event = Map.get(handler, :event_name, [])

        if event != [] do
          assert MapSet.member?(known_emitted_events, event),
                 "TelemetryLogger handler #{handler.id} references unknown event #{inspect(event)}"
        end
      end

      Lasso.TelemetryLogger.detach()
      Lasso.TelemetryLogger.attach()
    end
  end
end
