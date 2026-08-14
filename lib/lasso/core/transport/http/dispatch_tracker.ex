defmodule Lasso.Core.Transport.HTTP.DispatchTracker do
  @moduledoc false

  use GenServer

  alias Lasso.Core.Transport.AttemptProtocol

  @table :lasso_http_dispatch_tracker
  @handler_id "lasso-finch-dispatch-tracker"
  @failure_handler_id "lasso-finch-dispatch-tracker-failures"
  @dispatch_events [[:finch, :send, :start], [:finch, :send, :stop]]
  @failure_event [:telemetry, :handler, :failure]
  @session_key :lasso_finch_dispatch_session
  @audit_interval_ms 1_000

  @type token :: reference()
  @type dispatch_state :: :not_started | :started | :confirmed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec ready?() :: boolean()
  def ready?, do: match?({:ok, _token}, ready_token())

  @spec ready_token() :: {:ok, token()} | {:error, :unavailable}
  def ready_token do
    case :ets.lookup(@table, :ready) do
      [{:ready, token}] when is_reference(token) -> {:ok, token}
      _ -> {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @spec status() :: map()
  def status do
    case :ets.lookup(@table, :status) do
      [{:status, status}] -> status
      _ -> %{ready?: false, degraded_count: 0, reason: :unavailable}
    end
  rescue
    ArgumentError -> %{ready?: false, degraded_count: 0, reason: :unavailable}
  end

  @spec audit_now() :: :ok | {:error, :unavailable}
  def audit_now do
    GenServer.call(__MODULE__, :audit)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec begin_attempt(AttemptProtocol.context() | nil, token() | nil) :: :ok
  def begin_attempt(nil, _token), do: :ok

  def begin_attempt(context, token) when is_reference(token) do
    Process.put(@session_key, %{
      context: context,
      token: token,
      state: :not_started,
      protocol_open?: false
    })

    :ok
  end

  @spec open_send(AttemptProtocol.context() | nil, token() | nil) ::
          :ok | {:error, AttemptProtocol.send_start_error()}
  def open_send(nil, _token), do: :ok

  def open_send(context, token) when is_reference(token) do
    with :ok <- AttemptProtocol.send_started(context) do
      case Process.get(@session_key) do
        %{context: ^context, token: ^token} = session ->
          Process.put(@session_key, %{session | protocol_open?: true})

        _ ->
          :ok
      end

      :ok
    end
  end

  @spec attempt_state(AttemptProtocol.context() | nil) :: dispatch_state()
  def attempt_state(nil), do: :not_started

  def attempt_state(context) do
    case Process.get(@session_key) do
      %{context: ^context, state: state} -> state
      _ -> :not_started
    end
  end

  @spec clear_attempt(AttemptProtocol.context() | nil) :: :ok
  def clear_attempt(nil), do: :ok

  def clear_attempt(_context) do
    Process.delete(@session_key)
    :ok
  end

  @spec session_healthy?(token()) :: boolean()
  def session_healthy?(token) when is_reference(token) do
    Process.whereis(__MODULE__) != nil and exact_attachment?(token)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    token = make_ref()
    audit_interval_ms = Keyword.get(opts, :audit_interval_ms, @audit_interval_ms)
    state = %{token: token, degraded_count: 0, audit_interval_ms: audit_interval_ms}

    reclaim_handlers()

    case attach_handlers(token) do
      :ok ->
        publish_status(table, state, true, nil)
        schedule_audit(audit_interval_ms)
        {:ok, state}

      {:error, reason} ->
        publish_status(table, state, false, reason)
        reclaim_handlers()
        {:stop, {:dispatch_tracker_attach_failed, reason}}
    end
  end

  @impl true
  def handle_call(:audit, _from, state) do
    {result, state} = audit_attachment(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:audit, state) do
    {_result, state} = audit_attachment(state)
    schedule_audit(state.audit_interval_ms)
    {:noreply, state}
  end

  def handle_info({:handler_failed, token}, %{token: token} = state) do
    {_result, state} = repair_attachment(state, :handler_failed)
    {:noreply, state}
  end

  def handle_info({:handler_failed, _stale_token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    reclaim_handlers()
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event([:finch, :send, :start], _measurements, metadata, %{token: token}) do
    with %{request: %{private: private}} <- metadata,
         context when not is_nil(context) <- Map.get(private, :lasso_attempt) do
      if mark_started(context, token), do: AttemptProtocol.send_started(context)
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_event([:finch, :send, :stop], _measurements, metadata, %{token: token}) do
    with false <- Map.has_key?(metadata, :error),
         %{request: %{private: private}} <- metadata,
         context when not is_nil(context) <- Map.get(private, :lasso_attempt) do
      update_attempt(context, token, :confirmed)
      AttemptProtocol.send_confirmed(context)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  @spec handle_failure_event([atom()], map(), map(), map()) :: :ok
  def handle_failure_event([:telemetry, :handler, :failure], _measurements, metadata, %{
        token: token
      }) do
    if Map.get(metadata, :handler_id) == @handler_id do
      send(__MODULE__, {:handler_failed, token})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp update_attempt(context, _token, state) do
    case Process.get(@session_key) do
      %{context: ^context} = session ->
        Process.put(@session_key, %{session | state: promote_state(session.state, state)})

      _ ->
        :ok
    end
  end

  defp mark_started(context, _token) do
    case Process.get(@session_key) do
      %{context: ^context} = session ->
        Process.put(@session_key, %{
          session
          | state: promote_state(session.state, :started),
            protocol_open?: true
        })

        not session.protocol_open?

      _ ->
        true
    end
  end

  defp audit_attachment(state) do
    if exact_attachment?(state.token) do
      publish_status(@table, state, true, nil)
      {:ok, state}
    else
      repair_attachment(state, :attachment_mismatch)
    end
  end

  defp repair_attachment(state, reason) do
    degraded_state = %{
      state
      | token: make_ref(),
        degraded_count: state.degraded_count + 1
    }

    publish_status(@table, degraded_state, false, reason)
    emit_degraded(degraded_state, reason)
    reclaim_handlers()

    case attach_handlers(degraded_state.token) do
      :ok ->
        publish_status(@table, degraded_state, true, :recovered)
        {:ok, degraded_state}

      {:error, attach_reason} ->
        publish_status(@table, degraded_state, false, attach_reason)
        {{:error, attach_reason}, degraded_state}
    end
  end

  defp attach_handlers(token) do
    config = %{token: token}

    with :ok <-
           :telemetry.attach_many(
             @handler_id,
             @dispatch_events,
             &__MODULE__.handle_event/4,
             config
           ),
         :ok <-
           :telemetry.attach(
             @failure_handler_id,
             @failure_event,
             &__MODULE__.handle_failure_event/4,
             config
           ),
         true <- exact_attachment?(token) do
      :ok
    else
      false -> {:error, :attachment_validation_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_attachment?(token) do
    dispatch_config = %{token: token}

    dispatch_ok? =
      Enum.all?(@dispatch_events, fn event ->
        exact_handler?(
          event,
          @handler_id,
          &__MODULE__.handle_event/4,
          dispatch_config
        )
      end)

    dispatch_ok? and
      exact_handler?(
        @failure_event,
        @failure_handler_id,
        &__MODULE__.handle_failure_event/4,
        dispatch_config
      )
  end

  defp exact_handler?(event, id, function, config) do
    Enum.any?(:telemetry.list_handlers(event), fn handler ->
      handler.id == id and handler.function == function and handler.config == config and
        handler.event_name == event
    end)
  end

  defp reclaim_handlers do
    :telemetry.detach(@handler_id)
    :telemetry.detach(@failure_handler_id)
  end

  defp publish_status(table, state, ready?, reason) do
    if ready? do
      :ets.insert(table, {:ready, state.token})
    else
      :ets.delete(table, :ready)
    end

    :ets.insert(table, {
      :status,
      %{
        ready?: ready?,
        degraded_count: state.degraded_count,
        reason: reason,
        incarnation: state.token
      }
    })
  rescue
    ArgumentError -> :ok
  end

  defp emit_degraded(state, reason) do
    :telemetry.execute(
      [:lasso, :finch, :dispatch_tracker, :degraded],
      %{count: 1},
      %{reason: reason, degraded_count: state.degraded_count}
    )
  end

  defp schedule_audit(:infinity), do: :ok
  defp schedule_audit(interval_ms), do: Process.send_after(self(), :audit, interval_ms)

  defp promote_state(:confirmed, _state), do: :confirmed
  defp promote_state(_state, :confirmed), do: :confirmed
  defp promote_state(:started, _state), do: :started
  defp promote_state(_state, :started), do: :started
end
