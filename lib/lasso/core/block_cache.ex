defmodule Lasso.Core.BlockCache do
  @moduledoc """
  ETS-backed cache for real-time block data from WebSocket newHeads subscriptions.

  Provides a shared, fast-access store for:
  - Latest block data per chain (consensus view)
  - Per-provider block heights and sync status
  - Rich block metadata (hash, timestamp, parent_hash, etc.)

  ## Usage

      # Get latest block for a chain
      {:ok, block} = BlockCache.get_latest_block("ethereum")

      # Get provider-specific block height
      {:ok, height, timestamp} = BlockCache.get_provider_height("ethereum", "alchemy")

      # Get all provider heights for consensus calculation
      heights = BlockCache.get_all_provider_heights("ethereum")

      # Subscribe to real-time updates
      Phoenix.PubSub.subscribe(Lasso.PubSub, "block_cache:updates")

  ## Data Format

  Latest block includes:
  - `number` - Block height (integer)
  - `hash` - Block hash
  - `parent_hash` - Parent block hash
  - `timestamp` - Block timestamp (unix seconds)
  - `gas_limit` - Gas limit
  - `gas_used` - Gas used
  - `base_fee_per_gas` - Base fee (if EIP-1559)
  - `received_at` - When we received this block (ms timestamp)
  - `provider_id` - Which provider reported this block
  """

  use GenServer
  require Logger

  @table_name :lasso_block_cache
  @pubsub_topic "block_cache:updates"

  # Data freshness window (15 seconds)
  @freshness_window_ms 15_000

  # Types
  @type chain :: String.t()
  @type provider_id :: String.t()
  @type block_data :: %{
          number: non_neg_integer(),
          hash: String.t(),
          parent_hash: String.t(),
          timestamp: non_neg_integer(),
          gas_limit: non_neg_integer(),
          gas_used: non_neg_integer(),
          base_fee_per_gas: non_neg_integer() | nil,
          received_at: non_neg_integer(),
          provider_id: String.t()
        }

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the table name for direct ETS access (for high-performance reads).
  """
  @spec table_name() :: atom()
  def table_name, do: @table_name

  @doc """
  Get the PubSub topic for subscribing to block updates.
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Store a new block from a provider's newHeads subscription.
  Broadcasts update via PubSub.
  """
  @spec put_block(chain(), provider_id(), map()) :: :ok
  def put_block(chain, provider_id, raw_block) do
    GenServer.cast(__MODULE__, {:put_block, chain, provider_id, raw_block})
  end

  @doc """
  Get the latest block for a chain (highest block number seen).
  """
  @spec get_latest_block(chain()) :: {:ok, block_data()} | {:error, :not_found}
  def get_latest_block(chain) do
    case :ets.lookup(@table_name, {:latest, chain}) do
      [{{:latest, ^chain}, block}] -> {:ok, block}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @doc """
  Get the latest block height for a chain.
  """
  @spec get_latest_height(chain()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def get_latest_height(chain) do
    case get_latest_block(chain) do
      {:ok, %{number: height}} -> {:ok, height}
      error -> error
    end
  end

  @doc """
  Get a specific provider's latest reported block height.
  Returns {height, received_at_ms}.
  """
  @spec get_provider_height(chain(), provider_id()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :not_found}
  def get_provider_height(chain, provider_id) do
    case :ets.lookup(@table_name, {:provider, chain, provider_id}) do
      [{{:provider, ^chain, ^provider_id}, {height, received_at}}] ->
        {:ok, height, received_at}

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @doc """
  Get all provider heights for a chain.
  Returns a list of {provider_id, height, received_at} tuples.
  Optionally filter to only fresh data (within freshness window).
  """
  @spec get_all_provider_heights(chain(), keyword()) :: [
          {provider_id(), non_neg_integer(), non_neg_integer()}
        ]
  def get_all_provider_heights(chain, opts \\ []) do
    only_fresh = Keyword.get(opts, :only_fresh, false)
    now = System.system_time(:millisecond)

    :ets.match(@table_name, {{:provider, chain, :"$1"}, {:"$2", :"$3"}})
    |> Enum.map(fn [provider_id, height, received_at] ->
      {provider_id, height, received_at}
    end)
    |> then(fn heights ->
      if only_fresh do
        Enum.filter(heights, fn {_pid, _h, received_at} ->
          now - received_at < @freshness_window_ms
        end)
      else
        heights
      end
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Get consensus height from fresh WebSocket data.
  Uses the maximum height from providers with fresh data.
  """
  @spec get_ws_consensus_height(chain()) ::
          {:ok, non_neg_integer()} | {:error, :no_fresh_data}
  def get_ws_consensus_height(chain) do
    case get_all_provider_heights(chain, only_fresh: true) do
      [] ->
        {:error, :no_fresh_data}

      heights ->
        max_height = heights |> Enum.map(fn {_, h, _} -> h end) |> Enum.max()
        {:ok, max_height}
    end
  end

  @doc """
  Calculate provider lag from WebSocket data.
  Negative lag means provider is behind consensus.
  """
  @spec get_provider_lag(chain(), provider_id()) ::
          {:ok, integer()} | {:error, term()}
  def get_provider_lag(chain, provider_id) do
    with {:ok, provider_height, _} <- get_provider_height(chain, provider_id),
         {:ok, consensus} <- get_ws_consensus_height(chain) do
      {:ok, provider_height - consensus}
    end
  end

  @doc """
  Get full block data for a specific provider.
  """
  @spec get_provider_block(chain(), provider_id()) ::
          {:ok, block_data()} | {:error, :not_found}
  def get_provider_block(chain, provider_id) do
    case :ets.lookup(@table_name, {:provider_block, chain, provider_id}) do
      [{{:provider_block, ^chain, ^provider_id}, block}] -> {:ok, block}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @doc """
  Clear all data for a chain (useful for testing or chain removal).
  """
  @spec clear_chain(chain()) :: :ok
  def clear_chain(chain) do
    GenServer.cast(__MODULE__, {:clear_chain, chain})
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:put_block, chain, provider_id, raw_block}, state) do
    case normalize_block(raw_block, provider_id) do
      {:ok, block} ->
        # Store provider-specific data
        :ets.insert(
          @table_name,
          {{:provider, chain, provider_id}, {block.number, block.received_at}}
        )

        :ets.insert(@table_name, {{:provider_block, chain, provider_id}, block})

        # Update latest block if this is newer
        update_latest = should_update_latest?(chain, block)

        if update_latest do
          :ets.insert(@table_name, {{:latest, chain}, block})
        end

        # Broadcast update
        Phoenix.PubSub.broadcast(Lasso.PubSub, @pubsub_topic, %{
          type: :block_update,
          chain: chain,
          provider_id: provider_id,
          block_number: block.number,
          block_hash: block.hash,
          is_new_latest: update_latest
        })

      {:error, reason} ->
        require Logger

        Logger.warning("BlockCache: invalid block data from #{provider_id} on #{chain}",
          reason: reason,
          raw_block: inspect(raw_block, limit: 200)
        )
    end

    {:noreply, state}
  end

  def handle_cast({:clear_chain, chain}, state) do
    # Delete all entries for this chain
    :ets.match_delete(@table_name, {{:latest, chain}, :_})
    :ets.match_delete(@table_name, {{:provider, chain, :_}, :_})
    :ets.match_delete(@table_name, {{:provider_block, chain, :_}, :_})

    {:noreply, state}
  end

  ## Private Functions

  defp normalize_block(raw_block, provider_id) do
    # Validate required fields - number is required for block comparisons
    number = decode_hex(Map.get(raw_block, "number"))

    if is_nil(number) do
      {:error, :missing_block_number}
    else
      {:ok,
       %{
         number: number,
         hash: Map.get(raw_block, "hash"),
         parent_hash: Map.get(raw_block, "parentHash"),
         timestamp: decode_hex(Map.get(raw_block, "timestamp")),
         gas_limit: decode_hex(Map.get(raw_block, "gasLimit")),
         gas_used: decode_hex(Map.get(raw_block, "gasUsed")),
         base_fee_per_gas: decode_hex(Map.get(raw_block, "baseFeePerGas")),
         received_at: System.system_time(:millisecond),
         provider_id: provider_id
       }}
    end
  end

  defp should_update_latest?(chain, new_block) do
    case :ets.lookup(@table_name, {:latest, chain}) do
      [{{:latest, ^chain}, current}] ->
        new_block.number > current.number

      [] ->
        true
    end
  rescue
    ArgumentError -> true
  end

  defp decode_hex(nil), do: nil

  defp decode_hex("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp decode_hex(val) when is_integer(val), do: val
  defp decode_hex(_), do: nil
end
