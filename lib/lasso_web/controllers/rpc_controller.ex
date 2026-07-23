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

  alias Lasso.Config.ConfigStore
  alias Lasso.Config.MethodConstraints
  alias Lasso.Config.MethodPolicy
  alias Lasso.Config.ProfileValidator
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.RequestOptions.Builder, as: RequestOptionsBuilder
  alias Lasso.RPC.RequestPipeline
  alias Lasso.RPC.Response
  alias Lasso.RPC.Selection
  alias LassoWeb.Plugs.ObservabilityPlug
  alias LassoWeb.RPC.Helpers

  @jsonrpc_version "2.0"

  @type transport :: :http | :ws | :both

  @max_batch_requests Application.compile_env(:lasso, :max_batch_requests, 50)

  @doc """
  Handle JSON-RPC requests for any supported chain.
  """
  @spec rpc(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc(conn, %{"chain_id" => chain_id} = params) do
    case chain_id do
      nil ->
        Logger.error("Missing chain_id parameter", params: inspect(params))

        error = JError.new(-32_602, "Missing chain_id parameter")

        conn
        |> put_status(:bad_request)
        |> json(JError.to_response(error, nil))

      chain_id ->
        profile = routing_profile(conn)

        with {:ok, resolved_chain_id} <- resolve_chain(profile, chain_id),
             :ok <- validate_provider_override(profile, resolved_chain_id, conn, params) do
          requested_strategy = strategy_from(conn, params)

          conn =
            conn
            |> assign(:requested_provider_strategy, requested_strategy)
            |> assign(:provider_strategy, requested_strategy)

          handle_chain_rpc(conn, resolved_chain_id)
        else
          {:error, reason} ->
            error = JError.new(-32_602, "Unsupported chain: #{reason}")

            conn
            |> put_status(:bad_request)
            |> json(JError.to_response(error, nil))
        end
    end
  end

  @spec rpc_base(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc_base(conn, params) do
    rpc_with_strategy(conn, params, default_provider_strategy())
  end

  @spec rpc_fastest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc_fastest(conn, params) do
    rpc_with_strategy(conn, params, :fastest)
  end

  @spec rpc_load_balanced(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc_load_balanced(conn, params), do: rpc_with_strategy(conn, params, :load_balanced)
  @spec rpc_latency_weighted(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc_latency_weighted(conn, params), do: rpc_with_strategy(conn, params, :latency_weighted)

  defp rpc_with_strategy(conn, params, strategy_atom) do
    conn
    |> assign(:provider_strategy, strategy_atom)
    |> rpc(params)
  end

  @spec rpc_provider_override(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc_provider_override(
        conn,
        %{"provider_id" => provider_id, "chain_id" => chain_id} = params
      ) do
    handle_provider_override_rpc(conn, params, chain_id, provider_id)
  end

  defp handle_provider_override_rpc(conn, params, chain_id, provider_id) do
    params_with_override =
      Map.merge(params, %{
        "chain_id" => chain_id,
        "provider_override" => provider_id
      })

    rpc(conn, params_with_override)
  end

  defp handle_chain_rpc(conn, chain_name) do
    body = Map.get(conn.params, "_json", conn.params)

    case body do
      requests when is_list(requests) ->
        handle_json_rpc_batch(conn, requests, chain_name)

      request when is_map(request) ->
        handle_json_rpc(conn, request, chain_name)

      _ ->
        error = JError.new(-32_600, "Invalid Request")
        json(conn, JError.to_response(error, nil))
    end
  end

  defp handle_json_rpc(conn, params, chain) do
    with {:ok, request} <- validate_json_rpc_request(params),
         {:ok, result, ctx} <- process_json_rpc_request(request, chain, conn) do
      # Store context for observability logging in before_send callback
      conn = Plug.Conn.put_private(conn, :lasso_request_context, ctx)

      # Inject observability metadata to headers if requested
      conn = maybe_inject_observability_metadata(conn, ctx)

      # Passthrough optimization: send raw bytes directly for Response.Success
      # Skip passthrough if body metadata is requested (requires JSON manipulation)
      case {result, conn.assigns[:include_meta]} do
        {%Response.Success{raw_bytes: bytes}, mode} when mode != :body ->
          # Zero-copy passthrough - send raw bytes directly
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, bytes)

        {%Response.Success{raw_bytes: bytes}, :body} ->
          # Need to decode, add metadata, and re-encode
          case Jason.decode(bytes) do
            {:ok, decoded} ->
              response = ObservabilityPlug.enrich_response_body(decoded, ctx)
              json(conn, response)

            {:error, _} ->
              # Fallback: send without metadata if decode fails
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, bytes)
          end

        # Non-passthrough response (fallback for any non-Response.Success results)
        {result, _} ->
          response = %{
            jsonrpc: @jsonrpc_version,
            result: result,
            id: request["id"]
          }

          # Add metadata to body if requested
          response =
            case conn.assigns[:include_meta] do
              :body -> ObservabilityPlug.enrich_response_body(response, ctx)
              _ -> response
            end

          json(conn, response)
      end
    else
      {:error, error, ctx} ->
        # Store context for observability logging in before_send callback
        conn = Plug.Conn.put_private(conn, :lasso_request_context, ctx)

        # Inject observability metadata for errors with context
        conn = maybe_inject_observability_metadata(conn, ctx)

        error_response =
          error
          |> JError.from()
          |> JError.to_response(Map.get(params, "id"))

        # Add metadata to body if requested
        error_response =
          case conn.assigns[:include_meta] do
            :body -> ObservabilityPlug.enrich_response_body(error_response, ctx)
            _ -> error_response
          end

        json(conn, error_response)

      {:error, error} ->
        # Inject observability metadata even for errors (no context available)
        conn = maybe_inject_observability_metadata(conn, nil)

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
      error = JError.new(-32_600, "Invalid Request: batch too large")
      json(conn, JError.to_response(error, nil))
    else
      # Select a batch provider for consistency across batch items.
      # All items prefer this provider, but can failover independently.
      profile = routing_profile(conn)
      strategy = conn.assigns[:provider_strategy] || strategy_from(conn, %{})

      batch_provider =
        case Selection.select_provider(profile, chain, "eth_blockNumber", strategy: strategy) do
          {:ok, provider_id} -> provider_id
          {:error, _} -> nil
        end

      conn =
        if batch_provider,
          do: assign(conn, :batch_provider, batch_provider),
          else: conn

      # Process all requests and collect results with contexts
      {items, contexts} =
        requests
        |> Enum.map(&process_batch_request(&1, chain, conn))
        |> Enum.unzip()

      # Store all contexts for observability logging in before_send callback
      valid_contexts = Enum.filter(contexts, & &1)
      conn = Plug.Conn.put_private(conn, :lasso_request_contexts, valid_contexts)

      # Inject observability metadata headers (uses first non-nil context if available)
      conn = maybe_inject_observability_metadata(conn, Enum.find(contexts, & &1))

      # Check if all items are passthrough-eligible (Response structs)
      all_response_structs? =
        Enum.all?(items, fn
          %Response.Success{} -> true
          %Response.Error{} -> true
          _ -> false
        end)

      if all_response_structs? do
        # Build batch response from Response structs and send raw bytes
        request_ids = Enum.map(requests, &Map.get(&1, "id"))

        case Response.Batch.build(items, request_ids) do
          {:ok, batch} ->
            {:ok, bytes} = Response.Batch.to_bytes(batch)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, bytes)

          {:error, _reason} ->
            # Fallback to JSON encoding if batch build fails
            responses =
              Enum.zip(items, request_ids)
              |> Enum.map(fn {item, req_id} -> response_to_map(item, req_id) end)

            json(conn, responses)
        end
      else
        # Mixed responses - encode as JSON
        # Pair items with request IDs for proper response construction
        request_ids = Enum.map(requests, &Map.get(&1, "id"))

        responses =
          Enum.zip(items, request_ids)
          |> Enum.map(fn {item, req_id} -> response_to_map(item, req_id) end)

        json(conn, responses)
      end
    end
  end

  # Convert Response struct or map to JSON-encodable map
  defp response_to_map(%Response.Success{id: id, raw_bytes: bytes}, _req_id) do
    # Decode to get the full response map
    case Jason.decode(bytes) do
      {:ok, decoded} ->
        decoded

      {:error, _} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_700, "message" => "Internal decode error"}
        }
    end
  end

  defp response_to_map(%Response.Error{id: id, error: jerr}, _req_id) do
    JError.to_response(jerr, id)
  end

  defp response_to_map(map, _req_id) when is_map(map), do: map

  defp process_batch_request(req, chain, conn) do
    with {:ok, request} <- validate_json_rpc_request(req),
         {:ok, result, ctx} <- process_json_rpc_request(request, chain, conn) do
      {result, ctx}
    else
      {:error, error, ctx} ->
        request_id = Map.get(req, "id")
        jerr = JError.from(error)

        error_response = %Response.Error{
          id: request_id,
          jsonrpc: "2.0",
          error: jerr,
          raw_bytes: nil
        }

        {error_response, ctx}

      {:error, error} ->
        # Error without context
        request_id = Map.get(req, "id")
        jerr = JError.from(error)

        error_response = %Response.Error{
          id: request_id,
          jsonrpc: "2.0",
          error: jerr,
          raw_bytes: nil
        }

        {error_response, nil}
    end
  end

  defp validate_json_rpc_request(%{"method" => method} = request) when is_binary(method) do
    if Map.has_key?(request, "jsonrpc") and request["jsonrpc"] != @jsonrpc_version do
      {:error, JError.new(-32_600, "Invalid Request: jsonrpc must be \"2.0\"")}
    else
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

  defp validate_json_rpc_request(_), do: {:error, JError.new(-32_600, "Invalid Request")}

  defp process_json_rpc_request(
         %{"method" => "eth_chainId", "params" => [], "id" => req_id} = request,
         chain_id,
         conn
       )
       when is_integer(chain_id) and chain_id > 0 do
    if provider_override_requested?(conn) do
      forward_rpc_request(chain_id, "eth_chainId", Map.get(request, "params", []),
        conn: conn,
        jsonrpc_id: req_id
      )
    else
      Logger.debug("Getting chain ID", chain_id: chain_id)
      hex_chain_id = "0x" <> Integer.to_string(chain_id, 16)
      raw_bytes = Jason.encode!(%{"jsonrpc" => "2.0", "id" => req_id, "result" => hex_chain_id})

      ctx =
        Lasso.RPC.RequestContext.new(chain_id, "eth_chainId", [],
          strategy: conn.assigns[:provider_strategy],
          plug_start_time: conn.private[:plug_start_time]
        )

      {:ok, %Response.Success{id: req_id, jsonrpc: "2.0", raw_bytes: raw_bytes},
       %{ctx | status: :success}}
    end
  end

  # Reject WS-only methods over HTTP
  defp process_json_rpc_request(%{"method" => method} = req, chain, conn) do
    params = Map.get(req, "params", []) || []

    cond do
      MethodConstraints.ws_only?(method) ->
        ws_path = "/ws" <> conn.request_path

        {:error,
         JError.new(
           -32_601,
           "Method not supported over HTTP. Use WebSocket connection for subscriptions.",
           data: %{websocket_url: ws_path}
         )}

      MethodConstraints.disallowed?(method) ->
        {:error, JError.new(-32_601, "Method not supported by proxy")}

      true ->
        Logger.debug("Forwarding RPC method", method: method, chain: chain)
        forward_rpc_request(chain, method, params, conn: conn, jsonrpc_id: req["id"])
    end
  end

  defp forward_rpc_request(chain, method, params, opts) when is_list(opts) do
    strategy = extract_strategy(opts)
    conn = Keyword.get(opts, :conn)
    jsonrpc_id = Keyword.get(opts, :jsonrpc_id)

    provider_override = extract_provider_override(conn, opts)

    # Batch provider pinning: use the batch-selected provider if no explicit override
    {provider_override, failover_on_override} =
      case {provider_override, conn} do
        {nil, %Plug.Conn{assigns: %{batch_provider: bp}}} when is_binary(bp) ->
          {bp, true}

        _ ->
          {provider_override, Keyword.get(opts, :failover_on_override, false)}
      end

    transport_override =
      case conn do
        %Plug.Conn{} -> extract_transport_override(conn, method)
        _ -> nil
      end

    opts =
      RequestOptionsBuilder.from_conn(conn, method,
        strategy: strategy,
        provider_override: provider_override,
        failover_on_override: failover_on_override,
        transport: transport_override,
        timeout_ms: MethodPolicy.timeout_for(method),
        jsonrpc_id: jsonrpc_id
      )

    RequestPipeline.execute_via_channels(chain, method, params, opts)
  end

  defp extract_strategy(opts) do
    case Keyword.get(opts, :strategy) do
      nil ->
        case Keyword.get(opts, :conn) do
          %Plug.Conn{assigns: %{provider_strategy: s}} when not is_nil(s) -> s
          _ -> default_provider_strategy()
        end

      s ->
        s
    end
  end

  defp default_provider_strategy do
    Helpers.default_provider_strategy()
  end

  defp strategy_from(conn, params) do
    conn.assigns[:requested_provider_strategy] ||
      conn.assigns[:provider_strategy] ||
      Helpers.normalize_strategy_token(params["strategy"]) ||
      default_provider_strategy()
  end

  # Determine provider override from opts, params, or header.
  defp extract_provider_override(%Plug.Conn{} = conn, opts) do
    with_opt =
      case Keyword.get(opts, :provider_override) do
        pid when is_binary(pid) -> pid
        _ -> nil
      end

    with_param =
      case conn.params do
        %{"provider_override" => pid} when is_binary(pid) -> pid
        %{"provider_id" => pid} when is_binary(pid) -> pid
        _ -> nil
      end

    with_header =
      conn
      |> get_req_header("x-lasso-provider")
      |> List.first()

    with_opt || with_param || with_header
  end

  # Determine transport override from request preferences while respecting policy.
  defp extract_transport_override(%Plug.Conn{} = conn, method) do
    case MethodConstraints.required_transport_for(method) do
      :ws -> :ws
      nil -> resolve_transport_preference(conn)
    end
  end

  defp resolve_transport_preference(conn) do
    preference_from_params(conn) || preference_from_headers(conn)
  end

  defp preference_from_params(%{params: %{"transport" => "http"}}), do: :http
  defp preference_from_params(%{params: %{"transport" => "ws"}}), do: :ws
  defp preference_from_params(_), do: nil

  defp preference_from_headers(conn) do
    case get_req_header(conn, "x-lasso-transport") do
      ["http" | _] -> :http
      ["ws" | _] -> :ws
      _ -> nil
    end
  end

  defp routing_profile(conn) do
    conn.assigns[:profile_id] || conn.assigns[:profile_slug] || ProfileValidator.default_profile()
  end

  defp resolve_chain(profile, chain_identifier) when is_binary(chain_identifier) do
    case ConfigStore.lookup_chain_id_in_profile(profile, chain_identifier) do
      {:ok, chain_id} ->
        {:ok, chain_id}

      :not_found ->
        {:error, "Unknown chain '#{chain_identifier}' in profile '#{profile}'"}
    end
  end

  defp validate_provider_override(_profile, _chain_id, _conn, %{"provider_override" => nil}),
    do: :ok

  defp validate_provider_override(profile, chain_id, conn, _params) do
    case extract_provider_override(conn, []) do
      nil ->
        :ok

      provider_id ->
        case ConfigStore.get_provider(profile, chain_id, provider_id) do
          {:ok, _provider} ->
            :ok

          {:error, :not_found} ->
            {:error, "Provider '#{provider_id}' is not configured for this chain"}
        end
    end
  end

  defp provider_override_requested?(conn), do: not is_nil(extract_provider_override(conn, []))

  defp maybe_inject_observability_metadata(conn, ctx) do
    case conn.assigns[:include_meta] do
      :headers when not is_nil(ctx) ->
        ObservabilityPlug.inject_metadata(conn, ctx)

      _ ->
        conn
    end
  end
end
