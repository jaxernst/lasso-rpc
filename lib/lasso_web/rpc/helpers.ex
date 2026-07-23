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

  This reads from application configuration with a fallback to `:load_balanced`.

  ## Examples

      iex> LassoWeb.RPC.Helpers.default_provider_strategy()
      :load_balanced

  """
  @spec default_provider_strategy() :: atom()
  def default_provider_strategy do
    Application.get_env(:lasso, :provider_selection_strategy, :load_balanced)
  end

  @doc """
  Normalizes strategy tokens from params/routes into strategy atoms.
  """
  @spec normalize_strategy_token(String.t() | nil) ::
          :load_balanced | :latency_weighted | :fastest | :priority | nil
  def normalize_strategy_token("fastest"), do: :fastest
  def normalize_strategy_token("load-balanced"), do: :load_balanced
  def normalize_strategy_token("load_balanced"), do: :load_balanced
  def normalize_strategy_token("round-robin"), do: :load_balanced
  def normalize_strategy_token("round_robin"), do: :load_balanced
  def normalize_strategy_token("latency-weighted"), do: :latency_weighted
  def normalize_strategy_token("latency_weighted"), do: :latency_weighted
  def normalize_strategy_token("priority"), do: :priority
  def normalize_strategy_token(_), do: nil

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

      iex> LassoWeb.RPC.Helpers.get_chain_id("public", "ethereum")
      {:ok, "0x1"}

      iex> LassoWeb.RPC.Helpers.get_chain_id("public", "unknown")
      {:error, "Chain not configured: unknown"}

  """
  @spec get_chain_id(String.t(), pos_integer() | String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_chain_id(profile, chain_name) do
    case ConfigStore.get_chain(profile, chain_name) do
      {:ok, %{chain_id: chain_id}} when is_integer(chain_id) ->
        {:ok, "0x" <> Integer.to_string(chain_id, 16)}

      {:error, :not_found} ->
        {:error, "Chain not configured: #{chain_name}"}
    end
  end
end
