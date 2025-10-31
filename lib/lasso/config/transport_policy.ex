defmodule Lasso.Config.TransportPolicy do
  @moduledoc """
  Centralizes JSON-RPC method constraints and transport requirements.

  - Defines which methods are WS-only
  - Defines which methods are globally disallowed by the proxy
  - Provides helpers to compute allowed transports for a method
  """

  @type method :: String.t()
  @type transport :: :http | :ws

  @ws_only_methods [
    "eth_subscribe",
    "eth_unsubscribe"
  ]

  # Globally disallowed methods (stateful/account management)
  @disallowed_methods [
    "eth_sendTransaction",
    "personal_sign",
    "eth_sign",
    "eth_signTransaction",
    "eth_accounts",
    "txpool_content",
    "txpool_inspect",
    "txpool_status"
  ]

  @doc """
  Returns true if the method requires WebSocket transport.
  """
  @spec ws_only?(method) :: boolean()
  def ws_only?(method) when is_binary(method), do: method in @ws_only_methods

  @doc """
  Returns true if the method is globally disallowed by the proxy.
  """
  @spec disallowed?(method) :: boolean()
  def disallowed?(method) when is_binary(method), do: method in @disallowed_methods

  @doc """
  For a given method, return the required transport if any.

  - :ws for WS-only methods (subscriptions)
  - nil if both transports are acceptable
  """
  @spec required_transport_for(method) :: transport | nil
  def required_transport_for(method) when is_binary(method) do
    if ws_only?(method), do: :ws, else: nil
  end

  @doc """
  Compute the allowed transports for a method, honoring an optional request-level
  transport preference (e.g. client forced :http or :ws).

  If the method is WS-only, always returns [:ws] regardless of preference.
  If preference is nil or :both, returns [:http, :ws] (for unary methods).
  """
  @spec allowed_transports_for(method, transport | :both | nil) :: [transport]
  def allowed_transports_for(method, preference \\ :both) when is_binary(method) do
    case required_transport_for(method) do
      :ws ->
        [:ws]

      nil ->
        case preference do
          :http -> [:http]
          :ws -> [:ws]
          _ -> [:http, :ws]
        end
    end
  end
end
