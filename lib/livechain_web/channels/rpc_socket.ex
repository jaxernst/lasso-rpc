defmodule LivechainWeb.RPCSocket do
  @moduledoc """
  WebSocket handler for standard Ethereum JSON-RPC.

  Provides Ethereum JSON-RPC WebSocket endpoints at:
  - /rpc/ethereum
  - /rpc/arbitrum
  - /rpc/polygon

  Supports standard methods:
  - eth_subscribe / eth_unsubscribe
  - eth_getLogs
  - eth_getBlockByNumber
  - eth_getTransactionReceipt


  # TODO: Need to ensure we are connected to at least one provider for the target chain when connecting
          if not providers are available to connect, we should disconnect the client
  """

  use Phoenix.Socket
  require Logger

  ## Channels
  channel("rpc:*", LivechainWeb.RPCChannel)

  def connect(%{"chain_id" => chain_identifier}, socket, connect_info) do
    case Livechain.Config.ConfigStore.get_chain_by_name_or_id(chain_identifier) do
      {:ok, {chain_name, _chain_config}} ->
        Logger.info("JSON-RPC client connected to chain: #{chain_name}")
        socket = assign(socket, :chain, chain_name)

        publish_client_event(:client_connected, chain_name, connect_info)

        {:ok, socket}

      _ ->
        Logger.warning("Invalid chain requested: #{inspect(chain_identifier)}")
        :error
    end
  end

  def id(socket), do: "rpc_socket:#{socket.assigns.chain}"

  defp publish_client_event(event, chain, connect_info) do
    remote_ip =
      case connect_info do
        %{peer_data: %{address: {a, b, c, d}}} ->
          Enum.join([a, b, c, d], ".")

        _ ->
          nil
      end

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "clients:events",
      %{
        ts: System.system_time(:millisecond),
        event: event,
        chain: chain,
        transport: :ws,
        remote_ip: remote_ip
      }
    )
  end
end
