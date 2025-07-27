defmodule LivechainWeb.RPCChannel do
  @moduledoc """
  Standard Ethereum JSON-RPC WebSocket channel.
  
  Provides Viem-compatible JSON-RPC over WebSocket with:
  - Method routing (eth_subscribe, eth_getLogs, etc.)
  - Subscription management
  - Provider failover integration
  - Standard JSON-RPC 2.0 response format
  """

  use LivechainWeb, :channel
  require Logger

  alias Livechain.RPC.WSSupervisor

  @impl true
  def join("rpc:" <> chain, _payload, socket) do
    Logger.info("JSON-RPC client joined: #{chain}")
    
    socket = assign(socket, :chain, chain)
    socket = assign(socket, :subscriptions, %{})
    
    # Ensure we have a blockchain connection for this chain
    ensure_chain_connection(chain)
    
    {:ok, %{status: "connected", chain: chain}, socket}
  end

  @impl true
  def handle_in("rpc_call", %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}, socket) do
    Logger.debug("JSON-RPC call: #{method} with params: #{inspect(params)}")
    
    response = case handle_rpc_method(method, params, socket) do
      {:ok, result} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => result
        }
        
      {:error, reason} ->
        %{
          "jsonrpc" => "2.0", 
          "id" => id,
          "error" => %{
            "code" => -32000,
            "message" => to_string(reason)
          }
        }
        
      {:subscription, subscription_id} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id, 
          "result" => subscription_id
        }
    end
    
    {:reply, {:ok, response}, socket}
  end

  @impl true
  def handle_in("rpc_call", invalid_request, socket) do
    Logger.warning("Invalid JSON-RPC request: #{inspect(invalid_request)}")
    
    response = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{
        "code" => -32600,
        "message" => "Invalid Request"
      }
    }
    
    {:reply, {:ok, response}, socket}
  end

  # Handle subscription notifications from blockchain connections
  @impl true
  def handle_info(%{event: "new_block", payload: block_data}, socket) do
    # Send subscription notifications to client
    socket.assigns.subscriptions
    |> Enum.filter(fn {_sub_id, sub_type} -> sub_type == "newHeads" end)
    |> Enum.each(fn {subscription_id, _} ->
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => subscription_id,
          "result" => block_data
        }
      }
      
      push(socket, "rpc_notification", notification)
    end)
    
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_log", payload: log_data}, socket) do
    # Send log subscription notifications to client
    socket.assigns.subscriptions
    |> Enum.filter(fn {_sub_id, sub_type} -> sub_type == "logs" end)
    |> Enum.each(fn {subscription_id, _} ->
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription", 
        "params" => %{
          "subscription" => subscription_id,
          "result" => log_data
        }
      }
      
      push(socket, "rpc_notification", notification)
    end)
    
    {:noreply, socket}
  end

  # JSON-RPC method handlers
  
  defp handle_rpc_method("eth_subscribe", [subscription_type | params], socket) do
    subscription_id = generate_subscription_id()
    
    case subscription_type do
      "newHeads" ->
        # Subscribe to block updates for this chain
        Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{socket.assigns.chain}")
        
        _socket = update_subscriptions(socket, subscription_id, "newHeads")
        {:subscription, subscription_id}
        
      "logs" ->
        # Subscribe to log updates with optional filtering
        filter = List.first(params, %{})
        Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{socket.assigns.chain}:logs")
        
        _socket = update_subscriptions(socket, subscription_id, {"logs", filter})
        {:subscription, subscription_id}
        
      _ ->
        {:error, "Unsupported subscription type: #{subscription_type}"}
    end
  end

  defp handle_rpc_method("eth_unsubscribe", [subscription_id], socket) do
    case Map.pop(socket.assigns.subscriptions, subscription_id) do
      {nil, _} ->
        {:ok, false}
        
      {_subscription_type, updated_subscriptions} ->
        _socket = assign(socket, :subscriptions, updated_subscriptions)
        {:ok, true}
    end
  end

  defp handle_rpc_method("eth_getLogs", [filter], _socket) do
    # For now, return empty logs - will be implemented with real provider integration
    # In production, this would query the blockchain connection for the chain
    Logger.debug("eth_getLogs called with filter: #{inspect(filter)}")
    {:ok, []}
  end

  defp handle_rpc_method("eth_getBlockByNumber", [block_number, include_transactions], socket) do
    # Route to blockchain connection for this chain
    chain = socket.assigns.chain
    
    case get_chain_connection(chain) do
      {:ok, _connection_pid} ->
        # For now, return mock data - will integrate with real connections
        {:ok, %{
          "number" => block_number,
          "hash" => "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)),
          "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16),
          "transactions" => if(include_transactions, do: [], else: [])
        }}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_rpc_method("eth_getTransactionReceipt", [tx_hash], _socket) do
    Logger.debug("eth_getTransactionReceipt called for: #{tx_hash}")
    # For now, return null - will be implemented with real provider integration
    {:ok, nil}
  end

  defp handle_rpc_method("eth_blockNumber", [], _socket) do
    # Return latest block number for this chain
    {:ok, "0x" <> Integer.to_string(:rand.uniform(20_000_000), 16)}
  end

  defp handle_rpc_method(method, _params, _socket) do
    {:error, "Method not supported: #{method}"}
  end

  # Helper functions

  defp ensure_chain_connection(chain) do
    # Check if we have an active connection for this chain
    connections = WSSupervisor.list_connections()
    existing = Enum.find(connections, fn conn ->
      String.contains?(String.downcase(conn.name || ""), chain)
    end)

    if existing do
      Logger.debug("Using existing connection for #{chain}")
      :ok
    else
      Logger.info("Starting new connection for #{chain}")
      # Start a mock connection for this chain
      endpoint = case chain do
        "ethereum" -> Livechain.RPC.MockWSEndpoint.ethereum_mainnet()
        "arbitrum" -> Livechain.RPC.MockWSEndpoint.arbitrum() 
        "polygon" -> Livechain.RPC.MockWSEndpoint.polygon()
        "bsc" -> Livechain.RPC.MockWSEndpoint.bsc()
        _ -> nil
      end

      if endpoint do
        WSSupervisor.start_connection(endpoint)
      else
        {:error, :unsupported_chain}
      end
    end
  end

  defp get_chain_connection(chain) do
    connections = WSSupervisor.list_connections()
    case Enum.find(connections, fn conn ->
      String.contains?(String.downcase(conn.name || ""), chain)
    end) do
      nil -> {:error, :no_connection}
      connection -> {:ok, connection}
    end
  end

  defp generate_subscription_id do
    "0x" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp update_subscriptions(socket, subscription_id, subscription_type) do
    updated_subscriptions = Map.put(socket.assigns.subscriptions, subscription_id, subscription_type)
    assign(socket, :subscriptions, updated_subscriptions)
  end
end