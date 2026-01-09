defmodule Lasso.BlockSync.Registry do
  @moduledoc """
  Single source of truth for block height data.

  This GenServer owns an ETS table that stores block heights from all
  providers (WS or HTTP).

  ## ETS Schema

  Keys are tuples for efficient lookups:
  - `{:height, chain, provider_id}` => `{height, timestamp_ms, source, metadata}`

  ## Freshness

  Heights older than `freshness_threshold_ms` are ignored when calculating
  consensus. This ensures stale data doesn't pollute routing decisions.

  Note: Health metrics (latency, success/failure) are tracked by ProviderPool,
  not here. This module focuses solely on block height tracking.
  """

  use GenServer
  require Logger

  @table :block_sync_registry
  @default_freshness_ms 30_000

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a block height from a provider.

  ## Parameters
  - `chain` - Chain identifier (e.g., "ethereum")
  - `provider_id` - Provider identifier
  - `height` - Block height (integer)
  - `source` - `:ws` or `:http`
  - `metadata` - Optional map with additional data (hash, timestamp, latency_ms)
  """
  @spec put_height(String.t(), String.t(), integer(), :ws | :http, map()) :: :ok
  def put_height(chain, provider_id, height, source, metadata \\ %{})
      when is_binary(chain) and is_binary(provider_id) and is_integer(height) do
    timestamp = System.system_time(:millisecond)
    :ets.insert(@table, {{:height, chain, provider_id}, {height, timestamp, source, metadata}})
    :ok
  end

  @doc """
  Get the stored height for a specific provider.

  Returns `{:ok, {height, timestamp, source, metadata}}` or `{:error, :not_found}`.
  """
  @spec get_height(String.t(), String.t()) ::
          {:ok, {integer(), integer(), :ws | :http, map()}} | {:error, :not_found}
  def get_height(chain, provider_id) when is_binary(chain) and is_binary(provider_id) do
    case :ets.lookup(@table, {:height, chain, provider_id}) do
      [{_key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get the consensus (max) block height for a chain.

  Only considers heights from the last `freshness_ms` milliseconds.

  ## Parameters
  - `chain` - Chain identifier
  - `freshness_ms` - Maximum age of data to consider (default: 30 seconds)

  Returns `{:ok, height}` or `{:error, :no_data}`.
  """
  @spec get_consensus_height(String.t(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :no_data}
  def get_consensus_height(chain, freshness_ms \\ @default_freshness_ms)
      when is_binary(chain) do
    calculate_consensus(chain, nil, freshness_ms)
  end

  @doc """
  Get consensus height filtered by specific providers.

  ## Parameters
  - `chain` - Chain identifier
  - `provider_ids` - List of provider IDs to consider. If nil or empty, uses all providers.
  - `freshness_ms` - Maximum age of data to consider (default: 30 seconds)

  Returns `{:ok, height}` or `{:error, :no_data}`.
  """
  @spec get_consensus_height_filtered(String.t(), [String.t()] | nil, non_neg_integer()) ::
          {:ok, integer()} | {:error, :no_data}
  def get_consensus_height_filtered(chain, provider_ids, freshness_ms \\ @default_freshness_ms)
      when is_binary(chain) do
    calculate_consensus(chain, provider_ids, freshness_ms)
  end

  @doc """
  Calculate provider's lag compared to consensus height.

  ## Parameters
  - `chain` - Chain identifier
  - `provider_id` - Provider to check lag for
  - `freshness_ms` - Maximum age of data to consider (default: 30 seconds)

  Returns:
  - `{:ok, lag}` where lag is `provider_height - consensus_height`
    (negative means behind, positive means ahead)
  - `{:error, :no_provider_data}` if provider has no height data
  - `{:error, :no_consensus}` if no consensus can be calculated
  """
  @spec get_provider_lag(String.t(), String.t(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :no_provider_data | :no_consensus | :stale_data}
  def get_provider_lag(chain, provider_id, freshness_ms \\ @default_freshness_ms)
      when is_binary(chain) and is_binary(provider_id) do
    with {:ok, {height, timestamp, _source, _meta}} <- get_height(chain, provider_id),
         age = System.system_time(:millisecond) - timestamp,
         true <- age <= freshness_ms,
         {:ok, consensus} <- get_consensus_height(chain, freshness_ms) do
      {:ok, height - consensus}
    else
      {:ok, _stale} -> {:error, :stale_data}
      false -> {:error, :stale_data}
      {:error, :not_found} -> {:error, :no_provider_data}
      {:error, :no_data} -> {:error, :no_consensus}
    end
  end

  @doc """
  Get all heights for a chain (for dashboard/debugging).

  Returns a map of `provider_id => {height, timestamp, source, metadata}`.
  """
  @spec get_all_heights(String.t()) :: %{String.t() => {integer(), integer(), :ws | :http, map()}}
  def get_all_heights(chain) when is_binary(chain) do
    match_spec = [
      {{{:height, chain, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    :ets.select(@table, match_spec)
    |> Map.new()
  end

  @doc """
  Get a comprehensive status for all providers on a chain.

  Returns a map of provider_id => %{height: ..., source: ..., lag: ..., ...}
  """
  @spec get_chain_status(String.t()) :: %{String.t() => map()}
  def get_chain_status(chain) when is_binary(chain) do
    heights = get_all_heights(chain)
    now = System.system_time(:millisecond)

    # Get consensus for lag calculation
    consensus =
      case get_consensus_height(chain) do
        {:ok, h} -> h
        _ -> nil
      end

    heights
    |> Map.new(fn {provider_id, {height, ts, source, meta}} ->
      age_ms = now - ts
      lag = if consensus, do: height - consensus, else: nil

      status = %{
        height: height,
        height_age_ms: age_ms,
        source: source,
        lag: lag,
        metadata: meta
      }

      {provider_id, status}
    end)
  end

  @doc """
  Clear all data for a chain. Useful for testing.
  """
  @spec clear_chain(String.t()) :: :ok
  def clear_chain(chain) when is_binary(chain) do
    :ets.match_delete(@table, {{:height, chain, :_}, :_})
    :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    Logger.info("BlockSync.Registry started", table: table)
    {:ok, %{table: table}}
  end

  ## Private Functions

  defp calculate_consensus(chain, provider_ids, freshness_ms) do
    now = System.system_time(:millisecond)
    cutoff = now - freshness_ms

    # Find all fresh heights for this chain
    heights = get_all_heights(chain)

    # Filter by provider_ids if specified
    heights_filtered =
      case provider_ids do
        nil ->
          heights

        [] ->
          heights

        ids when is_list(ids) ->
          provider_set = MapSet.new(ids)

          Enum.filter(heights, fn {provider_id, _data} ->
            MapSet.member?(provider_set, provider_id)
          end)
      end

    fresh_heights =
      heights_filtered
      |> Enum.filter(fn {_provider_id, {_height, timestamp, _source, _meta}} ->
        timestamp >= cutoff
      end)
      |> Enum.map(fn {_provider_id, {height, _ts, _source, _meta}} -> height end)

    case fresh_heights do
      [] -> {:error, :no_data}
      list -> {:ok, Enum.max(list)}
    end
  end
end
