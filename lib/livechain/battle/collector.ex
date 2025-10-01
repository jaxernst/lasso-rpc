defmodule Livechain.Battle.Collector do
  @moduledoc """
  Collects telemetry events during battle tests.

  Attaches telemetry handlers for specified metrics and aggregates results.
  """

  require Logger

  @doc """
  Starts collecting specified metrics.

  Available collectors:
  - `:requests` - RPC request metrics (from RequestPipeline)
  - `:circuit_breaker` - Circuit breaker state changes
  - `:selection` - Provider selection decisions
  - `:normalization` - Response normalization events
  - `:system` - BEAM VM metrics (memory, processes)
  - `:websocket` - WebSocket subscription events
  """
  def start_collectors(collectors) when is_list(collectors) do
    # Stop existing Agent if present (from previous test run)
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> Agent.stop(pid)
      nil -> :ok
    end

    # Use Agent for cross-process telemetry collection
    # Telemetry handlers execute in the caller's process, so we need shared state
    {:ok, agent} = Agent.start_link(fn -> %{} end, name: __MODULE__)
    Process.put(:battle_agent, agent)
    Process.put(:battle_collectors, collectors)

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

    # Get data from Agent and stop it
    agent = Process.get(:battle_agent)
    data = if agent, do: Agent.get(agent, & &1), else: %{}

    if agent do
      Agent.stop(agent)
    end

    Process.delete(:battle_collectors)
    Process.delete(:battle_agent)

    Logger.debug("Stopped collectors, collected #{map_size(data)} data points")
    data
  end

  # Private helpers - attach telemetry handlers

  defp attach_collector(:requests) do
    # Attach to both production events and battle test events
    prod_handler_id = {:battle, :requests_prod, self()}
    battle_handler_id = {:battle, :requests_battle, self()}

    # Capture production request telemetry from RequestPipeline
    :telemetry.attach(
      prod_handler_id,
      [:livechain, :rpc, :request, :stop],
      &handle_request_event/4,
      nil
    )

    # Capture battle test telemetry events (from diagnostic tests)
    :telemetry.attach(
      battle_handler_id,
      [:livechain, :battle, :request],
      &handle_battle_request_event/4,
      nil
    )

    Logger.debug("Attached request collectors: prod=#{inspect(prod_handler_id)}, battle=#{inspect(battle_handler_id)}")
    :ok
  end

  defp attach_collector(:selection) do
    handler_id = {:battle, :selection, self()}

    :telemetry.attach(
      handler_id,
      [:livechain, :selection, :success],
      &handle_selection_event/4,
      nil
    )
  end

  defp attach_collector(:normalization) do
    handler_id = {:battle, :normalization, self()}

    :telemetry.attach_many(
      handler_id,
      [
        [:livechain, :normalize, :result],
        [:livechain, :normalize, :error]
      ],
      &handle_normalization_event/4,
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

    :telemetry.attach_many(
      handler_id,
      [
        [:livechain, :subs, :client_subscribe],
        [:livechain, :subs, :client_unsubscribe]
      ],
      &handle_websocket_event/4,
      nil
    )
  end

  defp attach_collector(unknown) do
    Logger.warning("Unknown collector: #{inspect(unknown)}")
  end

  # Detach handlers

  defp detach_collector(:requests) do
    prod_handler_id = {:battle, :requests_prod, self()}
    battle_handler_id = {:battle, :requests_battle, self()}
    :telemetry.detach(prod_handler_id)
    :telemetry.detach(battle_handler_id)
  end

  defp detach_collector(:circuit_breaker) do
    handler_id = {:battle, :circuit_breaker, self()}
    :telemetry.detach(handler_id)
  end

  defp detach_collector(:selection) do
    handler_id = {:battle, :selection, self()}
    :telemetry.detach(handler_id)
  end

  defp detach_collector(:normalization) do
    handler_id = {:battle, :normalization, self()}
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
    request_data = %{
      duration_ms: measurements.duration_ms,
      chain: metadata.chain,
      method: metadata.method,
      strategy: metadata.strategy,
      provider_id: metadata.provider_id,
      result: metadata.result,
      failovers: metadata.failovers,
      transport: Map.get(metadata, :transport),
      timestamp: System.monotonic_time(:millisecond)
    }

    Logger.debug("Collector received request event: #{metadata.chain}/#{metadata.method}")

    # Update Agent (shared across processes)
    try do
      Agent.update(__MODULE__, fn data ->
        requests = Map.get(data, :requests, [])
        Logger.debug("Collector Agent update: #{length(requests)} -> #{length(requests) + 1} requests")
        Map.put(data, :requests, [request_data | requests])
      end)
    catch
      kind, reason ->
        Logger.error("Failed to update collector Agent (#{kind}): #{inspect(reason)}")
    end
  end

  defp handle_battle_request_event(_event_name, measurements, metadata, _config) do
    # Battle test events use 'latency' instead of 'duration_ms'
    request_data = %{
      duration_ms: Map.get(measurements, :latency, Map.get(measurements, :duration_ms, 0)),
      chain: metadata.chain,
      method: metadata.method,
      strategy: metadata.strategy,
      provider_id: Map.get(metadata, :provider_id),
      result: metadata.result,
      failovers: Map.get(metadata, :failovers, 0),
      transport: Map.get(metadata, :transport),
      timestamp: System.monotonic_time(:millisecond)
    }

    Logger.debug("Collector received battle test event: #{metadata.chain}/#{metadata.method}")

    # Update Agent (shared across processes)
    try do
      Agent.update(__MODULE__, fn data ->
        requests = Map.get(data, :requests, [])
        Map.put(data, :requests, [request_data | requests])
      end)
    catch
      kind, reason ->
        Logger.error("Failed to update collector Agent (#{kind}): #{inspect(reason)}")
    end
  end

  defp handle_selection_event(_event_name, measurements, metadata, _config) do
    selection_data = %{
      count: measurements.count,
      chain: metadata.chain,
      method: metadata.method,
      strategy: metadata.strategy,
      protocol: metadata.protocol,
      provider_id: metadata.provider_id,
      timestamp: System.monotonic_time(:millisecond)
    }

    Agent.update(__MODULE__, fn data ->
      selections = Map.get(data, :selections, [])
      Map.put(data, :selections, [selection_data | selections])
    end)
  end

  defp handle_normalization_event(event_name, measurements, metadata, _config) do
    normalization_data =
      case event_name do
        [:livechain, :normalize, :result] ->
          %{
            type: :result,
            count: measurements.count,
            provider_id: metadata.provider_id,
            method: metadata.method,
            status: metadata.status,
            timestamp: System.monotonic_time(:millisecond)
          }

        [:livechain, :normalize, :error] ->
          %{
            type: :error,
            count: measurements.count,
            provider_id: metadata.provider_id,
            method: metadata.method,
            code: metadata.code,
            category: metadata.category,
            retriable?: metadata.retriable?,
            timestamp: System.monotonic_time(:millisecond)
          }
      end

    Agent.update(__MODULE__, fn data ->
      normalizations = Map.get(data, :normalizations, [])
      Map.put(data, :normalizations, [normalization_data | normalizations])
    end)
  end

  defp handle_circuit_breaker_event(_event_name, _measurements, metadata, _config) do
    cb_data = %{
      provider_id: metadata.provider_id,
      old_state: metadata.old_state,
      new_state: metadata.new_state,
      timestamp: System.monotonic_time(:millisecond)
    }

    Agent.update(__MODULE__, fn data ->
      cb_events = Map.get(data, :circuit_breaker, [])
      Map.put(data, :circuit_breaker, [cb_data | cb_events])
    end)
  end

  defp handle_websocket_event(event_name, measurements, metadata, _config) do
    ws_data =
      Map.merge(
        %{
          event: event_name,
          timestamp: System.monotonic_time(:millisecond)
        },
        Map.merge(measurements, metadata)
      )

    Agent.update(__MODULE__, fn data ->
      ws_events = Map.get(data, :websocket, [])
      Map.put(data, :websocket, [ws_data | ws_events])
    end)
  end

  defp record_system_metrics do
    sample = %{
      memory_mb: :erlang.memory(:total) / 1_024 / 1_024,
      process_count: :erlang.system_info(:process_count),
      timestamp: System.monotonic_time(:millisecond)
    }

    Agent.update(__MODULE__, fn data ->
      system_samples = Map.get(data, :system, [])
      Map.put(data, :system, [sample | system_samples])
    end)
  end
end