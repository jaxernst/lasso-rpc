defmodule Lasso.RPC.ChainState do
  @moduledoc """
  Fast read access to chain consensus state via lazy evaluation.

  CRITICAL: This module DOES NOT cache consensus. It calculates
  consensus on every call from fresh provider data. This guarantees
  correctness and eliminates stale data issues.

  Performance: ETS scan of 3-10 providers is <1ms.

  ## Usage

      # Get consensus height (calculated on-demand)
      {:ok, height} = ChainState.consensus_height("ethereum")

      # Get provider lag
      {:ok, -5} = ChainState.provider_lag("ethereum", "alchemy")

      # Graceful degradation (accepts stale data)
      {:ok, height, :stale} = ChainState.consensus_height("ethereum", allow_stale: true)
  """

  require Logger

  alias Lasso.RPC.ProviderPool
  alias Lasso.Core.BlockCache

  # 1.5x probe interval
  @consensus_window_multiplier 1.5
  # 60 seconds for stale fallback
  @max_stale_age_ms 60_000

  @spec consensus_height(String.t(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:ok, non_neg_integer(), :stale}
          | {:error, term()}
  def consensus_height(chain, opts \\ []) do
    allow_stale = Keyword.get(opts, :allow_stale, false)

    with {:ok, table} <- get_table(chain),
         {:ok, consensus} <- calculate_consensus(table, chain) do
      {:ok, consensus}
    else
      {:error, :no_fresh_data} when allow_stale ->
        # Fallback: Try stale consensus
        case get_table(chain) do
          {:ok, table} ->
            case calculate_consensus_stale(table, chain) do
              {:ok, height} -> {:ok, height, :stale}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("ChainState consensus_height crashed",
        chain: chain,
        error: Exception.message(e)
      )

      {:error, :calculation_failed}
  end

  @spec consensus_height!(String.t()) :: non_neg_integer()
  def consensus_height!(chain) do
    case consensus_height(chain) do
      {:ok, height} ->
        height

      {:ok, height, :stale} ->
        height

      {:error, reason} ->
        raise ArgumentError, "Consensus height unavailable for #{chain}: #{reason}"
    end
  end

  @spec provider_lag(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def provider_lag(chain, provider_id) do
    # Try real-time BlockCache data first (from WebSocket newHeads)
    case BlockCache.get_provider_lag(chain, provider_id) do
      {:ok, lag} ->
        {:ok, lag}

      {:error, _} ->
        # Fall back to probe-based lag data
        with {:ok, table} <- get_table(chain) do
          case :ets.lookup(table, {:provider_lag, chain, provider_id}) do
            [{{:provider_lag, ^chain, ^provider_id}, lag}] -> {:ok, lag}
            [] -> {:error, :not_found}
          end
        end
    end
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @spec consensus_fresh?(String.t()) :: boolean()
  def consensus_fresh?(chain) do
    case consensus_height(chain) do
      {:ok, _height} -> true
      {:ok, _height, :stale} -> false
      {:error, _} -> false
    end
  end

  @doc """
  Gets the current probe sequence number for a chain.
  Useful for debugging and testing probe cycles.
  """
  @spec current_sequence(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def current_sequence(chain) do
    with {:ok, table} <- get_table(chain) do
      # Find the maximum sequence number from all provider sync states
      case :ets.match(table, {{:provider_sync, chain, :_}, {:_, :_, :"$1"}}) do
        [] ->
          {:error, :no_data}

        sequences ->
          max_seq = sequences |> List.flatten() |> Enum.max()
          {:ok, max_seq}
      end
    end
  end

  ## Rich Block Data (via BlockCache)

  @doc """
  Get the latest block for a chain with full block data.

  Returns rich block data including hash, timestamp, gas, parent_hash, etc.
  Data comes from WebSocket newHeads subscriptions for real-time updates.

  ## Example

      {:ok, block} = ChainState.get_latest_block("ethereum")
      block.number  # 18500000
      block.hash    # "0xabc..."
      block.timestamp # 1699876543
  """
  @spec get_latest_block(String.t()) :: {:ok, map()} | {:error, term()}
  def get_latest_block(chain) do
    BlockCache.get_latest_block(chain)
  end

  @doc """
  Get a provider's current block height with timestamp.

  Tries real-time WebSocket data first, falls back to probe data.
  Returns {height, received_at_ms}.

  ## Example

      {:ok, height, received_at} = ChainState.provider_height("ethereum", "alchemy")
  """
  @spec provider_height(String.t(), String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def provider_height(chain, provider_id) do
    # Try real-time data first
    case BlockCache.get_provider_height(chain, provider_id) do
      {:ok, height, received_at} -> {:ok, height, received_at}
      {:error, _} -> get_probe_height(chain, provider_id)
    end
  end

  @doc """
  Get all provider heights for a chain.

  Returns list of {provider_id, height, received_at_ms} tuples.
  Uses real-time WebSocket data when available.

  ## Options

    * `:only_fresh` - Only return providers with data within freshness window (default: false)
  """
  @spec all_provider_heights(String.t(), keyword()) :: [
          {String.t(), non_neg_integer(), non_neg_integer()}
        ]
  def all_provider_heights(chain, opts \\ []) do
    BlockCache.get_all_provider_heights(chain, opts)
  end

  defp get_probe_height(chain, provider_id) do
    with {:ok, table} <- get_table(chain) do
      case :ets.lookup(table, {:provider_sync, chain, provider_id}) do
        [{{:provider_sync, ^chain, ^provider_id}, {height, timestamp, _seq}}] ->
          {:ok, height, timestamp}

        [] ->
          {:error, :not_found}
      end
    end
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  ## Private: Lazy Consensus Calculation

  defp calculate_consensus(table, chain) do
    now = System.system_time(:millisecond)
    probe_interval = get_probe_interval(chain)
    consensus_window_ms = trunc(probe_interval * @consensus_window_multiplier)

    # Get all provider sync states
    provider_heights =
      :ets.match(table, {{:provider_sync, chain, :"$1"}, {:"$2", :"$3", :"$4"}})
      |> Enum.filter(fn [_id, _height, timestamp, _seq] ->
        # Only use data from last consensus window
        now - timestamp < consensus_window_ms
      end)
      |> Enum.map(fn [_id, height, _ts, _seq] -> height end)

    if provider_heights != [] do
      {:ok, Enum.max(provider_heights)}
    else
      {:error, :no_fresh_data}
    end
  end

  defp calculate_consensus_stale(table, chain) do
    now = System.system_time(:millisecond)

    # Allow data up to 60 seconds old for stale fallback
    provider_heights =
      :ets.match(table, {{:provider_sync, chain, :"$1"}, {:"$2", :"$3", :"$4"}})
      |> Enum.filter(fn [_id, _height, timestamp, _seq] ->
        now - timestamp < @max_stale_age_ms
      end)
      |> Enum.map(fn [_id, height, _ts, _seq] -> height end)

    if provider_heights != [] do
      Logger.warning("Using stale consensus height",
        chain: chain,
        age_threshold_ms: @max_stale_age_ms
      )

      {:ok, Enum.max(provider_heights)}
    else
      {:error, :no_data_available}
    end
  end

  defp get_table(chain) do
    table = ProviderPool.table_name(chain)

    if :ets.info(table) != :undefined do
      {:ok, table}
    else
      {:error, :table_not_found}
    end
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  defp get_probe_interval(chain) do
    case Lasso.Config.ConfigStore.get_chain(chain) do
      {:ok, chain_config} ->
        chain_config.monitoring.probe_interval_ms

      {:error, _} ->
        # Fallback to application config for backwards compatibility
        intervals =
          Application.get_env(:lasso, :provider_probe, [])
          |> Keyword.get(:probe_interval_by_chain, %{})

        Map.get(intervals, chain) ||
          Application.get_env(:lasso, :provider_probe, [])
          |> Keyword.get(:default_probe_interval_ms, 12_000)
    end
  end
end
