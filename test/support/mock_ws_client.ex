defmodule TestSupport.MockWSClient do
  @moduledoc """
  Test-only fake WebSocket client with the same minimal interface used by WSConnection.

  It simulates connect/frames by messaging the WSConnection parent via the WSHandler contract.
  """

  use GenServer

  # Public API mimicking WebSockex - moved to later in file for proper grouping

  def send_frame(pid, frame) do
    GenServer.call(pid, {:send_frame, frame})
  end

  # Test helpers for simulating various WebSocket behaviors
  def emit_message(pid, json_map) when is_map(json_map) do
    GenServer.cast(pid, {:emit_message, json_map})
  end

  def close(pid, code \\ 1000, reason \\ "normal") do
    GenServer.cast(pid, {:close, code, reason})
  end

  def disconnect(pid, reason \\ :normal) do
    GenServer.cast(pid, {:disconnect, reason})
  end

  def simulate_connection_failure(pid, error) do
    GenServer.cast(pid, {:simulate_connection_failure, error})
  end

  def force_crash(pid, reason \\ :test_crash) do
    GenServer.cast(pid, {:force_crash, reason})
  end

  def set_failure_mode(pid, mode) when mode in [:fail_sends, :fail_pings, :normal] do
    GenServer.cast(pid, {:set_failure_mode, mode})
  end

  def set_response_delay(pid, delay_ms) do
    GenServer.cast(pid, {:set_response_delay, delay_ms})
  end

  def set_response_mode(pid, mode) when mode in [:result, :error] do
    GenServer.cast(pid, {:set_response_mode, mode})
  end

  def emit_subscription_notification(pid, subscription_id, result) do
    GenServer.cast(pid, {:emit_subscription, subscription_id, result})
  end

  # Configuration options for connection behavior
  def start_link(url, handler_mod, state, opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, {url, handler_mod, state, opts})
  end

  # Maintain compatibility with original 3-argument version
  def start_link(url, handler_mod, state) do
    GenServer.start_link(__MODULE__, {url, handler_mod, state, []})
  end

  # GenServer
  @impl true
  def init({url, handler_mod, state, opts}) do
    _ = url
    connect_delay = Keyword.get(opts, :connect_delay, 0)
    should_fail = Keyword.get(opts, :fail_connection, false)

    mock_state = %{
      handler: handler_mod,
      state: state,
      failure_mode: :normal,
      should_fail_connection: should_fail,
      connected: false,
      response_delay: 0,
      pending_responses: %{},
      response_mode: :result
    }

    if should_fail do
      # Don't connect at all
      {:ok, mock_state}
    else
      # Schedule connection after delay
      if connect_delay > 0 do
        Process.send_after(self(), :after_init, connect_delay)
      else
        send(self(), :after_init)
      end

      {:ok, mock_state}
    end
  end

  # Maintain compatibility with old 3-argument init
  def init({url, handler_mod, state}) do
    init({url, handler_mod, state, []})
  end

  @impl true
  def handle_info(:after_init, %{handler: handler, state: state} = s) do
    {:ok, new_state} = handler.handle_connect(nil, state)
    {:noreply, %{s | state: new_state, connected: true}}
  end

  # WebSockex sometimes sends an internal message to the client process
  # to perform the actual send. Simulate immediate success here.
  @impl true
  def handle_info({:"$websockex_send", _ref, :ping}, s) do
    # Pretend the ping was handled; also simulate a pong at handler level
    {:noreply, s}
  end

  def handle_info({:delayed_response, payload}, %{handler: handler, state: st} = s) do
    # Send delayed response
    case handler.handle_frame({:text, payload}, st) do
      {:ok, new_state} -> {:noreply, %{s | state: new_state}}
      other -> {:noreply, %{s | state: elem(other, 1)}}
    end
  end

  @impl true
  def handle_call({:send_frame, {:text, _payload}}, _from, %{failure_mode: :fail_sends} = s) do
    # Simulate send failure
    {:reply, {:error, :connection_closed}, s}
  end

  def handle_call(
        {:send_frame, {:text, payload}},
        _from,
        %{
          handler: handler,
          state: st,
          connected: true,
          response_delay: delay,
          response_mode: mode
        } = s
      ) do
    # Parse request and create proper JSON-RPC response
    response_payload =
      case Jason.decode(payload) do
        {:ok, %{"id" => id, "method" => method, "params" => params}} ->
          # Create a proper JSON-RPC response with the same ID
          response =
            case mode do
              :result ->
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{
                    "method" => method,
                    "params" => params,
                    "mock_response" => true
                  }
                }

              :error ->
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "error" => %{
                    "code" => -32001,
                    "message" => "mock error",
                    "data" => %{"method" => method, "params" => params}
                  }
                }
            end

          Jason.encode!(response)

        _ ->
          # Fallback to echo for non-standard messages
          payload
      end

    if delay > 0 do
      # Schedule delayed response
      Process.send_after(self(), {:delayed_response, response_payload}, delay)
      {:reply, :ok, s}
    else
      # Immediate response
      case handler.handle_frame({:text, response_payload}, st) do
        {:ok, new_state} -> {:reply, :ok, %{s | state: new_state}}
        other -> {:reply, :ok, %{s | state: elem(other, 1)}}
      end
    end
  end

  def handle_call({:send_frame, {:text, _payload}}, _from, %{connected: false} = s) do
    # Not connected
    {:reply, {:error, :not_connected}, s}
  end

  def handle_call({:send_frame, :ping}, _from, %{failure_mode: :fail_pings} = s) do
    # Simulate ping failure
    {:reply, {:error, :connection_closed}, s}
  end

  def handle_call(
        {:send_frame, :ping},
        _from,
        %{handler: handler, state: st, connected: true} = s
      ) do
    # Simulate pong response
    {:ok, new_state} = handler.handle_frame({:pong, ""}, st)
    {:reply, :ok, %{s | state: new_state}}
  end

  def handle_call({:send_frame, :ping}, _from, %{connected: false} = s) do
    # Not connected
    {:reply, {:error, :not_connected}, s}
  end

  @impl true
  def handle_cast({:emit_message, json_map}, %{handler: handler, state: st, connected: true} = s) do
    {:ok, new_state} = handler.handle_frame({:text, Jason.encode!(json_map)}, st)
    {:noreply, %{s | state: new_state}}
  end

  def handle_cast({:emit_message, _json_map}, %{connected: false} = s) do
    # Ignore messages when not connected
    {:noreply, s}
  end

  def handle_cast({:close, code, reason}, %{handler: handler, state: st} = s) do
    {:ok, new_state} = handler.handle_frame({:close, code, reason}, st)
    {:noreply, %{s | state: new_state, connected: false}}
  end

  def handle_cast({:disconnect, reason}, %{handler: handler, state: st} = s) do
    {:ok, new_state} = handler.handle_disconnect(%{reason: reason}, st)
    {:noreply, %{s | state: new_state, connected: false}}
  end

  def handle_cast({:simulate_connection_failure, _error}, s) do
    # This would be used to test initial connection failures
    # For now, just mark as failed - in real scenarios this might involve
    # sending error messages to the parent process
    {:noreply, %{s | should_fail_connection: true, connected: false}}
  end

  def handle_cast({:force_crash, reason}, _s) do
    # Simulate a process crash
    exit(reason)
  end

  def handle_cast({:set_failure_mode, mode}, s) do
    {:noreply, %{s | failure_mode: mode}}
  end

  def handle_cast({:set_response_delay, delay_ms}, s) do
    {:noreply, %{s | response_delay: delay_ms}}
  end

  def handle_cast({:set_response_mode, mode}, s) do
    {:noreply, %{s | response_mode: mode}}
  end

  def handle_cast(
        {:emit_subscription, subscription_id, result},
        %{handler: handler, state: st, connected: true} = s
      ) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "eth_subscription",
      "params" => %{
        "subscription" => subscription_id,
        "result" => result
      }
    }

    {:ok, new_state} = handler.handle_frame({:text, Jason.encode!(notification)}, st)
    {:noreply, %{s | state: new_state}}
  end

  def handle_cast({:emit_subscription, _subscription_id, _result}, %{connected: false} = s) do
    # Ignore subscription notifications when not connected
    {:noreply, s}
  end
end
