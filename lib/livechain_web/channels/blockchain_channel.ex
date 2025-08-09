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

  alias Livechain.RPC.WSSupervisor

  # Dynamic chain support loaded from configuration

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
      supported_chains = get_supported_chain_names()
      {:error, %{reason: "unsupported_chain", supported: supported_chains}}
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
  def handle_in("subscribe", %{"type" => sub_type}, socket)
      when sub_type in ["blocks", "transactions", "events"] do
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

    status =
      if chain_connection do
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
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        Map.has_key?(config.chains, chain_id)

      {:error, _reason} ->
        # Fallback to basic validation if config loading fails
        chain_id in ["ethereum", "arbitrum", "polygon", "bsc"]
    end
  end

  defp get_supported_chain_names do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        Map.keys(config.chains)

      {:error, _reason} ->
        ["ethereum", "arbitrum", "polygon", "bsc"]
    end
  end

  defp ensure_chain_connection(chain_id) do
    if chain_supported?(chain_id) do
      # Check if connection already exists
      connections = WSSupervisor.list_connections()
      existing = Enum.find(connections, &String.contains?(&1.name, chain_id))

      if existing do
        Logger.debug("Chain connection already exists for #{chain_id}")
        :ok
      else
        # Create and start new connection using configured providers
        case get_chain_endpoint(chain_id) do
          {:ok, endpoint} ->
            case WSSupervisor.start_connection(endpoint) do
              {:ok, _pid} ->
                Logger.info("Started new chain connection for #{chain_id}")
                :ok

              {:error, reason} ->
                Logger.error("Failed to start chain connection for #{chain_id}: #{inspect(reason)}")
                :error
            end

          {:error, reason} ->
            Logger.error("Failed to get endpoint for chain #{chain_id}: #{reason}")
            :error
        end
      end
    else
      Logger.error("Unsupported chain: #{chain_id}")
      :error
    end
  end

  defp get_chain_endpoint(chain_id) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        case Livechain.Config.ChainConfig.get_chain_config(config, chain_id) do
          {:ok, chain_config} ->
            # Get the first available provider for this chain
            case Livechain.Config.ChainConfig.get_available_providers(chain_config) do
              [provider | _] ->
                # Create endpoint struct using the Livechain.RPC.WSEndpoint
                endpoint = %Livechain.RPC.WSEndpoint{
                  id: provider.id,
                  name: provider.name,
                  url: provider.url,
                  ws_url: provider.ws_url,
                  chain_id: chain_config.chain_id,
                  api_key: nil,
                  reconnect_interval: chain_config.connection.reconnect_interval,
                  heartbeat_interval: chain_config.connection.heartbeat_interval,
                  max_reconnect_attempts: chain_config.connection.max_reconnect_attempts,
                  subscription_topics: chain_config.connection.subscription_topics
                }
                {:ok, endpoint}

              [] ->
                {:error, "No available providers for chain #{chain_id}"}
            end

          {:error, :chain_not_found} ->
            {:error, "Chain #{chain_id} not found in configuration"}
        end

      {:error, reason} ->
        {:error, "Failed to load configuration: #{reason}"}
    end
  end
end
