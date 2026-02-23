defmodule Lasso.Providers.LagCalculation do
  @moduledoc """
  Shared optimistic lag calculation used by both CandidateListing (selection) and
  StatusHelpers (dashboard display).
  """

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.ChainState

  @spec calculate_optimistic_lag(String.t(), String.t(), non_neg_integer()) ::
          {:ok, integer(), integer()} | {:error, term()}
  def calculate_optimistic_lag(chain, provider_or_instance_id, block_time_ms) do
    with {:ok, {height, timestamp, _source, _meta}} <-
           BlockSyncRegistry.get_height(chain, provider_or_instance_id),
         {:ok, consensus} <- ChainState.consensus_height(chain) do
      now = System.system_time(:millisecond)
      elapsed_ms = now - timestamp
      raw_lag = height - consensus

      staleness_credit =
        if block_time_ms > 0, do: div(elapsed_ms, block_time_ms), else: 0

      max_credit = div(30_000, max(block_time_ms, 1))
      capped_credit = min(staleness_credit, max_credit)
      optimistic_lag = height + capped_credit - consensus

      {:ok, optimistic_lag, raw_lag}
    else
      {:error, :not_found} -> {:error, :no_provider_data}
      {:error, :no_data} -> {:error, :no_consensus}
      error -> error
    end
  end

  @spec get_block_time_ms(String.t(), String.t() | nil) :: non_neg_integer()
  def get_block_time_ms(chain, profile \\ nil) do
    case BlockSyncRegistry.get_block_time_ms(chain) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      _ ->
        case resolve_chain_config(chain, profile) do
          {:ok, config} -> config.block_time_ms || 12_000
          _ -> 12_000
        end
    end
  end

  defp resolve_chain_config(chain, profile) when is_binary(profile) do
    ConfigStore.get_chain(profile, chain)
  end

  defp resolve_chain_config(chain, _) do
    case ConfigStore.list_profiles_for_chain(chain) do
      [profile | _] -> ConfigStore.get_chain(profile, chain)
      [] -> {:error, :not_found}
    end
  end
end
