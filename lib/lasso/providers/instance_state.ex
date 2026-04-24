defmodule Lasso.Providers.InstanceState do
  @moduledoc """
  Centralized ETS reads for shared instance state (`lasso_instance_state`).

  All health, circuit breaker, and rate limit state for provider instances
  is stored in a single ETS table. This module provides the canonical read
  functions with consistent default shapes and `ArgumentError` guards.
  """

  @default_probe %{
    status: nil,
    http_status: nil,
    last_health_check: nil,
    consecutive_failures: 0,
    last_error: nil
  }

  @default_routing %{
    status: nil,
    last_health_check: nil,
    consecutive_failures: 0,
    consecutive_successes: 0,
    last_error: nil
  }

  @default_circuit %{state: :closed, error: nil, recovery_deadline_ms: nil}

  @status_severity %{
    nil => 0,
    :healthy => 1,
    :degraded => 2,
    :misconfigured => 3,
    :unhealthy => 4
  }

  @spec read_health(String.t()) :: map()
  def read_health(instance_id) when is_binary(instance_id) do
    probe = read_probe_health(instance_id)
    block_sync = read_block_sync_health(instance_id)
    routing = read_routing_health(instance_id)
    merge_health(probe, block_sync, routing)
  end

  @spec read_probe_health(String.t()) :: map()
  def read_probe_health(instance_id) when is_binary(instance_id) do
    case safe_lookup({:health_probe, instance_id}) do
      [{_, data}] -> Map.merge(@default_probe, data)
      [] -> @default_probe
    end
  end

  @spec read_block_sync_health(String.t()) :: map()
  def read_block_sync_health(instance_id) when is_binary(instance_id) do
    case safe_lookup({:health_block_sync, instance_id}) do
      [{_, data}] -> data
      [] -> %{http_status: nil, last_health_check: nil}
    end
  end

  @spec read_routing_health(String.t()) :: map()
  def read_routing_health(instance_id) when is_binary(instance_id) do
    case safe_lookup({:health_routing, instance_id}) do
      [{_, data}] -> Map.merge(@default_routing, data)
      [] -> @default_routing
    end
  end

  defp merge_health(probe, block_sync, routing) do
    merged_status =
      case worse_status(probe.status, routing.status) do
        nil -> :connecting
        other -> other
      end

    http_status = worse_status(probe.http_status, block_sync.http_status)

    timestamps = [
      probe.last_health_check,
      block_sync.last_health_check,
      routing.last_health_check
    ]

    latest_check = timestamps |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

    last_error =
      case {routing.last_error, probe.last_error} do
        {nil, probe_err} ->
          probe_err

        {routing_err, nil} ->
          routing_err

        {routing_err, probe_err} ->
          routing_check = routing.last_health_check
          probe_check = probe.last_health_check
          if (routing_check || 0) >= (probe_check || 0), do: routing_err, else: probe_err
      end

    %{
      status: merged_status,
      http_status: http_status,
      last_health_check: latest_check,
      consecutive_failures: routing.consecutive_failures,
      consecutive_successes: routing.consecutive_successes,
      probe_consecutive_failures: probe.consecutive_failures,
      last_error: last_error
    }
  end

  defp worse_status(a, b) do
    a_sev = Map.get(@status_severity, a, 0)
    b_sev = Map.get(@status_severity, b, 0)
    if a_sev >= b_sev, do: a, else: b
  end

  @spec read_circuit(String.t(), :http | :ws) :: map()
  def read_circuit(instance_id, transport)
      when is_binary(instance_id) and transport in [:http, :ws] do
    case safe_lookup({:circuit, instance_id, transport}) do
      [{_, data}] -> Map.merge(@default_circuit, data)
      [] -> @default_circuit
    end
  end

  @spec read_rate_limit(String.t(), :http | :ws) :: map()
  def read_rate_limit(instance_id, transport)
      when is_binary(instance_id) and transport in [:http, :ws] do
    now_ms = System.monotonic_time(:millisecond)

    case safe_lookup({:rate_limit, instance_id, transport}) do
      [{_, %{expiry_ms: expiry}}] when expiry > now_ms ->
        %{rate_limited: true, remaining_ms: expiry - now_ms, expiry_ms: expiry}

      _ ->
        %{rate_limited: false, remaining_ms: nil, expiry_ms: nil}
    end
  end

  @default_ws_status %{
    status: :disconnected,
    reconnect_attempts: 0,
    last_event_ms: nil
  }

  @spec read_ws_status(String.t()) :: map()
  def read_ws_status(instance_id) when is_binary(instance_id) do
    case safe_lookup({:ws_status, instance_id}) do
      [{_, data}] -> Map.merge(@default_ws_status, data)
      [] -> @default_ws_status
    end
  end

  @spec status_to_availability(atom() | nil) :: :up | :down | :limited
  def status_to_availability(:healthy), do: :up
  def status_to_availability(:connecting), do: :up
  def status_to_availability(:degraded), do: :limited
  def status_to_availability(:misconfigured), do: :down
  def status_to_availability(:unhealthy), do: :down
  def status_to_availability(:disconnected), do: :down
  def status_to_availability(_), do: :up

  defp safe_lookup(key) do
    :ets.lookup(:lasso_instance_state, key)
  rescue
    ArgumentError -> []
  end
end
