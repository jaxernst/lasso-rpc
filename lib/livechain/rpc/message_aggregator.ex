defmodule Livechain.RPC.MessageAggregator do
  @moduledoc """
  Aggregates and deduplicates messages from multiple RPC providers.

  This GenServer receives blockchain events from multiple providers and ensures:
  1. Only the fastest message is forwarded (speed optimization)
  2. Duplicate messages are filtered out (deduplication)
  3. Message ordering and consistency across providers

  The aggregator maintains a sliding window cache of recent messages to detect
  duplicates while keeping memory usage bounded.

  Racing metrics are captured to track which provider delivers events fastest,
  providing valuable benchmarking data for provider performance analysis.
  """

  use GenServer
  require Logger

  alias Livechain.Benchmarking.BenchmarkStore

  defstruct [
    :chain_name,
    # TODO: Why do we store the chain config in this module struct? (Should already have config loaded)
    :chain_config,
    :message_cache,
    :cache_refs,
    :cache_size,
    :max_cache_size,
    :stats
  ]

  defmodule Stats do
    defstruct messages_received: 0,
              messages_forwarded: 0,
              messages_deduplicated: 0,
              providers_reporting: MapSet.new(),
              last_message_time: nil
  end

  @doc """
  Starts the MessageAggregator for a chain.
  """
  def start_link({chain_name, chain_config}) do
    GenServer.start_link(__MODULE__, {chain_name, chain_config}, name: via_name(chain_name))
  end

  @doc """
  Processes an incoming message from a provider.
  """
  def process_message(chain_name, provider_id, message, received_at \\ nil) do
    received_at = received_at || System.monotonic_time(:millisecond)
    GenServer.cast(via_name(chain_name), {:process_message, provider_id, message, received_at})
  end

  @doc """
  Gets aggregation statistics for a chain.
  """
  def get_stats(chain_name) do
    GenServer.call(via_name(chain_name), :get_stats)
  end

  @doc """
  Resets the message cache and statistics.
  """
  def reset_cache(chain_name) do
    GenServer.call(via_name(chain_name), :reset_cache)
  end

  # GenServer callbacks

  @impl true
  def init({chain_name, chain_config}) do
    Logger.info("Starting MessageAggregator for #{chain_name}")

    # Subscribe to PubSub to receive messages from WSConnections
    Phoenix.PubSub.subscribe(Livechain.PubSub, "raw_messages:#{chain_name}")

    state = %__MODULE__{
      chain_name: chain_name,
      chain_config: chain_config,
      message_cache: %{},
      cache_refs: %{},
      cache_size: 0,
      max_cache_size: Map.get(chain_config.aggregation, :max_cache_size, 10_000),
      stats: %Stats{}
    }

    # Schedule periodic cache cleanup
    schedule_cache_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_cast({:process_message, provider_id, message, received_at}, state) do
    new_state =
      state
      |> update_stats(provider_id, received_at)
      |> process_blockchain_message(provider_id, message, received_at)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:raw_message, provider_id, message, received_at}, state) do
    new_state =
      state
      |> update_stats(provider_id, received_at)
      |> process_blockchain_message(provider_id, message, received_at)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:cache_cleanup, cache_key}, state) do
    new_state = remove_from_cache(state, cache_key)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:periodic_cache_cleanup, state) do
    # Clean up old entries that might have missed their timers
    cache_ttl = state.chain_config.aggregation.deduplication_window * 2
    cutoff_time = System.monotonic_time(:millisecond) - cache_ttl

    expired_keys =
      state.message_cache
      |> Enum.filter(fn {_key, {_msg, timestamp, _provider}} -> timestamp < cutoff_time end)
      |> Enum.map(fn {key, _} -> key end)

    new_state = Enum.reduce(expired_keys, state, &remove_from_cache(&2, &1))

    if length(expired_keys) > 0 do
      Logger.debug(
        "Cleaned up #{length(expired_keys)} expired cache entries for #{state.chain_name}"
      )
    end

    # Schedule next cleanup
    schedule_cache_cleanup()

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call(:reset_cache, _from, state) do
    # Clear all timers
    Enum.each(state.cache_refs, fn {_key, ref} ->
      Process.cancel_timer(ref)
    end)

    new_state = %{state | message_cache: %{}, cache_refs: %{}, stats: %Stats{}}

    Logger.info("Reset message cache and stats for #{state.chain_name}")
    {:reply, :ok, new_state}
  end

  # Private functions

  defp process_blockchain_message(state, provider_id, message, received_at) do
    message_key = generate_message_key(message)
    event_type = extract_event_type(message)

    case Map.get(state.message_cache, message_key) do
      nil ->
        # First time seeing this message - forward it immediately and cache it
        forward_message(state.chain_name, provider_id, message, received_at)

        # Emit new block compact event for newHeads
        if event_type == "newHeads" do
          emit_block_compact(state.chain_name, provider_id, message, 0)
        end

        # Record racing victory
        BenchmarkStore.record_event_race_win(
          state.chain_name,
          provider_id,
          event_type,
          received_at
        )

        cache_message(state, message_key, message, received_at, provider_id)
        |> update_forwarded_stats()

      {_cached_msg, cached_time, cached_provider} ->
        # Duplicate message - log and increment stats
        margin_ms = received_at - cached_time

        Logger.debug(
          "Deduplicated message from #{provider_id} (original from #{cached_provider}) " <>
            "for #{state.chain_name}: #{message_key}, margin: #{margin_ms}ms"
        )

        # Emit duplicate arrival margin for newHeads to power racing insights
        if event_type == "newHeads" do
          emit_block_compact(state.chain_name, provider_id, message, margin_ms)
        end

        # Record racing loss with margin
        BenchmarkStore.record_event_race_loss(
          state.chain_name,
          provider_id,
          event_type,
          received_at,
          margin_ms
        )

        update_deduplicated_stats(state)
    end
  end

  defp emit_block_compact(chain_name, provider_id, message, margin_ms) do
    block = extract_block_data(message)

    compact = %{
      ts: System.system_time(:millisecond),
      chain: chain_name,
      block_number: Map.get(block, "number"),
      hash: Map.get(block, "hash"),
      tx_count:
        (block["transactions"] && length(block["transactions"])) ||
          Map.get(block, "transactions", []) |> length(),
      provider_first: provider_id,
      margin_ms: margin_ms
    }

    Phoenix.PubSub.broadcast(Livechain.PubSub, "blocks:new:#{chain_name}", compact)
  end

  defp extract_block_data(message) when is_map(message) do
    case message do
      %{"result" => result} when is_map(result) ->
        result

      %{"params" => %{"result" => result}} ->
        result

      _ ->
        message
    end
  end

  defp extract_block_data(data), do: data

  defp generate_message_key(message) do
    # Generate a unique key based on message content
    # For blockchain messages, use block hash or transaction hash
    cond do
      # New block message
      is_map(message) and Map.has_key?(message, "result") and
          Map.has_key?(message["result"], "hash") ->
        "block:" <> message["result"]["hash"]

      # Subscription message with block data
      is_map(message) and Map.has_key?(message, "params") and
        is_map(message["params"]) and Map.has_key?(message["params"], "result") ->
        result = message["params"]["result"]

        if is_map(result) and Map.has_key?(result, "hash") do
          "block:" <> result["hash"]
        else
          # Fall back to content hash
          "content:" <> content_hash(message)
        end

      # Log message
      is_map(message) and Map.has_key?(message, "params") and
        is_map(message["params"]) and Map.has_key?(message["params"], "result") and
          Map.has_key?(message["params"]["result"], "transactionHash") ->
        "log:" <> message["params"]["result"]["transactionHash"]

      # Generic fallback - hash the entire content
      true ->
        "content:" <> content_hash(message)
    end
  end

  defp content_hash(message) do
    message
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    # First 16 chars for efficiency
    |> String.slice(0..15)
  end

  defp extract_event_type(message) do
    cond do
      # New block subscription (newHeads)
      is_map(message) and Map.get(message, "method") == "eth_subscription" and
        is_map(message["params"]) and
          (Map.has_key?(message["params"]["result"], "hash") or
             Map.has_key?(message["params"]["result"], "number")) ->
        "newHeads"

      # Transaction logs
      is_map(message) and Map.get(message, "method") == "eth_subscription" and
        is_map(message["params"]) and Map.has_key?(message["params"]["result"], "topics") ->
        "logs"

      # Pending transactions
      is_map(message) and Map.get(message, "method") == "eth_subscription" and
        is_map(message["params"]) and
          (Map.has_key?(message["params"]["result"], "from") or
             Map.has_key?(message["params"]["result"], "to")) ->
        "pendingTransactions"

      # Sync status updates
      is_map(message) and Map.get(message, "method") == "eth_subscription" and
        is_map(message["params"]) and Map.has_key?(message["params"]["result"], "syncing") ->
        "syncing"

      # JSON-RPC response messages (non-subscription)
      is_map(message) and Map.has_key?(message, "result") and Map.has_key?(message, "id") ->
        "rpc_response"

      # Generic subscription events
      is_map(message) and Map.get(message, "method") == "eth_subscription" ->
        "subscription"

      # Fallback for unknown message types
      true ->
        "unknown"
    end
  end

  defp forward_message(chain_name, provider_id, message, received_at) do
    # Add metadata about the message source and timing
    enriched_message =
      if is_map(message) do
        Map.merge(message, %{
          "_livechain_meta" => %{
            "provider_id" => provider_id,
            "received_at" => received_at,
            "chain_name" => chain_name
          }
        })
      else
        message
      end

    # Broadcast to the appropriate chain channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "blockchain:#{chain_name}",
      {:blockchain_message, enriched_message}
    )

    # Also broadcast to the aggregated channel for monitoring
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "aggregated:#{chain_name}",
      {:fastest_message, provider_id, enriched_message}
    )
  end

  defp cache_message(state, message_key, message, received_at, provider_id) do
    # Check if we need to evict old entries due to size limits
    state =
      if state.cache_size >= state.max_cache_size do
        evict_oldest_entries(state)
      else
        state
      end

    # Set up automatic cleanup timer
    cleanup_delay = state.chain_config.aggregation.deduplication_window
    ref = Process.send_after(self(), {:cache_cleanup, message_key}, cleanup_delay)

    new_cache = Map.put(state.message_cache, message_key, {message, received_at, provider_id})
    new_refs = Map.put(state.cache_refs, message_key, ref)

    %{state | message_cache: new_cache, cache_refs: new_refs, cache_size: state.cache_size + 1}
  end

  defp remove_from_cache(state, cache_key) do
    # Cancel timer if it exists
    if ref = Map.get(state.cache_refs, cache_key) do
      Process.cancel_timer(ref)
    end

    new_cache = Map.delete(state.message_cache, cache_key)
    new_refs = Map.delete(state.cache_refs, cache_key)

    %{
      state
      | message_cache: new_cache,
        cache_refs: new_refs,
        cache_size: max(0, state.cache_size - 1)
    }
  end

  defp update_stats(state, provider_id, received_at) do
    old_stats = state.stats

    new_stats = %{
      old_stats
      | messages_received: old_stats.messages_received + 1,
        providers_reporting: MapSet.put(old_stats.providers_reporting, provider_id),
        last_message_time: received_at
    }

    %{state | stats: new_stats}
  end

  defp update_forwarded_stats(state) do
    old_stats = state.stats
    new_stats = %{old_stats | messages_forwarded: old_stats.messages_forwarded + 1}
    %{state | stats: new_stats}
  end

  defp update_deduplicated_stats(state) do
    old_stats = state.stats
    new_stats = %{old_stats | messages_deduplicated: old_stats.messages_deduplicated + 1}
    %{state | stats: new_stats}
  end

  defp evict_oldest_entries(state) do
    # Find oldest entries to evict (LRU-like behavior)
    entries_to_evict =
      state.message_cache
      |> Enum.sort_by(fn {_key, {_msg, timestamp, _provider}} -> timestamp end)
      # Evict 10% of cache
      |> Enum.take(div(state.max_cache_size, 10))

    Enum.reduce(entries_to_evict, state, fn {key, _}, acc_state ->
      remove_from_cache(acc_state, key)
    end)
  end

  defp schedule_cache_cleanup do
    # Clean up every 30 seconds
    Process.send_after(self(), :periodic_cache_cleanup, 30_000)
  end

  defp via_name(chain_name) do
    {:via, Registry, {Livechain.Registry, {:message_aggregator, chain_name}}}
  end
end
