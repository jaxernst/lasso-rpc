defmodule Lasso.Providers.LagCalculation do
  @moduledoc """
  Shared time-aligned lag calculation used by provider selection and dashboards.

  HTTP height samples receive bounded advancement credit based on their age and
  effective poll cadence. WebSocket observations are compared directly, stale
  evidence is rejected, and no projection can advance a provider past the
  captured consensus height.
  """

  alias Lasso.BlockSync.{Observation, ObservationProjection, Registry}
  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.ChainState

  @spec calculate_optimistic_lag(pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, integer(), integer()} | {:error, term()}
  def calculate_optimistic_lag(chain_id, provider_or_instance_id, block_time_ms)
      when is_integer(chain_id) and chain_id > 0 do
    with {:ok, observation} <- Observation.read(chain_id, provider_or_instance_id),
         {:ok, consensus} <- ChainState.consensus_height(chain_id) do
      calculate_from_observation(observation, block_time_ms, consensus)
    else
      {:error, :not_found} -> {:error, :no_provider_data}
      {:error, {:stale, _observation}} -> {:error, :stale_provider_data}
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
    case Observation.read(chain_id, provider_or_instance_id) do
      {:ok, observation} ->
        calculate_from_observation(observation, block_time_ms, consensus)

      {:error, :not_found} ->
        {:error, :no_provider_data}

      {:error, {:stale, _observation}} ->
        {:error, :stale_provider_data}
    end
  end

  defp calculate_from_observation(observation, block_time_ms, consensus) do
    raw_lag = observation.height - consensus

    projected =
      observation
      |> Map.put(:lag, raw_lag)
      |> Map.put(:credit_window_ms, credit_window_ms(observation.metadata))
      |> ObservationProjection.project(block_time_ms)

    {:ok, projected.lag, raw_lag}
  end

  defp credit_window_ms(%{optimistic_credit_ms: credit_ms})
       when is_integer(credit_ms) and credit_ms > 0,
       do: credit_ms

  defp credit_window_ms(_metadata), do: nil

  @spec get_block_time_ms(pos_integer(), String.t() | nil) :: non_neg_integer()
  def get_block_time_ms(chain_id, profile \\ nil) when is_integer(chain_id) and chain_id > 0 do
    case Registry.get_block_time_ms(chain_id) do
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
