defmodule LivechainWeb.BlockchainChannel do
  @moduledoc """
  Channel for real-time blockchain data subscriptions.

  This channel provides real-time streaming of blockchain data including:
  - New blocks
  - Transactions  
  - Events and logs
  - Contract interactions

  ## Usage

  Connect to a specific blockchain:
  ```javascript
  const socket = new Socket("/socket", {})
  socket.connect()

  // Subscribe to Ethereum blocks
  const channel = socket.channel("blockchain:ethereum", {})
  channel.join()
    .receive("ok", resp => { console.log("Joined successfully", resp) })
    .receive("error", resp => { console.log("Unable to join", resp) })

  // Listen for new blocks
  channel.on("new_block", payload => {
    console.log("New block:", payload)
  })
  ```

  ## Topics

  - `blockchain:ethereum` - Ethereum mainnet
  - `blockchain:polygon` - Polygon network  
  - `blockchain:arbitrum` - Arbitrum network
  - `blockchain:bsc` - Binance Smart Chain
  """

  use LivechainWeb, :channel
  require Logger

  alias Livechain.RPC.{WSSupervisor, MockWSEndpoint}

  @supported_chains %{
    "ethereum" => :ethereum_mainnet,
    "polygon" => :polygon,
    "arbitrum" => :arbitrum,
    "bsc" => :bsc
  }

  @impl true
  def join("blockchain:" <> chain_id, _payload, socket) do
    if chain_supported?(chain_id) do
      Logger.info("Client joined blockchain channel: #{chain_id}")
      
      # Subscribe to PubSub for this chain
      Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{chain_id}")
      
      socket = assign(socket, :chain_id, chain_id)
      send(self(), :after_join)
      
      {:ok, %{chain_id: chain_id, status: "connected"}, socket}
    else
      Logger.warning("Unsupported chain requested: #{chain_id}")
      {:error, %{reason: "unsupported_chain", supported: Map.keys(@supported_chains)}}
    end
  end

  @impl true
  def join(topic, _payload, _socket) do
    Logger.warning("Invalid channel topic: #{topic}")
    {:error, %{reason: "invalid_topic"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    chain_id = socket.assigns.chain_id
    
    # Start monitoring the blockchain connection if not already started
    ensure_chain_connection(chain_id)
    
    # Send initial status
    push(socket, "status", %{
      chain_id: chain_id,
      connected: true,
      message: "Successfully connected to #{chain_id} blockchain feed"
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_block", payload: block_data}, socket) do
    push(socket, "new_block", %{
      chain_id: socket.assigns.chain_id,
      block: block_data
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_transaction", payload: tx_data}, socket) do
    push(socket, "new_transaction", %{
      chain_id: socket.assigns.chain_id,
      transaction: tx_data
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "chain_status", payload: status}, socket) do
    push(socket, "chain_status", %{
      chain_id: socket.assigns.chain_id,
      status: status
    })
    {:noreply, socket}
  end

  @impl true
  def handle_in("subscribe", %{"type" => sub_type}, socket) when sub_type in ["blocks", "transactions", "events"] do
    chain_id = socket.assigns.chain_id
    Logger.info("Client subscribing to #{sub_type} for #{chain_id}")
    
    # Subscribe to specific event type
    Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{chain_id}:#{sub_type}")
    
    {:reply, {:ok, %{subscribed_to: sub_type}}, socket}
  end

  @impl true
  def handle_in("subscribe", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_subscription_type"}}, socket}
  end

  @impl true
  def handle_in("get_status", _payload, socket) do
    chain_id = socket.assigns.chain_id
    
    # Get connection status from WSSupervisor
    connections = WSSupervisor.list_connections()
    chain_connection = Enum.find(connections, &String.contains?(&1.name, chain_id))
    
    status = if chain_connection do
      %{
        connected: chain_connection.status == :connected,
        reconnect_attempts: chain_connection.reconnect_attempts || 0,
        subscriptions: chain_connection.subscriptions || 0
      }
    else
      %{connected: false, reconnect_attempts: 0, subscriptions: 0}
    end
    
    {:reply, {:ok, status}, socket}
  end

  # Private functions

  defp chain_supported?(chain_id) do
    Map.has_key?(@supported_chains, chain_id)
  end

  defp ensure_chain_connection(chain_id) do
    case Map.get(@supported_chains, chain_id) do
      nil ->
        Logger.error("Unsupported chain: #{chain_id}")
        :error

      chain_function ->
        # Check if connection already exists
        connections = WSSupervisor.list_connections()
        existing = Enum.find(connections, &String.contains?(&1.name, chain_id))
        
        if existing do
          Logger.debug("Chain connection already exists for #{chain_id}")
          :ok
        else
          # Create and start new connection
          endpoint = apply(MockWSEndpoint, chain_function, [])
          
          case WSSupervisor.start_connection(endpoint) do
            {:ok, _pid} ->
              Logger.info("Started new chain connection for #{chain_id}")
              :ok
              
            {:error, reason} ->
              Logger.error("Failed to start chain connection for #{chain_id}: #{inspect(reason)}")
              :error
          end
        end
    end
  end
end