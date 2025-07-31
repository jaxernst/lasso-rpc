defmodule LivechainWeb.RPCController do
  @moduledoc """
  JSON-RPC controller providing Viem-compatible endpoints for blockchain interactions.

  This controller implements the Ethereum JSON-RPC specification to provide
  drop-in compatibility with Viem, Wagmi, and other Ethereum client libraries.

  Supported methods:
  - eth_subscribe: Real-time event subscriptions
  - eth_getLogs: Historical log queries
  - eth_getBlockByNumber: Block data retrieval
  - eth_blockNumber: Latest block number
  - eth_chainId: Chain identification
  """

  use LivechainWeb, :controller
  require Logger

  alias Livechain.RPC.ChainManager
  alias Livechain.RPC.SubscriptionManager

  @doc """
  Handle Ethereum JSON-RPC requests.
  """
  def ethereum(conn, _params) do
    case read_json_body(conn) do
      {:ok, params} ->
        handle_json_rpc(conn, params, "ethereum")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32700,
            message: "Parse error: #{reason}"
          },
          id: nil
        })
    end
  end

  @doc """
  Handle Arbitrum JSON-RPC requests.
  """
  def arbitrum(conn, _params) do
    case read_json_body(conn) do
      {:ok, params} ->
        handle_json_rpc(conn, params, "arbitrum")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32700,
            message: "Parse error: #{reason}"
          },
          id: nil
        })
    end
  end

  @doc """
  Handle Polygon JSON-RPC requests.
  """
  def polygon(conn, _params) do
    case read_json_body(conn) do
      {:ok, params} ->
        handle_json_rpc(conn, params, "polygon")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32700,
            message: "Parse error: #{reason}"
          },
          id: nil
        })
    end
  end

  @doc """
  Handle BSC JSON-RPC requests.
  """
  def bsc(conn, _params) do
    case read_json_body(conn) do
      {:ok, params} ->
        handle_json_rpc(conn, params, "bsc")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32700,
            message: "Parse error: #{reason}"
          },
          id: nil
        })
    end
  end

  defp handle_json_rpc(conn, params, chain) do
    Logger.info("JSON-RPC request", method: params["method"], chain: chain, id: params["id"])

    case process_json_rpc_request(params, chain) do
      {:ok, result} ->
        response = %{
          jsonrpc: "2.0",
          result: result,
          id: params["id"]
        }

        json(conn, response)

      {:error, error} ->
        response = %{
          jsonrpc: "2.0",
          error: %{
            code: error.code || -32603,
            message: error.message || "Internal error",
            data: error.data
          },
          id: params["id"]
        }

        json(conn, response)

      {:error, code, message} ->
        response = %{
          jsonrpc: "2.0",
          error: %{
            code: code,
            message: message
          },
          id: params["id"]
        }

        json(conn, response)
    end
  end

  defp process_json_rpc_request(
         %{"method" => "eth_subscribe", "params" => ["logs", filter]},
         chain
       ) do
    Logger.info("Subscribing to logs", chain: chain, filter: filter)

    case SubscriptionManager.subscribe_to_logs(chain, filter) do
      {:ok, subscription_id} ->
        {:ok, subscription_id}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Subscription failed: #{reason}"}}
    end
  end

  defp process_json_rpc_request(%{"method" => "eth_subscribe", "params" => ["newHeads"]}, chain) do
    Logger.info("Subscribing to new heads", chain: chain)

    case SubscriptionManager.subscribe_to_new_heads(chain) do
      {:ok, subscription_id} ->
        {:ok, subscription_id}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Subscription failed: #{reason}"}}
    end
  end

  defp process_json_rpc_request(%{"method" => "eth_getLogs", "params" => [filter]}, chain) do
    Logger.info("Getting logs", chain: chain, filter: filter)

    case ChainManager.get_logs(chain, filter) do
      {:ok, logs} ->
        {:ok, logs}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get logs: #{reason}"}}
    end
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getBlockByNumber", "params" => [block_number, include_transactions]},
         chain
       ) do
    Logger.info("Getting block by number", chain: chain, block: block_number)

    case ChainManager.get_block_by_number(chain, block_number, include_transactions) do
      {:ok, block} ->
        {:ok, block}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get block: #{reason}"}}
    end
  end

  defp process_json_rpc_request(%{"method" => "eth_blockNumber", "params" => []}, chain) do
    Logger.info("Getting block number", chain: chain)

    case ChainManager.get_block_number(chain) do
      {:ok, block_number} ->
        {:ok, block_number}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get block number: #{reason}"}}
    end
  end

  defp process_json_rpc_request(%{"method" => "eth_chainId", "params" => []}, chain) do
    Logger.info("Getting chain ID", chain: chain)

    case get_chain_id(chain) do
      {:ok, chain_id} ->
        {:ok, chain_id}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get chain ID: #{reason}"}}
    end
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getBalance", "params" => [address, block]},
         chain
       ) do
    Logger.info("Getting balance", chain: chain, address: address)

    case ChainManager.get_balance(chain, address, block) do
      {:ok, balance} ->
        {:ok, balance}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get balance: #{reason}"}}
    end
  end

  defp process_json_rpc_request(%{"method" => method, "params" => _params}, _chain) do
    Logger.warn("Unsupported JSON-RPC method", method: method)
    {:error, -32601, "Method not found"}
  end

  defp process_json_rpc_request(%{"method" => method}, _chain) do
    Logger.warn("Unsupported JSON-RPC method", method: method)
    {:error, -32601, "Method not found"}
  end

  defp process_json_rpc_request(_params, _chain) do
    Logger.warn("Invalid JSON-RPC request")
    {:error, -32600, "Invalid Request"}
  end

  defp get_chain_id("ethereum"), do: {:ok, "0x1"}
  defp get_chain_id("arbitrum"), do: {:ok, "0xa4b1"}
  defp get_chain_id("polygon"), do: {:ok, "0x89"}
  defp get_chain_id("bsc"), do: {:ok, "0x38"}
  defp get_chain_id("base"), do: {:ok, "0x2105"}
  defp get_chain_id("optimism"), do: {:ok, "0xa"}
  defp get_chain_id("avalanche"), do: {:ok, "0xa86a"}
  defp get_chain_id("zksync"), do: {:ok, "0x144"}
  defp get_chain_id("linea"), do: {:ok, "0xe708"}
  defp get_chain_id("scroll"), do: {:ok, "0x82750"}
  defp get_chain_id("mantle"), do: {:ok, "0x1388"}
  defp get_chain_id("blast"), do: {:ok, "0x13e31"}
  defp get_chain_id("mode"), do: {:ok, "0x86a7"}
  defp get_chain_id("fantom"), do: {:ok, "0xfa"}
  defp get_chain_id("celo"), do: {:ok, "0xa4ec"}
  defp get_chain_id(_), do: {:error, "Unknown chain"}

  defp read_json_body(conn) do
    case read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, params} -> {:ok, params}
          {:error, reason} -> {:error, "Invalid JSON: #{reason}"}
        end

      {:more, _body, _conn} ->
        {:error, "Request body too large"}

      {:error, reason} ->
        {:error, "Failed to read body: #{reason}"}
    end
  end
end
