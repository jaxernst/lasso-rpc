defmodule LivechainWeb.RPCController do
  @moduledoc """
  HTTP JSON-RPC endpoint for simple RPC calls.
  
  Provides Viem-compatible HTTP POST endpoints for:
  - /rpc/ethereum
  - /rpc/arbitrum  
  - /rpc/polygon
  - /rpc/bsc
  
  Supports standard JSON-RPC 2.0 format.
  """
  
  use LivechainWeb, :controller
  require Logger
  
  alias Livechain.RPC.WSSupervisor
  
  def ethereum(conn, params), do: handle_rpc(conn, params, "ethereum")
  def arbitrum(conn, params), do: handle_rpc(conn, params, "arbitrum")
  def polygon(conn, params), do: handle_rpc(conn, params, "polygon") 
  def bsc(conn, params), do: handle_rpc(conn, params, "bsc")
  
  defp handle_rpc(conn, %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}, chain) do
    Logger.debug("HTTP JSON-RPC call: #{method} on #{chain}")
    
    response = case handle_rpc_method(method, params, chain) do
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
    end
    
    json(conn, response)
  end
  
  defp handle_rpc(conn, _invalid_request, _chain) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{
        "code" => -32600,
        "message" => "Invalid Request"
      }
    }
    
    conn
    |> put_status(:bad_request)
    |> json(response)
  end
  
  # RPC method handlers (simplified for HTTP - no subscriptions)
  
  defp handle_rpc_method("eth_getBlockByNumber", [block_number, include_transactions], chain) do
    case get_chain_connection(chain) do
      {:ok, _connection} ->
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
  
  defp handle_rpc_method("eth_getLogs", [filter], chain) do
    Logger.debug("eth_getLogs called with filter: #{inspect(filter)} on #{chain}")
    {:ok, []}
  end
  
  defp handle_rpc_method("eth_getTransactionReceipt", [tx_hash], chain) do
    Logger.debug("eth_getTransactionReceipt called for: #{tx_hash} on #{chain}")
    {:ok, nil}
  end
  
  defp handle_rpc_method("eth_blockNumber", [], chain) do
    {:ok, "0x" <> Integer.to_string(:rand.uniform(20_000_000), 16)}
  end
  
  defp handle_rpc_method("eth_getBalance", [address, block], chain) do
    Logger.debug("eth_getBalance called for: #{address} at #{block} on #{chain}")
    {:ok, "0x" <> Integer.to_string(:rand.uniform(1000000000000000000), 16)}
  end
  
  defp handle_rpc_method("eth_subscribe", _params, _chain) do
    {:error, "Subscriptions not supported over HTTP. Use WebSocket endpoint."}
  end
  
  defp handle_rpc_method("eth_unsubscribe", _params, _chain) do
    {:error, "Subscriptions not supported over HTTP. Use WebSocket endpoint."}
  end
  
  defp handle_rpc_method(method, _params, _chain) do
    {:error, "Method not supported: #{method}"}
  end
  
  defp get_chain_connection(chain) do
    connections = WSSupervisor.list_connections()
    case Enum.find(connections, fn conn ->
      String.contains?(String.downcase(conn.name || ""), chain)
    end) do
      nil -> 
        # Try to start a connection if none exists
        ensure_chain_connection(chain)
        {:ok, :mock_connection}
      connection -> 
        {:ok, connection}
    end
  end
  
  defp ensure_chain_connection(chain) do
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