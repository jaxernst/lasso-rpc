defmodule Lasso.RPC.Transport.WebSocket.Endpoint do
  @moduledoc """
  Defines the structure for blockchain WebSocket RPC endpoint configurations.

  WebSocket connections are stateful and require different management patterns
  than HTTP endpoints. This struct includes WebSocket-specific configuration.
  """

  @type t :: %__MODULE__{
          profile: String.t() | nil,
          id: String.t(),
          name: String.t(),
          chain_id: non_neg_integer(),
          chain_name: String.t() | nil,

          # WebSocket specific fields
          ws_url: String.t(),
          reconnect_interval: non_neg_integer(),
          heartbeat_interval: non_neg_integer(),
          max_reconnect_attempts: non_neg_integer() | :infinity
        }

  defstruct [
    :profile,
    :id,
    :name,
    :chain_id,
    :chain_name,
    :ws_url,

    # WebSocket specific fields
    reconnect_interval: 5_000,
    heartbeat_interval: 15_000,
    max_reconnect_attempts: :infinity
  ]

  @doc """
  Creates a new WebSocket endpoint configuration.

  ## Examples

      iex> Lasso.RPC.Transport.WebSocket.Endpoint.new(
      ...>   id: "ethereum_ws",
      ...>   name: "Ethereum WebSocket",
      ...>   url: "https://mainnet.infura.io/v3/YOUR_KEY",
      ...>   ws_url: "wss://mainnet.infura.io/ws/v3/YOUR_KEY",
      ...>   chain_id: 1
      ...> )
      %Lasso.RPC.Transport.WebSocket.Endpoint{
        id: "ethereum_ws",
        name: "Ethereum WebSocket",
        ws_url: "wss://mainnet.infura.io/ws/v3/YOUR_KEY",
        chain_id: 1,
        reconnect_interval: 5000,
        heartbeat_interval: 15_000,
        max_reconnect_attempts: :infinity
      }
  """
  @spec new(map()) :: t()
  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Validates that a WebSocket endpoint configuration is complete and valid.

  Returns `{:ok, endpoint}` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
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

      is_nil(endpoint.chain_id) ->
        {:error, "Chain ID is required"}

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

      true ->
        {:ok, endpoint}
    end
  end
end
