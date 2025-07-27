defmodule Livechain.RPC.WSEndpoint do
  @moduledoc """
  Defines the structure for blockchain WebSocket RPC endpoint configurations.

  WebSocket connections are stateful and require different management patterns
  than HTTP endpoints. This struct includes WebSocket-specific configuration.
  """

  alias Livechain.RPC.Endpoint

  @type t :: %__MODULE__{
          # Inherit from base Endpoint
          id: String.t(),
          name: String.t(),
          url: String.t(),
          chain_id: non_neg_integer(),
          api_key: String.t() | nil,
          timeout: non_neg_integer(),
          max_retries: non_neg_integer(),
          enabled: boolean(),

          # WebSocket specific fields
          ws_url: String.t(),
          reconnect_interval: non_neg_integer(),
          heartbeat_interval: non_neg_integer(),
          max_reconnect_attempts: non_neg_integer() | :infinity,
          subscription_topics: [String.t()]
        }

  defstruct [
    # Base endpoint fields
    :id,
    :name,
    :url,
    :chain_id,
    :api_key,
    :ws_url,
    timeout: 30_000,
    max_retries: 3,
    enabled: true,

    # WebSocket specific fields
    reconnect_interval: 5_000,
    heartbeat_interval: 30_000,
    max_reconnect_attempts: :infinity,
    subscription_topics: []
  ]

  @doc """
  Creates a new WebSocket endpoint configuration.

  ## Examples

      iex> Livechain.RPC.WSEndpoint.new(
      ...>   id: "ethereum_ws",
      ...>   name: "Ethereum WebSocket",
      ...>   url: "https://mainnet.infura.io/v3/YOUR_KEY",
      ...>   ws_url: "wss://mainnet.infura.io/ws/v3/YOUR_KEY",
      ...>   chain_id: 1
      ...> )
      %Livechain.RPC.WSEndpoint{
        id: "ethereum_ws",
        name: "Ethereum WebSocket",
        url: "https://mainnet.infura.io/v3/YOUR_KEY",
        ws_url: "wss://mainnet.infura.io/ws/v3/YOUR_KEY",
        chain_id: 1,
        api_key: nil,
        timeout: 30000,
        max_retries: 3,
        enabled: true,
        reconnect_interval: 5000,
        heartbeat_interval: 30000,
        max_reconnect_attempts: :infinity,
        subscription_topics: []
      }
  """
  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Converts a base Endpoint to a WSEndpoint by adding WebSocket URL.
  """
  def from_endpoint(%Endpoint{} = endpoint, ws_url) do
    struct(__MODULE__, Map.from_struct(endpoint) |> Map.put(:ws_url, ws_url))
  end

  @doc """
  Validates that a WebSocket endpoint configuration is complete and valid.

  Returns `{:ok, endpoint}` if valid, `{:error, reason}` otherwise.
  """
  def validate(%__MODULE__{} = endpoint) do
    with {:ok, _} <- validate_base(endpoint),
         {:ok, _} <- validate_ws_specific(endpoint) do
      {:ok, endpoint}
    end
  end

  defp validate_base(endpoint) do
    cond do
      is_nil(endpoint.id) or endpoint.id == "" ->
        {:error, "Endpoint ID is required"}

      is_nil(endpoint.name) or endpoint.name == "" ->
        {:error, "Endpoint name is required"}

      is_nil(endpoint.url) or endpoint.url == "" ->
        {:error, "Endpoint URL is required"}

      is_nil(endpoint.chain_id) ->
        {:error, "Chain ID is required"}

      endpoint.timeout <= 0 ->
        {:error, "Timeout must be greater than 0"}

      endpoint.max_retries < 0 ->
        {:error, "Max retries must be non-negative"}

      true ->
        {:ok, endpoint}
    end
  end

  defp validate_ws_specific(endpoint) do
    cond do
      is_nil(endpoint.ws_url) or endpoint.ws_url == "" ->
        {:error, "WebSocket URL is required"}

      endpoint.reconnect_interval <= 0 ->
        {:error, "Reconnect interval must be greater than 0"}

      endpoint.heartbeat_interval <= 0 ->
        {:error, "Heartbeat interval must be greater than 0"}

      not is_list(endpoint.subscription_topics) ->
        {:error, "Subscription topics must be a list"}

      true ->
        {:ok, endpoint}
    end
  end
end
