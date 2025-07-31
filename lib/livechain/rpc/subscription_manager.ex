defmodule Livechain.RPC.SubscriptionManager do
  @moduledoc """
  Manages real-time event subscriptions for JSON-RPC endpoints.

  This module handles:
  - WebSocket subscriptions to blockchain events
  - Subscription lifecycle management
  - Event routing to connected clients
  - Subscription deduplication and filtering
  """

  use GenServer
  require Logger

  alias Livechain.RPC.ChainManager
  alias Livechain.RPC.WSSupervisor

  defstruct [
    :subscriptions,
    :subscription_counter,
    :event_cache,
    :active_filters
  ]

  @doc """
  Starts the SubscriptionManager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to log events on a specific chain.
  """
  def subscribe_to_logs(chain, filter) do
    GenServer.call(__MODULE__, {:subscribe_logs, chain, filter})
  end

  @doc """
  Subscribe to new block headers on a specific chain.
  """
  def subscribe_to_new_heads(chain) do
    GenServer.call(__MODULE__, {:subscribe_new_heads, chain})
  end

  @doc """
  Unsubscribe from an event subscription.
  """
  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Get active subscriptions.
  """
  def get_subscriptions do
    GenServer.call(__MODULE__, :get_subscriptions)
  end

  @doc """
  Handle incoming blockchain events and route to subscribers.
  """
  def handle_event(chain, event_type, event_data) do
    GenServer.cast(__MODULE__, {:handle_event, chain, event_type, event_data})
  end

  @impl true
  def init(_opts) do
    # Initialize ETS tables for subscriptions and event cache
    :ets.new(:subscriptions, [:set, :protected, :named_table])
    :ets.new(:event_cache, [:ordered_set, :protected, :named_table])

    # Subscribe to PubSub for blockchain events
    Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain_events")

    {:ok,
     %{
       subscriptions: %{},
       subscription_counter: 1,
       event_cache: [],
       active_filters: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe_logs, chain, filter}, _from, state) do
    subscription_id = "logs_#{chain}_#{state.subscription_counter}"

    # Create subscription record
    subscription = %{
      id: subscription_id,
      type: :logs,
      chain: chain,
      filter: filter,
      created_at: DateTime.utc_now(),
      status: :active
    }

    # Store subscription
    updated_subscriptions = Map.put(state.subscriptions, subscription_id, subscription)

    # Add to active filters for this chain
    updated_filters = Map.update(state.active_filters, chain, [filter], &[filter | &1])

    # Ensure chain is running and subscribe to events
    ensure_chain_subscription(chain, filter)

    Logger.info("Created log subscription",
      subscription_id: subscription_id,
      chain: chain,
      filter: filter
    )

    {:reply, {:ok, subscription_id},
     %{
       state
       | subscriptions: updated_subscriptions,
         subscription_counter: state.subscription_counter + 1,
         active_filters: updated_filters
     }}
  end

  @impl true
  def handle_call({:subscribe_new_heads, chain}, _from, state) do
    subscription_id = "newHeads_#{chain}_#{state.subscription_counter}"

    # Create subscription record
    subscription = %{
      id: subscription_id,
      type: :new_heads,
      chain: chain,
      created_at: DateTime.utc_now(),
      status: :active
    }

    # Store subscription
    updated_subscriptions = Map.put(state.subscriptions, subscription_id, subscription)

    # Ensure chain is running and subscribe to new heads
    ensure_chain_subscription(chain, :new_heads)

    Logger.info("Created new heads subscription",
      subscription_id: subscription_id,
      chain: chain
    )

    {:reply, {:ok, subscription_id},
     %{
       state
       | subscriptions: updated_subscriptions,
         subscription_counter: state.subscription_counter + 1
     }}
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:reply, {:error, "Subscription not found"}, state}

      subscription ->
        # Remove subscription
        updated_subscriptions = Map.delete(state.subscriptions, subscription_id)

        # Update active filters if needed
        updated_filters =
          case subscription.type do
            :logs ->
              chain_filters = Map.get(state.active_filters, subscription.chain, [])
              filtered_filters = Enum.reject(chain_filters, &(&1 == subscription.filter))
              Map.put(state.active_filters, subscription.chain, filtered_filters)

            _ ->
              state.active_filters
          end

        Logger.info("Unsubscribed", subscription_id: subscription_id)

        {:reply, {:ok, true},
         %{
           state
           | subscriptions: updated_subscriptions,
             active_filters: updated_filters
         }}
    end
  end

  @impl true
  def handle_call(:get_subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl true
  def handle_cast({:handle_event, chain, event_type, event_data}, state) do
    # Find subscriptions that match this event
    matching_subscriptions = find_matching_subscriptions(chain, event_type, event_data, state)

    # Route event to matching subscribers
    Enum.each(matching_subscriptions, fn subscription ->
      route_event_to_subscriber(subscription, event_data)
    end)

    # Cache event for potential reconnection scenarios
    cache_event(chain, event_type, event_data, state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:blockchain_event, chain, event_type, event_data}, state) do
    # Handle events from PubSub
    GenServer.cast(self(), {:handle_event, chain, event_type, event_data})
    {:noreply, state}
  end

  defp ensure_chain_subscription(chain, filter) do
    # Ensure the chain is running
    case ChainManager.get_chain_status(chain) do
      {:ok, %{status: :running}} ->
        # Chain is already running, subscribe to events
        subscribe_to_chain_events(chain, filter)

      _ ->
        # Start the chain if it's not running
        case ChainManager.start_chain(chain) do
          {:ok, _} ->
            subscribe_to_chain_events(chain, filter)

          {:error, reason} ->
            Logger.error("Failed to start chain", chain: chain, reason: reason)
        end
    end
  end

  defp subscribe_to_chain_events(chain, filter) do
    # Subscribe to the appropriate event stream
    case filter do
      :new_heads ->
        Phoenix.PubSub.subscribe(Livechain.PubSub, "chain:#{chain}:new_heads")

      filter when is_map(filter) ->
        Phoenix.PubSub.subscribe(Livechain.PubSub, "chain:#{chain}:logs")

      _ ->
        Logger.warn("Unknown filter type", filter: filter)
    end
  end

  defp find_matching_subscriptions(chain, event_type, event_data, state) do
    Enum.filter(state.subscriptions, fn {_id, subscription} ->
      subscription.chain == chain &&
        subscription.status == :active &&
        matches_subscription_filter(subscription, event_type, event_data)
    end)
    |> Enum.map(fn {_id, subscription} -> subscription end)
  end

  defp matches_subscription_filter(subscription, event_type, event_data) do
    case subscription.type do
      :new_heads ->
        event_type == :new_heads

      :logs ->
        event_type == :logs && matches_log_filter(subscription.filter, event_data)

      _ ->
        false
    end
  end

  defp matches_log_filter(filter, log_data) do
    # Check if log matches the filter criteria
    address_match =
      case filter["address"] do
        nil ->
          true

        address when is_list(address) ->
          log_data["address"] in address

        address ->
          log_data["address"] == address
      end

    topics_match =
      case filter["topics"] do
        nil ->
          true

        topics when is_list(topics) ->
          # Simple topic matching - can be enhanced
          true

        _ ->
          true
      end

    address_match && topics_match
  end

  defp route_event_to_subscriber(subscription, event_data) do
    # Create subscription notification
    notification = %{
      jsonrpc: "2.0",
      method: "eth_subscription",
      params: %{
        subscription: subscription.id,
        result: event_data
      }
    }

    # Broadcast to subscribers via PubSub
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "subscription:#{subscription.id}",
      {:subscription_event, notification}
    )

    Logger.debug("Routed event to subscriber",
      subscription_id: subscription.id,
      event_type: "subscription"
    )
  end

  defp cache_event(chain, event_type, event_data, state) do
    # Cache recent events for reconnection scenarios
    cache_entry = %{
      chain: chain,
      type: event_type,
      data: event_data,
      timestamp: DateTime.utc_now()
    }

    # Keep only last 100 events per chain
    current_cache = :ets.lookup(:event_cache, chain) || []
    updated_cache = [cache_entry | current_cache] |> Enum.take(100)

    :ets.insert(:event_cache, {chain, updated_cache})
  end
end
