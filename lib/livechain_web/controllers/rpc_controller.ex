defmodule LivechainWeb.RPCController do
  @moduledoc """
  Ethereum JSON-RPC controller providing endpoints for blockchain interactions.

  This controller acts as a smart proxy that:
  - Forwards read-only RPC requests to the best-performing provider
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

  alias Livechain.RPC.ChainManager
  alias Livechain.Benchmarking.BenchmarkStore

  @ws_only_methods [
    "eth_subscribe",
    "eth_unsubscribe"
  ]

  @doc """
  Handle JSON-RPC requests for any supported chain.
  """
  def rpc(conn, %{"chain_id" => chain_id} = params) do
    case resolve_chain_name(chain_id) do
      {:ok, chain_name} ->
        # Support strategy via path segment (/rpc/:strategy/:chain) or query (?strategy=)
        strategy =
          params["strategy"] ||
            conn.params["strategy"]

        conn = assign(conn, :provider_strategy, parse_strategy(strategy))
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

    case process_json_rpc_request(params, chain, conn) do
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
  defp process_json_rpc_request(%{"method" => "eth_chainId", "params" => []}, chain, conn) do
    Logger.info("Getting chain ID", chain: chain)

    case get_chain_id(chain) do
      {:ok, chain_id} ->
        {:ok, chain_id}

      {:error, reason} ->
        {:error, %{code: -32603, message: "Failed to get chain ID: #{reason}"}}
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

  defp process_json_rpc_request(params, chain) do
    # Backwards compatibility when conn is not provided
    process_json_rpc_request(params, chain, %{})
  end

  defp process_json_rpc_request(_params, _chain) do
    Logger.warn("Invalid JSON-RPC request")
    {:error, -32600, "Invalid Request"}
  end

  defp unsupported_over_http?(method) do
    method in @ws_only_methods
  end

  @doc """
  Forward RPC request to the best-performing provider for the given chain.
  Uses performance benchmarks to select the optimal provider.
  Supports pluggable provider selection strategies via Application config:
    config :livechain, :provider_selection_strategy, :leaderboard | :priority | :round_robin
  """
  defp forward_rpc_request(chain, method, params, opts \\ []) do
    strategy =
      case Keyword.get(opts, :strategy) do
        nil ->
          case Map.get(opts, :conn) do
            %Plug.Conn{assigns: %{provider_strategy: s}} when not is_nil(s) -> s
            _ -> default_provider_strategy()
          end

        s ->
          s
      end

    case select_best_provider(chain, method, strategy) do
      {:ok, provider_id} ->
        # Measure request duration
        start_time = System.monotonic_time(:millisecond)
        
        case ChainManager.forward_rpc_request(chain, provider_id, method, params) do
          {:ok, result} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            record_rpc_success(chain, provider_id, method, duration_ms)
            {:ok, result}

          {:error, reason} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            record_rpc_failure(chain, provider_id, method, reason, duration_ms)

            case try_failover(chain, method, params, [provider_id]) do
              {:ok, result} -> {:ok, result}
              {:error, error} -> {:error, error}
            end
        end

      {:error, reason} ->
        {:error, %{code: -32000, message: "No available providers: #{reason}"}}
    end
  end

  defp default_provider_strategy do
    Application.get_env(:livechain, :provider_selection_strategy, :latency)
  end

  defp parse_strategy(nil), do: nil

  defp parse_strategy(str) when is_binary(str) do
    case String.downcase(str) do
      "leaderboard" -> :leaderboard
      "priority" -> :priority
      "round_robin" -> :round_robin
      "latency" -> :latency
      "latency_based" -> :latency
      "fastest" -> :latency  # "fastest" is an alias for latency-based selection
      "cheapest" -> :cheapest
      _ -> nil
    end
  end

  @doc """
  Select the best-performing provider for a given RPC method based on strategy.
  Supported strategies:
  - :leaderboard (default): Highest score from BenchmarkStore
  - :priority: First available by configured provider priority
  - :round_robin: Simple rotation among available providers
  """
  defp select_best_provider(chain, method, :leaderboard) do
    case BenchmarkStore.get_provider_leaderboard(chain) do
      {:ok, [_ | _] = leaderboard} ->
        [best_provider | _] = Enum.sort_by(leaderboard, & &1.score, :desc)
        {:ok, best_provider.provider_id}

      {:ok, []} ->
        select_best_provider(chain, method, :priority)

      {:error, _reason} ->
        select_best_provider(chain, method, :priority)
    end
  end

  defp select_best_provider(chain, _method, :priority) do
    case ChainManager.get_available_providers(chain) do
      {:ok, [provider_id | _]} -> {:ok, provider_id}
      {:ok, []} -> {:error, "No providers available"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_best_provider(chain, _method, :round_robin) do
    case ChainManager.get_available_providers(chain) do
      {:ok, []} ->
        {:error, "No providers available"}

      {:ok, providers} ->
        idx = rem(System.monotonic_time(:millisecond), length(providers))
        {:ok, Enum.at(providers, idx)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_best_provider(chain, _method, :latency) do
    case Livechain.RPC.ProviderPool.get_best_provider(chain) do
      nil -> 
        # Fallback to priority if no provider selected by pool
        select_best_provider(chain, :ignored, :priority)
      provider_id -> 
        {:ok, provider_id}
    end
  end

  defp select_best_provider(chain, _method, :cheapest) do
    case ChainManager.get_available_providers(chain) do
      {:ok, []} ->
        {:error, "No providers available"}

      {:ok, providers} ->
        # Get chain config to check provider types
        with {:ok, config} <- Livechain.Config.ChainConfig.load_config(),
             chain_config when not is_nil(chain_config) <- Map.get(config.chains, chain) do
          
          # First try public providers
          public_providers = filter_providers_by_type(chain_config.providers, providers, "public")
          
          case public_providers do
            [] ->
              # No public providers available, use paid providers
              paid_providers = filter_providers_by_type(chain_config.providers, providers, "paid")
              case paid_providers do
                [] -> {:error, "No providers available"}
                [provider_id | _] -> {:ok, provider_id}
              end
            _ ->
              # Round-robin among public providers
              idx = rem(System.monotonic_time(:millisecond), length(public_providers))
              {:ok, Enum.at(public_providers, idx)}
          end
        else
          _ -> 
            # Fallback to priority if config can't be loaded
            select_best_provider(chain, :ignored, :priority)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Helper function to filter providers by type (public, paid, dedicated)
  defp filter_providers_by_type(provider_configs, available_provider_ids, desired_type) do
    provider_configs
    |> Enum.filter(fn provider -> 
      provider.type == desired_type and provider.id in available_provider_ids
    end)
    |> Enum.map(& &1.id)
  end

  # Failover and benchmarking helpers remain the same

  @doc """
  Try failover to alternative providers if the primary provider fails.
  """
  defp try_failover(chain, method, params, excluded_providers) do
    case ChainManager.get_available_providers(chain) do
      {:ok, available_providers} ->
        remaining_providers = available_providers -- excluded_providers

        case remaining_providers do
          [] ->
            {:error, %{code: -32000, message: "All providers failed for method: #{method}"}}

          [next_provider | _] ->
            Logger.warning("Failing over to provider",
              chain: chain,
              method: method,
              provider: next_provider
            )

            # Measure failover request duration
            start_time = System.monotonic_time(:millisecond)
            
            case ChainManager.forward_rpc_request(chain, next_provider, method, params) do
              {:ok, result} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time
                record_rpc_success(chain, next_provider, method, duration_ms)
                {:ok, result}

              {:error, reason} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time
                record_rpc_failure(chain, next_provider, method, reason, duration_ms)
                try_failover(chain, method, params, [next_provider | excluded_providers])
            end
        end

      {:error, reason} ->
        {:error, %{code: -32000, message: "Failed to get available providers: #{reason}"}}
    end
  end

  @doc """
  Record successful RPC call for performance benchmarking.
  """
  defp record_rpc_success(chain, provider_id, method, duration_ms) do
    # Record in BenchmarkStore for historical analysis
    BenchmarkStore.record_rpc_call(chain, provider_id, method, duration_ms, :success)
    
    # Update ProviderPool with real-time metrics for provider selection
    Livechain.RPC.ProviderPool.report_success(chain, provider_id, duration_ms)
  end

  @doc """
  Record failed RPC call for performance benchmarking.
  """
  defp record_rpc_failure(chain, provider_id, method, reason, duration_ms) do
    # Record in BenchmarkStore for historical analysis
    BenchmarkStore.record_rpc_call(chain, provider_id, method, duration_ms, :error)
    
    # Update ProviderPool with failure information for provider selection
    Livechain.RPC.ProviderPool.report_failure(chain, provider_id, reason)
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
