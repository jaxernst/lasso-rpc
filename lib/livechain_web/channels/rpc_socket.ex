defmodule LivechainWeb.RPCSocket do
  @moduledoc """
  WebSocket handler for standard Ethereum JSON-RPC.

  # TODO: 'Viem compatible' is the wrong way to describe this. 'Viem compatible' just means that it follows the ethereum JSON-RPC spec.
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
  def connect(_params, socket, connect_info) do
    # Extract chain from the socket path
    chain = extract_chain_from_connect_info(connect_info)

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

  defp extract_chain_from_connect_info(connect_info) do
    # Try to extract chain from the URI path
    case connect_info do
      %{uri: %{path: path}} when is_binary(path) ->
        case String.split(path, "/") do
          ["", "rpc", chain | _] -> chain
          _ -> "unknown"
        end

      _ ->
        # Fallback: try to get from params
        case connect_info do
          %{params: %{"chain" => chain}} -> chain
          _ -> "unknown"
        end
    end
  end

  @impl true
  def id(socket), do: "rpc_socket:#{socket.assigns.chain}"

  # Validate chain against configured chains
  defp valid_chain?(chain) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        Map.has_key?(config.chains, chain)

      # TODO: Should not use fallbacks here (config is the source of truth).
      {:error, _reason} ->
        # Fallback to basic validation if config loading fails
        chain in ["ethereum", "arbitrum", "polygon", "bsc"]
    end
  end
end
