defmodule Lasso.Providers.InstanceState do
  @moduledoc """
  Centralized ETS reads for shared instance state (`lasso_instance_state`).

  All health, circuit breaker, and rate limit state for provider instances
  is stored in a single ETS table. This module provides the canonical read
  functions with consistent default shapes and `ArgumentError` guards.
  """

  alias Lasso.Core.Support.CircuitBreaker.{ControlRing, Snapshot, Storage}

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

  @default_circuit %{
    state: :unavailable,
    error: nil,
    recovery_deadline_ms: nil,
    control_health: :degraded
  }

  @status_severity %{
    nil => 0,
    :healthy => 1,
    :degraded => 2,
    :misconfigured => 3,
    :unhealthy => 4
  }

  @spec read_health(String.t(), keyword()) :: map()
  def read_health(instance_id, opts \\ []) when is_binary(instance_id) do
    probe = read_probe_health(instance_id)
    block_sync = read_block_sync_health(instance_id)

    routing =
      if Keyword.get(opts, :include_learned, true) do
        case Keyword.fetch(opts, :routing_states) do
          {:ok, states} ->
            merge_routing_states(states)

          :error ->
            read_routing_health(
              instance_id,
              Keyword.get(opts, :learned_scope),
              Keyword.get(opts, :learned_floor_us)
            )
        end
      else
        @default_routing
      end

    merge_health(probe, block_sync, routing)
  end

  @doc false
  @spec read_candidate_health(String.t(), map() | nil, map() | nil, boolean()) :: %{
          base: map(),
          http: map(),
          ws: map()
        }
  def read_candidate_health(instance_id, http_routing, ws_routing, include_learned?)
      when is_binary(instance_id) and is_boolean(include_learned?) do
    probe = read_probe_health(instance_id)
    block_sync = read_block_sync_health(instance_id)
    base = merge_health(probe, block_sync, @default_routing)

    %{
      base: base,
      http: merge_health(probe, block_sync, candidate_routing(http_routing, include_learned?)),
      ws: merge_health(probe, block_sync, candidate_routing(ws_routing, include_learned?))
    }
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

  defp read_routing_health(instance_id, nil, _floor_us), do: read_routing_health(instance_id)

  defp read_routing_health(instance_id, {profile, chain_id}, floor_us)
       when is_binary(profile) and is_integer(chain_id) do
    key = {:health_routing, profile, chain_id, instance_id}

    case safe_lookup(key) do
      [{^key, data}] ->
        if fresh_learned?(data, floor_us),
          do: Map.merge(@default_routing, data),
          else: @default_routing

      [] ->
        @default_routing
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

  defp candidate_routing(routing_state, true), do: merge_routing_states([routing_state])
  defp candidate_routing(_routing_state, false), do: @default_routing

  defp worse_status(a, b) do
    a_sev = Map.get(@status_severity, a, 0)
    b_sev = Map.get(@status_severity, b, 0)
    if a_sev >= b_sev, do: a, else: b
  end

  @spec read_circuit(String.t(), :http | :ws) :: map()
  def read_circuit(instance_id, transport)
      when is_binary(instance_id) and transport in [:http, :ws] do
    case Snapshot.lookup({instance_id, transport}) do
      {:ok, %{owner_pid: owner_pid, ready?: true} = snapshot} when is_pid(owner_pid) ->
        if Process.alive?(owner_pid) do
          state =
            if snapshot.control_health == :degraded,
              do: :half_open,
              else: snapshot.state

          %{
            state: state,
            error: nil,
            recovery_deadline_ms: recovery_deadline_ms(snapshot.recovery_deadline_us),
            control_health: snapshot.control_health
          }
        else
          @default_circuit
        end

      _ ->
        @default_circuit
    end
  rescue
    ArgumentError -> @default_circuit
  end

  defp recovery_deadline_ms(nil), do: nil
  defp recovery_deadline_ms(deadline_us), do: div(deadline_us, 1_000)

  @spec read_rate_limit(String.t(), :http | :ws, keyword()) :: map()
  def read_rate_limit(instance_id, transport, opts \\ [])
      when is_binary(instance_id) and transport in [:http, :ws] do
    now_ms = System.monotonic_time(:millisecond)
    include_learned? = Keyword.get(opts, :include_learned, true)

    direct_expiries =
      case Keyword.get(opts, :routing_state) do
        %{rate_limit_expiry_ms: expiry} when include_learned? and expiry > now_ms -> [expiry]
        _other -> []
      end

    expiries =
      [{{:rate_limit, instance_id, transport}, false}]
      |> maybe_add_learned_rate_limit(
        instance_id,
        transport,
        include_learned? and not Keyword.has_key?(opts, :routing_state),
        opts
      )
      |> Enum.flat_map(fn {key, learned?} ->
        case safe_lookup(key) do
          [{_, %{expiry_ms: expiry} = data}] when expiry > now_ms ->
            if not learned? or fresh_learned?(data, Keyword.get(opts, :learned_floor_us)),
              do: [expiry],
              else: []

          _other ->
            []
        end
      end)
      |> Kernel.++(direct_expiries)

    case expiries do
      [] ->
        %{rate_limited: false, remaining_ms: nil, expiry_ms: nil}

      _active ->
        expiry = Enum.max(expiries)
        %{rate_limited: true, remaining_ms: expiry - now_ms, expiry_ms: expiry}
    end
  end

  defp maybe_add_learned_rate_limit(keys, instance_id, transport, true, opts) do
    learned_key =
      case Keyword.get(opts, :learned_scope) do
        {profile, chain_id} ->
          {:rate_limit_routing, profile, chain_id, instance_id, transport}

        nil ->
          {:rate_limit_routing, instance_id, transport}
      end

    [{learned_key, true} | keys]
  end

  defp maybe_add_learned_rate_limit(keys, _instance_id, _transport, false, _opts), do: keys

  defp fresh_learned?(_data, nil), do: true

  defp fresh_learned?(%{observed_at_us: observed_at_us}, floor_us)
       when is_integer(observed_at_us) and is_integer(floor_us),
       do: observed_at_us > floor_us

  defp fresh_learned?(_data, _floor_us), do: false

  defp merge_routing_states(states) when is_list(states) do
    states
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(@default_routing, fn state, merged ->
      last_health_check = monotonic_us_to_ms(Map.get(state, :observed_at_us))

      %{
        status: worse_status(merged.status, Map.get(state, :status)),
        last_health_check: latest(merged.last_health_check, last_health_check),
        consecutive_failures:
          max(merged.consecutive_failures, Map.get(state, :consecutive_failures, 0)),
        consecutive_successes:
          max(merged.consecutive_successes, Map.get(state, :consecutive_successes, 0)),
        last_error:
          case Map.get(state, :last_error_category) do
            nil -> merged.last_error
            category -> %{category: category}
          end
      }
    end)
  end

  defp monotonic_us_to_ms(nil), do: nil
  defp monotonic_us_to_ms(value), do: div(value, 1_000)

  defp latest(nil, right), do: right
  defp latest(left, nil), do: left
  defp latest(left, right), do: max(left, right)

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

  @doc """
  Deletes every `:lasso_instance_state` row for the given `instance_id`.

  Called when the last `Catalog` reference to an instance is removed (instance
  is being torn down). Without this, deterministic-instance-id rebinding on
  re-activation would resurrect stale health/circuit/rate-limit verdicts —
  e.g. a previously-`:unhealthy` instance would start life unhealthy on the
  next activation, before any probe has run.
  """
  @spec clear(String.t()) :: :ok
  def clear(instance_id) when is_binary(instance_id) do
    keys = [
      {:health_probe, instance_id},
      {:health_block_sync, instance_id},
      {:health_routing, instance_id},
      {:circuit, instance_id, :http},
      {:circuit, instance_id, :ws},
      {:rate_limit, instance_id, :http},
      {:rate_limit, instance_id, :ws},
      {:rate_limit_routing, instance_id, :http},
      {:rate_limit_routing, instance_id, :ws},
      {:ws_status, instance_id}
    ]

    Enum.each(keys, fn key ->
      try do
        :ets.delete(:lasso_instance_state, key)
      rescue
        ArgumentError -> :ok
      end
    end)

    clear_scoped_routing_state(instance_id)

    Enum.each([:http, :ws], fn transport ->
      breaker_id = {instance_id, transport}
      clear_breaker_table(Storage.snapshot_table(), breaker_id)
      clear_breaker_table(Storage.lease_table(), breaker_id)
      ControlRing.delete(breaker_id)
    end)

    :ok
  end

  defp clear_breaker_table(table, breaker_id) do
    :ets.delete(table, breaker_id)
  rescue
    ArgumentError -> :ok
  end

  defp clear_scoped_routing_state(instance_id) do
    :ets.match_delete(:lasso_instance_state, {{:health_routing, :_, :_, instance_id}, :_})

    :ets.match_delete(
      :lasso_instance_state,
      {{:rate_limit_routing, :_, :_, instance_id, :_}, :_}
    )

    :ets.match_delete(
      :lasso_instance_state,
      {{:routing_control, :_, :_, instance_id, :_, :_}, :_}
    )
  rescue
    ArgumentError -> :ok
  end

  defp safe_lookup(key) do
    :ets.lookup(:lasso_instance_state, key)
  rescue
    ArgumentError -> []
  end
end
