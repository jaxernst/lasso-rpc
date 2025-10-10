defmodule Lasso.RPC.Caching.BlockchainMetadataCache do
  @moduledoc """
  Centralized blockchain metadata caching system.

  Provides fast (<1ms) access to blockchain state information like block heights,
  chain IDs, and provider lag metrics. Backed by ETS for sub-millisecond lookups.

  ## Usage

      # Get current block height (explicit error handling)
      case BlockchainMetadataCache.get_block_height("ethereum") do
        {:ok, height} -> use_height(height)
        {:error, :not_found} -> handle_missing_cache()
        {:error, :stale} -> handle_stale_cache()
      end

      # Or raise on error
      height = BlockchainMetadataCache.get_block_height!("ethereum")

      # Check provider lag
      {:ok, lag} = BlockchainMetadataCache.get_provider_lag("ethereum", "alchemy")

  ## Design Philosophy

  This module follows explicit error handling patterns. There are no silent
  fallbacks to hardcoded estimates. Callers must handle cache unavailability
  explicitly, which makes the failure modes visible and testable.

  For adapters that need block height validation, they should:
  1. Try to get cached height with `get_block_height/1`
  2. If unavailable, decide whether to skip validation or reject the request
  3. Make the decision explicit in their code

  ## Architecture

  - ETS table `:blockchain_metadata` owned by dedicated MetadataTableOwner process
  - `BlockchainMetadataMonitor` GenServers refresh data every 10s
  - Table survives individual monitor crashes
  - Explicit error propagation for observable failures
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
    # Table is now created by MetadataTableOwner during application startup
    # This function just verifies it exists (useful for tests)
    case :ets.whereis(@table_name) do
      :undefined ->
        # Try to create it (race-safe with try/rescue)
        # This only happens in test scenarios where MetadataTableOwner might not be running
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
          Logger.debug("Created ETS table :blockchain_metadata (fallback mode)")
          :ok
        rescue
          ArgumentError ->
            # Another process created it between whereis and new
            :ok
        end

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
    try do
      :ets.insert(@table_name, {key, value})
    rescue
      e in ArgumentError ->
        Logger.error("ETS write failed",
          key: inspect(key),
          error: Exception.message(e)
        )

        telemetry_write_error(key, e)
        false
    end
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
    # Calculate age for staleness events
    age_ms =
      case lookup({:chain, chain, :updated_at}) do
        {:ok, timestamp} -> System.system_time(:millisecond) - timestamp
        :error -> 0
      end

    :telemetry.execute([:lasso, :metadata, :cache, :stale], %{count: 1, age_ms: age_ms}, %{
      chain: chain,
      key: key
    })
  end

  defp telemetry_write_error(key, error) do
    :telemetry.execute([:lasso, :metadata, :cache, :write_error], %{count: 1}, %{
      key: inspect(key),
      error: Exception.message(error)
    })
  end
end
