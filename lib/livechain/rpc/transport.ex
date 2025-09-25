defmodule Livechain.RPC.Transport do
  @moduledoc """
  Unified transport abstraction for RPC requests.

  Provides a consistent interface for forwarding requests regardless of
  the underlying protocol (HTTP, WebSocket, etc.), enabling clean separation
  of transport concerns from failover and routing logic.
  """

  alias Livechain.JSONRPC.Error, as: JError

  @type provider_config :: map()
  @type method :: String.t()
  @type params :: list()
  @type request_id :: String.t()
  @type opts :: keyword()

  @doc """
  Forwards a request using the appropriate transport for the provider configuration.

  Options:
  - `:timeout` - Request timeout in milliseconds
  - `:request_id` - Unique request identifier (generated if not provided)
  - `:protocol` - Force specific protocol (:http | :ws)

  Returns the decoded response or a normalized JError.
  """
  @callback forward_request(provider_config, method, params, opts) ::
              {:ok, any()} | {:error, JError.t()}

  @doc """
  Determines if a provider supports the specified protocol.
  """
  @callback supports_protocol?(provider_config, :http | :ws | :both) :: boolean()

  @doc """
  Gets the preferred transport for a provider configuration.
  """
  @callback get_transport_type(provider_config) :: :http | :ws

  @doc """
  Forwards a request using the best available transport for the provider.

  Automatically selects HTTP or WebSocket based on provider configuration
  and request type. Falls back gracefully between protocols when possible.
  """
  @spec forward_request(String.t(), provider_config, method, params, opts) ::
          {:ok, any()} | {:error, JError.t()}
  def forward_request(provider_id, provider_config, method, params, opts \\ []) do
    case select_transport(provider_config, method, opts) do
      nil ->
        {:error, JError.new(-32000, "No suitable transport available", provider_id: provider_id)}

      transport when is_atom(transport) ->
        transport.forward_request(provider_config, method, params,
                                  Keyword.put(opts, :provider_id, provider_id))
    end
  end

  @doc """
  Checks if a provider supports the specified protocol.
  """
  @spec supports_protocol?(provider_config, :http | :ws | :both) :: boolean()
  def supports_protocol?(provider_config, protocol) do
    case protocol do
      :http -> has_http_url?(provider_config)
      :ws -> has_ws_url?(provider_config)
      :both -> has_http_url?(provider_config) and has_ws_url?(provider_config)
    end
  end

  # Private functions

  defp select_transport(provider_config, method, opts) do
    forced_protocol = Keyword.get(opts, :protocol)

    case forced_protocol do
      :http ->
        if has_http_url?(provider_config), do: Livechain.RPC.Transport.HTTP, else: nil

      :ws ->
        if has_ws_url?(provider_config), do: Livechain.RPC.Transport.WebSocket, else: nil

      :both ->
        # For :both, prefer WebSocket for subscriptions, HTTP otherwise
        cond do
          subscription_method?(method) and has_ws_url?(provider_config) ->
            Livechain.RPC.Transport.WebSocket
          has_http_url?(provider_config) ->
            Livechain.RPC.Transport.HTTP
          has_ws_url?(provider_config) ->
            Livechain.RPC.Transport.WebSocket
          true ->
            nil
        end

      nil ->
        # Auto-select based on method and availability
        cond do
          subscription_method?(method) and has_ws_url?(provider_config) ->
            Livechain.RPC.Transport.WebSocket
          has_http_url?(provider_config) ->
            Livechain.RPC.Transport.HTTP
          has_ws_url?(provider_config) ->
            Livechain.RPC.Transport.WebSocket
          true ->
            nil
        end
    end
  end

  defp subscription_method?("eth_subscribe"), do: true
  defp subscription_method?("eth_unsubscribe"), do: true
  defp subscription_method?(_), do: false

  defp has_http_url?(provider_config) do
    is_binary(Map.get(provider_config, :url)) or
      is_binary(Map.get(provider_config, :http_url))
  end

  defp has_ws_url?(provider_config) do
    is_binary(Map.get(provider_config, :ws_url))
  end

  @doc """
  Generates a unique request ID for tracking purposes.
  """
  def generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end