defmodule LivechainWeb.RPCController do
  @moduledoc """
  Ethereum JSON-RPC controller providing endpoints for blockchain interactions.

  This controller acts as a smart proxy that:
  - Forwards read-only RPC requests a provider based on a selected strategy
  - Routes requests based on real-time performance benchmarks
  - Provides automatic failover to healthy providers
  - Rejects subscription requests (use WebSocket for real-time events)

  Supported methods:
  - eth_getLogs: Historical log queries
  - eth_getBlockByNumber: Block data retrieval
  - eth_blockNumber: Latest block number
  - eth_chainId: Chain identification
  - eth_getBalance: Account balance queries
  - eth_getTransactionCount: Account nonce
  - eth_getCode: Contract code
  - eth_call: Contract read calls
  - eth_estimateGas: Gas estimation
  - eth_gasPrice: Current gas price
  - eth_maxPriorityFeePerGas: EIP-1559 fee data
  - eth_feeHistory: Historical fee data
  """

  use LivechainWeb, :controller
  require Logger

  alias Livechain.RPC.{ChainRegistry, Failover, Error}
  alias Livechain.Config.ConfigStore

  @ws_only_methods [
    "eth_subscribe",
    "eth_unsubscribe"
  ]

  @doc """
  Handle JSON-RPC requests for any supported chain.
  """
  def rpc(conn, params) do
    Logger.info("RPC request received", params: inspect(params), path: conn.request_path)

    case Map.get(params, "chain_id") do
      nil ->
        Logger.error("Missing chain_id parameter", params: inspect(params))

        conn
        |> put_status(:bad_request)
        |> json(%{
          jsonrpc: "2.0",
          error: %{
            code: -32602,
            message: "Missing chain_id parameter"
          },
          id: nil
        })

      chain_id ->
        case resolve_chain_name(chain_id) do
          {:ok, chain_name} ->
            # Support strategy via path segment (/rpc/:strategy/:chain) or query (?strategy=)
            strategy =
              params["strategy"] ||
                conn.params["strategy"]

            parsed = parse_strategy(strategy)
            conn = assign(conn, :provider_strategy, parsed)

            maybe_publish_strategy_event(chain_name, parsed)

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
  end

  defp maybe_publish_strategy_event(_chain, nil), do: :ok

  defp maybe_publish_strategy_event(chain, strategy) do
    default = Application.get_env(:livechain, :provider_selection_strategy, :cheapest)

    if strategy != default do
      Phoenix.PubSub.broadcast(
        Livechain.PubSub,
        "strategy:events",
        %{
          ts: System.system_time(:millisecond),
          scope: {:chain, chain},
          from: default,
          to: strategy,
          reason: :request_override
        }
      )
    else
      :ok
    end
  end

  defp handle_chain_rpc(conn, chain_name) do
    # Phoenix has already parsed the JSON body into conn.params
    params = conn.params
    handle_json_rpc(conn, params, chain_name)
  end

  defp handle_json_rpc(conn, params, chain) do
    Logger.info("JSON-RPC request", method: params["method"], chain: chain, id: params["id"])

    case process_json_rpc_request(params, chain, conn) do
      {:ok, result} ->
        response = %{
          jsonrpc: "2.0",
          result: result,
          id: params["id"]
        }

        json(conn, response)

      {:error, error} ->
        # Normalize error to JSON-RPC format
        normalized_error =
          case error do
            %{code: _, message: _} -> error
            error_tuple -> Error.to_json_rpc(error_tuple)
          end

        # Build error response with required fields and optional data
        error_data =
          %{
            code: normalized_error[:code] || -32603,
            message: normalized_error[:message] || "Internal error"
          }
          |> Map.merge(Map.take(normalized_error, [:data]))

        response = %{
          jsonrpc: "2.0",
          error: error_data,
          id: params["id"]
        }

        json(conn, response)
    end
  end

  # Block and transaction queries
  defp process_json_rpc_request(
         %{"method" => "eth_getLogs", "params" => [filter]},
         chain,
         conn
       ) do
    Logger.info("Getting logs", chain: chain, filter: filter)
    forward_rpc_request(chain, "eth_getLogs", [filter], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getBlockByNumber", "params" => [block_number, include_transactions]},
         chain,
         conn
       ) do
    Logger.info("Getting block by number", chain: chain, block: block_number)

    forward_rpc_request(chain, "eth_getBlockByNumber", [block_number, include_transactions],
      conn: conn
    )
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getBlockByHash", "params" => [block_hash, include_transactions]},
         chain,
         conn
       ) do
    Logger.info("Getting block by hash", chain: chain, block_hash: block_hash)

    forward_rpc_request(chain, "eth_getBlockByHash", [block_hash, include_transactions],
      conn: conn
    )
  end

  defp process_json_rpc_request(%{"method" => "eth_blockNumber", "params" => []}, chain, conn) do
    Logger.info("Getting block number", chain: chain)
    forward_rpc_request(chain, "eth_blockNumber", [], conn: conn)
  end

  # Account and contract queries
  defp process_json_rpc_request(
         %{"method" => "eth_getBalance", "params" => [address, block]},
         chain,
         conn
       ) do
    Logger.info("Getting balance", chain: chain, address: address)
    forward_rpc_request(chain, "eth_getBalance", [address, block], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getTransactionCount", "params" => [address, block]},
         chain,
         conn
       ) do
    Logger.info("Getting transaction count", chain: chain, address: address)
    forward_rpc_request(chain, "eth_getTransactionCount", [address, block], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getCode", "params" => [address, block]},
         chain,
         conn
       ) do
    Logger.info("Getting contract code", chain: chain, address: address)
    forward_rpc_request(chain, "eth_getCode", [address, block], conn: conn)
  end

  # Contract interaction queries
  defp process_json_rpc_request(
         %{"method" => "eth_call", "params" => [call_object, block]},
         chain,
         conn
       ) do
    Logger.info("Making contract call", chain: chain, call_object: call_object)
    forward_rpc_request(chain, "eth_call", [call_object, block], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_estimateGas", "params" => [call_object, block]},
         chain,
         conn
       ) do
    Logger.info("Estimating gas", chain: chain, call_object: call_object)
    forward_rpc_request(chain, "eth_estimateGas", [call_object, block], conn: conn)
  end

  # Gas and fee queries
  defp process_json_rpc_request(%{"method" => "eth_gasPrice", "params" => []}, chain, conn) do
    Logger.info("Getting gas price", chain: chain)
    forward_rpc_request(chain, "eth_gasPrice", [], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_maxPriorityFeePerGas", "params" => []},
         chain,
         conn
       ) do
    Logger.info("Getting max priority fee", chain: chain)
    forward_rpc_request(chain, "eth_maxPriorityFeePerGas", [], conn: conn)
  end

  defp process_json_rpc_request(
         %{
           "method" => "eth_feeHistory",
           "params" => [block_count, newest_block, reward_percentiles]
         },
         chain,
         conn
       ) do
    Logger.info("Getting fee history", chain: chain, block_count: block_count)

    forward_rpc_request(chain, "eth_feeHistory", [block_count, newest_block, reward_percentiles],
      conn: conn
    )
  end

  # Chain info
  defp process_json_rpc_request(%{"method" => "eth_chainId", "params" => []}, chain, _conn) do
    Logger.info("Getting chain ID", chain: chain)

    case get_chain_id(chain) do
      {:ok, chain_id} ->
        {:ok, chain_id}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get chain ID: #{reason}"}}
    end
  end

  # Debug method for chain status
  defp process_json_rpc_request(%{"method" => "debug_chains", "params" => []}, _chain, _conn) do
    case ChainRegistry.get_status() do
      status when is_map(status) ->
        {:ok, status}

      error ->
        {:error, %{code: -32603, message: "Failed to get chain status: #{inspect(error)}"}}
    end
  end

  # Debug method to manually start chains
  defp process_json_rpc_request(
         %{"method" => "debug_start_chains", "params" => []},
         _chain,
         _conn
       ) do
    case ChainRegistry.start_all_chains() do
      {:ok, started_count} ->
        {:ok,
         %{started_count: started_count, message: "Started #{started_count} chain supervisors"}}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to start chains: #{inspect(reason)}"}}
    end
  end

  # Generic method handler: forward allowed methods, reject unsupported-over-HTTP methods
  defp process_json_rpc_request(%{"method" => method, "params" => params}, chain, conn) do
    if unsupported_over_http?(method) do
      {:error,
       %{
         code: -32601,
         message: "Method not supported over HTTP. Use WebSocket connection for subscriptions.",
         data: %{
           websocket_url: "/socket/websocket",
           supported_http_methods: [
             "eth_getLogs",
             "eth_getBlockByNumber",
             "eth_blockNumber",
             "eth_chainId",
             "eth_getBalance",
             "eth_getTransactionCount",
             "eth_getCode",
             "eth_call",
             "eth_estimateGas",
             "eth_gasPrice",
             "eth_maxPriorityFeePerGas",
             "eth_feeHistory"
           ]
         }
       }}
    else
      Logger.info("Forwarding RPC method", method: method, chain: chain, params: params)
      forward_rpc_request(chain, method, params, conn: conn)
    end
  end

  defp process_json_rpc_request(%{"method" => method}, chain, conn) do
    if unsupported_over_http?(method) do
      {:error,
       %{
         code: -32601,
         message: "Method not supported over HTTP. Use WebSocket connection for subscriptions.",
         data: %{
           websocket_url: "/socket/websocket"
         }
       }}
    else
      Logger.info("Forwarding RPC method", method: method, chain: chain, params: [])
      forward_rpc_request(chain, method, [], conn: conn)
    end
  end

  defp unsupported_over_http?(method) do
    method in @ws_only_methods
  end

  defp forward_rpc_request(chain, method, params, opts) do
    with {:ok, strategy} <- extract_strategy(opts),
         {:ok, region_filter} <- extract_region_filter(opts) do
      failover_opts = [
        strategy: strategy,
        protocol: :http,
        region_filter: region_filter
      ]

      Failover.execute_with_failover(chain, method, params, failover_opts)
    else
      {:error, reason} ->
        {:error, %{code: -32000, message: "Failed to extract request options: #{reason}"}}
    end
  end

  defp extract_strategy(opts) do
    strategy =
      case Keyword.get(opts, :strategy) do
        nil ->
          case Keyword.get(opts, :conn) do
            %Plug.Conn{assigns: %{provider_strategy: s}} when not is_nil(s) -> s
            _ -> default_provider_strategy()
          end

        s ->
          s
      end

    {:ok, strategy}
  end

  defp extract_region_filter(opts) do
    region_filter =
      case Keyword.get(opts, :conn) do
        %Plug.Conn{} = conn ->
          Plug.Conn.get_req_header(conn, "x-livechain-region") |> List.first()

        _ ->
          nil
      end

    {:ok, region_filter}
  end

  defp default_provider_strategy do
    Application.get_env(:livechain, :provider_selection_strategy, :cheapest)
  end

  def parse_strategy(nil), do: nil

  def parse_strategy(str) when is_binary(str) do
    case String.downcase(str) do
      "priority" -> :priority
      "round_robin" -> :round_robin
      "fastest" -> :fastest
      "cheapest" -> :cheapest
      _ -> nil
    end
  end

  defp resolve_chain_name(chain_identifier) do
    all_chains = ConfigStore.get_all_chains()

    cond do
      is_binary(chain_identifier) and Map.has_key?(all_chains, chain_identifier) ->
        {:ok, chain_identifier}

      is_integer(chain_identifier) ->
        case find_chain_by_id(all_chains, chain_identifier) do
          {:ok, chain_name} -> {:ok, chain_name}
          :not_found -> {:error, "Chain ID #{chain_identifier} not configured"}
        end

      is_binary(chain_identifier) ->
        case Integer.parse(chain_identifier) do
          {chain_id, ""} ->
            case find_chain_by_id(all_chains, chain_id) do
              {:ok, chain_name} -> {:ok, chain_name}
              :not_found -> {:error, "Chain ID #{chain_id} not configured"}
            end

          _ ->
            {:error, "Invalid chain identifier: #{chain_identifier}"}
        end

      true ->
        {:error, "Invalid chain identifier format"}
    end
  end

  defp find_chain_by_id(chains, chain_id) do
    case Enum.find(chains, fn {_name, chain_config} ->
           chain_config.chain_id == chain_id
         end) do
      {chain_name, _config} -> {:ok, chain_name}
      nil -> :not_found
    end
  end

  defp get_chain_id(chain_name) do
    case ConfigStore.get_chain(chain_name) do
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

      {:error, :not_found} ->
        {:error, "Chain not configured: #{chain_name}"}
    end
  end
end
