defmodule LassoWeb.RPC.Helpers do
  @moduledoc """
  Shared helper functions for RPC handling across HTTP and WebSocket transports.

  This module provides common utilities used by both `LassoWeb.RPCController`
  and `LassoWeb.RPCSocket` to eliminate duplication and ensure consistency
  across transport layers.
  """

  alias Lasso.Config.ConfigStore

  @doc """
  Returns the configured default provider selection strategy.

  This reads from application configuration with a fallback to `:round_robin`.

  ## Examples

      iex> LassoWeb.RPC.Helpers.default_provider_strategy()
      :round_robin

  """
  @spec default_provider_strategy() :: atom()
  def default_provider_strategy do
    Application.get_env(:lasso, :provider_selection_strategy, :round_robin)
  end

  @doc """
  Gets the hexadecimal chain ID for a given chain name.

  Looks up the chain configuration and formats the chain ID as a hex string
  with "0x" prefix, as required by the Ethereum JSON-RPC specification.

  ## Parameters

    - `chain_name` - The name of the chain (e.g., "ethereum", "polygon")

  ## Returns

    - `{:ok, chain_id}` - Success with hex-formatted chain ID (e.g., "0x1")
    - `{:error, reason}` - Error if chain is not configured

  ## Examples

      iex> LassoWeb.RPC.Helpers.get_chain_id("default", "ethereum")
      {:ok, "0x1"}

      iex> LassoWeb.RPC.Helpers.get_chain_id("default", "unknown")
      {:error, "Chain not configured: unknown"}

  """
  @spec get_chain_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def get_chain_id(profile, chain_name) do
    case ConfigStore.get_chain(profile, chain_name) do
      {:ok, %{chain_id: chain_id}} when is_integer(chain_id) ->
        {:ok, "0x" <> Integer.to_string(chain_id, 16)}

      {:error, :not_found} ->
        {:error, "Chain not configured: #{chain_name}"}
    end
  end
end
