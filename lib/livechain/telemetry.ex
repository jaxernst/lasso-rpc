defmodule Livechain.Telemetry do
  @moduledoc """
  Telemetry integration for Livechain observability.

  Provides comprehensive metrics collection, event tracking, and
  performance monitoring for the multi-provider RPC system.
  """

  require Logger

  @doc """
  Emits telemetry events for RPC operations.
  """
  def emit_rpc_call(provider_id, method, duration, result) do
    :telemetry.execute(
      [:livechain, :rpc, :call],
      %{duration: duration},
      %{
        provider_id: provider_id,
        method: method,
        result: result
      }
    )
  end

  @doc """
  Emits telemetry events for message aggregation.
  """
  def emit_message_aggregation(chain_name, message_type, duration, result) do
    :telemetry.execute(
      [:livechain, :aggregation, :message],
      %{duration: duration},
      %{
        chain_name: chain_name,
        message_type: message_type,
        result: result
      }
    )
  end

  @doc """
  Emits telemetry events for provider health changes.
  """
  def emit_provider_health_change(provider_id, old_status, new_status) do
    :telemetry.execute(
      [:livechain, :provider, :health_change],
      %{},
      %{
        provider_id: provider_id,
        old_status: old_status,
        new_status: new_status,
        timestamp: System.monotonic_time(:millisecond)
      }
    )
  end

  @doc """
  Emits telemetry events for circuit breaker state changes.
  """
  def emit_circuit_breaker_change(provider_id, old_state, new_state) do
    :telemetry.execute(
      [:livechain, :circuit_breaker, :state_change],
      %{},
      %{
        provider_id: provider_id,
        old_state: old_state,
        new_state: new_state,
        timestamp: System.monotonic_time(:millisecond)
      }
    )
  end

  @doc """
  Emits telemetry events for WebSocket connection lifecycle.
  """
  def emit_websocket_lifecycle(connection_id, event, metadata \\ %{}) do
    :telemetry.execute(
      [:livechain, :websocket, event],
      %{},
      Map.merge(metadata, %{
        connection_id: connection_id,
        timestamp: System.monotonic_time(:millisecond)
      })
    )
  end

  @doc """
  Emits telemetry events for cache operations.
  """
  def emit_cache_operation(chain_name, operation, cache_size, duration) do
    :telemetry.execute(
      [:livechain, :cache, operation],
      %{duration: duration},
      %{
        chain_name: chain_name,
        cache_size: cache_size
      }
    )
  end

  @doc """
  Emits telemetry events for failover operations.
  """
  def emit_failover(chain_name, from_provider, to_provider, reason) do
    :telemetry.execute(
      [:livechain, :failover, :triggered],
      %{},
      %{
        chain_name: chain_name,
        from_provider: from_provider,
        to_provider: to_provider,
        reason: reason,
        timestamp: System.monotonic_time(:millisecond)
      }
    )
  end

  @doc """
  Emits telemetry events for error conditions.
  """
  def emit_error(component, error, metadata \\ %{}) do
    :telemetry.execute(
      [:livechain, :error, component],
      %{},
      Map.merge(metadata, %{
        error: error,
        timestamp: System.monotonic_time(:millisecond)
      })
    )
  end

  @doc """
  Emits telemetry events for performance metrics.
  """
  def emit_performance_metric(metric_name, value, metadata \\ %{}) do
    :telemetry.execute(
      [:livechain, :performance, metric_name],
      %{value: value},
      metadata
    )
  end

  @doc """
  Attaches default telemetry handlers for common metrics.
  """
  def attach_default_handlers do
    # RPC call metrics
    :telemetry.attach_many(
      "livechain-rpc-metrics",
      [
        [:livechain, :rpc, :call],
        [:livechain, :aggregation, :message],
        [:livechain, :provider, :health_change],
        [:livechain, :circuit_breaker, :state_change],
        [:livechain, :websocket, :connected],
        [:livechain, :websocket, :disconnected],
        [:livechain, :cache, :hit],
        [:livechain, :cache, :miss],
        [:livechain, :failover, :triggered],
        [:livechain, :error, :rpc],
        [:livechain, :error, :websocket],
        [:livechain, :performance, :latency]
      ],
      &Livechain.Telemetry.Handlers.handle_event/4,
      %{}
    )

    Logger.info("Attached default telemetry handlers")
  end

  @doc """
  Detaches all telemetry handlers.
  """
  def detach_handlers do
    :telemetry.detach("livechain-rpc-metrics")
    Logger.info("Detached telemetry handlers")
  end
end

defmodule Livechain.Telemetry.Handlers do
  @moduledoc """
  Default telemetry event handlers for Livechain metrics.
  """

  require Logger

  @doc """
  Handles telemetry events and logs/metrics them appropriately.
  """
  def handle_event([:livechain, :rpc, :call], %{duration: duration}, metadata, _config) do
    Logger.debug("RPC call completed", %{
      provider_id: metadata.provider_id,
      method: metadata.method,
      duration_ms: duration,
      result: metadata.result
    })

    # Here you could send to external metrics systems like Prometheus, DataDog, etc.
  end

  def handle_event([:livechain, :aggregation, :message], %{duration: duration}, metadata, _config) do
    Logger.debug("Message aggregated", %{
      chain_name: metadata.chain_name,
      message_type: metadata.message_type,
      duration_ms: duration,
      result: metadata.result
    })
  end

  def handle_event([:livechain, :provider, :health_change], _measurements, metadata, _config) do
    Logger.info("Provider health changed", %{
      provider_id: metadata.provider_id,
      old_status: metadata.old_status,
      new_status: metadata.new_status
    })
  end

  def handle_event(
        [:livechain, :circuit_breaker, :state_change],
        _measurements,
        metadata,
        _config
      ) do
    Logger.warning("Circuit breaker state changed", %{
      provider_id: metadata.provider_id,
      old_state: metadata.old_state,
      new_state: metadata.new_state
    })
  end

  def handle_event([:livechain, :websocket, event], _measurements, metadata, _config) do
    Logger.info("WebSocket #{event}", %{
      connection_id: metadata.connection_id
    })
  end

  def handle_event([:livechain, :cache, operation], %{duration: duration}, metadata, _config) do
    Logger.debug("Cache #{operation}", %{
      chain_name: metadata.chain_name,
      cache_size: metadata.cache_size,
      duration_ms: duration
    })
  end

  def handle_event([:livechain, :failover, :triggered], _measurements, metadata, _config) do
    Logger.warning("Failover triggered", %{
      chain_name: metadata.chain_name,
      from_provider: metadata.from_provider,
      to_provider: metadata.to_provider,
      reason: metadata.reason
    })
  end

  def handle_event([:livechain, :error, component], _measurements, metadata, _config) do
    Logger.error("Error in #{component}", %{
      error: metadata.error
    })
  end

  def handle_event([:livechain, :performance, metric_name], %{value: value}, metadata, _config) do
    Logger.debug("Performance metric: #{metric_name} = #{value}", metadata)
  end

  # Catch-all for unhandled events
  def handle_event(event_name, measurements, metadata, _config) do
    Logger.debug("Unhandled telemetry event", %{
      event: event_name,
      measurements: measurements,
      metadata: metadata
    })
  end
end
