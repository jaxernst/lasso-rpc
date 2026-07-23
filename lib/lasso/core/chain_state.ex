defmodule Lasso.RPC.ChainState do
  @moduledoc """
  Fast read access to chain consensus state.

  This module provides a thin wrapper over BlockSync.Registry for
  consensus height and provider lag calculations.

  ## Usage

      # Get consensus height (uses default 30s freshness)
      {:ok, height} = ChainState.consensus_height("ethereum")

      # Get provider lag
      {:ok, -5} = ChainState.provider_lag("ethereum", "alchemy")
  """

  require Logger

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Core.BlockCache

  # Default freshness window for consensus calculation (30 seconds)
  @default_freshness_ms 30_000

  @spec consensus_height(pos_integer(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, term()}
  def consensus_height(chain_id, opts \\ []) when is_integer(chain_id) and chain_id > 0 do
    provider_ids = Keyword.get(opts, :provider_ids, nil)
    freshness_ms = Keyword.get(opts, :freshness_ms, @default_freshness_ms)

    if provider_ids do
      BlockSyncRegistry.get_consensus_height_filtered(chain_id, provider_ids, freshness_ms)
    else
      BlockSyncRegistry.get_consensus_height(chain_id, freshness_ms)
    end
  rescue
    e ->
      Logger.error("ChainState consensus_height crashed",
        chain_id: chain_id,
        error: Exception.message(e)
      )

      {:error, :calculation_failed}
  end

  @spec consensus_height!(pos_integer()) :: non_neg_integer()
  def consensus_height!(chain_id) when is_integer(chain_id) and chain_id > 0 do
    case consensus_height(chain_id) do
      {:ok, height} ->
        height

      {:error, reason} ->
        raise ArgumentError, "Consensus height unavailable for chain_id #{chain_id}: #{reason}"
    end
  end

  @spec provider_lag(pos_integer(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def provider_lag(chain_id, provider_id, opts \\ [])
      when is_integer(chain_id) and chain_id > 0 do
    freshness_ms = Keyword.get(opts, :freshness_ms, @default_freshness_ms)
    BlockSyncRegistry.get_provider_lag(chain_id, provider_id, freshness_ms)
  rescue
    e ->
      Logger.error("ChainState provider_lag crashed",
        chain_id: chain_id,
        provider_id: provider_id,
        error: Exception.message(e)
      )

      {:error, :calculation_failed}
  end

  @spec consensus_fresh?(pos_integer()) :: boolean()
  def consensus_fresh?(chain_id) when is_integer(chain_id) and chain_id > 0 do
    case consensus_height(chain_id) do
      {:ok, _height} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Check if the BlockSync system has data for a chain.
  Returns the count of providers with height data.
  """
  @spec data_available?(pos_integer()) :: boolean()
  def data_available?(chain_id) when is_integer(chain_id) and chain_id > 0 do
    case BlockSyncRegistry.get_all_heights(chain_id) do
      heights when map_size(heights) > 0 -> true
      _ -> false
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
  @spec get_latest_block(pos_integer()) :: {:ok, map()} | {:error, term()}
  def get_latest_block(chain_id) when is_integer(chain_id) and chain_id > 0 do
    BlockCache.get_latest_block(chain_id)
  end

  @doc """
  Get a provider's current block height with timestamp.

  Returns {height, received_at_ms}.

  ## Example

      {:ok, height, received_at} = ChainState.provider_height("ethereum", "alchemy")
  """
  @spec provider_height(pos_integer(), String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def provider_height(chain_id, provider_id) when is_integer(chain_id) and chain_id > 0 do
    case BlockSyncRegistry.get_height(chain_id, provider_id) do
      {:ok, {height, timestamp, _source, _metadata}} ->
        {:ok, height, timestamp}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Get all provider heights for a chain.

  Returns list of {provider_id, height, received_at_ms} tuples.

  ## Options

    * `:only_fresh` - Only return providers with data within freshness window (default: false)
  """
  @spec all_provider_heights(pos_integer(), keyword()) :: [
          {String.t(), non_neg_integer(), non_neg_integer()}
        ]
  def all_provider_heights(chain_id, opts \\ []) when is_integer(chain_id) and chain_id > 0 do
    only_fresh = Keyword.get(opts, :only_fresh, false)
    heights = BlockSyncRegistry.get_all_heights(chain_id)

    now = System.system_time(:millisecond)
    freshness_window = @default_freshness_ms

    heights
    |> Enum.map(fn {provider_id, {height, timestamp, _source, _meta}} ->
      {provider_id, height, timestamp}
    end)
    |> then(fn list ->
      if only_fresh do
        Enum.filter(list, fn {_id, _height, timestamp} ->
          now - timestamp < freshness_window
        end)
      else
        list
      end
    end)
  end

  @doc """
  Get comprehensive status for all providers on a chain.

  Returns a map of provider_id => status_map with height, lag, source, etc.
  """
  @spec get_chain_status(pos_integer()) :: map()
  def get_chain_status(chain_id) when is_integer(chain_id) and chain_id > 0 do
    BlockSyncRegistry.get_chain_status(chain_id)
  end
end
