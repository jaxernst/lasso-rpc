defmodule Lasso.Config.TransportPolicy do
  @moduledoc """
  Centralizes JSON-RPC method constraints and transport requirements.

  - Defines which methods are WS-only
  - Defines the hard product-policy boundary for methods Lasso never forwards
  - Provides helpers to compute allowed transports for a method
  """

  @type method :: String.t()
  @type transport :: :http | :ws

  alias Lasso.RPC.MethodRegistry

  @ws_only_methods [
    "eth_subscribe",
    "eth_unsubscribe"
  ]

  @stateful_filter_methods [
    "eth_newFilter",
    "eth_newBlockFilter",
    "eth_newPendingTransactionFilter",
    "eth_getFilterChanges",
    "eth_getFilterLogs",
    "eth_uninstallFilter"
  ]

  @signing_and_keystore_methods ["personal_sign"]

  @product_restricted_methods Enum.uniq(
                                MethodRegistry.category_methods(:local_only) ++
                                  @signing_and_keystore_methods ++ @stateful_filter_methods
                              )

  @doc """
  Returns true if the method requires WebSocket transport.
  """
  @spec ws_only?(method) :: boolean()
  def ws_only?(method) when is_binary(method), do: method in @ws_only_methods

  @doc """
  Returns true if the hard product policy forbids forwarding the method.

  This policy is independent of provider capabilities. Provider overrides and
  capability safety fallbacks cannot make a restricted method routable.
  """
  @spec disallowed?(method) :: boolean()
  def disallowed?(method) when is_binary(method), do: method in @product_restricted_methods

  @doc "Methods Lasso never forwards to an upstream provider."
  @spec disallowed_methods() :: [method]
  def disallowed_methods, do: @product_restricted_methods

  @doc "Stateful HTTP filter methods that require provider affinity Lasso does not provide."
  @spec stateful_filter_methods() :: [method]
  def stateful_filter_methods, do: @stateful_filter_methods

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
