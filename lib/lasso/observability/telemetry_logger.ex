defmodule Lasso.TelemetryLogger do
  @moduledoc """
  Attaches telemetry handlers that log important operational events.

  This module bridges telemetry events to structured logs for production debugging.
  Events are logged at appropriate levels based on severity:

  - :info  - Normal operational events (circuit state changes, degraded mode recovery)
  - :warning - Events requiring attention (slow requests, failovers, degraded mode entry)
  - :error - Critical events (channel exhaustion, very slow requests)

  ## Configuration

      config :lasso, Lasso.TelemetryLogger,
        enabled: true,
        log_slow_requests: true,
        log_failovers: true,
        log_circuit_breaker: true

  ## Events Logged

  - `[:lasso, :failover, :fast_fail]` - Provider failover triggered
  - `[:lasso, :failover, :circuit_open]` - Circuit breaker blocked request
  - `[:lasso, :failover, :degraded_mode]` - Entered degraded mode (trying half-open circuits)
  - `[:lasso, :failover, :degraded_success]` - Recovered via degraded mode
  - `[:lasso, :failover, :exhaustion]` - All providers exhausted
  - `[:lasso, :request, :slow]` - Request took >2000ms
  - `[:lasso, :request, :very_slow]` - Request took >4000ms
  - `[:lasso, :circuit_breaker, :open]` - Circuit breaker opened
  - `[:lasso, :circuit_breaker, :close]` - Circuit breaker closed (recovered)
  - `[:lasso, :circuit_breaker, :half_open]` - Circuit breaker half-open transition
  - `[:lasso, :circuit_breaker, :proactive_recovery]` - Circuit breaker proactive recovery attempt
  """

  require Logger

  @handler_id_prefix "lasso_telemetry_logger"

  @doc """
  Attaches all telemetry handlers. Call this during application startup.
  """
  def attach do
    if enabled?() do
      handlers = build_handlers()

      Enum.each(handlers, fn {event, handler_id, handler_fn, config_key} ->
        if Keyword.get(config(), config_key, true) do
          :telemetry.attach(handler_id, event, handler_fn, nil)
        end
      end)

      Logger.debug("TelemetryLogger attached #{length(handlers)} handlers")
    end

    :ok
  end

  @doc """
  Detaches all telemetry handlers. Useful for testing.
  """
  def detach do
    handlers = build_handlers()

    Enum.each(handlers, fn {_event, handler_id, _handler_fn, _config_key} ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  defp build_handlers do
    [
      # Failover events
      {[:lasso, :failover, :fast_fail], "#{@handler_id_prefix}_fast_fail",
       &__MODULE__.handle_fast_fail/4, :log_failovers},
      {[:lasso, :failover, :circuit_open], "#{@handler_id_prefix}_circuit_open",
       &__MODULE__.handle_circuit_open/4, :log_failovers},
      {[:lasso, :failover, :degraded_mode], "#{@handler_id_prefix}_degraded_mode",
       &__MODULE__.handle_degraded_mode/4, :log_failovers},
      {[:lasso, :failover, :degraded_success], "#{@handler_id_prefix}_degraded_success",
       &__MODULE__.handle_degraded_success/4, :log_failovers},
      {[:lasso, :failover, :exhaustion], "#{@handler_id_prefix}_exhaustion",
       &__MODULE__.handle_exhaustion/4, :log_failovers},

      # Slow request events
      {[:lasso, :request, :slow], "#{@handler_id_prefix}_slow_request",
       &__MODULE__.handle_slow_request/4, :log_slow_requests},
      {[:lasso, :request, :very_slow], "#{@handler_id_prefix}_very_slow_request",
       &__MODULE__.handle_very_slow_request/4, :log_slow_requests},

      # Circuit breaker events
      {[:lasso, :circuit_breaker, :open], "#{@handler_id_prefix}_cb_open",
       &__MODULE__.handle_cb_open/4, :log_circuit_breaker},
      {[:lasso, :circuit_breaker, :close], "#{@handler_id_prefix}_cb_close",
       &__MODULE__.handle_cb_close/4, :log_circuit_breaker},
      {[:lasso, :circuit_breaker, :half_open], "#{@handler_id_prefix}_cb_half_open",
       &__MODULE__.handle_cb_half_open/4, :log_circuit_breaker},
      {[:lasso, :circuit_breaker, :proactive_recovery], "#{@handler_id_prefix}_cb_recovery",
       &__MODULE__.handle_cb_recovery/4, :log_circuit_breaker}
    ]
  end

  # Failover handlers
  # These are public because they're callbacks for :telemetry.attach/4

  def handle_fast_fail(_event, _measurements, metadata, _config) do
    Logger.warning(
      "Failover: #{metadata.method} #{metadata.provider_id}:#{metadata.transport} -> #{metadata.error_category}",
      chain: metadata.chain,
      request_id: metadata.request_id
    )
  end

  def handle_circuit_open(_event, _measurements, metadata, _config) do
    Logger.warning("Circuit open: skipping #{metadata.provider_id}:#{metadata.transport}",
      chain: metadata.chain
    )
  end

  def handle_degraded_mode(_event, _measurements, metadata, _config) do
    Logger.warning("Degraded mode: #{metadata.method} trying half-open circuits",
      chain: metadata.chain
    )
  end

  def handle_degraded_success(_event, _measurements, metadata, _config) do
    Logger.info(
      "Degraded recovery: #{metadata.method} via #{metadata.provider_id}:#{metadata.transport}",
      chain: metadata.chain
    )
  end

  def handle_exhaustion(_event, _measurements, metadata, _config) do
    Logger.error(
      "Exhausted: #{metadata.method} all providers failed (retry_after: #{metadata.retry_after_ms}ms)",
      chain: metadata.chain
    )
  end

  # Slow request handlers

  def handle_slow_request(_event, measurements, metadata, _config) do
    Logger.warning(
      "Slow (>2s): #{metadata.method} #{metadata.provider}:#{metadata.transport} #{round(measurements.latency_ms)}ms",
      chain: metadata.chain
    )
  end

  def handle_very_slow_request(_event, measurements, metadata, _config) do
    Logger.error(
      "Very slow (>4s): #{metadata.method} #{metadata.provider}:#{metadata.transport} #{round(measurements.latency_ms)}ms",
      chain: metadata.chain
    )
  end

  # Circuit breaker handlers

  def handle_cb_open(_event, _measurements, metadata, _config) do
    extra =
      case metadata do
        %{failure_count: count, error_category: cat} ->
          [failure_count: count, error_category: cat]

        _ ->
          []
      end

    level = if Map.get(metadata, :consecutive_open_count, 0) > 1, do: :debug, else: :warning

    Logger.log(
      level,
      "Circuit opened: #{metadata.provider_id}:#{metadata.transport}",
      [
        chain: metadata.chain,
        from: metadata.from_state,
        to: metadata.to_state,
        reason: metadata.reason
      ] ++ extra
    )
  end

  def handle_cb_close(_event, _measurements, metadata, _config) do
    Logger.info("Circuit closed: #{metadata.provider_id}:#{metadata.transport}",
      chain: metadata.chain,
      reason: metadata.reason
    )
  end

  def handle_cb_half_open(_event, _measurements, metadata, _config) do
    level = if Map.get(metadata, :consecutive_open_count, 0) > 1, do: :debug, else: :info

    Logger.log(level, "Circuit half-open: #{metadata.provider_id}:#{metadata.transport}",
      chain: metadata.chain,
      reason: metadata.reason
    )
  end

  def handle_cb_recovery(_event, _measurements, metadata, _config) do
    level = if Map.get(metadata, :consecutive_open_count, 0) > 1, do: :debug, else: :info

    Logger.log(level, "Circuit proactive recovery: #{metadata.provider_id}:#{metadata.transport}",
      chain: metadata.chain
    )
  end

  # Configuration helpers

  defp enabled? do
    Keyword.get(config(), :enabled, true)
  end

  defp config do
    Application.get_env(:lasso, __MODULE__, [])
  end
end
