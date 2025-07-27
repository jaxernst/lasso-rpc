defmodule Livechain.RPC.Endpoint do
  @moduledoc """
  Defines the structure for blockchain RPC endpoint configurations.

  This module provides a struct that encapsulates all the necessary
  information for connecting to a blockchain RPC endpoint.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          url: String.t(),
          chain_id: non_neg_integer(),
          api_key: String.t() | nil,
          timeout: non_neg_integer(),
          max_retries: non_neg_integer(),
          enabled: boolean()
        }

  defstruct [
    :id,
    :name,
    :url,
    :chain_id,
    :api_key,
    timeout: 30_000,
    max_retries: 3,
    enabled: true
  ]

  @doc """
  Creates a new endpoint configuration.

  ## Examples

      iex> Livechain.RPC.Endpoint.new(
      ...>   id: "ethereum_mainnet",
      ...>   name: "Ethereum Mainnet",
      ...>   url: "https://mainnet.infura.io/v3/YOUR_KEY",
      ...>   chain_id: 1
      ...> )
      %Livechain.RPC.Endpoint{
        id: "ethereum_mainnet",
        name: "Ethereum Mainnet",
        url: "https://mainnet.infura.io/v3/YOUR_KEY",
        chain_id: 1,
        api_key: nil,
        timeout: 30000,
        max_retries: 3,
        enabled: true
      }
  """
  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Validates that an endpoint configuration is complete and valid.

  Returns `{:ok, endpoint}` if valid, `{:error, reason}` otherwise.
  """
  def validate(%__MODULE__{} = endpoint) do
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
end
