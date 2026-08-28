defmodule TestSupport.ProtocolWSClient do
  @moduledoc false

  use GenServer

  def start_link(url, handler, handler_state, opts \\ []) do
    GenServer.start_link(__MODULE__, {url, handler, handler_state, opts})
  end

  def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame}, :infinity)
  def cast(pid, message), do: GenServer.cast(pid, {:client_cast, message})

  def acknowledge(pid, transport_id, raw_response \\ nil) do
    GenServer.call(pid, {:acknowledge, transport_id, raw_response})
  end

  def emit_raw(pid, raw_response), do: GenServer.call(pid, {:emit_raw, raw_response})

  def disconnect(pid, reason \\ :closed), do: GenServer.call(pid, {:disconnect, reason})

  @impl true
  def init({_url, handler, handler_state, _opts}) do
    controller = Application.fetch_env!(:lasso, :protocol_ws_test_owner)
    mode = Application.get_env(:lasso, :protocol_ws_send_mode, :manual)
    {:ok, connected_state} = handler.handle_connect(%{}, handler_state)
    send(controller, {:protocol_ws_connected, self(), connected_state.connection_generation})

    {:ok,
     %{
       controller: controller,
       handler: handler,
       handler_state: connected_state,
       mode: mode,
       sends: %{},
       successful_writes: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:client_cast, message}, state) do
    case state.handler.handle_cast(message, state.handler_state) do
      {:reply, frame, handler_state} ->
        state = %{state | handler_state: handler_state}

        case complete_cast_write(message, frame, state) do
          {:ok, state} ->
            {:noreply, state}

          {:error, reason, state} ->
            fail_cast_write(message, frame, reason, state)
        end

      {:ok, handler_state} ->
        {:noreply, %{state | handler_state: handler_state}}
    end
  end

  @impl true
  def handle_info({:lasso_ws_send_written, generation, send_key} = message, state) do
    write_key = {generation, send_key}

    if MapSet.member?(state.successful_writes, write_key) do
      {:ok, handler_state} = state.handler.handle_info(message, state.handler_state)

      {:noreply,
       %{
         state
         | handler_state: handler_state,
           successful_writes: MapSet.delete(state.successful_writes, write_key)
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info({:protocol_auto_response, transport_id}, state) do
    raw_response =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => transport_id, "result" => "0x1"})

    {:ok, handler_state} =
      state.handler.handle_frame({:text, raw_response}, state.handler_state)

    {:noreply, %{state | handler_state: handler_state}}
  end

  @impl true
  def handle_call({:send_frame, {:text, payload}}, from, state) do
    %{"id" => transport_id} = Jason.decode!(payload)
    send(state.controller, {:protocol_ws_send, self(), transport_id, payload})

    case state.mode do
      :manual ->
        {:noreply, %{state | sends: Map.put(state.sends, transport_id, from)}}

      :auto_success ->
        raw_response =
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => transport_id, "result" => "0x1"})

        {:ok, handler_state} =
          state.handler.handle_frame({:text, raw_response}, state.handler_state)

        sync_connection(handler_state)
        {:reply, :ok, %{state | handler_state: handler_state}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_frame, _frame}, _from, state), do: {:reply, :ok, state}

  def handle_call({:acknowledge, transport_id, raw_response}, _from, state) do
    {send_entry, sends} = Map.pop(state.sends, transport_id)
    true = not is_nil(send_entry)

    if is_tuple(send_entry), do: GenServer.reply(send_entry, :ok)

    state = %{state | sends: sends}

    case raw_response do
      nil ->
        {:reply, :ok, state}

      raw_response ->
        {:ok, handler_state} =
          state.handler.handle_frame({:text, raw_response}, state.handler_state)

        sync_connection(handler_state)
        {:reply, :ok, %{state | handler_state: handler_state}}
    end
  end

  def handle_call({:emit_raw, raw_response}, _from, state) do
    {:ok, handler_state} = state.handler.handle_frame({:text, raw_response}, state.handler_state)
    sync_connection(handler_state)
    {:reply, :ok, %{state | handler_state: handler_state}}
  end

  def handle_call({:disconnect, reason}, _from, state) do
    {:ok, handler_state} = state.handler.handle_disconnect(%{reason: reason}, state.handler_state)
    sync_connection(handler_state)
    {:reply, :ok, %{state | handler_state: handler_state}}
  end

  defp sync_connection(handler_state) do
    GenServer.call(handler_state.parent, :status)
  end

  defp complete_cast_write(message, frame, state) do
    case maybe_pause_before_write(frame, state) do
      {:ok, state} ->
        case state.mode do
          {:error, reason} ->
            {:error, reason, state}

          _other ->
            state = record_outbound_frame(frame, state)
            {:ok, mark_write_success(message, state)}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp fail_cast_write(message, frame, reason, state) do
    :ok = drop_post_write_ack(message)
    send(state.controller, {:protocol_ws_write_failed, self(), frame_id(frame), reason})

    {:ok, handler_state} =
      state.handler.handle_disconnect(%{reason: {:error, reason}}, state.handler_state)

    {:stop, {:socket_write_error, reason}, %{state | handler_state: handler_state}}
  end

  defp mark_write_success(
         {:send_if_live, generation, send_key, _deadline_us, _cancel_latch, _frame},
         state
       ) do
    %{state | successful_writes: MapSet.put(state.successful_writes, {generation, send_key})}
  end

  defp drop_post_write_ack(
         {:send_if_live, generation, send_key, _deadline_us, _cancel_latch, _frame}
       ) do
    receive do
      {:lasso_ws_send_written, ^generation, ^send_key} -> :ok
    after
      0 -> raise "missing queued post-write acknowledgement"
    end
  end

  defp frame_id({:text, payload}) do
    %{"id" => transport_id} = Jason.decode!(payload)
    transport_id
  end

  defp frame_id(_frame), do: nil

  defp record_outbound_frame({:text, payload}, state) do
    %{"id" => transport_id} = Jason.decode!(payload)
    send(state.controller, {:protocol_ws_send, self(), transport_id, payload})
    state = %{state | sends: Map.put(state.sends, transport_id, payload)}

    case state.mode do
      :auto_success ->
        send(self(), {:protocol_auto_response, transport_id})
        state

      _other ->
        state
    end
  end

  defp record_outbound_frame(frame, state) do
    send(state.controller, {:protocol_ws_control_send, self(), frame})
    state
  end

  defp maybe_pause_before_write({:text, payload}, %{mode: :pause_before_write} = state) do
    %{"id" => transport_id} = Jason.decode!(payload)

    send(
      state.controller,
      {:protocol_ws_accepted_before_write, self(), transport_id, payload}
    )

    receive do
      :resume_protocol_ws_write -> {:ok, state}
      {:fail_protocol_ws_write, reason} -> {:error, reason, state}
    end
  end

  defp maybe_pause_before_write(_frame, state), do: {:ok, state}
end
