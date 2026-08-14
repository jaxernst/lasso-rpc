defmodule Lasso.Core.Transport.AttemptProtocol do
  @moduledoc false

  alias Lasso.Core.Support.{AttemptLifecycle, ErrorClassification}

  @dispatch_context_key :lasso_attempt_dispatch_context
  @deadline_key :lasso_attempt_deadline_us
  @terminal_candidate_key :lasso_attempt_terminal_candidate

  @open_not_started 0
  @open_started 1
  @open_confirmed 2
  @closed_not_started 3
  @closed_started 4
  @closed_confirmed 5
  @timestamp_unset -9_223_372_036_854_775_808

  defmodule Context do
    @moduledoc false

    @enforce_keys [:owner, :attempt_ref, :deadline_us, :gate]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            owner: pid(),
            attempt_ref: reference(),
            deadline_us: integer(),
            gate: :atomics.atomics_ref()
          }
  end

  @type legacy_context :: {pid(), reference()}
  @type context :: legacy_context() | Context.t()
  @type certainty :: :not_dispatched | :indeterminate | :dispatched
  @type send_start_error :: :deadline_expired | :owner_down
  @type terminal_candidate ::
          {:ok, map()} | {:conflict, map()} | :missing

  @terminal_kinds [:predispatch_failure, :response, :invalid_response, :transport_failure]

  @doc false
  @spec new_context(pid(), reference(), integer()) :: Context.t()
  def new_context(owner, attempt_ref, deadline_us)
      when is_pid(owner) and is_reference(attempt_ref) and is_integer(deadline_us) do
    gate = :atomics.new(3, signed: true)
    :atomics.put(gate, 1, @open_not_started)
    :atomics.put(gate, 2, @timestamp_unset)
    :atomics.put(gate, 3, @timestamp_unset)

    %Context{owner: owner, attempt_ref: attempt_ref, deadline_us: deadline_us, gate: gate}
  end

  @doc false
  @spec install_context(context()) :: :ok
  def install_context(context) do
    Process.put(@dispatch_context_key, context)
    Process.put(@deadline_key, context_deadline(context))
    Process.delete(@terminal_candidate_key)
    :ok
  end

  @doc false
  @spec clear_context() :: :ok
  def clear_context do
    Process.delete(@dispatch_context_key)
    Process.delete(@deadline_key)
    Process.delete(@terminal_candidate_key)
    :ok
  end

  @doc false
  @spec take_terminal_candidate(Context.t()) :: terminal_candidate()
  def take_terminal_candidate(%Context{}) do
    case Process.delete(@terminal_candidate_key) do
      {:candidate, candidate} -> {:ok, candidate}
      {:conflict, candidate} -> {:conflict, candidate}
      nil -> :missing
    end
  end

  @doc false
  @spec close(Context.t()) :: map()
  def close(%Context{gate: gate}) do
    state = close_gate(gate)
    gate_snapshot(gate, state)
  end

  @doc false
  @spec gate_observations([map()], map()) :: [map()]
  def gate_observations(observations, snapshot) do
    observations =
      if snapshot.certainty in [:indeterminate, :dispatched] and
           is_integer(snapshot.started_at_us) and
           not Enum.any?(observations, &(&1.kind == :send_started)) do
        [%{id: -1, kind: :send_started, event_us: snapshot.started_at_us} | observations]
      else
        observations
      end

    if snapshot.certainty == :dispatched and is_integer(snapshot.confirmed_at_us) and
         not Enum.any?(observations, &(&1.kind == :send_confirmed)) do
      [%{id: -2, kind: :send_confirmed, event_us: snapshot.confirmed_at_us} | observations]
    else
      observations
    end
  end

  @spec context() :: context() | nil
  def context, do: Process.get(@dispatch_context_key)

  @spec deadline_us() :: integer() | nil
  def deadline_us, do: Process.get(@deadline_key)

  @spec authorized?(context() | nil, integer() | nil) :: boolean()
  def authorized?(nil, deadline_us), do: before_deadline?(deadline_us)

  def authorized?(%Context{owner: owner, gate: gate}, deadline_us),
    do: Process.alive?(owner) and gate_open?(gate) and before_deadline?(deadline_us)

  def authorized?(_context, deadline_us), do: before_deadline?(deadline_us)

  @spec send_started(context() | nil) :: :ok | {:error, send_start_error()}
  def send_started(context) do
    send_started_at(context, System.monotonic_time(:microsecond))
  end

  @doc false
  @spec send_started_at(context() | nil, integer()) :: :ok | {:error, send_start_error()}
  def send_started_at(context, event_us) when is_integer(event_us) do
    with :ok <- validate_send_start(context, event_us),
         :ok <- record_dispatch_state(context, :ambiguous, event_us) do
      deliver_observation(context, :send_started, event_us, %{})
    end
  end

  @spec send_confirmed(context() | nil) :: :ok
  def send_confirmed(context), do: observe(context, :send_confirmed, %{})

  @spec predispatch_failure(context() | nil, atom()) :: :ok
  def predispatch_failure(context, reason) when is_atom(reason) do
    observe(context, :predispatch_failure, %{reason: predispatch_reason(reason), elapsed_us: 0})
  end

  @spec terminal(context() | nil, atom(), map()) :: :ok
  def terminal(context, kind, fields) when kind in @terminal_kinds and is_map(fields) do
    terminal_at(context, kind, fields, System.monotonic_time(:microsecond))
  end

  @spec terminal_at(context() | nil, atom(), map(), integer()) :: :ok
  def terminal_at(
        context,
        :transport_failure,
        %{certainty: :not_dispatched, reason: reason} = fields,
        event_us
      )
      when is_integer(event_us) do
    observe_at(context, :predispatch_failure, event_us, %{
      reason: transport_predispatch_reason(reason),
      elapsed_us: Map.get(fields, :elapsed_us, 0)
    })
  end

  def terminal_at(context, kind, fields, event_us)
      when kind in @terminal_kinds and is_map(fields) and is_integer(event_us) do
    observe_at(context, kind, event_us, normalize_terminal(kind, fields))
  end

  @spec observe(context() | nil, atom(), map()) :: :ok | {:error, send_start_error()}
  def observe(context, kind, fields),
    do: observe_at(context, kind, System.monotonic_time(:microsecond), fields)

  @spec observe_at(context() | nil, atom(), integer(), map()) ::
          :ok | {:error, send_start_error()}
  def observe_at(context, :send_started, event_us, _fields),
    do: send_started_at(context, event_us)

  def observe_at(context, :send_confirmed, event_us, fields) do
    _result = record_dispatch_state(context, :dispatched, event_us)
    deliver_observation(context, :send_confirmed, event_us, fields)
    :ok
  end

  def observe_at(context, :predispatch_failure, event_us, fields) do
    _result = record_dispatch_state(context, :not_dispatched, event_us)
    deliver_terminal(context, :predispatch_failure, event_us, fields)
  end

  def observe_at(context, kind, event_us, fields)
      when kind in [:response, :invalid_response] do
    _result = record_dispatch_state(context, :dispatched, event_us)
    deliver_terminal(context, kind, event_us, fields)
  end

  def observe_at(context, :transport_failure, event_us, %{certainty: certainty} = fields) do
    shared_certainty =
      case certainty do
        :not_dispatched -> :not_dispatched
        :dispatched -> :dispatched
        :indeterminate -> :ambiguous
      end

    _result = record_dispatch_state(context, shared_certainty, event_us)
    deliver_terminal(context, :transport_failure, event_us, fields)
  end

  def observe_at(context, kind, event_us, fields),
    do: deliver_observation(context, kind, event_us, fields)

  defp deliver_terminal(%Context{}, kind, event_us, fields) do
    candidate = build_context_observation(kind, event_us, fields)

    case Process.get(@terminal_candidate_key) do
      nil -> Process.put(@terminal_candidate_key, {:candidate, candidate})
      {:candidate, ^candidate} -> :ok
      {:candidate, first} -> Process.put(@terminal_candidate_key, {:conflict, first})
      {:conflict, _first} -> :ok
    end

    :ok
  end

  defp deliver_terminal(context, kind, event_us, fields),
    do: deliver_observation(context, kind, event_us, fields)

  defp deliver_observation(nil, _kind, _event_us, _fields), do: :ok

  defp deliver_observation(%Context{}, _kind, _event_us, _fields), do: :ok

  defp deliver_observation({owner, attempt_ref}, kind, event_us, fields)
       when is_pid(owner) and is_reference(attempt_ref) and is_atom(kind) and is_integer(event_us) and
              is_map(fields) do
    send(owner, {:transport_observation, attempt_ref, build_observation(kind, event_us, fields)})
    :ok
  end

  defp build_observation(kind, event_us, fields) do
    build_observation(System.unique_integer([:positive, :monotonic]), kind, event_us, fields)
  end

  defp build_context_observation(kind, event_us, fields) do
    build_observation(context_observation_id(kind), kind, event_us, fields)
  end

  defp build_observation(id, kind, event_us, fields) do
    fields
    |> Map.take([
      :certainty,
      :reason,
      :response_kind,
      :error_code,
      :error_category,
      :retry_after_ms,
      :io_duration_us,
      :elapsed_us,
      :censoring_boundary_us
    ])
    |> Map.merge(%{
      id: id,
      kind: kind,
      event_us: event_us
    })
  end

  defp context_observation_id(:predispatch_failure), do: -10
  defp context_observation_id(:response), do: -11
  defp context_observation_id(:invalid_response), do: -12
  defp context_observation_id(:transport_failure), do: -13

  defp validate_send_start(nil, _event_us), do: :ok

  defp validate_send_start(%Context{owner: owner, deadline_us: deadline_us}, event_us) do
    cond do
      not Process.alive?(owner) -> {:error, :owner_down}
      event_us >= deadline_us -> {:error, :deadline_expired}
      true -> :ok
    end
  end

  defp validate_send_start({owner, _attempt_ref}, event_us) do
    cond do
      not Process.alive?(owner) ->
        {:error, :owner_down}

      not AttemptLifecycle.dispatch_owner_alive?() ->
        {:error, :owner_down}

      deadline = deadline_us() ->
        if(event_us < deadline, do: :ok, else: {:error, :deadline_expired})

      true ->
        :ok
    end
  end

  defp record_dispatch_state(%Context{gate: gate, deadline_us: deadline_us}, certainty, event_us)
       when event_us < deadline_us do
    if System.monotonic_time(:microsecond) < deadline_us do
      transition_gate(gate, certainty, event_us)
    else
      late_dispatch_state_result(certainty)
    end
  end

  defp record_dispatch_state(%Context{}, _certainty, _event_us), do: :ok

  defp record_dispatch_state(_context, certainty, event_us),
    do: AttemptLifecycle.record_dispatch_state(certainty, event_us)

  defp late_dispatch_state_result(:ambiguous), do: {:error, :deadline_expired}
  defp late_dispatch_state_result(_certainty), do: :ok

  defp transition_gate(gate, :ambiguous, event_us) do
    case :atomics.get(gate, 1) do
      @open_not_started ->
        put_timestamp_once(gate, 2, event_us)

        retry_gate(gate, @open_not_started, @open_started, fn gate ->
          transition_gate(gate, :ambiguous, event_us)
        end)

      state when state in [@open_started, @open_confirmed] ->
        :ok

      _closed ->
        {:error, :owner_down}
    end
  end

  defp transition_gate(gate, :dispatched, event_us) do
    if gate_open?(gate) do
      put_timestamp_once(gate, 3, event_us)
      promote_confirmed(gate)
    end

    :ok
  end

  defp transition_gate(gate, :not_dispatched, _event_us) do
    prove_not_dispatched(gate)
    :ok
  end

  defp promote_confirmed(gate) do
    case :atomics.get(gate, 1) do
      @open_confirmed ->
        :ok

      @open_not_started ->
        retry_gate(gate, @open_not_started, @open_confirmed, &promote_confirmed/1)

      @open_started ->
        retry_gate(gate, @open_started, @open_confirmed, &promote_confirmed/1)

      state when state in [@closed_not_started, @closed_started, @closed_confirmed] ->
        :ok
    end
  end

  defp prove_not_dispatched(gate) do
    case :atomics.get(gate, 1) do
      @open_started ->
        retry_gate(gate, @open_started, @open_not_started, &prove_not_dispatched/1)

      _state ->
        :ok
    end
  end

  defp close_gate(gate) do
    case :atomics.get(gate, 1) do
      state when state in [@closed_not_started, @closed_started, @closed_confirmed] ->
        state

      state ->
        case cas_gate(gate, state, state + 3) do
          :ok -> state + 3
          _raced -> close_gate(gate)
        end
    end
  end

  defp retry_gate(gate, expected, desired, retry) do
    case cas_gate(gate, expected, desired) do
      :ok -> :ok
      _raced -> retry.(gate)
    end
  end

  defp cas_gate(gate, expected, desired),
    do: :atomics.compare_exchange(gate, 1, expected, desired)

  defp put_timestamp_once(gate, index, event_us) do
    case :atomics.compare_exchange(gate, index, @timestamp_unset, event_us) do
      :ok -> :ok
      _existing -> :ok
    end
  end

  defp gate_open?(gate), do: :atomics.get(gate, 1) in [0, 1, 2]

  defp gate_snapshot(_gate, @closed_not_started),
    do: %{certainty: :not_dispatched, confirmed_at_us: nil, started_at_us: nil}

  defp gate_snapshot(gate, @closed_started),
    do: %{certainty: :indeterminate, confirmed_at_us: nil, started_at_us: gate_value(gate, 2)}

  defp gate_snapshot(gate, @closed_confirmed) do
    %{
      certainty: :dispatched,
      confirmed_at_us: gate_value(gate, 3),
      started_at_us: gate_value(gate, 2)
    }
  end

  defp gate_value(gate, index) do
    case :atomics.get(gate, index) do
      @timestamp_unset -> nil
      timestamp -> timestamp
    end
  end

  defp context_deadline(%Context{deadline_us: deadline_us}), do: deadline_us
  defp context_deadline(_legacy_context), do: Process.get(@deadline_key)

  defp normalize_terminal(:response, %{response_kind: :error} = fields) do
    fields
    |> Map.put(:response_kind, :application_error)
    |> maybe_normalize_application_error_category()
  end

  defp normalize_terminal(:transport_failure, fields) do
    Map.update!(fields, :reason, &transport_reason/1)
  end

  defp normalize_terminal(_kind, fields), do: fields

  defp maybe_normalize_application_error_category(fields) do
    case Map.fetch(fields, :error_category) do
      {:ok, category} ->
        Map.put(fields, :error_category, canonical_application_error_category(category))

      :error ->
        fields
    end
  end

  defp canonical_application_error_category(:rate_limit), do: :quota

  defp canonical_application_error_category(category)
       when category in [:deterministic, :quota, :capability, :provider_failure],
       do: category

  defp canonical_application_error_category(category) do
    cond do
      ErrorClassification.breaker_penalty?(category) -> :provider_failure
      ErrorClassification.retriable_for_category?(category) -> :capability
      true -> :deterministic
    end
  end

  defp predispatch_reason(reason)
       when reason in [:pool_unavailable, :not_connected, :invalid_frame],
       do: reason

  defp predispatch_reason(:encode_error), do: :encode
  defp predispatch_reason(:request_build_error), do: :request_build

  defp predispatch_reason(reason)
       when reason in [:deadline, :registration_failed, :registration_exit],
       do: :local

  defp predispatch_reason(:stale_connection), do: :not_connected
  defp predispatch_reason(_reason), do: :local

  defp transport_predispatch_reason(reason)
       when reason in [
              :network_error,
              :connection_error,
              :not_connected,
              :closed,
              :tls,
              :dns
            ],
       do: :not_connected

  defp transport_predispatch_reason(reason)
       when reason in [:local_capacity, :pool_unavailable],
       do: :pool_unavailable

  defp transport_predispatch_reason(reason), do: predispatch_reason(reason)

  defp transport_reason(reason) when reason in [:timeout, :closed, :tls, :dns, :protocol],
    do: reason

  defp transport_reason(reason) when reason in [:network_error, :connection_error],
    do: :connection

  defp transport_reason(reason) when reason in [:rate_limited, :server_error, :client_error],
    do: :protocol

  defp transport_reason(_reason), do: :unknown

  defp before_deadline?(nil), do: true
  defp before_deadline?(deadline_us), do: System.monotonic_time(:microsecond) < deadline_us
end
