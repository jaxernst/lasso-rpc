defmodule Lasso.RPC.Caching.BlockchainMetadataCache do
  @moduledoc """
  Centralized blockchain metadata caching system.

  Provides fast (<1ms) access to blockchain state information like block heights,
  chain IDs, and provider lag metrics. Backed by ETS for sub-millisecond lookups.

  ## Usage

      # Get current block height
      {:ok, height} = BlockchainMetadataCache.get_block_height("ethereum")

      # Get with fallback estimate (never errors)
      height = BlockchainMetadataCache.get_block_height_or_estimate("ethereum")

      # Check provider lag
      {:ok, lag} = BlockchainMetadataCache.get_provider_lag("ethereum", "alchemy")

  ## Architecture

  - ETS table `:blockchain_metadata` stores all cached values
  - `BlockchainMetadataMonitor` GenServers refresh data every 10s
  - Graceful degradation when cache unavailable
  """

  require Logger

  @table_name :blockchain_metadata
  @default_staleness_threshold_ms 30_000

  # ETS table keys
  @type cache_key ::
          {:chain, chain :: String.t(), key :: atom()}
          | {:provider, chain :: String.t(), provider_id :: String.t(), key :: atom()}

  ## Public API

  @doc """
  Returns the best known block height for a chain.

  ## Examples

      {:ok, 21_234_567} = get_block_height("ethereum")
      {:error, :not_found} = get_block_height("unknown_chain")
      {:error, :stale} = get_block_height("ethereum")  # If data too old
  """
  @spec get_block_height(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_block_height(chain) do
    case lookup({:chain, chain, :block_height}) do
      {:ok, height} ->
        if fresh?(chain) do
          telemetry_cache_hit(chain, :block_height)
          {:ok, height}
        else
          telemetry_cache_stale(chain, :block_height)
          {:error, :stale}
        end

      :error ->
        telemetry_cache_miss(chain, :block_height, :not_found)
        {:error, :not_found}
    end
  end

  @doc """
  Returns block height, raising on error.

  ## Examples

      21_234_567 = get_block_height!("ethereum")
  """
  @spec get_block_height!(String.t()) :: non_neg_integer()
  def get_block_height!(chain) do
    case get_block_height(chain) do
      {:ok, height} -> height
      {:error, reason} -> raise ArgumentError, "Block height unavailable for #{chain}: #{reason}"
    end
  end

  @doc """
  Returns cached block height or falls back to conservative estimate.

  This function never errors - it returns the cached value if available,
  or a configured fallback estimate if not. Use for parameter validation
  where graceful degradation is preferred.

  ## Examples

      21_234_567 = get_block_height_or_estimate("ethereum")  # Cache hit
      21_000_000 = get_block_height_or_estimate("ethereum")  # Cache miss, uses estimate
  """
  @spec get_block_height_or_estimate(String.t()) :: non_neg_integer()
  def get_block_height_or_estimate(chain) do
    case get_block_height(chain) do
      {:ok, height} -> height
      {:error, _} -> fallback_estimate(chain)
    end
  end

  @doc """
  Returns the last known block height for a specific provider.

  ## Examples

      {:ok, 21_234_567} = get_provider_block_height("ethereum", "alchemy")
      {:error, :not_found} = get_provider_block_height("ethereum", "unknown")
  """
  @spec get_provider_block_height(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def get_provider_block_height(chain, provider_id) do
    case lookup({:provider, chain, provider_id, :block_height}) do
      {:ok, height} ->
        telemetry_cache_hit(chain, :provider_block_height)
        {:ok, height}

      :error ->
        telemetry_cache_miss(chain, :provider_block_height, :not_found)
        {:error, :not_found}
    end
  end

  @doc """
  Returns how many blocks behind the best known height a provider is.

  Returns:
  - Positive lag: Provider ahead (unusual, possible clock skew or reorg)
  - Zero lag: Provider at best known height
  - Negative lag: Provider behind by N blocks

  ## Examples

      {:ok, 0} = get_provider_lag("ethereum", "alchemy")    # Up to date
      {:ok, -5} = get_provider_lag("ethereum", "infura")    # 5 blocks behind
  """
  @spec get_provider_lag(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def get_provider_lag(chain, provider_id) do
    with {:ok, provider_height} <- get_provider_block_height(chain, provider_id),
         {:ok, best_height} <- get_block_height(chain) do
      lag = provider_height - best_height
      {:ok, lag}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns the chain ID for a blockchain network.

  ## Examples

      {:ok, "0x1"} = get_chain_id("ethereum")
  """
  @spec get_chain_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_chain_id(chain) do
    case lookup({:chain, chain, :chain_id}) do
      {:ok, chain_id} ->
        telemetry_cache_hit(chain, :chain_id)
        {:ok, chain_id}

      :error ->
        telemetry_cache_miss(chain, :chain_id, :not_found)
        {:error, :not_found}
    end
  end

  @doc """
  Returns aggregate network health status for a chain.

  ## Examples

      {:ok, %{
        status: :healthy,
        best_known_height: 21_234_567,
        providers_tracked: 3,
        cache_age_ms: 5_234,
        updated_at: ~U[2025-01-10 12:00:00Z]
      }} = get_network_status("ethereum")
  """
  @spec get_network_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_network_status(chain) do
    with {:ok, height} <- lookup({:chain, chain, :block_height}),
         {:ok, updated_at} <- lookup({:chain, chain, :updated_at}) do
      age_ms = System.system_time(:millisecond) - updated_at
      status = if age_ms < staleness_threshold(), do: :healthy, else: :stale

      provider_heights = get_all_provider_heights(chain)

      {:ok,
       %{
         status: status,
         best_known_height: height,
         providers_tracked: length(provider_heights),
         cache_age_ms: age_ms,
         updated_at: DateTime.from_unix!(updated_at, :millisecond)
       }}
    else
      :error -> {:error, :not_found}
    end
  end

  ## Internal Cache Management (called by Monitor)

  @doc false
  def put_block_height(chain, height) when is_binary(chain) and is_integer(height) do
    timestamp = System.system_time(:millisecond)
    write({:chain, chain, :block_height}, height)
    write({:chain, chain, :updated_at}, timestamp)
    :ok
  end

  @doc false
  def put_chain_id(chain, chain_id) when is_binary(chain) and is_binary(chain_id) do
    write({:chain, chain, :chain_id}, chain_id)
    :ok
  end

  @doc false
  def put_provider_block_height(chain, provider_id, height, latency_ms)
      when is_binary(chain) and is_binary(provider_id) and is_integer(height) do
    timestamp = System.system_time(:millisecond)
    write({:provider, chain, provider_id, :block_height}, height)
    write({:provider, chain, provider_id, :updated_at}, timestamp)
    write({:provider, chain, provider_id, :latency_ms}, latency_ms)
    :ok
  end

  @doc false
  def put_provider_lag(chain, provider_id, lag_blocks)
      when is_binary(chain) and is_binary(provider_id) and is_integer(lag_blocks) do
    write({:provider, chain, provider_id, :lag_blocks}, lag_blocks)
    :ok
  end

  ## ETS Table Management

  @doc false
  def ensure_table do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        Logger.debug("Created ETS table :blockchain_metadata")
        :ok

      _tid ->
        :ok
    end
  end

  @doc false
  def clear_chain(chain) do
    # Remove all entries for a chain
    :ets.match_delete(@table_name, {{:chain, chain, :_}, :_})
    :ets.match_delete(@table_name, {{:provider, chain, :_, :_}, :_})
    :ok
  end

  ## Private Helpers

  defp lookup(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  defp write(key, value) do
    :ets.insert(@table_name, {key, value})
  end

  defp fresh?(chain) do
    case lookup({:chain, chain, :updated_at}) do
      {:ok, timestamp} ->
        age_ms = System.system_time(:millisecond) - timestamp
        age_ms < staleness_threshold()

      :error ->
        false
    end
  end

  defp get_all_provider_heights(chain) do
    :ets.match(@table_name, {{:provider, chain, :"$1", :block_height}, :"$2"})
  end

  defp fallback_estimate(chain) do
    config()
    |> get_in([:fallback_estimates, chain])
    |> case do
      nil -> default_estimate(chain)
      estimate -> estimate
    end
  end

  defp default_estimate("ethereum"), do: 21_000_000
  defp default_estimate("base"), do: 10_000_000
  defp default_estimate("polygon"), do: 52_000_000
  defp default_estimate("arbitrum"), do: 180_000_000
  defp default_estimate(_), do: 10_000_000

  defp staleness_threshold do
    get_in(config(), [:staleness_threshold_ms]) || @default_staleness_threshold_ms
  end

  defp config do
    Application.get_env(:lasso, :metadata_cache, [])
  end

  ## Telemetry

  defp telemetry_cache_hit(chain, key) do
    :telemetry.execute([:lasso, :metadata, :cache, :hit], %{count: 1}, %{
      chain: chain,
      key: key
    })
  end

  defp telemetry_cache_miss(chain, key, reason) do
    :telemetry.execute([:lasso, :metadata, :cache, :miss], %{count: 1}, %{
      chain: chain,
      key: key,
      reason: reason
    })
  end

  defp telemetry_cache_stale(chain, key) do
    :telemetry.execute([:lasso, :metadata, :cache, :stale], %{count: 1}, %{
      chain: chain,
      key: key
    })
  end
end
