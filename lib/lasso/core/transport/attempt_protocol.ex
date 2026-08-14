defmodule Lasso.Core.Transport.AttemptProtocol do
  @moduledoc false

  alias Lasso.Core.Support.AttemptLifecycle

  @type context :: {pid(), reference()}
  @type certainty :: :not_dispatched | :indeterminate | :dispatched
  @type send_start_error :: :deadline_expired | :owner_down

  @terminal_kinds [:predispatch_failure, :response, :invalid_response, :transport_failure]

  @spec context() :: context() | nil
  def context, do: AttemptLifecycle.dispatch_context()

  @spec deadline_us() :: integer() | nil
  def deadline_us, do: AttemptLifecycle.deadline_us()

  @spec authorized?(context() | nil, integer() | nil) :: boolean()
  def authorized?(nil, deadline_us), do: before_deadline?(deadline_us)
  def authorized?(_context, deadline_us), do: before_deadline?(deadline_us)

  @spec send_started(context() | nil) :: :ok | {:error, send_start_error()}
  def send_started(context) do
    send_started_at(context, System.monotonic_time(:microsecond))
  end

  @doc false
  @spec send_started_at(context() | nil, integer()) :: :ok | {:error, send_start_error()}
  def send_started_at(context, event_us) when is_integer(event_us) do
    with :ok <- validate_send_start(context, event_us),
         :ok <- AttemptLifecycle.record_dispatch_state(:ambiguous, event_us) do
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
    _result = AttemptLifecycle.record_dispatch_state(:dispatched, event_us)
    deliver_observation(context, :send_confirmed, event_us, fields)
    :ok
  end

  def observe_at(context, :predispatch_failure, event_us, fields) do
    _result = AttemptLifecycle.record_dispatch_state(:not_dispatched, event_us)
    deliver_observation(context, :predispatch_failure, event_us, fields)
  end

  def observe_at(context, kind, event_us, fields)
      when kind in [:response, :invalid_response] do
    _result = AttemptLifecycle.record_dispatch_state(:dispatched, event_us)
    deliver_observation(context, kind, event_us, fields)
  end

  def observe_at(context, :transport_failure, event_us, %{certainty: certainty} = fields) do
    shared_certainty =
      case certainty do
        :not_dispatched -> :not_dispatched
        :dispatched -> :dispatched
        :indeterminate -> :ambiguous
      end

    _result = AttemptLifecycle.record_dispatch_state(shared_certainty, event_us)
    deliver_observation(context, :transport_failure, event_us, fields)
  end

  def observe_at(context, kind, event_us, fields),
    do: deliver_observation(context, kind, event_us, fields)

  defp deliver_observation(nil, _kind, _event_us, _fields), do: :ok

  defp deliver_observation({owner, attempt_ref}, kind, event_us, fields)
       when is_pid(owner) and is_reference(attempt_ref) and is_atom(kind) and is_integer(event_us) and
              is_map(fields) do
    observation =
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
        id: System.unique_integer([:positive, :monotonic]),
        kind: kind,
        event_us: event_us
      })

    send(owner, {:transport_observation, attempt_ref, observation})
    :ok
  end

  defp validate_send_start(nil, _event_us), do: :ok

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

  defp normalize_terminal(:response, %{response_kind: :error} = fields),
    do: %{fields | response_kind: :application_error}

  defp normalize_terminal(:transport_failure, fields) do
    Map.update!(fields, :reason, &transport_reason/1)
  end

  defp normalize_terminal(_kind, fields), do: fields

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
