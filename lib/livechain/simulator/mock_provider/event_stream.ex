defmodule Livechain.Simulator.MockProvider.EventStream do
  @moduledoc """
  Manages event streaming and broadcasting to subscribers.

  This module handles the distribution of blockchain events (like new blocks,
  transactions, etc.) to subscribed clients, simulating the WebSocket
  subscription functionality of real RPC providers.
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts an event stream process.
  """
  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: via_name(state.name))
  end

  @doc """
  Broadcasts an event to all subscribers of a topic.
  """
  def broadcast(pid, topic, data) do
    GenServer.cast(pid, {:broadcast, topic, data})
  end

  @doc """
  Adds a subscriber to a topic.
  """
  def subscribe(pid, topic, subscriber_pid) do
    GenServer.cast(pid, {:subscribe, topic, subscriber_pid})
  end

  @doc """
  Removes a subscriber from a topic.
  """
  def unsubscribe(pid, topic, subscriber_pid) do
    GenServer.cast(pid, {:unsubscribe, topic, subscriber_pid})
  end

  @doc """
  Gets the current subscriber count for a topic.
  """
  def subscriber_count(pid, topic) do
    GenServer.call(pid, {:subscriber_count, topic})
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Logger.info("Starting event stream for #{state.name}")

    {:ok, %{state | subscribers: %{}, stats: %{events_sent: 0, total_subscribers: 0}}}
  end

  @impl true
  def handle_cast({:broadcast, topic, data}, state) do
    case Map.get(state.subscribers, topic) do
      nil ->
        Logger.debug("No subscribers for topic: #{topic}")
        {:noreply, state}

      subscribers ->
        message = %{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => generate_subscription_id(topic),
            "result" => data
          }
        }

        Enum.each(subscribers, fn subscriber_pid ->
          if Process.alive?(subscriber_pid) do
            send(subscriber_pid, {:websocket_message, Jason.encode!(message)})
          end
        end)

        stats = %{state.stats | events_sent: state.stats.events_sent + 1}
        Logger.debug("Broadcasted #{topic} event to #{length(subscribers)} subscribers")
        {:noreply, %{state | stats: stats}}
    end
  end

  @impl true
  def handle_cast({:subscribe, topic, subscriber_pid}, state) do
    current_subscribers = Map.get(state.subscribers, topic, MapSet.new())
    updated_subscribers = MapSet.put(current_subscribers, subscriber_pid)
    updated_subscribers_map = Map.put(state.subscribers, topic, updated_subscribers)

    stats = %{state.stats | total_subscribers: state.stats.total_subscribers + 1}

    Logger.info(
      "New subscriber to #{topic} on #{state.name} (total: #{MapSet.size(updated_subscribers)})"
    )

    {:noreply, %{state | subscribers: updated_subscribers_map, stats: stats}}
  end

  @impl true
  def handle_cast({:unsubscribe, topic, subscriber_pid}, state) do
    case Map.get(state.subscribers, topic) do
      nil ->
        {:noreply, state}

      subscribers ->
        updated_subscribers = MapSet.delete(subscribers, subscriber_pid)
        updated_subscribers_map = Map.put(state.subscribers, topic, updated_subscribers)

        stats = %{state.stats | total_subscribers: max(0, state.stats.total_subscribers - 1)}

        Logger.info(
          "Unsubscribed from #{topic} on #{state.name} (remaining: #{MapSet.size(updated_subscribers)})"
        )

        {:noreply, %{state | subscribers: updated_subscribers_map, stats: stats}}
    end
  end

  @impl true
  def handle_call({:subscriber_count, topic}, _from, state) do
    count =
      case Map.get(state.subscribers, topic) do
        nil -> 0
        subscribers -> MapSet.size(subscribers)
      end

    {:reply, count, state}
  end

  # Private functions

  defp via_name(name) do
    {:via, Registry, {Livechain.Registry, {:event_stream, name}}}
  end

  defp generate_subscription_id(_topic) do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
    |> then(&"0x#{&1}")
  end
end
