defmodule Lasso.RPC.Channel do
  @moduledoc """
  Channel abstraction that wraps transport-specific channels.

  A Channel represents a runtime connection or pool (HTTP pool or WS connection/pool)
  with a consistent interface regardless of the underlying transport. This allows
  the RequestPipeline and selection logic to work with channels in a transport-agnostic way.

  Each channel has:
  - A transport type (:http or :ws)
  - A provider ID
  - The underlying transport-specific channel
  - Cached capabilities
  - Health status
  """

  @type t :: %__MODULE__{
          provider_id: String.t(),
          transport: :http | :ws,
          raw_channel: term(),
          transport_module: module(),
          capabilities: map() | nil,
          created_at: integer()
        }

  defstruct [
    :provider_id,
    :transport,
    :raw_channel,
    :transport_module,
    :capabilities,
    :created_at
  ]

  @doc """
  Creates a new Channel wrapper.
  """
  @spec new(String.t(), :http | :ws, term(), module()) :: t()
  def new(provider_id, transport, raw_channel, transport_module) do
    %__MODULE__{
      provider_id: provider_id,
      transport: transport,
      raw_channel: raw_channel,
      transport_module: transport_module,
      # Lazily loaded
      capabilities: nil,
      created_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Checks if a channel is healthy and ready to handle requests.
  """
  @spec healthy?(t()) :: boolean()
  def healthy?(%__MODULE__{} = channel) do
    channel.transport_module.healthy?(channel.raw_channel)
  end

  @doc """
  Gets the capabilities of a channel, caching the result.
  """
  @spec get_capabilities(t()) :: map()
  def get_capabilities(%__MODULE__{capabilities: nil} = channel) do
    capabilities = channel.transport_module.capabilities(channel.raw_channel)
    %{channel | capabilities: capabilities}
    capabilities
  end

  def get_capabilities(%__MODULE__{capabilities: capabilities}), do: capabilities

  @doc """
  Performs a single JSON-RPC request over the channel.
  """
  @spec request(t(), map(), timeout()) ::
          {:ok, term()} | {:error, :unsupported_method | :timeout | term()}
  def request(%__MODULE__{} = channel, rpc_request, timeout \\ 30_000) do
    channel.transport_module.request(channel.raw_channel, rpc_request, timeout)
  end

  @doc """
  Starts a streaming subscription (WebSocket only).
  """
  @spec subscribe(t(), map(), pid()) ::
          {:ok, term()} | {:error, :unsupported_method | term()}
  def subscribe(%__MODULE__{} = channel, rpc_request, handler_pid) do
    channel.transport_module.subscribe(channel.raw_channel, rpc_request, handler_pid)
  end

  @doc """
  Cancels a streaming subscription.
  """
  @spec unsubscribe(t(), term()) :: :ok | {:error, term()}
  def unsubscribe(%__MODULE__{} = channel, subscription_ref) do
    channel.transport_module.unsubscribe(channel.raw_channel, subscription_ref)
  end

  @doc """
  Closes a channel and cleans up resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = channel) do
    channel.transport_module.close(channel.raw_channel)
  end

  @doc """
  Checks if a channel supports a specific method.
  """
  @spec supports_method?(t(), String.t()) :: boolean()
  def supports_method?(%__MODULE__{} = channel, method) do
    capabilities = get_capabilities(channel)

    case Map.get(capabilities, :methods) do
      :all -> true
      method_set when is_struct(method_set, MapSet) -> MapSet.member?(method_set, method)
      # Default to true if capabilities are unclear
      _ -> true
    end
  end

  @doc """
  Checks if a channel supports unary requests.
  """
  @spec supports_unary?(t()) :: boolean()
  def supports_unary?(%__MODULE__{} = channel) do
    capabilities = get_capabilities(channel)
    Map.get(capabilities, :unary?, false)
  end

  @doc """
  Checks if a channel supports streaming subscriptions.
  """
  @spec supports_subscriptions?(t()) :: boolean()
  def supports_subscriptions?(%__MODULE__{} = channel) do
    capabilities = get_capabilities(channel)
    Map.get(capabilities, :subscriptions?, false)
  end

  @doc """
  Returns a string representation of the channel for logging.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = channel) do
    "#{channel.provider_id}:#{channel.transport}"
  end

  @doc """
  Returns debug information about the channel.
  """
  @spec debug_info(t()) :: map()
  def debug_info(%__MODULE__{} = channel) do
    %{
      provider_id: channel.provider_id,
      transport: channel.transport,
      capabilities: get_capabilities(channel),
      healthy: healthy?(channel),
      created_at: channel.created_at,
      age_ms: System.monotonic_time(:millisecond) - channel.created_at
    }
  end
end
