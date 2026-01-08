defmodule LassoWeb.RPCSocket do
  @moduledoc """
  Raw JSON-RPC WebSocket handler for standard Ethereum json rpc clients.

  Implements Phoenix.Socket.Transport behavior to handle raw WebSocket frames
  instead of Phoenix Channel protocol.

  **Protocol:**
  - Client sends: `{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}`
  - Server responds: `{"jsonrpc":"2.0","id":1,"result":"0xabc123..."}`
  - Server pushes: `{"jsonrpc":"2.0","method":"eth_subscription","params":{...}}`

  **Supported Methods:**
  - `eth_subscribe` - Create subscription (newHeads, logs)
  - `eth_unsubscribe` - Cancel subscription
  - All read-only methods (`eth_blockNumber`, `eth_getLogs`, etc.)
  """

  @behaviour Phoenix.Socket.Transport
  require Logger

  alias Lasso.Config.ProfileValidator
  alias Lasso.Core.Streaming.SubscriptionRouter
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Observability, RequestContext, RequestOptions, RequestPipeline, Response}
  alias LassoWeb.RPC.Helpers

  # Heartbeat configuration (aggressive keepalive for subscription connections)
  # Send ping every 30 seconds
  @heartbeat_interval 30_000
  # Expect pong within 5 seconds (more aggressive than 10)
  @heartbeat_timeout 5_000
  # Allow 2 missed heartbeats before closing (stricter than 3)
  @max_missed_heartbeats 2

  ## Phoenix.Socket.Transport callbacks

  @impl true
  def child_spec(_opts) do
    # Return :ignore since we don't need a persistent process
    :ignore
  end

  @impl true
  def connect(transport_info) do
    # Extract client IP for connection tracking
    client_ip = extract_client_ip(transport_info)
    connection_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    # Extract routing parameters from path
    # Paths can be:
    #   /ws/rpc/:chain_id                           -> base endpoint with default strategy
    #   /ws/rpc/:strategy/:chain_id                 -> strategy-specific endpoint
    #   /ws/rpc/provider/:provider_id/:chain_id     -> provider override
    #   /ws/rpc/:chain_id/:provider_id              -> alternative provider override
    params = transport_info[:params] || %{}
    uri = transport_info[:connect_info][:uri]
    chain = params["chain_id"] || "ethereum"

    # Determine if a strategy or provider override is specified by parsing the URI
    {strategy, provider_id} = extract_routing_params(uri, params)

    # Validate profile parameter, falling back to "default" for WebSocket connections
    # WebSocket connections should not be rejected for invalid profiles - instead log
    # a warning and fall back to default profile to maintain connection stability
    profile =
      case ProfileValidator.validate_with_default(params["profile"]) do
        {:ok, validated} ->
          validated

        {:error, error_type, message} ->
          Logger.warning("WebSocket connection profile validation failed: #{message}",
            error_type: error_type,
            provided_profile: params["profile"],
            fallback: "default",
            connection_id: connection_id
          )

          # Fall back to default profile to avoid rejecting connection
          "default"
      end

    socket_state = %{
      profile: profile,
      chain: chain,
      strategy: strategy,
      provider_id: provider_id,
      subscriptions: %{},
      client_pid: self(),
      heartbeat_ref: nil,
      missed_heartbeats: 0,
      last_ping_time: nil,
      connection_id: connection_id,
      client_ip: client_ip
    }

    routing_info = build_routing_info(strategy, provider_id)

    Logger.info(
      "JSON-RPC WebSocket client connected: #{profile}:#{chain}#{routing_info} (id: #{connection_id}, ip: #{client_ip})"
    )

    {:ok, socket_state}
  end

  @impl true
  def init(state) do
    # Start heartbeat timer
    heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)

    {:ok, %{state | heartbeat_ref: heartbeat_ref}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"jsonrpc" => "2.0"} = request} ->
        handle_json_rpc(request, state)

      {:ok, invalid} ->
        error = JError.new(-32_600, "Invalid Request: missing jsonrpc field")
        response = JError.to_response(error, Map.get(invalid, "id"))
        {:reply, :ok, {:text, Jason.encode!(response)}, state}

      {:error, _reason} ->
        error = JError.new(-32_700, "Parse error")
        response = JError.to_response(error, nil)
        {:reply, :ok, {:text, Jason.encode!(response)}, state}
    end
  end

  @impl true
  def handle_in(_, state) do
    # Ignore other non-text frames (binary, etc)
    {:ok, state}
  end

  @impl true
  def handle_control({_payload, [opcode: :pong]}, state) do
    # Handle pong response from client - reset heartbeat counter and cancel timeout
    Logger.debug("[Client←] Received pong from downstream client")

    # Cancel the pending heartbeat timeout since we received the pong
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    # Schedule the next heartbeat
    heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)

    {:ok, %{state | missed_heartbeats: 0, last_ping_time: nil, heartbeat_ref: heartbeat_ref}}
  end

  @impl true
  def handle_control({_payload, [opcode: :ping]}, state) do
    # Client sent us a ping - respond with pong (standard keepalive behavior)
    Logger.debug("[Client←] Received ping from client, responding with pong")
    {:reply, :ok, {:pong, ""}, state}
  end

  @impl true
  def handle_info({:subscription_event, payload}, state) do
    # Received from ClientSubscriptionRegistry via StreamCoordinator
    # Payload is already formatted as JSON-RPC notification
    case Jason.encode(payload) do
      {:ok, json} ->
        {:push, {:text, json}, state}

      {:error, reason} ->
        Logger.error("Failed to encode subscription event: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:send_notification, notification_json}, state) do
    # Send metadata notification as separate WebSocket frame
    {:push, {:text, notification_json}, state}
  end

  @impl true
  def handle_info(:send_heartbeat, state) do
    # Send ping frame and set timeout for pong response
    Logger.debug("[Client→] Sending heartbeat ping to downstream client")

    # Cancel existing timeout if any
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    # Send ping frame (empty payload)
    ping_frame = {:ping, ""}

    # Set timeout for pong response
    timeout_ref = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout)

    {:push, ping_frame,
     %{state | heartbeat_ref: timeout_ref, last_ping_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:heartbeat_timeout, state) do
    # Pong not received within timeout - increment missed counter
    missed = state.missed_heartbeats + 1

    Logger.warning(
      "Client heartbeat timeout - missed #{missed}/#{@max_missed_heartbeats} heartbeats"
    )

    if missed >= @max_missed_heartbeats do
      Logger.error("Too many missed client heartbeats (#{missed}), closing connection")
      # Close with proper WebSocket code: 1002 = Protocol Error (failed to respond to pings)
      {:stop, {:shutdown, {1002, "Heartbeat timeout - no pong responses"}}, state}
    else
      # Schedule next heartbeat
      heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)
      {:ok, %{state | missed_heartbeats: missed, heartbeat_ref: heartbeat_ref}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("WebSocket terminated: #{inspect(reason)}")

    # Cancel heartbeat timer
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    # Unsubscribe all active subscriptions
    Enum.each(state.subscriptions, fn {subscription_id, _type} ->
      SubscriptionRouter.unsubscribe(state.profile, state.chain, subscription_id)
    end)

    :ok
  end

  ## JSON-RPC handling

  defp handle_json_rpc(%{"method" => method, "params" => params, "id" => id} = request, state) do
    # Extract lasso_meta preference (notify or nil - inline mode removed)
    {lasso_meta_mode, _clean_request} = extract_lasso_meta(request)

    # Create request context for observability
    ctx =
      RequestContext.new(state.chain, method,
        params_present: params != nil and params != [],
        transport: :ws,
        strategy: default_provider_strategy()
      )

    case handle_rpc_method(method, params || [], state, ctx) do
      {:ok, result, new_state, updated_ctx} ->
        Observability.log_request_completed(updated_ctx)

        # Passthrough optimization: send raw bytes directly for Response.Success
        case result do
          %Response.Success{raw_bytes: bytes} ->
            # Zero-copy passthrough - send raw bytes directly
            case lasso_meta_mode do
              :notify ->
                # Send response first, then metadata notification
                notification = build_metadata_notification(updated_ctx)
                {:ok, notification_json} = Jason.encode(notification)
                send(self(), {:send_notification, notification_json})
                {:reply, :ok, {:text, bytes}, new_state}

              _ ->
                # No metadata requested - pure passthrough
                {:reply, :ok, {:text, bytes}, new_state}
            end

          # Non-passthrough response (subscriptions, eth_chainId, etc.)
          _ ->
            response = %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => result
            }

            case lasso_meta_mode do
              :notify ->
                {:ok, json} = Jason.encode(response)
                notification = build_metadata_notification(updated_ctx)
                {:ok, notification_json} = Jason.encode(notification)
                send(self(), {:send_notification, notification_json})
                {:reply, :ok, {:text, json}, new_state}

              _ ->
                {:reply, :ok, {:text, Jason.encode!(response)}, new_state}
            end
        end

      {:error, reason, new_state, updated_ctx} ->
        Observability.log_request_completed(updated_ctx)

        error = JError.from(reason)
        response = JError.to_response(error, id)
        {:reply, :ok, {:text, Jason.encode!(response)}, new_state}
    end
  end

  defp handle_json_rpc(%{"method" => method, "id" => id}, state) do
    # Params optional (default to [])
    handle_json_rpc(%{"method" => method, "params" => [], "id" => id}, state)
  end

  defp handle_json_rpc(invalid, state) do
    error = JError.new(-32_600, "Invalid Request: missing required fields")
    response = JError.to_response(error, Map.get(invalid, "id"))
    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

  ## RPC method handlers

  defp handle_rpc_method("eth_subscribe", [subscription_type | rest], state, ctx) do
    case subscription_type do
      "newHeads" ->
        case SubscriptionRouter.subscribe(state.profile, state.chain, {:newHeads}) do
          {:ok, subscription_id} ->
            new_state = update_subscriptions(state, subscription_id, "newHeads")
            updated_ctx = RequestContext.record_success(ctx, subscription_id)
            {:ok, subscription_id, new_state, updated_ctx}

          {:error, reason} ->
            error_msg = "Failed to create newHeads subscription: #{inspect(reason)}"
            updated_ctx = RequestContext.record_error(ctx, error_msg)
            {:error, error_msg, state, updated_ctx}
        end

      "logs" ->
        filter = List.first(rest, %{})

        case SubscriptionRouter.subscribe(state.profile, state.chain, {:logs, filter}) do
          {:ok, subscription_id} ->
            new_state = update_subscriptions(state, subscription_id, {"logs", filter})
            updated_ctx = RequestContext.record_success(ctx, subscription_id)
            {:ok, subscription_id, new_state, updated_ctx}

          {:error, reason} ->
            error_msg = "Failed to create logs subscription: #{inspect(reason)}"
            updated_ctx = RequestContext.record_error(ctx, error_msg)
            {:error, error_msg, state, updated_ctx}
        end

      _ ->
        error_msg = "Unsupported subscription type: #{subscription_type}"
        updated_ctx = RequestContext.record_error(ctx, error_msg)
        {:error, error_msg, state, updated_ctx}
    end
  end

  defp handle_rpc_method("eth_unsubscribe", [subscription_id], state, ctx) do
    case Map.pop(state.subscriptions, subscription_id) do
      {nil, _} ->
        updated_ctx = RequestContext.record_success(ctx, false)
        {:ok, false, state, updated_ctx}

      {_subscription_type, updated_subscriptions} ->
        SubscriptionRouter.unsubscribe(state.profile, state.chain, subscription_id)
        new_state = %{state | subscriptions: updated_subscriptions}
        updated_ctx = RequestContext.record_success(ctx, true)
        {:ok, true, new_state, updated_ctx}
    end
  end

  defp handle_rpc_method("eth_chainId", [], state, ctx) do
    # Note: We don't have request_id here, so we can't build a Response.Success
    # This is fine - subscriptions and chainId return plain values, only pipeline results are Response.Success
    case get_chain_id(state.profile, state.chain) do
      {:ok, chain_id} ->
        updated_ctx = RequestContext.record_success(ctx, chain_id)
        {:ok, chain_id, state, updated_ctx}

      {:error, reason} ->
        updated_ctx = RequestContext.record_error(ctx, reason)
        {:error, reason, state, updated_ctx}
    end
  end

  # Generic read-only method forwarding
  defp handle_rpc_method(method, params, state, ctx) do
    strategy = state[:strategy] || default_provider_strategy()

    request_opts = %RequestOptions{
      strategy: strategy,
      timeout_ms: 10_000,
      request_context: ctx,
      provider_override: state[:provider_id]
    }

    # Pass context to RequestPipeline
    case RequestPipeline.execute_via_channels(
           state.chain,
           method,
           params,
           request_opts
         ) do
      {:ok, result, updated_ctx} ->
        {:ok, result, state, updated_ctx}

      {:error, reason, updated_ctx} ->
        {:error, reason, state, updated_ctx}
    end
  end

  ## Helper functions

  defp update_subscriptions(state, subscription_id, subscription_type) do
    updated_subscriptions = Map.put(state.subscriptions, subscription_id, subscription_type)
    %{state | subscriptions: updated_subscriptions}
  end

  defp get_chain_id(profile, chain_name) do
    Helpers.get_chain_id(profile, chain_name)
  end

  defp default_provider_strategy do
    Helpers.default_provider_strategy()
  end

  ## Observability helpers

  defp extract_lasso_meta(%{"lasso_meta" => meta_value} = request) when is_binary(meta_value) do
    # Parse the lasso_meta field and strip it from request
    # Note: :inline mode removed - only :notify supported for metadata delivery
    mode =
      case String.downcase(meta_value) do
        "notify" -> :notify
        # "inline" was removed - passthrough optimization is incompatible with inline metadata
        _ -> nil
      end

    clean_request = Map.delete(request, "lasso_meta")
    {mode, clean_request}
  end

  defp extract_lasso_meta(request) do
    # No lasso_meta field present
    {nil, request}
  end

  defp build_metadata_notification(ctx) do
    metadata = Observability.build_client_metadata(ctx)

    %{
      "jsonrpc" => "2.0",
      "method" => "lasso_meta",
      "params" => metadata
    }
  end

  ## Routing parameter extraction

  # Valid strategies that can appear in the path
  @valid_strategies ~w(fastest round-robin latency-weighted)

  defp extract_routing_params(nil, _params), do: {nil, nil}

  defp extract_routing_params(uri, _params) when is_binary(uri) do
    # Parse the URI path: /ws/rpc/[strategy|provider|chain_id]/[chain_id|provider_id]
    path_segments =
      uri
      |> String.split("?")
      |> List.first()
      |> String.split("/", trim: true)

    case path_segments do
      # Pattern: ["ws", "rpc", "provider", provider_id, _chain_id]
      ["ws", "rpc", "provider", provider_id | _] ->
        {nil, provider_id}

      # Pattern: ["ws", "rpc", strategy, _chain_id] where strategy is valid
      ["ws", "rpc", strategy, _chain_id] when strategy in @valid_strategies ->
        # Convert hyphenated URL strategy (round-robin) to underscored atom (:round_robin)
        strategy_atom = strategy |> String.replace("-", "_") |> String.to_atom()
        {strategy_atom, nil}

      # Pattern: ["ws", "rpc", _chain_id, provider_id] - alternative provider override
      ["ws", "rpc", _chain_id, provider_id] ->
        {nil, provider_id}

      # Pattern: ["ws", "rpc", _chain_id] - base endpoint
      ["ws", "rpc" | _] ->
        {nil, nil}

      _ ->
        {nil, nil}
    end
  end

  defp extract_routing_params(%URI{} = uri, params) do
    extract_routing_params(uri.path, params)
  end

  defp build_routing_info(nil, nil), do: ""
  defp build_routing_info(strategy, nil) when is_atom(strategy), do: " [strategy: #{strategy}]"

  defp build_routing_info(nil, provider_id) when is_binary(provider_id),
    do: " [provider: #{provider_id}]"

  ## Connection tracking helpers

  defp extract_client_ip(transport_info) do
    # Extract client IP from various possible locations in transport_info
    # Phoenix WebSocket transport provides peer information

    cond do
      # Check for x-forwarded-for header (when behind proxy/load balancer)
      # x_headers is a list of tuples like [{"x-forwarded-for", "value"}]
      x_headers = get_in(transport_info, [:connect_info, :x_headers]) ->
        extract_ip_from_headers(x_headers, transport_info)

      # Check for peer data
      peer = get_in(transport_info, [:connect_info, :peer]) ->
        format_ip(peer)

      # Fallback to unknown
      true ->
        "unknown"
    end
  end

  defp extract_ip_from_headers(x_headers, transport_info) do
    case List.keyfind(x_headers, "x-forwarded-for", 0) do
      {"x-forwarded-for", value} ->
        parse_forwarded_for(value)

      nil ->
        extract_ip_from_peer(transport_info)
    end
  end

  defp parse_forwarded_for(value) do
    # Take the first IP if multiple are present
    value
    |> String.split(",")
    |> List.first()
    |> String.trim()
  end

  defp extract_ip_from_peer(transport_info) do
    case get_in(transport_info, [:connect_info, :peer]) do
      nil -> "unknown"
      peer -> format_ip(peer)
    end
  end

  defp format_ip({ip_tuple, _port}) when is_tuple(ip_tuple) do
    # Convert IP tuple to string
    ip_tuple
    |> :inet.ntoa()
    |> to_string()
  end

  defp format_ip(ip) when is_binary(ip) do
    ip
  end

  defp format_ip(_), do: "unknown"
end
