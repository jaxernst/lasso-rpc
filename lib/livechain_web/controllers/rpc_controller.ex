defmodule LivechainWeb.RPCController do
  @moduledoc """
  Ethereum JSON-RPC controller providing Viem-compatible endpoints for blockchain interactions.

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
  Handle JSON-RPC requests for any supported chain.
  """
  def rpc(conn, %{"chain_id" => chain_id}) do
    case resolve_chain_name(chain_id) do
      {:ok, chain_name} ->
        handle_chain_rpc(conn, chain_name)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32602,
            message: "Unsupported chain: #{reason}"
          },
          id: nil
        })
    end
  end

  @doc """
  Handle Ethereum JSON-RPC requests (backward compatibility).
  """
  def ethereum(conn, _params), do: handle_chain_rpc(conn, "ethereum")

  @doc """
  Handle Arbitrum JSON-RPC requests (backward compatibility).
  """
  def arbitrum(conn, _params), do: handle_chain_rpc(conn, "arbitrum")

  @doc """
  Handle Polygon JSON-RPC requests (backward compatibility).
  """
  def polygon(conn, _params), do: handle_chain_rpc(conn, "polygon")

  @doc """
  Handle BSC JSON-RPC requests (backward compatibility).
  """
  def bsc(conn, _params), do: handle_chain_rpc(conn, "bsc")

  defp handle_chain_rpc(conn, chain_name) do
    case read_json_body(conn) do
      {:ok, params} ->
        handle_json_rpc(conn, params, chain_name)

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

  defp resolve_chain_name(chain_identifier) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        cond do
          is_binary(chain_identifier) and Map.has_key?(config.chains, chain_identifier) ->
            {:ok, chain_identifier}

          is_integer(chain_identifier) ->
            case find_chain_by_id(config, chain_identifier) do
              {:ok, chain_name} -> {:ok, chain_name}
              :not_found -> {:error, "Chain ID #{chain_identifier} not configured"}
            end

          is_binary(chain_identifier) ->
            case Integer.parse(chain_identifier) do
              {chain_id, ""} ->
                case find_chain_by_id(config, chain_id) do
                  {:ok, chain_name} -> {:ok, chain_name}
                  :not_found -> {:error, "Chain ID #{chain_id} not configured"}
                end

              _ ->
                {:error, "Invalid chain identifier: #{chain_identifier}"}
            end

          true ->
            {:error, "Invalid chain identifier format"}
        end

      {:error, _reason} ->
        {:error, "Failed to load chain configuration"}
    end
  end

  defp find_chain_by_id(config, chain_id) do
    case Enum.find(config.chains, fn {_name, chain_config} ->
           chain_config.chain_id == chain_id
         end) do
      {chain_name, _config} -> {:ok, chain_name}
      nil -> :not_found
    end
  end

  defp get_chain_id(chain_name) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        case Livechain.Config.ChainConfig.get_chain_config(config, chain_name) do
          {:ok, chain_config} ->
            chain_id = chain_config.chain_id

            cond do
              is_integer(chain_id) ->
                {:ok, "0x" <> Integer.to_string(chain_id, 16)}

              is_binary(chain_id) ->
                {:ok, chain_id}

              true ->
                {:error, "Invalid chain ID format for: #{chain_name}"}
            end

          {:error, :chain_not_found} ->
            {:error, "Chain not configured: #{chain_name}"}
        end

      {:error, _reason} ->
        {:error, "Failed to load chain configuration"}
    end
  end

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
