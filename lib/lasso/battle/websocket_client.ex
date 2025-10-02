defmodule Lasso.Battle.WebSocketClient do
  @moduledoc """
  WebSocket client for battle testing subscriptions.

  Tracks events, detects duplicates and gaps, emits telemetry.
  """

  use WebSockex
  require Logger

  defstruct [
    :url,
    :subscription_type,
    :client_id,
    :subscription_id,
    events_received: 0,
    duplicates: 0,
    gaps: 0,
    last_block_number: nil,
    seen_hashes: MapSet.new(),
    connected_at: nil
  ]

  ## Client API

  def start_link(url, subscription_type, client_id) do
    state = %__MODULE__{
      url: url,
      subscription_type: subscription_type,
      client_id: client_id,
      connected_at: System.monotonic_time(:millisecond)
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  def get_stats(pid) do
    send(pid, {:get_stats, self()})

    receive do
      {:stats, stats} -> stats
    after
      5_000 -> %{error: :timeout}
    end
  end

  def stop(pid) do
    WebSockex.cast(pid, :close)
  end

  ## WebSockex callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.debug("[#{state.client_id}] Connected to #{state.url}")

    # Schedule subscription request to be sent after connection completes
    send(self(), :subscribe)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"id" => _id, "result" => subscription_id}} when is_binary(subscription_id) ->
        Logger.debug("[#{state.client_id}] Subscribed: #{subscription_id}")

        new_state = %{state | subscription_id: subscription_id}

        # Emit telemetry for subscription success
        :telemetry.execute(
          [:lasso, :battle, :ws_subscription, :created],
          %{count: 1},
          %{
            client_id: state.client_id,
            subscription_id: subscription_id,
            subscription_type: inspect(state.subscription_type)
          }
        )

        {:ok, new_state}

      {:ok, %{"method" => "eth_subscription", "params" => params}} ->
        handle_subscription_event(params, state)

      {:ok, %{"error" => error}} ->
        Logger.error("[#{state.client_id}] Error: #{inspect(error)}")
        {:ok, state}

      {:ok, other} ->
        Logger.warning("[#{state.client_id}] Unexpected message: #{inspect(other)}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("[#{state.client_id}] Failed to decode: #{reason}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect_map, state) do
    Logger.warning("[#{state.client_id}] Disconnected: #{inspect(disconnect_map)}")

    # Emit telemetry for disconnection
    :telemetry.execute(
      [:lasso, :battle, :ws_subscription, :disconnected],
      %{count: 1},
      %{client_id: state.client_id, reason: inspect(disconnect_map)}
    )

    {:ok, state}
  end

  @impl true
  def handle_cast(:close, state) do
    {:close, state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    # Send subscription request
    request = build_subscription_request(state.subscription_type)
    {:reply, {:text, Jason.encode!(request)}, state}
  end

  @impl true
  def handle_info({:get_stats, from}, state) do
    stats = %{
      client_id: state.client_id,
      subscription_id: state.subscription_id,
      events_received: state.events_received,
      duplicates: state.duplicates,
      gaps: state.gaps,
      uptime_ms: System.monotonic_time(:millisecond) - (state.connected_at || 0)
    }

    send(from, {:stats, stats})
    {:ok, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  ## Internal helpers

  defp build_subscription_request("newHeads") do
    %{
      "jsonrpc" => "2.0",
      "id" => :rand.uniform(10000),
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }
  end

  defp build_subscription_request({"logs", filter}) do
    %{
      "jsonrpc" => "2.0",
      "id" => :rand.uniform(10000),
      "method" => "eth_subscribe",
      "params" => ["logs", filter]
    }
  end

  defp handle_subscription_event(%{"subscription" => _sub_id, "result" => result}, state) do
    # Detect event type and extract key fields
    {event_type, block_number, hash} = extract_event_info(result)

    # Check for duplicates
    {is_duplicate, new_seen_hashes} =
      if hash do
        if MapSet.member?(state.seen_hashes, hash) do
          {true, state.seen_hashes}
        else
          {false, MapSet.put(state.seen_hashes, hash)}
        end
      else
        {false, state.seen_hashes}
      end

    # Check for gaps (only for sequential events like newHeads)
    gap_detected =
      case {event_type, state.last_block_number, block_number} do
        {:newHeads, last, current} when is_integer(last) and is_integer(current) ->
          current > last + 1

        _ ->
          false
      end

    # Update state
    new_state = %{
      state
      | events_received: state.events_received + 1,
        duplicates: state.duplicates + if(is_duplicate, do: 1, else: 0),
        gaps: state.gaps + if(gap_detected, do: 1, else: 0),
        last_block_number: block_number || state.last_block_number,
        seen_hashes: new_seen_hashes
    }

    # Emit telemetry
    :telemetry.execute(
      [:lasso, :battle, :ws_subscription, :event],
      %{count: 1},
      %{
        client_id: state.client_id,
        subscription_id: state.subscription_id,
        event_type: event_type,
        is_duplicate: is_duplicate,
        gap_detected: gap_detected,
        block_number: block_number
      }
    )

    if is_duplicate do
      Logger.warning("[#{state.client_id}] Duplicate event detected: #{hash}")
    end

    if gap_detected do
      Logger.warning(
        "[#{state.client_id}] Gap detected: #{state.last_block_number} -> #{block_number}"
      )
    end

    {:ok, new_state}
  end

  defp extract_event_info(%{"number" => "0x" <> hex_number, "hash" => hash}) do
    # newHeads event
    block_number = String.to_integer(hex_number, 16)
    {:newHeads, block_number, hash}
  end

  defp extract_event_info(%{"blockNumber" => "0x" <> hex_number, "transactionHash" => hash}) do
    # logs event
    block_number = String.to_integer(hex_number, 16)
    {:logs, block_number, hash}
  end

  defp extract_event_info(_result) do
    # Unknown event type
    {:unknown, nil, nil}
  end
end
