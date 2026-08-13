defmodule Lasso.RPC.ExecutionReducer do
  @moduledoc """
  Pure logical-clock reducer for one authorized attempt.

  Event timestamps are authoritative. An event is eligible only when its stamp
  is strictly before the decision deadline.
  """

  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal}

  @certainty_rank %{not_dispatched: 0, indeterminate: 1, dispatched: 2}
  @max_observations 16
  @observation_kinds [
    :send_started,
    :send_confirmed,
    :not_dispatched,
    :response,
    :invalid_response,
    :transport_failure,
    :predispatch_failure,
    :cancelled,
    :task_exit
  ]

  @enforce_keys [:identity, :started_us, :deadline_us]
  defstruct @enforce_keys ++
              [
                dispatch_certainty: :not_dispatched,
                terminal: nil,
                terminal_at_us: nil,
                terminal_event: nil,
                committed: false,
                seen: %{},
                observations: %{},
                late_observations: [],
                protocol_violations: [],
                sticky_violations: []
              ]

  @type t :: %__MODULE__{}
  @type event :: %{
          required(:id) => term(),
          required(:kind) => atom(),
          required(:event_us) => integer()
        }

  @spec new(AttemptIdentity.t(), integer(), integer()) :: t()
  def new(%AttemptIdentity{} = identity, started_us, deadline_us)
      when is_integer(started_us) and is_integer(deadline_us) and deadline_us >= started_us do
    %__MODULE__{identity: identity, started_us: started_us, deadline_us: deadline_us}
  end

  @spec observe(t(), event()) :: t()
  def observe(%__MODULE__{} = state, %{id: _id, kind: kind, event_us: event_us} = event)
      when kind in @observation_kinds and is_integer(event_us) do
    normalized = normalize(event)

    cond do
      existing_event(state, normalized.id) ->
        diagnose_reused_id(state, normalized)

      state.committed ->
        late(state, event)

      event_us >= state.deadline_us ->
        late(state, event)

      true ->
        state |> put_seen(normalized) |> add_observation(normalized) |> recompute()
    end
  end

  def observe(%__MODULE__{}, event),
    do: raise(ArgumentError, "invalid observation: #{inspect(event)}")

  @spec close_deadline(t()) :: t()
  def close_deadline(%__MODULE__{terminal: nil} = state) do
    %{state | terminal: :deadline, terminal_at_us: state.deadline_us, committed: true}
  end

  def close_deadline(state), do: commit(state)

  @spec commit(t()) :: t()
  def commit(%__MODULE__{terminal: nil}),
    do: raise(ArgumentError, "cannot commit without a terminal")

  def commit(%__MODULE__{} = state), do: %{state | committed: true}

  @spec eligible?(t(), integer()) :: boolean()
  def eligible?(%__MODULE__{deadline_us: deadline_us}, event_us), do: event_us < deadline_us

  @spec terminal_fact(t()) :: AttemptTerminal.t()
  def terminal_fact(%__MODULE__{terminal: :response, terminal_event: event, identity: identity}) do
    opts =
      []
      |> maybe_option(:error_code, event)
      |> maybe_option(:error_category, event)
      |> maybe_option(:retry_after_ms, event)

    AttemptTerminal.Response.new(identity, event.response_kind, event.io_duration_us, opts)
  end

  def terminal_fact(%__MODULE__{
        terminal: :invalid_response,
        terminal_event: event,
        identity: identity
      }),
      do: AttemptTerminal.InvalidResponse.new(identity, event.reason, event.io_duration_us)

  def terminal_fact(%__MODULE__{
        terminal: :predispatch_failure,
        terminal_event: event,
        identity: identity
      }),
      do: AttemptTerminal.PredispatchFailure.new(identity, event.reason, event.elapsed_us)

  def terminal_fact(%__MODULE__{
        terminal: :transport_failure,
        terminal_event: %{kind: :task_exit},
        identity: identity
      }),
      do: AttemptTerminal.TransportFailure.new(identity, :unknown, :indeterminate)

  def terminal_fact(%__MODULE__{
        terminal: :transport_failure,
        terminal_event: event,
        identity: identity
      }) do
    opts = maybe_option([], :io_duration_us, event)
    AttemptTerminal.TransportFailure.new(identity, event.reason, event.certainty, opts)
  end

  def terminal_fact(%__MODULE__{terminal: :cancelled, terminal_event: event, identity: identity}),
    do:
      AttemptTerminal.Cancelled.new(
        identity,
        event.reason,
        event.certainty,
        event.censoring_boundary_us
      )

  def terminal_fact(%__MODULE__{
        terminal: :deadline,
        identity: identity,
        dispatch_certainty: certainty,
        started_us: started_us,
        deadline_us: deadline_us
      }),
      do:
        AttemptTerminal.Deadline.new(
          identity,
          certainty,
          if(certainty == :not_dispatched, do: 0, else: deadline_us - started_us)
        )

  def terminal_fact(%__MODULE__{}),
    do: raise(ArgumentError, "cannot materialize without a terminal")

  defp maybe_option(options, key, event) do
    case Map.fetch(event, key) do
      {:ok, value} -> Keyword.put(options, key, value)
      :error -> options
    end
  end

  defp fold(%{terminal: terminal} = state, %{kind: kind, event_us: event_us} = event)
       when not is_nil(terminal) and kind in [:response, :invalid_response] do
    state = promote(state, :dispatched)
    state = %{state | terminal: kind, terminal_at_us: event_us, terminal_event: event}
    violation(state, event, :observation_after_terminal)
  end

  defp fold(%{terminal: terminal} = state, event) when not is_nil(terminal) do
    certainty = event_certainty(event)
    state = if certainty, do: promote(state, certainty), else: state
    violation(state, event, :observation_after_terminal)
  end

  defp fold(state, %{kind: :send_started}), do: promote(state, :indeterminate)
  defp fold(state, %{kind: :send_confirmed}), do: promote(state, :dispatched)

  defp fold(state, %{kind: :not_dispatched} = event) do
    if state.dispatch_certainty == :not_dispatched do
      state
    else
      violation(state, event, :certainty_regression)
    end
  end

  defp fold(state, %{kind: :response, event_us: event_us} = event) do
    state |> promote(:dispatched) |> terminal(:response, event_us, event)
  end

  defp fold(state, %{kind: :invalid_response, event_us: event_us} = event) do
    state |> promote(:dispatched) |> terminal(:invalid_response, event_us, event)
  end

  defp fold(state, %{kind: :predispatch_failure, event_us: event_us} = event) do
    if state.dispatch_certainty == :not_dispatched,
      do: terminal(state, :predispatch_failure, event_us, event),
      else: violation(state, event, :predispatch_after_send)
  end

  defp fold(state, %{kind: kind, event_us: event_us, certainty: certainty} = event)
       when kind in [:transport_failure, :cancelled] do
    if @certainty_rank[certainty] < @certainty_rank[state.dispatch_certainty] do
      violation(state, event, :certainty_regression)
    else
      state |> promote(certainty) |> terminal(kind, event_us, event)
    end
  end

  defp fold(state, %{kind: :task_exit, event_us: event_us} = event) do
    state |> promote(:indeterminate) |> terminal(:transport_failure, event_us, event)
  end

  defp fold(_state, event),
    do: raise(ArgumentError, "observation lacks required fields: #{inspect(event)}")

  defp promote(state, certainty) do
    unless Map.has_key?(@certainty_rank, certainty),
      do: raise(ArgumentError, "invalid dispatch certainty: #{inspect(certainty)}")

    if @certainty_rank[certainty] > @certainty_rank[state.dispatch_certainty],
      do: %{state | dispatch_certainty: certainty},
      else: state
  end

  defp terminal(state, kind, event_us, event),
    do: %{state | terminal: kind, terminal_at_us: event_us, terminal_event: event}

  defp late(state, event) do
    event = normalize(event)

    if map_size(state.seen) >= @max_observations do
      bounded_violation(state, event, :observation_limit_exceeded)
    else
      %{
        state
        | late_observations: append_bounded(state.late_observations, event),
          seen: Map.put(state.seen, event.id, fingerprint(event))
      }
    end
  end

  defp violation(state, event, reason) do
    %{
      state
      | protocol_violations:
          state.protocol_violations ++ [%{reason: reason, event: normalize(event)}]
    }
  end

  defp normalize(%{id: id, kind: kind, event_us: event_us} = event) do
    base = %{id: bounded_id(id), kind: kind, event_us: bounded_integer(event_us, :event_us)}

    normalized =
      Enum.reduce(
        [
          :certainty,
          :reason,
          :response_kind,
          :error_code,
          :error_category,
          :retry_after_ms,
          :io_duration_us,
          :elapsed_us,
          :censoring_boundary_us
        ],
        base,
        fn key, acc ->
          case Map.fetch(event, key) do
            {:ok, value} -> Map.put(acc, key, bounded_metadata(key, value))
            :error -> acc
          end
        end
      )

    validate_observation!(normalized)
  end

  defp bounded_id(id) when is_integer(id), do: bounded_integer(id, :id)
  defp bounded_id(id) when is_binary(id), do: Lasso.RPC.BoundedIdentifier.encode(id)
  defp bounded_id(_id), do: raise(ArgumentError, "observation id must be an integer or string")

  defp bounded_integer(value, _field)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: value

  defp bounded_integer(_value, field), do: raise(ArgumentError, "invalid #{field}")

  defp bounded_metadata(:certainty, value)
       when value in [:not_dispatched, :indeterminate, :dispatched],
       do: value

  defp bounded_metadata(:error_code, value)
       when is_integer(value) and value in -2_147_483_648..2_147_483_647,
       do: value

  defp bounded_metadata(key, value)
       when key in [:io_duration_us, :elapsed_us, :censoring_boundary_us, :retry_after_ms] do
    value = bounded_integer(value, key)
    if value < 0, do: raise(ArgumentError, "invalid #{key}"), else: value
  end

  defp bounded_metadata(_key, value) when is_atom(value), do: value

  defp bounded_metadata(key, value) when is_binary(value),
    do: Lasso.RPC.ExecutionFact.bounded!(value, key)

  defp bounded_metadata(key, _value), do: raise(ArgumentError, "invalid #{key}")

  defp validate_observation!(%{kind: :response, response_kind: kind, io_duration_us: _} = event)
       when kind in [:success, :application_error],
       do: event

  defp validate_observation!(
         %{kind: :invalid_response, reason: reason, io_duration_us: _} = event
       )
       when reason in [
              :invalid_json,
              :invalid_envelope,
              :unsupported_version,
              :id_mismatch,
              :unexpected_notification,
              :unexpected_batch
            ],
       do: event

  defp validate_observation!(%{kind: :predispatch_failure, reason: reason, elapsed_us: _} = event)
       when reason in [
              :encode,
              :request_build,
              :pool_unavailable,
              :not_connected,
              :invalid_frame,
              :local
            ],
       do: event

  defp validate_observation!(
         %{kind: :transport_failure, reason: reason, certainty: certainty} = event
       )
       when reason in [
              :connection,
              :closed,
              :timeout,
              :protocol,
              :tls,
              :dns,
              :local_capacity,
              :unknown
            ] and certainty in [:indeterminate, :dispatched],
       do: event

  defp validate_observation!(
         %{kind: :cancelled, reason: reason, certainty: certainty, censoring_boundary_us: _} =
           event
       )
       when reason in [:caller_abandoned, :socket_closed, :owner_shutdown, :superseded] and
              certainty in [:not_dispatched, :indeterminate, :dispatched],
       do: event

  defp validate_observation!(%{kind: kind} = event)
       when kind in [:send_started, :send_confirmed, :not_dispatched, :task_exit],
       do: event

  defp validate_observation!(event),
    do: raise(ArgumentError, "observation lacks legal metadata: #{inspect(event)}")

  defp put_seen(%{seen: seen} = state, event) when map_size(seen) < @max_observations,
    do: %{state | seen: Map.put(seen, event.id, fingerprint(event))}

  defp put_seen(state, _event), do: state

  defp add_observation(state, event) do
    observations =
      Map.update(state.observations, event.kind, event, fn current ->
        if event_key(event) < event_key(current), do: event, else: current
      end)

    %{state | observations: observations}
  end

  defp recompute(state) do
    base = %{
      state
      | dispatch_certainty: :not_dispatched,
        terminal: nil,
        terminal_at_us: nil,
        terminal_event: nil,
        protocol_violations: state.sticky_violations
    }

    state.observations
    |> Map.values()
    |> Enum.sort_by(fn event -> {event.event_us, event_order(event.kind)} end)
    |> Enum.reduce(base, &fold(&2, &1))
  end

  defp event_order(:send_started), do: 0
  defp event_order(:send_confirmed), do: 1
  defp event_order(:not_dispatched), do: 2
  defp event_order(:predispatch_failure), do: 3
  defp event_order(:task_exit), do: 4
  defp event_order(:transport_failure), do: 5
  defp event_order(:cancelled), do: 6
  defp event_order(:invalid_response), do: 7
  defp event_order(:response), do: 8

  defp fingerprint(event), do: event

  defp event_key(event),
    do: {event.event_us, event_order(event.kind), :erlang.term_to_binary(event)}

  defp existing_event(state, id) do
    case Map.fetch(state.seen, id) do
      {:ok, event} -> event
      :error -> Enum.find(Map.values(state.observations), &(&1.id == id))
    end
  end

  defp event_certainty(%{kind: kind})
       when kind in [:response, :invalid_response, :send_confirmed],
       do: :dispatched

  defp event_certainty(%{kind: :send_started}), do: :indeterminate
  defp event_certainty(%{certainty: certainty}), do: certainty
  defp event_certainty(_event), do: nil

  defp diagnose_reused_id(state, event) do
    if existing_event(state, event.id) == fingerprint(event),
      do: state,
      else: bounded_violation(state, event, :observation_id_reused)
  end

  defp bounded_violation(state, event, reason) do
    violation = %{reason: reason, event: normalize(event)}
    sticky = append_bounded(state.sticky_violations, violation)
    combined = Enum.take(sticky ++ state.protocol_violations, @max_observations)
    %{state | sticky_violations: sticky, protocol_violations: combined}
  end

  defp append_bounded(items, item) do
    if length(items) < @max_observations, do: [item | items], else: items
  end
end
