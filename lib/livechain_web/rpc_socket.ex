defmodule LivechainWeb.RPCSocket do
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

  alias Livechain.RPC.{SubscriptionRouter, RequestPipeline, RequestContext, Observability}
  alias Livechain.JSONRPC.Error, as: JError
  alias Livechain.Config.ConfigStore

  ## Phoenix.Socket.Transport callbacks

  @impl true
  def child_spec(_opts) do
    # Return :ignore since we don't need a persistent process
    :ignore
  end

  @impl true
  def connect(transport_info) do
    # Extract chain from path parameters
    # transport_info is a map with :params key containing route params
    chain = get_in(transport_info, [:params, "chain_id"]) || "ethereum"

    socket_state = %{
      chain: chain,
      subscriptions: %{},
      client_pid: self()
    }

    Logger.info(
      "JSON-RPC WebSocket client connected: #{chain} (params: #{inspect(transport_info)})"
    )

    {:ok, socket_state}
  end

  @impl true
  def init(state) do
    # Subscribe to receive subscription events
    Process.flag(:trap_exit, true)
    {:ok, state}
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
  def handle_in(_, state) do
    # Ignore non-text frames (ping, pong, binary)
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
    Application.get_env(:livechain, :provider_selection_strategy, :cheapest)
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
end
