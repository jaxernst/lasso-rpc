defmodule Livechain.Battle.Collector do
  @moduledoc """
  Collects telemetry events during battle tests.

  Attaches telemetry handlers for specified metrics and aggregates results.
  """

  require Logger

  @doc """
  Starts collecting specified metrics.

  Available collectors:
  - `:requests` - HTTP/RPC request metrics
  - `:circuit_breaker` - Circuit breaker state changes
  - `:system` - BEAM VM metrics (memory, processes)
  - `:websocket` - WebSocket event metrics
  """
  def start_collectors(collectors) when is_list(collectors) do
    # Store collector state in process dictionary (simple for Phase 1)
    # Phase 2: Use Agent or ETS for better concurrency
    Process.put(:battle_collectors, collectors)
    Process.put(:battle_data, %{})

    Enum.each(collectors, fn collector ->
      attach_collector(collector)
    end)

    Logger.debug("Started collectors: #{inspect(collectors)}")
    :ok
  end

  @doc """
  Stops collectors and returns collected data.
  """
  def stop_collectors(collectors) when is_list(collectors) do
    Enum.each(collectors, fn collector ->
      detach_collector(collector)
    end)

    data = Process.get(:battle_data, %{})
    Process.delete(:battle_collectors)
    Process.delete(:battle_data)

    Logger.debug("Stopped collectors, collected #{map_size(data)} data points")
    data
  end

  # Private helpers - attach telemetry handlers

  defp attach_collector(:requests) do
    handler_id = {:battle, :requests, self()}

    :telemetry.attach(
      handler_id,
      [:livechain, :battle, :request],
      &handle_request_event/4,
      nil
    )
  end

  defp attach_collector(:circuit_breaker) do
    handler_id = {:battle, :circuit_breaker, self()}

    :telemetry.attach(
      handler_id,
      [:livechain, :circuit_breaker, :state_change],
      &handle_circuit_breaker_event/4,
      nil
    )
  end

  defp attach_collector(:system) do
    # Start periodic system metrics collection
    # For Phase 1, collect once at start and end
    # Phase 2: Periodic sampling
    record_system_metrics()
  end

  defp attach_collector(:websocket) do
    handler_id = {:battle, :websocket, self()}

    :telemetry.attach(
      handler_id,
      [:livechain, :battle, :websocket],
      &handle_websocket_event/4,
      nil
    )
  end

  defp attach_collector(unknown) do
    Logger.warning("Unknown collector: #{inspect(unknown)}")
  end

  # Detach handlers

  defp detach_collector(:requests) do
    handler_id = {:battle, :requests, self()}
    :telemetry.detach(handler_id)
  end

  defp detach_collector(:circuit_breaker) do
    handler_id = {:battle, :circuit_breaker, self()}
    :telemetry.detach(handler_id)
  end

  defp detach_collector(:system) do
    # Collect final system metrics
    record_system_metrics()
  end

  defp detach_collector(:websocket) do
    handler_id = {:battle, :websocket, self()}
    :telemetry.detach(handler_id)
  end

  defp detach_collector(_), do: :ok

  # Event handlers

  defp handle_request_event(_event_name, measurements, metadata, _config) do
    data = Process.get(:battle_data, %{})
    requests = Map.get(data, :requests, [])

    request_data = %{
      latency: measurements.latency,
      chain: metadata.chain,
      method: metadata.method,
      strategy: metadata.strategy,
      result: metadata.result,
      request_id: metadata.request_id,
      timestamp: System.monotonic_time(:millisecond)
    }

    updated_requests = [request_data | requests]
    Process.put(:battle_data, Map.put(data, :requests, updated_requests))
  end

  defp handle_circuit_breaker_event(_event_name, _measurements, metadata, _config) do
    data = Process.get(:battle_data, %{})
    cb_events = Map.get(data, :circuit_breaker, [])

    cb_data = %{
      provider_id: metadata.provider_id,
      old_state: metadata.old_state,
      new_state: metadata.new_state,
      timestamp: System.monotonic_time(:millisecond)
    }

    updated_cb = [cb_data | cb_events]
    Process.put(:battle_data, Map.put(data, :circuit_breaker, updated_cb))
  end

  defp handle_websocket_event(_event_name, measurements, metadata, _config) do
    data = Process.get(:battle_data, %{})
    ws_events = Map.get(data, :websocket, [])

    ws_data = Map.merge(measurements, metadata)
    updated_ws = [ws_data | ws_events]
    Process.put(:battle_data, Map.put(data, :websocket, updated_ws))
  end

  defp record_system_metrics do
    data = Process.get(:battle_data, %{})
    system_samples = Map.get(data, :system, [])

    sample = %{
      memory_mb: :erlang.memory(:total) / 1_024 / 1_024,
      process_count: :erlang.system_info(:process_count),
      timestamp: System.monotonic_time(:millisecond)
    }

    updated_samples = [sample | system_samples]
    Process.put(:battle_data, Map.put(data, :system, updated_samples))
  end
end