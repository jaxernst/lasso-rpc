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

  alias Livechain.RPC.WSSupervisor
  alias Livechain.RPC.ChainManager
  alias Livechain.RPC.SubscriptionManager
  alias Livechain.Benchmarking.BenchmarkStore

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

    response =
      case handle_rpc_method(method, params, socket) do
        {:ok, result} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => result
          }

        {:error, reason} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{
              "code" => -32000,
              "message" => to_string(reason)
            }
          }

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

    response = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{
        "code" => -32600,
        "message" => "Invalid Request"
      }
    }

    {:reply, {:ok, response}, socket}
  end

  # Handle subscription notifications from SubscriptionManager
  @impl true
  def handle_info({:subscription_event, notification}, socket) do
    # Forward the subscription notification directly to the client
    push(socket, "rpc_notification", notification)
    {:noreply, socket}
  end

  # JSON-RPC method handlers

  defp handle_rpc_method("eth_subscribe", [subscription_type | params], socket) do
    case subscription_type do
      "newHeads" ->
        case SubscriptionManager.subscribe_to_new_heads(socket.assigns.chain) do
          {:ok, subscription_id} ->
            # Subscribe to the per-subscription topic
            Phoenix.PubSub.subscribe(Livechain.PubSub, "subscription:#{subscription_id}")

            _socket = update_subscriptions(socket, subscription_id, "newHeads")
            {:subscription, subscription_id}

          {:error, reason} ->
            {:error, "Failed to create newHeads subscription: #{reason}"}
        end

      "logs" ->
        filter = List.first(params, %{})

        case SubscriptionManager.subscribe_to_logs(socket.assigns.chain, filter) do
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
        # Unsubscribe from SubscriptionManager
        SubscriptionManager.unsubscribe(subscription_id)

        # Unsubscribe from per-subscription topic
        Phoenix.PubSub.unsubscribe(Livechain.PubSub, "subscription:#{subscription_id}")

        _socket = assign(socket, :subscriptions, updated_subscriptions)
        {:ok, true}
    end
  end

  # Prefer generic forwarding path for reads; keep legacy specific handlers for now
  defp handle_rpc_method("eth_getLogs", [filter], socket) do
    forward_over_ws(socket.assigns.chain, "eth_getLogs", [filter])
  end

  defp handle_rpc_method("eth_getBlockByNumber", [block_number, include_transactions], socket) do
    forward_over_ws(socket.assigns.chain, "eth_getBlockByNumber", [
      block_number,
      include_transactions
    ])
  end

  defp handle_rpc_method("eth_blockNumber", [], socket) do
    forward_over_ws(socket.assigns.chain, "eth_blockNumber", [])
  end

  defp handle_rpc_method("eth_getBalance", [address, block], socket) do
    forward_over_ws(socket.assigns.chain, "eth_getBalance", [address, block])
  end

  defp handle_rpc_method("eth_chainId", [], socket) do
    case get_chain_id(socket.assigns.chain) do
      {:ok, chain_id} -> {:ok, chain_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # Generic forwarding catchall for read-only JSON-RPC methods over WS
  defp handle_rpc_method(method, params, socket) do
    forward_over_ws(socket.assigns.chain, method, params)
  end

  # Helper functions

  defp forward_over_ws(chain, method, params) do
    with {:ok, provider_id} <- select_best_provider(chain, method, default_provider_strategy()),
         {:ok, result} <- ChainManager.forward_rpc_request(chain, provider_id, method, params) do
      BenchmarkStore.record_rpc_call(chain, provider_id, method, 0, :success)
      {:ok, result}
    else
      {:error, reason} ->
        {:error, "RPC forwarding failed: #{inspect(reason)}"}

      other ->
        {:error, "RPC forwarding failed: #{inspect(other)}"}
    end
  end

  defp default_provider_strategy do
    Application.get_env(:livechain, :provider_selection_strategy, :leaderboard)
  end

  defp select_best_provider(chain, method, :leaderboard) do
    case BenchmarkStore.get_provider_leaderboard(chain) do
      {:ok, [_ | _] = leaderboard} ->
        [best | _] = Enum.sort_by(leaderboard, & &1.score, :desc)
        {:ok, best.provider_id}

      {:ok, []} ->
        select_best_provider(chain, method, :priority)

      {:error, _} ->
        select_best_provider(chain, method, :priority)
    end
  end

  defp select_best_provider(chain, _method, :priority) do
    # Prefer active providers from ProviderPool; fallback to static config if not running
    case Livechain.RPC.ChainManager.get_available_providers(chain) do
      {:ok, [provider_id | _]} -> {:ok, provider_id}
      _ -> select_provider_from_config(chain)
    end
  end

  defp select_best_provider(chain, _method, :round_robin) do
    case Livechain.RPC.ChainManager.get_available_providers(chain) do
      {:ok, []} ->
        select_provider_from_config(chain)

      {:ok, providers} ->
        idx = rem(System.monotonic_time(:millisecond), length(providers))
        {:ok, Enum.at(providers, idx)}

      {:error, _reason} ->
        select_provider_from_config(chain)
    end
  end

  defp select_provider_from_config(chain) do
    with {:ok, cfg} <- Livechain.Config.ChainConfig.load_config(),
         %{providers: providers} <- Map.get(cfg.chains, chain) do
      case providers do
        [%{id: id} | _] -> {:ok, id}
        _ -> {:error, :no_providers}
      end
    else
      _ -> {:error, :no_providers}
    end
  end

  defp update_subscriptions(socket, subscription_id, subscription_type) do
    updated_subscriptions =
      Map.put(socket.assigns.subscriptions, subscription_id, subscription_type)

    assign(socket, :subscriptions, updated_subscriptions)
  end

  # Get chain ID from configuration
  defp get_chain_id(chain_name) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        case Map.get(config.chains, chain_name) do
          %{chain_id: chain_id} when is_integer(chain_id) ->
            {:ok, "0x" <> Integer.to_string(chain_id, 16)}

          %{chain_id: chain_id} when is_binary(chain_id) ->
            {:ok, chain_id}

          nil ->
            {:error, "Chain not configured: #{chain_name}"}

          _ ->
            {:error, "Invalid chain configuration for: #{chain_name}"}
        end

      {:error, _reason} ->
        {:error, "Failed to load chain configuration"}
    end
  end
end
