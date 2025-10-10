defmodule LassoWeb.RPCController do
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

  use LassoWeb, :controller
  require Logger

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Config.ConfigStore
  alias LassoWeb.Plugs.ObservabilityPlug

  @jsonrpc_version "2.0"

  @ws_only_methods [
    "eth_subscribe",
    "eth_unsubscribe"
  ]

  # Additional HTTP disallowed methods (stateful or account management)
  @http_disallowed_methods [
    "eth_sendRawTransaction",
    "eth_sendTransaction",
    "personal_sign",
    "eth_sign",
    "eth_signTransaction",
    "eth_accounts",
    "txpool_content",
    "txpool_inspect",
    "txpool_status"
  ]

  @max_batch_requests Application.compile_env(:lasso, :max_batch_requests, 50)

  @doc """
  Handle JSON-RPC requests for any supported chain.
  """
  def rpc(conn, %{"chain_id" => chain_id} = params) do
    case chain_id do
      nil ->
        Logger.error("Missing chain_id parameter", params: inspect(params))

        error = JError.new(-32602, "Missing chain_id parameter")

        conn
        |> put_status(:bad_request)
        |> json(JError.to_response(error, nil))

      chain_id ->
        case resolve_chain_name(chain_id) do
          {:ok, chain_name} ->
            # Check if strategy was already assigned by strategy-specific endpoint
            strategy_atom =
              case conn.assigns[:provider_strategy] do
                nil ->
                  # No strategy assigned yet, check URL params (for backward compatibility)
                  strategy_str = params["strategy"]

                  case strategy_str do
                    "priority" -> :priority
                    "round_robin" -> :round_robin
                    "fastest" -> :fastest
                    "cheapest" -> :cheapest
                    _ -> default_provider_strategy()
                  end

                existing_strategy ->
                  # Strategy already assigned by endpoint-specific handler
                  existing_strategy
              end

            conn = assign(conn, :provider_strategy, strategy_atom)

            maybe_publish_strategy_event(chain_name, strategy_atom)

            handle_chain_rpc(conn, chain_name)

          {:error, reason} ->
            error = JError.new(-32602, "Unsupported chain: #{reason}")

            conn
            |> put_status(:bad_request)
            |> json(JError.to_response(error, nil))
        end
    end
  end

  def rpc_base(conn, params) do
    Logger.debug("RPC_BASE called with params: #{inspect(Map.keys(params))}", chain: "base")
    rpc_with_strategy(conn, params, :cheapest)
  end

  def rpc_fastest(conn, params) do
    Logger.debug("RPC_FASTEST called with params: #{inspect(Map.keys(params))}", chain: "fastest")
    rpc_with_strategy(conn, params, :fastest)
  end

  def rpc_cheapest(conn, params), do: rpc_with_strategy(conn, params, :cheapest)
  def rpc_priority(conn, params), do: rpc_with_strategy(conn, params, :priority)
  def rpc_round_robin(conn, params), do: rpc_with_strategy(conn, params, :round_robin)

  defp rpc_with_strategy(conn, params, strategy_atom) do
    conn
    |> assign(:provider_strategy, strategy_atom)
    |> rpc(params)
  end

  def rpc_provider_override(
        conn,
        %{"provider_id" => provider_id, "chain_id" => chain_id} = params
      ) do
    handle_provider_override_rpc(conn, params, chain_id, provider_id)
  end

  defp handle_provider_override_rpc(conn, params, chain_id, provider_id) do
    Logger.info("Provider override RPC request",
      provider_id: provider_id,
      chain_id: chain_id,
      method: params["method"]
    )

    # Add provider override to params and delegate to main rpc function
    params_with_override =
      Map.merge(params, %{
        "chain_id" => chain_id,
        "provider_override" => provider_id
      })

    rpc(conn, params_with_override)
  end

  defp maybe_publish_strategy_event(_chain, nil), do: :ok

  defp maybe_publish_strategy_event(chain, strategy) do
    default = Application.get_env(:lasso, :provider_selection_strategy, :cheapest)

    if strategy != default do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
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
    body = Map.get(conn.params, "_json", conn.params)

    case body do
      requests when is_list(requests) ->
        handle_json_rpc_batch(conn, requests, chain_name)

      request when is_map(request) ->
        handle_json_rpc(conn, request, chain_name)

      _ ->
        error = JError.new(-32600, "Invalid Request")
        json(conn, JError.to_response(error, nil))
    end
  end

  defp handle_json_rpc(conn, params, chain) do
    with {:ok, request} <- validate_json_rpc_request(params),
         {:ok, result} <- process_json_rpc_request(request, chain, conn) do
      response = %{
        jsonrpc: @jsonrpc_version,
        result: result,
        id: request["id"]
      }

      # Inject observability metadata if requested
      conn = maybe_inject_observability_metadata(conn)

      # Enrich response body if include_meta=body
      response =
        case conn.assigns[:include_meta] do
          :body ->
            case Process.get(:request_context) do
              nil -> response
              ctx -> ObservabilityPlug.enrich_response_body(response, ctx)
            end

          _ ->
            response
        end

      json(conn, response)
    else
      {:error, error} ->
        # Inject observability metadata even for errors
        conn = maybe_inject_observability_metadata(conn)

        json(
          conn,
          error
          |> JError.from()
          |> JError.to_response(Map.get(params, "id"))
        )
    end
  end

  defp handle_json_rpc_batch(conn, requests, chain) do
    if length(requests) > @max_batch_requests do
      error = JError.new(-32600, "Invalid Request: batch too large")
      json(conn, JError.to_response(error, nil))
    else
      results =
        Enum.map(requests, fn req ->
          case validate_json_rpc_request(req) do
            {:ok, request} ->
              case process_json_rpc_request(request, chain, conn) do
                {:ok, result} ->
                  %{jsonrpc: @jsonrpc_version, result: result, id: request["id"]}

                {:error, error} ->
                  JError.to_response(JError.from(error), request["id"])
              end

            {:error, error} ->
              JError.to_response(JError.from(error), Map.get(req, "id"))
          end
        end)

      json(conn, results)
    end
  end

  defp validate_json_rpc_request(%{"method" => method} = request) when is_binary(method) do
    cond do
      Map.has_key?(request, "jsonrpc") and request["jsonrpc"] != @jsonrpc_version ->
        {:error, JError.new(-32600, "Invalid Request: jsonrpc must be \"2.0\"")}

      true ->
        normalized =
          Map.update(request, "params", [], fn
            nil -> []
            list when is_list(list) -> list
            map when is_map(map) -> [map]
            other -> [other]
          end)

        {:ok, normalized}
    end
  end

  defp validate_json_rpc_request(_), do: {:error, JError.new(-32600, "Invalid Request")}

  # Block and transaction queries
  defp process_json_rpc_request(
         %{"method" => "eth_getLogs", "params" => [filter]},
         chain,
         conn
       ) do
    Logger.debug("Getting logs", chain: chain)
    forward_rpc_request(chain, "eth_getLogs", [filter], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getBlockByNumber", "params" => [block_number, include_transactions]},
         chain,
         conn
       ) do
    Logger.debug("Getting block by number", chain: chain)

    forward_rpc_request(chain, "eth_getBlockByNumber", [block_number, include_transactions],
      conn: conn
    )
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getBlockByHash", "params" => [block_hash, include_transactions]},
         chain,
         conn
       ) do
    Logger.debug("Getting block by hash", chain: chain)

    forward_rpc_request(chain, "eth_getBlockByHash", [block_hash, include_transactions],
      conn: conn
    )
  end

  defp process_json_rpc_request(%{"method" => "eth_blockNumber", "params" => []}, chain, conn) do
    Logger.debug("Getting block number", chain: chain)
    forward_rpc_request(chain, "eth_blockNumber", [], conn: conn)
  end

  # Account and contract queries
  defp process_json_rpc_request(
         %{"method" => "eth_getBalance", "params" => [address, block]},
         chain,
         conn
       ) do
    Logger.debug("Getting balance", chain: chain)
    forward_rpc_request(chain, "eth_getBalance", [address, block], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getTransactionCount", "params" => [address, block]},
         chain,
         conn
       ) do
    Logger.debug("Getting transaction count", chain: chain)
    forward_rpc_request(chain, "eth_getTransactionCount", [address, block], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_getCode", "params" => [address, block]},
         chain,
         conn
       ) do
    Logger.debug("Getting contract code", chain: chain)
    forward_rpc_request(chain, "eth_getCode", [address, block], conn: conn)
  end

  # Contract interaction queries
  defp process_json_rpc_request(
         %{"method" => "eth_call", "params" => [call_object, block]},
         chain,
         conn
       ) do
    Logger.debug("Making contract call", chain: chain)
    forward_rpc_request(chain, "eth_call", [call_object, block], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_estimateGas", "params" => [call_object, block]},
         chain,
         conn
       ) do
    Logger.debug("Estimating gas", chain: chain)
    forward_rpc_request(chain, "eth_estimateGas", [call_object, block], conn: conn)
  end

  # Gas and fee queries
  defp process_json_rpc_request(%{"method" => "eth_gasPrice", "params" => []}, chain, conn) do
    Logger.debug("Getting gas price", chain: chain)
    forward_rpc_request(chain, "eth_gasPrice", [], conn: conn)
  end

  defp process_json_rpc_request(
         %{"method" => "eth_maxPriorityFeePerGas", "params" => []},
         chain,
         conn
       ) do
    Logger.debug("Getting max priority fee", chain: chain)
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
    Logger.debug("Getting fee history", chain: chain)

    forward_rpc_request(chain, "eth_feeHistory", [block_count, newest_block, reward_percentiles],
      conn: conn
    )
  end

  # Chain info
  defp process_json_rpc_request(%{"method" => "eth_chainId", "params" => []}, chain, _conn) do
    Logger.debug("Getting chain ID", chain: chain)

    case get_chain_id(chain) do
      {:ok, chain_id} ->
        {:ok, chain_id}

      {:error, reason} ->
        {:error, JError.new(-32603, "Failed to get chain ID: #{reason}")}
    end
  end

  # Reject WS-only methods over HTTP
  defp process_json_rpc_request(%{"method" => method}, _chain, _conn)
       when method in @ws_only_methods do
    {:error,
     JError.new(
       -32601,
       "Method not supported over HTTP. Use WebSocket connection for subscriptions.",
       data: %{websocket_url: "/socket/websocket"}
     )}
  end

  # Reject stateful/account methods over HTTP
  defp process_json_rpc_request(%{"method" => method}, _chain, _conn)
       when method in @http_disallowed_methods do
    {:error, JError.new(-32601, "Method not supported by proxy")}
  end

  # Generic method handler: forward allowed methods
  defp process_json_rpc_request(%{"method" => method, "params" => params}, chain, conn) do
    Logger.debug("Forwarding RPC method", method: method, chain: chain)
    forward_rpc_request(chain, method, params || [], conn: conn)
  end

  defp process_json_rpc_request(%{"method" => method}, chain, conn) do
    process_json_rpc_request(%{"method" => method, "params" => []}, chain, conn)
  end

  # Unified forwarding: extracts strategy and optional provider override, delegates to RequestPipeline
  defp forward_rpc_request(chain, method, params, opts) when is_list(opts) do
    with {:ok, strategy} <- extract_strategy(opts) do
      provider_override =
        case Keyword.get(opts, :provider_override) do
          pid when is_binary(pid) ->
            pid

          _ ->
            case Keyword.get(opts, :conn) do
              %Plug.Conn{params: %{"provider_override" => pid}} when is_binary(pid) -> pid
              _ -> nil
            end
        end

      pipeline_opts = [
        strategy: strategy,
        provider_override: provider_override,
        failover_on_override: false
      ]

      Lasso.RPC.RequestPipeline.execute_via_channels(chain, method, params, pipeline_opts)
    else
      {:error, reason} ->
        {:error, JError.new(-32000, "Failed to extract request options: #{reason}")}
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

  defp default_provider_strategy do
    Application.get_env(:lasso, :provider_selection_strategy, :cheapest)
  end

  defp resolve_chain_name(chain_identifier) do
    case ConfigStore.get_chain_by_name_or_id(chain_identifier) do
      {:ok, {chain_name, _chain_config}} ->
        {:ok, chain_name}

      {:error, :not_found} ->
        {:error, "Chain ID #{inspect(chain_identifier)} not configured"}

      {:error, :invalid_format} ->
        {:error, "Invalid chain identifier: #{inspect(chain_identifier)}"}
    end
  end

  defp get_chain_id(chain_name) do
    case ConfigStore.get_chain(chain_name) do
      {:ok, %{chain_id: chain_id}} when is_integer(chain_id) ->
        {:ok, "0x" <> Integer.to_string(chain_id, 16)}

      {:error, :not_found} ->
        {:error, "Chain not configured: #{chain_name}"}
    end
  end

  defp maybe_inject_observability_metadata(conn) do
    case conn.assigns[:include_meta] do
      :headers ->
        case Process.get(:request_context) do
          nil -> conn
          ctx -> ObservabilityPlug.inject_metadata(conn, ctx)
        end

      _ ->
        conn
    end
  end
end
