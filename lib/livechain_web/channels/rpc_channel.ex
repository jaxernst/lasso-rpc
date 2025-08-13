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
  alias Livechain.Benchmarking.BenchmarkStore

  @impl true
  def join("rpc:" <> chain, _payload, socket) do
    Logger.info("JSON-RPC client joined: #{chain}")

    socket = assign(socket, :chain, chain)
    socket = assign(socket, :subscriptions, %{})

    # Ensure we have a blockchain connection for this chain
    ensure_chain_connection(chain)

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

  # Handle subscription notifications from message aggregator
  @impl true
  def handle_info({:fastest_message, provider_id, message}, socket) do
    # Process aggregated messages from MessageAggregator
    case detect_message_type(message) do
      :block ->
        send_block_subscription(socket, message)

      :log ->
        send_log_subscription(socket, message)

      :transaction ->
        send_transaction_subscription(socket, message)

      _ ->
        Logger.debug("Unhandled message type from #{provider_id}: #{inspect(message)}")
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:blockchain_message, message}, socket) do
    # Handle direct blockchain messages
    case detect_message_type(message) do
      :block ->
        send_block_subscription(socket, message)

      :log ->
        send_log_subscription(socket, message)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # Legacy handlers for backwards compatibility
  @impl true
  def handle_info(%{event: "new_block", payload: block_data}, socket) do
    send_block_subscription(socket, block_data)
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_log", payload: log_data}, socket) do
    send_log_subscription(socket, log_data)
    {:noreply, socket}
  end

  # JSON-RPC method handlers

  defp handle_rpc_method("eth_subscribe", [subscription_type | params], socket) do
    subscription_id = generate_subscription_id()

    case subscription_type do
      "newHeads" ->
        # Subscribe to block updates for this chain
        Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{socket.assigns.chain}")

        _socket = update_subscriptions(socket, subscription_id, "newHeads")
        {:subscription, subscription_id}

      "logs" ->
        # Subscribe to log updates with optional filtering
        filter = List.first(params, %{})
        Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{socket.assigns.chain}:logs")

        _socket = update_subscriptions(socket, subscription_id, {"logs", filter})
        {:subscription, subscription_id}

      _ ->
        {:error, "Unsupported subscription type: #{subscription_type}"}
    end
  end

  defp handle_rpc_method("eth_unsubscribe", [subscription_id], socket) do
    case Map.pop(socket.assigns.subscriptions, subscription_id) do
      {nil, _} ->
        {:ok, false}

      {_subscription_type, updated_subscriptions} ->
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
    case ChainManager.get_available_providers(chain) do
      {:ok, [provider_id | _]} -> {:ok, provider_id}
      {:ok, []} -> {:error, :no_providers}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_best_provider(chain, _method, :round_robin) do
    case ChainManager.get_available_providers(chain) do
      {:ok, []} ->
        {:error, :no_providers}

      {:ok, providers} ->
        idx = rem(System.monotonic_time(:millisecond), length(providers))
        {:ok, Enum.at(providers, idx)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_chain_connection(chain) do
    # Check if we have an active connection for this chain
    connections = WSSupervisor.list_connections()

    existing =
      Enum.find(connections, fn conn ->
        String.contains?(String.downcase(conn.name || ""), chain)
      end)

    if existing do
      Logger.debug("Using existing connection for #{chain}")
      :ok
    else
      Logger.info("Starting new connection for #{chain}")
      # Start a mock connection for this chain
      endpoint =
        case chain do
          "ethereum" -> Livechain.RPC.MockWSEndpoint.ethereum_mainnet()
          "arbitrum" -> Livechain.RPC.MockWSEndpoint.arbitrum()
          "polygon" -> Livechain.RPC.MockWSEndpoint.polygon()
          "bsc" -> Livechain.RPC.MockWSEndpoint.bsc()
          _ -> nil
        end

      if endpoint do
        WSSupervisor.start_connection(endpoint)
      else
        {:error, :unsupported_chain}
      end
    end
  end

  defp get_chain_connection(chain) do
    connections = WSSupervisor.list_connections()

    case Enum.find(connections, fn conn ->
           String.contains?(String.downcase(conn.name || ""), chain)
         end) do
      nil -> {:error, :no_connection}
      connection -> {:ok, connection}
    end
  end

  defp generate_subscription_id do
    "0x" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
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

  # Subscription notification helpers
  defp send_block_subscription(socket, block_data) do
    socket.assigns.subscriptions
    |> Enum.filter(fn {_sub_id, sub_type} -> sub_type == "newHeads" end)
    |> Enum.each(fn {subscription_id, _} ->
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => subscription_id,
          "result" => extract_block_data(block_data)
        }
      }

      IO.inspect(notification, label: "send_block_subscription")
      push(socket, "rpc_notification", notification)
    end)
  end

  defp send_log_subscription(socket, log_data) do
    socket.assigns.subscriptions
    |> Enum.filter(fn {_sub_id, sub_type} ->
      case sub_type do
        "logs" -> true
        {"logs", _filter} -> true
        _ -> false
      end
    end)
    |> Enum.each(fn {subscription_id, _} ->
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => subscription_id,
          "result" => extract_log_data(log_data)
        }
      }

      push(socket, "rpc_notification", notification)
    end)
  end

  defp send_transaction_subscription(socket, tx_data) do
    socket.assigns.subscriptions
    |> Enum.filter(fn {_sub_id, sub_type} -> sub_type == "newPendingTransactions" end)
    |> Enum.each(fn {subscription_id, _} ->
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => subscription_id,
          "result" => extract_transaction_data(tx_data)
        }
      }

      push(socket, "rpc_notification", notification)
    end)
  end

  # Message type detection based on content using pattern matching
  defp detect_message_type(message) when is_map(message) do
    case message do
      # New block message (direct result)
      %{"result" => %{"hash" => _hash, "number" => _number}} ->
        :block

      # Subscription message with block data that has transaction hash (log)
      %{"params" => %{"result" => %{"hash" => _hash, "transactionHash" => _tx_hash}}} ->
        :log

      # Subscription message with block data that has block number (block)
      %{"params" => %{"result" => %{"hash" => _hash, "number" => _number}}} ->
        :block

      # Log message (transaction-based)
      %{"params" => %{"result" => %{"transactionHash" => _tx_hash}}} ->
        :log

      # Transaction message (string result - typically a hash)
      %{"params" => %{"result" => result}} when is_binary(result) ->
        :transaction

      _ ->
        :other
    end
  end

  defp detect_message_type(_), do: :other

  # Data extraction helpers for subscriptions using pattern matching
  defp extract_block_data(message) when is_map(message) do
    case message do
      %{"result" => result} when is_map(result) ->
        result

      %{"params" => %{"result" => result}} ->
        result

      _ ->
        message
    end
  end

  defp extract_block_data(data), do: data

  defp extract_log_data(message) when is_map(message) do
    case message do
      %{"params" => %{"result" => result}} ->
        result

      %{"result" => result} ->
        result

      _ ->
        message
    end
  end

  defp extract_log_data(data), do: data

  defp extract_transaction_data(message) when is_map(message) do
    case message do
      %{"params" => %{"result" => result}} ->
        result

      %{"result" => result} ->
        result

      _ ->
        message
    end
  end

  defp extract_transaction_data(data), do: data
end
