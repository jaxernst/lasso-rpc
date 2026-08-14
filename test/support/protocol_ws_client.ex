defmodule TestSupport.ProtocolWSClient do
  @moduledoc false

  use GenServer

  def start_link(url, handler, handler_state, opts \\ []) do
    GenServer.start_link(__MODULE__, {url, handler, handler_state, opts})
  end

  def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame}, :infinity)
  def cast(pid, message), do: GenServer.cast(pid, {:websockex_cast, message})

  def acknowledge(pid, transport_id, raw_response \\ nil) do
    GenServer.call(pid, {:acknowledge, transport_id, raw_response})
  end

  def fail(pid, transport_id, reason) do
    GenServer.call(pid, {:fail, transport_id, reason})
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
       sends: %{}
     }}
  end

  @impl true
  def handle_cast({:websockex_cast, message}, state) do
    case state.handler.handle_cast(message, state.handler_state) do
      {:reply, frame, handler_state} ->
        state = %{state | handler_state: handler_state}
        {:noreply, record_outbound_frame(frame, state)}

      {:ok, handler_state} ->
        {:noreply, %{state | handler_state: handler_state}}
    end
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

  def handle_call({:fail, transport_id, reason}, _from, state) do
    {send_entry, sends} = Map.pop(state.sends, transport_id)
    true = not is_nil(send_entry)
    if is_tuple(send_entry), do: GenServer.reply(send_entry, {:error, reason})
    {:reply, :ok, %{state | sends: sends}}
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

  defp record_outbound_frame({:text, payload}, state) do
    %{"id" => transport_id} = Jason.decode!(payload)
    send(state.controller, {:protocol_ws_send, self(), transport_id, payload})
    state = %{state | sends: Map.put(state.sends, transport_id, payload)}

    case state.mode do
      :auto_success ->
        raw_response =
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => transport_id, "result" => "0x1"})

        {:ok, handler_state} =
          state.handler.handle_frame({:text, raw_response}, state.handler_state)

        %{state | handler_state: handler_state}

      _other ->
        state
    end
  end

  defp record_outbound_frame(frame, state) do
    send(state.controller, {:protocol_ws_control_send, self(), frame})
    state
  end
end
