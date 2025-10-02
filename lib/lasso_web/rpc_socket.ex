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

  alias Lasso.RPC.{SubscriptionRouter, RequestPipeline, RequestContext, Observability}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Config.ConfigStore
  alias LassoWeb.ConnectionTracker

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

    # Check connection limits (feature-flagged; proceed if disabled)
    case maybe_check_connection_allowed(client_ip) do
      {:ok, connection_id} ->
        # Extract chain from path parameters
        chain = get_in(transport_info, [:params, "chain_id"]) || "ethereum"

        socket_state = %{
          chain: chain,
          subscriptions: %{},
          client_pid: self(),
          heartbeat_ref: nil,
          missed_heartbeats: 0,
          last_ping_time: nil,
          connection_id: connection_id,
          client_ip: client_ip
        }

        Logger.info(
          "JSON-RPC WebSocket client connected: #{chain} (id: #{connection_id}, ip: #{client_ip})"
        )

        {:ok, socket_state}

      {:error, reason} ->
        Logger.warning("Connection rejected: #{reason} (ip: #{client_ip})")
        {:error, reason}
    end
  end

  @impl true
  def init(state) do
    # Subscribe to receive subscription events
    Process.flag(:trap_exit, true)

    # Register connection with tracker if enabled
    maybe_register_connection(state.connection_id, state.client_ip)

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
        error = JError.new(-32600, "Invalid Request: missing jsonrpc field")
        response = JError.to_response(error, Map.get(invalid, "id"))
        {:reply, :ok, {:text, Jason.encode!(response)}, state}

      {:error, _reason} ->
        error = JError.new(-32700, "Parse error")
        response = JError.to_response(error, nil)
        {:reply, :ok, {:text, Jason.encode!(response)}, state}
    end
  end

  @impl true
  def handle_in({_data, [opcode: :pong]}, state) do
    # Handle pong response - reset heartbeat counter
    Logger.debug("Received pong from client")
    {:ok, %{state | missed_heartbeats: 0, last_ping_time: nil}}
  end

  @impl true
  def handle_in(_, state) do
    # Ignore other non-text frames (ping, binary)
    {:ok, state}
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
    Logger.debug("Sending heartbeat ping to client")

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
    Logger.warning("Heartbeat timeout - missed #{missed}/#{@max_missed_heartbeats} heartbeats")

    if missed >= @max_missed_heartbeats do
      Logger.error("Too many missed heartbeats (#{missed}), closing connection")
      {:stop, :heartbeat_timeout, state}
    else
      # Schedule next heartbeat
      heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)
      {:ok, %{state | missed_heartbeats: missed, heartbeat_ref: heartbeat_ref}}
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.debug("WebSocket process exiting: #{inspect(reason)}")
    {:stop, reason, state}
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

    # Unregister connection from tracker if enabled
    maybe_unregister_connection(state.connection_id, state.client_ip)

    # Unsubscribe all active subscriptions
    Enum.each(state.subscriptions, fn {subscription_id, _type} ->
      SubscriptionRouter.unsubscribe(state.chain, subscription_id)
    end)

    :ok
  end

  ## JSON-RPC handling

  defp handle_json_rpc(%{"method" => method, "params" => params, "id" => id} = request, state) do
    # Extract and parse lasso_meta preference (inline, notify, or nil)
    {lasso_meta_mode, _clean_request} = extract_lasso_meta(request)

    # Create request context for observability
    ctx =
      RequestContext.new(state.chain, method,
        params_present: params != nil and params != [],
        params_digest: RequestContext.compute_params_digest(params),
        transport: :ws,
        strategy: default_provider_strategy()
      )

    case handle_rpc_method(method, params || [], state, ctx) do
      {:ok, result, new_state, updated_ctx} ->
        # Emit structured log
        Observability.log_request_completed(updated_ctx)

        # Build base response
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => result
        }

        # Inject metadata based on mode
        case lasso_meta_mode do
          :inline ->
            # Add lasso_meta field to response
            enriched_response = inject_inline_metadata(response, updated_ctx)
            {:reply, :ok, {:text, Jason.encode!(enriched_response)}, new_state}

          :notify ->
            # Send response first, then notification
            {:ok, json} = Jason.encode(response)
            notification = build_metadata_notification(updated_ctx)
            {:ok, notification_json} = Jason.encode(notification)

            # Reply with response only, then send notification as separate push
            send(self(), {:send_notification, notification_json})
            {:reply, :ok, {:text, json}, new_state}

          _ ->
            # No metadata requested
            {:reply, :ok, {:text, Jason.encode!(response)}, new_state}
        end

      {:error, reason, new_state, updated_ctx} ->
        # Emit structured log even for errors
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
    error = JError.new(-32600, "Invalid Request: missing required fields")
    response = JError.to_response(error, Map.get(invalid, "id"))
    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

  ## RPC method handlers

  defp handle_rpc_method("eth_subscribe", [subscription_type | rest], state, ctx) do
    case subscription_type do
      "newHeads" ->
        case SubscriptionRouter.subscribe(state.chain, {:newHeads}) do
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

        case SubscriptionRouter.subscribe(state.chain, {:logs, filter}) do
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
        SubscriptionRouter.unsubscribe(state.chain, subscription_id)
        new_state = %{state | subscriptions: updated_subscriptions}
        updated_ctx = RequestContext.record_success(ctx, true)
        {:ok, true, new_state, updated_ctx}
    end
  end

  defp handle_rpc_method("eth_chainId", [], state, ctx) do
    case get_chain_id(state.chain) do
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
    strategy = default_provider_strategy()

    # Pass context to RequestPipeline
    case RequestPipeline.execute_via_channels(
           state.chain,
           method,
           params,
           strategy: strategy,
           request_context: ctx
         ) do
      {:ok, result} ->
        # Retrieve updated context from Process dictionary
        updated_ctx = Process.get(:request_context, ctx)
        {:ok, result, state, updated_ctx}

      {:error, reason} ->
        # Retrieve updated context even on error
        updated_ctx = Process.get(:request_context, ctx)
        {:error, reason, state, updated_ctx}
    end
  end

  ## Helper functions

  defp update_subscriptions(state, subscription_id, subscription_type) do
    updated_subscriptions = Map.put(state.subscriptions, subscription_id, subscription_type)
    %{state | subscriptions: updated_subscriptions}
  end

  defp get_chain_id(chain_name) do
    case ConfigStore.get_chain(chain_name) do
      {:ok, %{chain_id: chain_id}} when is_integer(chain_id) ->
        {:ok, "0x" <> Integer.to_string(chain_id, 16)}

      {:ok, %{chain_id: chain_id}} when is_binary(chain_id) ->
        {:ok, chain_id}

      {:error, :not_found} ->
        {:error, "Chain not configured: #{chain_name}"}

      {:ok, _} ->
        {:error, "Invalid chain configuration for: #{chain_name}"}
    end
  end

  defp default_provider_strategy do
    Application.get_env(:lasso, :provider_selection_strategy, :cheapest)
  end

  ## Observability helpers

  defp extract_lasso_meta(%{"lasso_meta" => meta_value} = request) when is_binary(meta_value) do
    # Parse the lasso_meta field and strip it from request
    mode =
      case String.downcase(meta_value) do
        "inline" -> :inline
        "notify" -> :notify
        _ -> nil
      end

    clean_request = Map.delete(request, "lasso_meta")
    {mode, clean_request}
  end

  defp extract_lasso_meta(request) do
    # No lasso_meta field present
    {nil, request}
  end

  defp inject_inline_metadata(response, ctx) do
    metadata = Observability.build_client_metadata(ctx)
    Map.put(response, "lasso_meta", metadata)
  end

  defp build_metadata_notification(ctx) do
    metadata = Observability.build_client_metadata(ctx)

    %{
      "jsonrpc" => "2.0",
      "method" => "lasso_meta",
      "params" => metadata
    }
  end

  ## Connection tracking helpers

  defp extract_client_ip(transport_info) do
    # Extract client IP from various possible locations in transport_info
    # Phoenix WebSocket transport provides peer information

    cond do
      # Check for x-forwarded-for header (when behind proxy/load balancer)
      x_forwarded_for = get_in(transport_info, [:connect_info, :x_headers, "x-forwarded-for"]) ->
        # Take the first IP if multiple are present
        String.split(x_forwarded_for, ",") |> List.first() |> String.trim()

      # Check for peer data
      peer = get_in(transport_info, [:connect_info, :peer]) ->
        format_ip(peer)

      # Fallback to unknown
      true ->
        "unknown"
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

  defp tracker_enabled? do
    Application.get_env(:lasso, :enable_connection_tracker, false)
  end

  defp maybe_check_connection_allowed(client_ip) do
    if tracker_enabled?() do
      ConnectionTracker.check_connection_allowed(client_ip)
    else
      {:ok, "conn-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
    end
  end

  defp maybe_register_connection(connection_id, client_ip) do
    if tracker_enabled?() do
      ConnectionTracker.register_connection(connection_id, client_ip)
    else
      :ok
    end
  end

  defp maybe_unregister_connection(connection_id, client_ip) do
    if tracker_enabled?() do
      ConnectionTracker.unregister_connection(connection_id, client_ip)
    else
      :ok
    end
  end
end
