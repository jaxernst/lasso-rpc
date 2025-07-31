defmodule LivechainWeb.RPCSocket do
  @moduledoc """
  WebSocket handler for standard Ethereum JSON-RPC.

  Provides Viem-compatible WebSocket endpoints at:
  - /rpc/ethereum
  - /rpc/arbitrum
  - /rpc/polygon

  Supports standard methods:
  - eth_subscribe / eth_unsubscribe
  - eth_getLogs
  - eth_getBlockByNumber
  - eth_getTransactionReceipt
  """

  use Phoenix.Socket
  require Logger

  ## Channels
  channel("rpc:*", LivechainWeb.RPCChannel)

  @impl true
  def connect(%{"chain" => chain}, socket, _connect_info) do
    case valid_chain?(chain) do
      true ->
        Logger.info("JSON-RPC client connected to chain: #{chain}")
        socket = assign(socket, :chain, chain)
        {:ok, socket}

      false ->
        Logger.warning("Invalid chain requested: #{chain}")
        :error
    end
  end

  @impl true
  def connect(_params, _socket, _connect_info) do
    Logger.warning("Missing chain parameter in RPC connection")
    :error
  end

  @impl true
  def id(socket), do: "rpc_socket:#{socket.assigns.chain}"

  # Supported chains for JSON-RPC compatibility
  defp valid_chain?(chain) when chain in ["ethereum", "arbitrum", "polygon", "bsc"], do: true
  defp valid_chain?(_), do: false
end
