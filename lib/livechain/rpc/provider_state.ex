defmodule Livechain.RPC.ProviderState do
  @moduledoc """
  Unified provider state aggregate managing availability, health, circuit breaker,
  and performance data in a single cohesive structure.

  This eliminates the complexity of coordinating state between ProviderPool,
  HealthPolicy, and CircuitBreaker by providing a single state machine
  that handles all provider-related events and state transitions.
  """

  alias Livechain.RPC.{HealthPolicy, ErrorClassifier}
  alias Livechain.JSONRPC.Error, as: JError
  alias Livechain.Events.Provider

  @derive Jason.Encoder
  defstruct [
    :id,
    :config,
    :availability,
    :circuit_state,
    :connection_state,
    :last_updated,
    :health_policy,
    :performance_stats,
    :pid,
    # Legacy compatibility fields
    :status,
    :consecutive_failures,
    :consecutive_successes,
    :last_error,
    :last_health_check,
    :cooldown_until
  ]

  @type availability :: :up | :limited | :down | :misconfigured
  @type circuit_state :: :closed | :open | :half_open
  @type connection_state :: :connected | :disconnected | :connecting | :error
  @type health_status :: :healthy | :unhealthy | :connecting | :disconnected |
                         :rate_limited | :misconfigured | :degraded

  @type t :: %__MODULE__{
          id: String.t(),
          config: map(),
          availability: availability(),
          circuit_state: circuit_state(),
          connection_state: connection_state(),
          last_updated: integer(),
          health_policy: HealthPolicy.t(),
          performance_stats: map(),
          pid: pid() | nil,
          # Legacy compatibility
          status: health_status(),
          consecutive_failures: non_neg_integer(),
          consecutive_successes: non_neg_integer(),
          last_error: term(),
          last_health_check: integer(),
          cooldown_until: integer() | nil
        }

  @doc """
  Creates a new provider state with default values.
  """
  @spec new(String.t(), map(), keyword()) :: t()
  def new(provider_id, provider_config, opts \\ []) do
    now = System.monotonic_time(:millisecond)
    health_policy = HealthPolicy.new(Keyword.get(opts, :health_policy_opts, []))

    %__MODULE__{
      id: provider_id,
      config: provider_config,
      availability: :up,
      circuit_state: :closed,
      connection_state: :disconnected,
      last_updated: now,
      health_policy: health_policy,
      performance_stats: %{},
      pid: nil,
      # Legacy compatibility
      status: :connecting,
      consecutive_failures: 0,
      consecutive_successes: 0,
      last_error: nil,
      last_health_check: now,
      cooldown_until: nil
    }
  end

  @doc """
  Applies an event to the provider state, updating all relevant fields atomically.

  Supported events:
  - {:success, latency_ms, method}
  - {:failure, error, context, method}
  - {:ws_connected, pid}
  - {:ws_disconnected, reason}
  - {:circuit_state_changed, from_state, to_state}
  - {:health_check_success}
  - {:health_check_failure, reason}
  """
  @spec apply_event(t(), tuple()) :: {t(), [Provider.t()]}
  def apply_event(%__MODULE__{} = state, event) do
    now = System.monotonic_time(:millisecond)
    {new_state, events} = do_apply_event(state, event, now)

    final_state = %{new_state | last_updated: now}
    {final_state, events}
  end

  # Private event application functions

  defp do_apply_event(state, {:success, latency_ms, method}, now) do
    # Update health policy
    new_health_policy = HealthPolicy.apply_event(state.health_policy, {:success, latency_ms, method})

    # Update state
    new_state = %{
      state
      | health_policy: new_health_policy,
        availability: HealthPolicy.availability(new_health_policy),
        consecutive_successes: state.consecutive_successes + 1,
        consecutive_failures: 0,
        status: :healthy,
        last_health_check: now,
        cooldown_until: if(new_health_policy.cooldown_until, do: nil, else: state.cooldown_until)
    }

    # Generate events for state changes
    events = []
    events = maybe_emit_became_healthy(state, new_state, events, now)
    events = maybe_emit_cooldown_end(state, new_state, events, now)

    {new_state, events}
  end

  defp do_apply_event(state, {:failure, error, context, method}, now) do
    # Normalize error through ErrorClassifier
    jerr = ErrorClassifier.normalize_error(error, %{
      provider_id: state.id,
      transport: infer_transport(state.config)
    })

    # Update health policy
    new_health_policy = HealthPolicy.apply_event(state.health_policy, {:failure, jerr, context, method, now})

    # Determine new status based on error type and policy state
    new_status = determine_failure_status(jerr, context, state.consecutive_failures + 1,
                                         new_health_policy.config.failure_threshold)

    new_state = %{
      state
      | health_policy: new_health_policy,
        availability: HealthPolicy.availability(new_health_policy),
        consecutive_failures: state.consecutive_failures + 1,
        consecutive_successes: 0,
        status: new_status,
        last_error: jerr,
        last_health_check: now,
        cooldown_until: new_health_policy.cooldown_until
    }

    # Generate events for state changes
    events = []
    events = maybe_emit_became_unhealthy(state, new_state, events, now, jerr)
    events = maybe_emit_cooldown_start(state, new_state, events, now)

    {new_state, events}
  end

  defp do_apply_event(state, {:ws_connected, pid}, now) do
    new_state = %{
      state
      | pid: pid,
        connection_state: :connected,
        status: :healthy,
        consecutive_successes: state.consecutive_successes + 1,
        consecutive_failures: 0,
        last_health_check: now
    }

    events = [%Provider.WSConnected{ts: now, chain: chain_name(state), provider_id: state.id}]
    {new_state, events}
  end

  defp do_apply_event(state, {:ws_disconnected, reason}, now) do
    new_state = %{
      state
      | pid: nil,
        connection_state: :disconnected,
        status: :disconnected,
        consecutive_failures: state.consecutive_failures + 1,
        last_error: {:ws_disconnected, reason},
        last_health_check: now
    }

    events = [%Provider.WSDisconnected{ts: now, chain: chain_name(state), provider_id: state.id, reason: reason}]
    {new_state, events}
  end

  defp do_apply_event(state, {:circuit_state_changed, _from, to}, _now) do
    new_state = %{state | circuit_state: to}
    {new_state, []}
  end

  defp do_apply_event(state, {:health_check_success}, now) do
    do_apply_event(state, {:success, 0, nil}, now)
  end

  defp do_apply_event(state, {:health_check_failure, reason}, now) do
    do_apply_event(state, {:failure, reason, :health_check, nil}, now)
  end

  # Helper functions for event generation

  defp maybe_emit_became_healthy(old_state, new_state, events, now) do
    if old_state.status != :healthy and new_state.status == :healthy do
      event = %Provider.Healthy{ts: now, chain: chain_name(new_state), provider_id: new_state.id}
      [event | events]
    else
      events
    end
  end

  defp maybe_emit_became_unhealthy(old_state, new_state, events, now, error) do
    if old_state.status != :unhealthy and new_state.status == :unhealthy do
      event = %Provider.Unhealthy{ts: now, chain: chain_name(new_state), provider_id: new_state.id, reason: error}
      [event | events]
    else
      events
    end
  end

  defp maybe_emit_cooldown_start(old_state, new_state, events, now) do
    old_cooldown = old_state.cooldown_until
    new_cooldown = new_state.cooldown_until

    if is_nil(old_cooldown) and not is_nil(new_cooldown) do
      event = %Provider.CooldownStart{ts: now, chain: chain_name(new_state), provider_id: new_state.id, until: new_cooldown}
      [event | events]
    else
      events
    end
  end

  defp maybe_emit_cooldown_end(old_state, new_state, events, now) do
    old_cooldown = old_state.cooldown_until
    new_cooldown = new_state.cooldown_until

    if not is_nil(old_cooldown) and is_nil(new_cooldown) do
      event = %Provider.CooldownEnd{ts: now, chain: chain_name(new_state), provider_id: new_state.id}
      [event | events]
    else
      events
    end
  end

  # Helper functions

  defp determine_failure_status(%JError{category: :rate_limit}, _context, _failures, _threshold) do
    :rate_limited
  end

  defp determine_failure_status(%JError{category: :client_error}, :health_check, _failures, _threshold) do
    :misconfigured
  end

  defp determine_failure_status(_error, _context, consecutive_failures, threshold) when consecutive_failures >= threshold do
    :unhealthy
  end

  defp determine_failure_status(_error, _context, _failures, _threshold) do
    :degraded
  end

  defp infer_transport(config) do
    cond do
      is_binary(Map.get(config, :ws_url)) -> :ws
      is_binary(Map.get(config, :url)) or is_binary(Map.get(config, :http_url)) -> :http
      true -> nil
    end
  end

  defp chain_name(state) do
    Map.get(state.config, :chain, "unknown")
  end

  @doc """
  Checks if the provider is available for routing at the current time.
  """
  @spec available_for_routing?(t(), integer()) :: boolean()
  def available_for_routing?(%__MODULE__{} = state, now_ms \\ System.monotonic_time(:millisecond)) do
    state.availability in [:up, :limited] and
      state.circuit_state != :open and
      not HealthPolicy.cooldown?(state.health_policy, now_ms)
  end

  @doc """
  Gets a summary of the provider's current status for external consumption.
  """
  @spec to_summary(t()) :: map()
  def to_summary(%__MODULE__{} = state) do
    %{
      id: state.id,
      availability: state.availability,
      circuit_state: state.circuit_state,
      connection_state: state.connection_state,
      status: state.status,
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes,
      last_error: state.last_error,
      last_updated: state.last_updated,
      is_in_cooldown: HealthPolicy.cooldown?(state.health_policy, System.monotonic_time(:millisecond)),
      cooldown_until: state.health_policy.cooldown_until
    }
  end
end