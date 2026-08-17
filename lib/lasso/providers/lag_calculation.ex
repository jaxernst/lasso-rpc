defmodule Lasso.Providers.LagCalculation do
  @moduledoc """
  Shared optimistic lag calculation used by both CandidateListing (selection) and
  StatusHelpers (dashboard display).
  """

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.ChainState

  @spec calculate_optimistic_lag(pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, integer(), integer()} | {:error, term()}
  def calculate_optimistic_lag(chain_id, provider_or_instance_id, block_time_ms)
      when is_integer(chain_id) and chain_id > 0 do
    with {:ok, {height, timestamp, _source, _meta}} <-
           BlockSyncRegistry.get_height(chain_id, provider_or_instance_id),
         {:ok, consensus} <- ChainState.consensus_height(chain_id) do
      calculate_from_height(height, timestamp, block_time_ms, consensus)
    else
      {:error, :not_found} -> {:error, :no_provider_data}
      {:error, :no_data} -> {:error, :no_consensus}
      error -> error
    end
  end

  @doc false
  @spec calculate_optimistic_lag(
          pos_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, integer(), integer()} | {:error, term()}
  def calculate_optimistic_lag(
        chain_id,
        provider_or_instance_id,
        block_time_ms,
        consensus
      )
      when is_integer(chain_id) and chain_id > 0 and is_integer(consensus) and consensus >= 0 do
    case BlockSyncRegistry.get_height(chain_id, provider_or_instance_id) do
      {:ok, {height, timestamp, _source, _meta}} ->
        calculate_from_height(height, timestamp, block_time_ms, consensus)

      {:error, :not_found} ->
        {:error, :no_provider_data}
    end
  end

  defp calculate_from_height(height, timestamp, block_time_ms, consensus) do
    now = System.system_time(:millisecond)
    elapsed_ms = now - timestamp
    raw_lag = height - consensus

    staleness_credit =
      if block_time_ms > 0, do: div(elapsed_ms, block_time_ms), else: 0

    max_credit = div(30_000, max(block_time_ms, 1))
    capped_credit = min(staleness_credit, max_credit)
    optimistic_lag = height + capped_credit - consensus

    {:ok, optimistic_lag, raw_lag}
  end

  @spec get_block_time_ms(pos_integer(), String.t() | nil) :: non_neg_integer()
  def get_block_time_ms(chain_id, profile \\ nil) when is_integer(chain_id) and chain_id > 0 do
    case BlockSyncRegistry.get_block_time_ms(chain_id) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      _ ->
        case resolve_chain_config(chain_id, profile) do
          {:ok, config} -> config.block_time_ms || 12_000
          _ -> 12_000
        end
    end
  end

  defp resolve_chain_config(chain_id, profile) when is_binary(profile) do
    ConfigStore.get_chain(profile, chain_id)
  end

  defp resolve_chain_config(chain_id, _) do
    case ConfigStore.list_profiles_for_chain(chain_id) do
      [profile | _] -> ConfigStore.get_chain(profile, chain_id)
      [] -> {:error, :not_found}
    end
  end
end
