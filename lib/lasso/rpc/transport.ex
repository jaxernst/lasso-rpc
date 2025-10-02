defmodule Lasso.RPC.Transport do
  @moduledoc """
  Transport abstraction behaviour for RPC requests and subscriptions.

  Provides a unified interface for different transport protocols (HTTP, WebSocket)
  to enable transport-agnostic request routing and capability-aware selection.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @type channel :: term()
  @type rpc_request :: map()
  @type rpc_response :: map()
  @type subscription_ref :: term()
  @type provider_config :: map()
  @type method :: String.t()
  @type params :: list()
  @type opts :: keyword()

  @doc """
  Opens a channel (connection/pool) for the given provider configuration.

  Options:
  - `:timeout` - Connection timeout in milliseconds
  - Any transport-specific options

  Returns {:ok, channel} or {:error, reason}
  """
  @callback open(provider_config, opts) :: {:ok, channel} | {:error, term()}

  @doc """
  Checks if a channel is healthy and ready to handle requests.
  """
  @callback healthy?(channel) :: boolean()

  @doc """
  Gets the capabilities of a channel.

  Returns capabilities map with:
  - unary?: boolean - supports single request/response
  - subscriptions?: boolean - supports streaming subscriptions
  - methods: :all | MapSet.t(String.t()) - supported method names
  """
  @callback capabilities(channel) :: %{
              unary?: boolean(),
              subscriptions?: boolean(),
              methods: :all | MapSet.t(String.t())
            }

  @doc """
  Performs a single JSON-RPC request over the channel.

  Returns {:ok, response} for successful requests,
  {:error, :unsupported_method} if the method isn't supported,
  {:error, reason} for other failures.
  """
  @callback request(channel, rpc_request, timeout()) ::
              {:ok, rpc_response} | {:error, :unsupported_method | :timeout | term()}

  @doc """
  Starts a streaming subscription (WebSocket only).

  The response handler process will receive subscription messages.
  Returns {:ok, subscription_ref} or {:error, reason}.
  """
  @callback subscribe(channel, rpc_request, pid()) ::
              {:ok, subscription_ref} | {:error, :unsupported_method | term()}

  @doc """
  Cancels a streaming subscription.
  """
  @callback unsubscribe(channel, subscription_ref) :: :ok | {:error, term()}

  @doc """
  Closes a channel and cleans up resources.
  """
  @callback close(channel) :: :ok

  # Legacy compatibility functions

  @doc """
  Forwards a request via the specified protocol.

  This is the primary, explicit API. The transport module mapping is direct:
  - :http → Lasso.RPC.Transports.HTTP
  - :ws   → Lasso.RPC.Transports.WebSocket

  URL presence and protocol support are validated inside each transport.
  """
  @spec forward_request(String.t(), provider_config, :http | :ws, method, params, opts) ::
          {:ok, any()} | {:error, JError.t()}
  def forward_request(provider_id, provider_config, protocol, method, params, opts) do
    opts_with_pid = Keyword.put(opts, :provider_id, provider_id)

    case protocol do
      :http ->
        Lasso.RPC.Transports.HTTP.forward_request(
          provider_config,
          method,
          params,
          opts_with_pid
        )

      :ws ->
        Lasso.RPC.Transports.WebSocket.forward_request(
          provider_config,
          method,
          params,
          opts_with_pid
        )

      other ->
        {:error,
         JError.new(-32000, "Invalid protocol: #{inspect(other)}", provider_id: provider_id)}
    end
  end

  @doc """
  Backward-compatible API that reads :protocol from opts.
  Defaults to :http if not provided.
  """
  @spec forward_request(String.t(), provider_config, method, params, opts) ::
          {:ok, any()} | {:error, JError.t()}
  def forward_request(provider_id, provider_config, method, params, opts) do
    protocol = Keyword.get(opts, :protocol, :http)
    forward_request(provider_id, provider_config, protocol, method, params, opts)
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

  # No resolver helpers needed; explicit protocol mapping above keeps this simple.

  # No subscription detection needed in explicit protocol mode

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
