defmodule Lasso.RPC.Transport do
  @moduledoc """
  Transport abstraction behaviour for RPC requests and subscriptions.

  Provides a unified interface for different transport protocols (HTTP, WebSocket)
  to enable transport-agnostic request routing and capability-aware selection.
  """

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

  Always returns a 3-tuple with io_latency_ms as the third element:
  - {:ok, response, io_latency_ms} for successful requests
  - {:error, reason, io_latency_ms} for failures

  The io_latency_ms is the actual I/O time spent communicating with the upstream provider,
  or 0 for pre-flight failures that never reached the provider (like :unsupported_method).
  """
  @callback request(channel, rpc_request, timeout()) ::
              {:ok, rpc_response, non_neg_integer()}
              | {:error, term(), non_neg_integer()}

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
