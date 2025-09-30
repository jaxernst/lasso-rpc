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

  alias Livechain.RPC.{SubscriptionRouter, RequestPipeline}
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

    Logger.info("JSON-RPC WebSocket client connected: #{chain} (params: #{inspect(transport_info)})")
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

  defp handle_json_rpc(%{"method" => method, "params" => params, "id" => id}, state) do
    case handle_rpc_method(method, params || [], state) do
      {:ok, result, new_state} ->
        response = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => result
        }

        {:reply, :ok, {:text, Jason.encode!(response)}, new_state}

      {:error, reason, new_state} ->
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

  defp handle_rpc_method("eth_subscribe", [subscription_type | rest], state) do
    case subscription_type do
      "newHeads" ->
        case SubscriptionRouter.subscribe(state.chain, {:newHeads}) do
          {:ok, subscription_id} ->
            new_state = update_subscriptions(state, subscription_id, "newHeads")
            {:ok, subscription_id, new_state}

          {:error, reason} ->
            {:error, "Failed to create newHeads subscription: #{inspect(reason)}", state}
        end

      "logs" ->
        filter = List.first(rest, %{})

        case SubscriptionRouter.subscribe(state.chain, {:logs, filter}) do
          {:ok, subscription_id} ->
            new_state = update_subscriptions(state, subscription_id, {"logs", filter})
            {:ok, subscription_id, new_state}

          {:error, reason} ->
            {:error, "Failed to create logs subscription: #{inspect(reason)}", state}
        end

      _ ->
        {:error, "Unsupported subscription type: #{subscription_type}", state}
    end
  end

  defp handle_rpc_method("eth_unsubscribe", [subscription_id], state) do
    case Map.pop(state.subscriptions, subscription_id) do
      {nil, _} ->
        {:ok, false, state}

      {_subscription_type, updated_subscriptions} ->
        SubscriptionRouter.unsubscribe(state.chain, subscription_id)
        new_state = %{state | subscriptions: updated_subscriptions}
        {:ok, true, new_state}
    end
  end

  defp handle_rpc_method("eth_chainId", [], state) do
    case get_chain_id(state.chain) do
      {:ok, chain_id} -> {:ok, chain_id, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Generic read-only method forwarding
  defp handle_rpc_method(method, params, state) do
    strategy = default_provider_strategy()

    case RequestPipeline.execute_via_channels(state.chain, method, params, strategy: strategy) do
      {:ok, result} ->
        {:ok, result, state}

      {:error, reason} ->
        {:error, reason, state}
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
end
