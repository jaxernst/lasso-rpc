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
  alias LassoWeb.Plugs.ObservabilityPlug
  alias LassoWeb.Plugs.RequestTimingPlug
  alias LassoWeb.RPC.Helpers
  alias LassoWeb.RPCController.BatchExecutor

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
        provider_override = extract_provider_override(conn, [])

        with {:ok, resolved_chain_id} <- resolve_chain(profile, chain_id),
             :ok <- validate_provider_override(profile, resolved_chain_id, provider_override) do
          requested_strategy = strategy_from(conn, params)

          conn =
            conn
            |> assign(:requested_provider_strategy, requested_strategy)
            |> assign(:provider_strategy, requested_strategy)
            |> assign(:resolved_provider_override, provider_override)

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
      # Inject observability metadata to headers if requested
      conn = maybe_inject_observability_metadata(conn, ctx)

      if Map.has_key?(request, "id") do
        send_single_success(conn, request, result, ctx)
      else
        send_resp(conn, 204, "")
      end
    else
      {:error, error, ctx} ->
        # Inject observability metadata for errors with context
        conn = maybe_inject_observability_metadata(conn, ctx)

        if notification_request?(params) do
          send_resp(conn, 204, "")
        else
          error_response =
            error
            |> JError.from()
            |> JError.to_response(Map.get(params, "id"))

          error_response =
            case conn.assigns[:include_meta] do
              :body -> ObservabilityPlug.enrich_response_body(error_response, ctx)
              _ -> error_response
            end

          json(conn, error_response)
        end

      {:error, error} ->
        # Inject observability metadata even for errors (no context available)
        conn = maybe_inject_observability_metadata(conn, nil)

        if notification_request?(params) do
          send_resp(conn, 204, "")
        else
          json(
            conn,
            error
            |> JError.from()
            |> JError.to_response(Map.get(params, "id"))
          )
        end
    end
  end

  defp send_single_success(conn, _request, %Response.Success{raw_bytes: bytes}, ctx) do
    case conn.assigns[:include_meta] do
      :body ->
        case Jason.decode(bytes) do
          {:ok, decoded} ->
            json(conn, ObservabilityPlug.enrich_response_body(decoded, ctx))

          {:error, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, bytes)
        end

      _mode ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, bytes)
    end
  end

  defp send_single_success(conn, request, result, ctx) do
    response = %{
      jsonrpc: @jsonrpc_version,
      result: result,
      id: request["id"]
    }

    response =
      case conn.assigns[:include_meta] do
        :body -> ObservabilityPlug.enrich_response_body(response, ctx)
        _ -> response
      end

    json(conn, response)
  end

  defp notification_request?(request) when is_map(request) do
    not Map.has_key?(request, "id") and is_binary(request["method"]) and
      request["jsonrpc"] in [nil, @jsonrpc_version]
  end

  defp notification_request?(_request), do: false

  defp handle_json_rpc_batch(conn, requests, chain) do
    cond do
      requests == [] ->
        error = JError.new(-32_600, "Invalid Request")
        json(conn, JError.to_response(error, nil))

      length(requests) > @max_batch_requests ->
        error = JError.new(-32_600, "Invalid Request: batch too large")
        json(conn, JError.to_response(error, nil))

      true ->
        execute_json_rpc_batch(conn, requests, chain)
    end
  end

  defp execute_json_rpc_batch(conn, requests, chain) do
    started_at_us = RequestTimingPlug.get_start_time(conn) || System.monotonic_time(:microsecond)

    {immediate, forwarded} =
      requests
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {request, index}, {ready, pending} ->
        case prepare_batch_item(request, index, chain, conn, started_at_us) do
          {:immediate, item, result} -> {[finish_batch_item(item, result) | ready], pending}
          {:forward, item} -> {ready, [item | pending]}
        end
      end)

    forwarded = Enum.reverse(forwarded)

    executed =
      case forwarded do
        [] ->
          []

        items ->
          items
          |> BatchExecutor.run(&execute_batch_item/2)
          |> Map.fetch!(:items)
          |> Enum.map(fn {item, result} -> finish_batch_item(item, result) end)
      end

    completed = Enum.sort_by(immediate ++ executed, & &1.index)
    contexts = completed |> Enum.map(& &1.context) |> Enum.reject(&is_nil/1)

    conn = maybe_inject_observability_metadata(conn, List.first(contexts))
    responses = Enum.filter(completed, & &1.respond?)

    if responses == [] do
      send_resp(conn, 204, "")
    else
      send_batch_response(conn, responses)
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

  defp prepare_batch_item(request, index, chain, conn, started_at_us) do
    case validate_json_rpc_request(request) do
      {:ok, normalized} ->
        item = %{
          index: index,
          request_id: Map.get(normalized, "id"),
          respond?: Map.has_key?(normalized, "id")
        }

        prepare_valid_batch_item(item, normalized, chain, conn, started_at_us)

      {:error, error} ->
        item = %{index: index, request_id: request_id(request), respond?: true}
        {:immediate, item, {:error, error}}
    end
  end

  defp prepare_valid_batch_item(item, %{"method" => method} = request, chain, conn, started_at_us) do
    params = Map.get(request, "params", []) || []

    cond do
      method == "eth_chainId" and params == [] and not provider_override_requested?(conn) ->
        {:immediate, item, local_chain_id_result(item.request_id, chain, conn)}

      MethodConstraints.ws_only?(method) ->
        ws_path = "/ws" <> conn.request_path

        error =
          JError.new(
            -32_601,
            "Method not supported over HTTP. Use WebSocket connection for subscriptions.",
            data: %{websocket_url: ws_path}
          )

        {:immediate, item, {:error, error}}

      MethodConstraints.disallowed?(method) ->
        {:immediate, item, {:error, JError.new(-32_601, "Method not supported by proxy")}}

      true ->
        opts =
          build_request_options(conn, method, item.request_id, jsonrpc_id_present?: item.respond?)

        {:forward,
         Map.merge(item, %{
           chain: chain,
           deadline_us: started_at_us + opts.timeout_ms * 1_000,
           method: method,
           opts: opts,
           params: params
         })}
    end
  end

  defp execute_batch_item(item, scope) do
    RequestPipeline.execute_owned(
      scope,
      item.chain,
      item.method,
      item.params,
      item.opts
    )
  end

  defp local_chain_id_result(request_id, chain_id, conn)
       when is_integer(chain_id) and chain_id > 0 do
    raw_bytes =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => "0x" <> Integer.to_string(chain_id, 16)
      })

    ctx =
      Lasso.RPC.RequestContext.new(chain_id, "eth_chainId", [],
        strategy: conn.assigns[:provider_strategy],
        plug_start_time: RequestTimingPlug.get_start_time(conn)
      )

    {:ok, %Response.Success{id: request_id, jsonrpc: "2.0", raw_bytes: raw_bytes},
     %{ctx | status: :success}}
  end

  defp finish_batch_item(item, {:ok, result, context}) do
    %{
      index: item.index,
      request_id: item.request_id,
      respond?: item.respond?,
      response: result,
      context: context
    }
  end

  defp finish_batch_item(item, {:error, error, context}) do
    %{
      index: item.index,
      request_id: item.request_id,
      respond?: item.respond?,
      response: response_error(item.request_id, error),
      context: context
    }
  end

  defp finish_batch_item(item, {:error, %JError{} = error}) do
    %{
      index: item.index,
      request_id: item.request_id,
      respond?: item.respond?,
      response: response_error(item.request_id, error),
      context: nil
    }
  end

  defp finish_batch_item(item, {:error, error}) do
    %{
      index: item.index,
      request_id: item.request_id,
      respond?: item.respond?,
      response: response_error(item.request_id, batch_owner_error(error)),
      context: nil
    }
  end

  defp response_error(request_id, error) do
    %Response.Error{
      id: request_id,
      jsonrpc: "2.0",
      error: JError.from(error),
      raw_bytes: nil
    }
  end

  defp batch_owner_error(reason) do
    {code, message, category, retriable?} = batch_owner_error_fields(reason)

    JError.new(code, message,
      category: category,
      retriable?: retriable?,
      breaker_penalty?: false,
      data: %{reason: bounded_batch_reason(reason)}
    )
  end

  defp batch_owner_error_fields(:owner_unresponsive) do
    {-32_000, "Request outcome unavailable after owner exit", :server_error, false}
  end

  defp batch_owner_error_fields({:owner_down, _reason}) do
    {-32_000, "Request outcome unavailable after owner exit", :server_error, false}
  end

  defp batch_owner_error_fields(_reason) do
    {-32_005, "Local request capacity unavailable", :local_capacity_rejection, true}
  end

  defp bounded_batch_reason(:owner_spawn_failed), do: :owner_spawn_failed
  defp bounded_batch_reason(:deadline_expired), do: :deadline_expired
  defp bounded_batch_reason(:owner_unresponsive), do: :owner_unresponsive
  defp bounded_batch_reason({:owner_down, reason}), do: {:owner_down, reason}
  defp bounded_batch_reason(_reason), do: :owner_failed

  defp send_batch_response(conn, responses) do
    items = Enum.map(responses, & &1.response)
    request_ids = Enum.map(responses, & &1.request_id)

    if Enum.all?(items, &(match?(%Response.Success{}, &1) or match?(%Response.Error{}, &1))) do
      case Response.Batch.build(items, request_ids) do
        {:ok, batch} ->
          {:ok, bytes} = Response.Batch.to_bytes(batch)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, bytes)

        {:error, _reason} ->
          json(conn, Enum.zip_with(items, request_ids, &response_to_map/2))
      end
    else
      json(conn, Enum.zip_with(items, request_ids, &response_to_map/2))
    end
  end

  defp request_id(request) when is_map(request), do: Map.get(request, "id")
  defp request_id(_request), do: nil

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
         %{"method" => "eth_chainId", "params" => []} = request,
         chain_id,
         conn
       )
       when is_integer(chain_id) and chain_id > 0 do
    req_id = Map.get(request, "id")
    id_present? = Map.has_key?(request, "id")

    if provider_override_requested?(conn) do
      forward_rpc_request(chain_id, "eth_chainId", Map.get(request, "params", []),
        conn: conn,
        jsonrpc_id: req_id,
        jsonrpc_id_present?: id_present?
      )
    else
      Logger.debug("Getting chain ID", chain_id: chain_id)
      hex_chain_id = "0x" <> Integer.to_string(chain_id, 16)
      raw_bytes = Jason.encode!(%{"jsonrpc" => "2.0", "id" => req_id, "result" => hex_chain_id})

      ctx =
        Lasso.RPC.RequestContext.new(chain_id, "eth_chainId", [],
          strategy: conn.assigns[:provider_strategy],
          plug_start_time: RequestTimingPlug.get_start_time(conn)
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

        forward_rpc_request(chain, method, params,
          conn: conn,
          jsonrpc_id: Map.get(req, "id"),
          jsonrpc_id_present?: Map.has_key?(req, "id")
        )
    end
  end

  defp forward_rpc_request(chain, method, params, opts) when is_list(opts) do
    conn = Keyword.get(opts, :conn)
    jsonrpc_id = Keyword.get(opts, :jsonrpc_id)
    request_options = build_request_options(conn, method, jsonrpc_id, opts)

    RequestPipeline.execute_via_channels(chain, method, params, request_options)
  end

  defp build_request_options(conn, method, jsonrpc_id, opts) do
    transport_override = extract_transport_override(conn, method)

    RequestOptionsBuilder.from_conn(conn, method,
      strategy: extract_strategy(Keyword.put_new(opts, :conn, conn)),
      provider_override: extract_provider_override(conn, opts),
      failover_on_override: Keyword.get(opts, :failover_on_override, false),
      transport: transport_override,
      timeout_ms: MethodPolicy.timeout_for(method),
      jsonrpc_id: jsonrpc_id,
      jsonrpc_id_present?: Keyword.get(opts, :jsonrpc_id_present?, true)
    )
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
    case Map.fetch(conn.assigns, :resolved_provider_override) do
      {:ok, provider_override} -> provider_override
      :error -> resolve_provider_override(conn, opts)
    end
  end

  defp resolve_provider_override(conn, opts) do
    with_opt =
      case Keyword.get(opts, :provider_override) do
        provider_id when is_binary(provider_id) -> provider_id
        _other -> nil
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

  defp validate_provider_override(profile, chain_id, provider_override) do
    case provider_override do
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
