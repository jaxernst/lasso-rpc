defmodule Lasso.Providers.InstanceState do
  @moduledoc """
  Centralized ETS reads for shared instance state (`lasso_instance_state`).

  All health, circuit breaker, and rate limit state for provider instances
  is stored in a single ETS table. This module provides the canonical read
  functions with consistent default shapes and `ArgumentError` guards.
  """

  @default_health %{
    status: :connecting,
    http_status: nil,
    last_health_check: nil,
    consecutive_failures: 0,
    consecutive_successes: 0,
    last_error: nil
  }

  @default_circuit %{state: :closed, error: nil, recovery_deadline_ms: nil}

  @spec read_health(String.t()) :: map()
  def read_health(instance_id) when is_binary(instance_id) do
    case safe_lookup({:health, instance_id}) do
      [{_, data}] -> Map.merge(@default_health, data)
      [] -> @default_health
    end
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
  def status_to_availability(:unhealthy), do: :down
  def status_to_availability(:disconnected), do: :down
  def status_to_availability(_), do: :up

  defp safe_lookup(key) do
    :ets.lookup(:lasso_instance_state, key)
  rescue
    ArgumentError -> []
  end
end
