defmodule Lasso.RPC.ExecutionReducer do
  @moduledoc """
  Pure logical-clock reducer for one authorized attempt.

  Event timestamps are authoritative. An event is eligible only when its stamp
  is strictly before the decision deadline.
  """

  alias Lasso.RPC.AttemptIdentity

  @certainty_rank %{not_dispatched: 0, indeterminate: 1, dispatched: 2}
  @max_observations 16
  @terminal_rank %{
    predispatch_failure: 0,
    task_exit: 1,
    transport_failure: 2,
    cancelled: 3,
    invalid_response: 4,
    response: 5,
    deadline: 6
  }
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

  @enforce_keys [:identity, :deadline_us]
  defstruct @enforce_keys ++
              [
                dispatch_certainty: :not_dispatched,
                terminal: nil,
                terminal_at_us: nil,
                committed: false,
                seen: %{},
                observations: [],
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

  @spec new(AttemptIdentity.t(), integer()) :: t()
  def new(%AttemptIdentity{} = identity, deadline_us) when is_integer(deadline_us) do
    %__MODULE__{identity: identity, deadline_us: deadline_us}
  end

  @spec observe(t(), event()) :: t()
  def observe(%__MODULE__{} = state, %{id: _id, kind: kind, event_us: event_us} = event)
      when kind in @observation_kinds and is_integer(event_us) do
    normalized = normalize(event)

    cond do
      Map.has_key?(state.seen, normalized.id) ->
        diagnose_reused_id(state, normalized)

      state.committed ->
        late(state, event)

      event_us >= state.deadline_us ->
        late(state, event)

      map_size(state.seen) >= @max_observations ->
        bounded_violation(state, normalized, :observation_limit_exceeded)

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

  defp fold(%{terminal: :predispatch_failure} = state, %{kind: kind} = event)
       when kind in [:send_started, :send_confirmed],
       do: violation(state, event, :send_after_predispatch_terminal)

  defp fold(state, %{kind: :send_started}), do: promote(state, :indeterminate)
  defp fold(state, %{kind: :send_confirmed}), do: promote(state, :dispatched)

  defp fold(state, %{kind: :not_dispatched} = event) do
    if state.dispatch_certainty == :not_dispatched do
      state
    else
      violation(state, event, :certainty_regression)
    end
  end

  defp fold(state, %{kind: :response, event_us: event_us}) do
    state |> promote(:dispatched) |> terminal(:response, event_us)
  end

  defp fold(state, %{kind: :invalid_response, event_us: event_us}) do
    state |> promote(:dispatched) |> terminal(:invalid_response, event_us)
  end

  defp fold(state, %{kind: :predispatch_failure, event_us: event_us} = event) do
    if state.dispatch_certainty == :not_dispatched,
      do: terminal(state, :predispatch_failure, event_us),
      else: violation(state, event, :predispatch_after_send)
  end

  defp fold(state, %{kind: kind, event_us: event_us, certainty: certainty})
       when kind in [:transport_failure, :cancelled] do
    state |> promote(certainty) |> terminal(kind, event_us)
  end

  defp fold(state, %{kind: :task_exit, event_us: event_us}) do
    state |> promote(:indeterminate) |> terminal(:transport_failure, event_us)
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

  defp terminal(%__MODULE__{terminal_at_us: nil} = state, kind, event_us),
    do: %{state | terminal: kind, terminal_at_us: event_us}

  defp terminal(%__MODULE__{terminal_at_us: current} = state, kind, event_us)
       when event_us < current,
       do: %{state | terminal: kind, terminal_at_us: event_us}

  defp terminal(%__MODULE__{terminal_at_us: event_us, terminal: current} = state, kind, event_us) do
    if @terminal_rank[kind] > @terminal_rank[current], do: %{state | terminal: kind}, else: state
  end

  defp terminal(state, _kind, _event_us), do: state

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
    %{id: bounded_id(id), kind: kind, event_us: event_us}
    |> maybe_put(:certainty, Map.get(event, :certainty))
  end

  defp bounded_id(id) when is_integer(id), do: id
  defp bounded_id(id) when is_binary(id), do: Lasso.RPC.BoundedIdentifier.encode(id)
  defp bounded_id(_id), do: raise(ArgumentError, "observation id must be an integer or string")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_seen(state, event),
    do: %{state | seen: Map.put(state.seen, event.id, fingerprint(event))}

  defp add_observation(state, event),
    do: %{state | observations: state.observations ++ [event]}

  defp recompute(state) do
    base = %{
      state
      | dispatch_certainty: :not_dispatched,
        terminal: nil,
        terminal_at_us: nil,
        protocol_violations: state.sticky_violations
    }

    state.observations
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

  defp fingerprint(event), do: {event.kind, event.event_us, Map.get(event, :certainty)}

  defp diagnose_reused_id(state, event) do
    if state.seen[event.id] == fingerprint(event),
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
