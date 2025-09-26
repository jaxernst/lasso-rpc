defmodule LivechainWeb.RPCChannel do
  @moduledoc """
  Standard Ethereum JSON-RPC WebSocket channel.

  Provides Viem-compatible JSON-RPC over WebSocket with:
  - Method routing (eth_subscribe, eth_getLogs, etc.)
  - Subscription management
  - Provider failover integration
  - Standard JSON-RPC 2.0 response format
  """

  use LivechainWeb, :channel
  require Logger

  alias Livechain.RPC.{SubscriptionRouter, RequestPipeline}
  alias Livechain.JSONRPC.Error, as: JError
  alias Livechain.Config.ConfigStore

  @impl true
  def join("rpc:" <> chain, _payload, socket) do
    Logger.info("JSON-RPC client joined: #{chain}")

    socket = assign(socket, :chain, chain)
    socket = assign(socket, :subscriptions, %{})

    {:ok, %{status: "connected", chain: chain}, socket}
  end

  @impl true
  def handle_in(
        "rpc_call",
        %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id},
        socket
      ) do
    Logger.debug("JSON-RPC call: #{method} with params: #{inspect(params)}")

    IO.puts("handle_in: #{method} with params: #{inspect(params)}")

    response =
      case handle_rpc_method(method, params, socket) do
        {:ok, result} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => result
          }

        {:error, reason} ->
          JError.to_response(JError.from(reason), id)

        {:subscription, subscription_id} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => subscription_id
          }
      end

    {:reply, {:ok, response}, socket}
  end

  @impl true
  def handle_in("rpc_call", invalid_request, socket) do
    Logger.warning("Invalid JSON-RPC request: #{inspect(invalid_request)}")

    error = JError.new(-32600, "Invalid Request")
    response = JError.to_response(error, nil)

    {:reply, {:ok, response}, socket}
  end

  # Handle subscription notifications from ClientSubscriptionRegistry
  @impl true
  def handle_info({:subscription_event, payload}, socket) do
    # If payload is already a proper JSON-RPC notification, forward directly
    # Otherwise, wrap it (defensive)
    message =
      case payload do
        %{"jsonrpc" => "2.0", "method" => "eth_subscription", "params" => %{"subscription" => _}} ->
          payload

        other ->
          %{"jsonrpc" => "2.0", "method" => "eth_subscription", "params" => other}
      end

    push(socket, "rpc_notification", message)
    {:noreply, socket}
  end

  # JSON-RPC method handlers

  defp handle_rpc_method("eth_subscribe", [subscription_type | params], socket) do
    case subscription_type do
      "newHeads" ->
        case SubscriptionRouter.subscribe(socket.assigns.chain, {:newHeads}) do
          {:ok, subscription_id} ->
            _socket = update_subscriptions(socket, subscription_id, "newHeads")
            {:subscription, subscription_id}

          {:error, reason} ->
            {:error, "Failed to create newHeads subscription: #{reason}"}
        end

      "logs" ->
        filter = List.first(params, %{})

        case SubscriptionRouter.subscribe(socket.assigns.chain, {:logs, filter}) do
          {:ok, subscription_id} ->
            # Subscribe to the per-subscription topic
            Phoenix.PubSub.subscribe(Livechain.PubSub, "subscription:#{subscription_id}")

            _socket = update_subscriptions(socket, subscription_id, {"logs", filter})
            {:subscription, subscription_id}

          {:error, reason} ->
            {:error, "Failed to create logs subscription: #{reason}"}
        end

      _ ->
        {:error, "Unsupported subscription type: #{subscription_type}"}
    end
  end

  defp handle_rpc_method("eth_unsubscribe", [subscription_id], socket) do
    case Map.pop(socket.assigns.subscriptions, subscription_id) do
      {nil, _} ->
        {:ok, false}

      {_subscription_type, updated_subscriptions} ->
        # Unsubscribe from new pool/router
        SubscriptionRouter.unsubscribe(socket.assigns.chain, subscription_id)

        # Unsubscribe from per-subscription topic
        Phoenix.PubSub.unsubscribe(Livechain.PubSub, "subscription:#{subscription_id}")

        _socket = assign(socket, :subscriptions, updated_subscriptions)
        {:ok, true}
    end
  end

  # Prefer generic forwarding path for reads; keep legacy specific handlers for now
  defp handle_rpc_method("eth_getLogs", [filter], socket) do
    forward_read_call(socket.assigns.chain, "eth_getLogs", [filter])
  end

  defp handle_rpc_method("eth_getBlockByNumber", [block_number, include_transactions], socket) do
    forward_read_call(socket.assigns.chain, "eth_getBlockByNumber", [
      block_number,
      include_transactions
    ])
  end

  defp handle_rpc_method("eth_blockNumber", [], socket) do
    forward_read_call(socket.assigns.chain, "eth_blockNumber", [])
  end

  defp handle_rpc_method("eth_getBalance", [address, block], socket) do
    forward_read_call(socket.assigns.chain, "eth_getBalance", [address, block])
  end

  defp handle_rpc_method("eth_chainId", [], socket) do
    case get_chain_id(socket.assigns.chain) do
      {:ok, chain_id} -> {:ok, chain_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # Generic forwarding catchall for read-only JSON-RPC methods over WS
  defp handle_rpc_method(method, params, socket) do
    forward_read_call(socket.assigns.chain, method, params)
  end

  # Helper functions

  # Forward read calls from WS clients with full failover support
  # Uses the same failover logic as HTTP for seamless error recovery
  defp forward_read_call(chain, method, params) do
    strategy = default_provider_strategy()

    pipeline_opts = [
      strategy: strategy
    ]

    # Pass through the error directly for consistent normalization upstream
    RequestPipeline.execute(chain, method, params, pipeline_opts)
  end

  defp default_provider_strategy do
    Application.get_env(:livechain, :provider_selection_strategy, :cheapest)
  end

  defp update_subscriptions(socket, subscription_id, subscription_type) do
    updated_subscriptions =
      Map.put(socket.assigns.subscriptions, subscription_id, subscription_type)

    assign(socket, :subscriptions, updated_subscriptions)
  end

  # Get chain ID from ConfigStore
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
end
