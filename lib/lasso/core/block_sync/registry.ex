defmodule Lasso.BlockSync.Registry do
  @moduledoc """
  Single source of truth for block height data.

  Stores block heights from all providers (WS or HTTP) in an ETS table
  owned by the application supervisor. All public functions operate
  directly on the table — there is no coordinating process.

  ## ETS Schema

  Keys are tuples for efficient lookups:
  - `{:height, chain_id, provider_id}` => `{height, timestamp_ms, source, metadata}`
  - `{:head_observation, chain_id, provider_id, transport}` => `%HeadObservation{}`
  - `{:block_time, chain_id}` => `%BlockTimeMeasurement{}`

  ## Freshness

  Heights older than `freshness_threshold_ms` are ignored when calculating
  consensus. This ensures stale data doesn't pollute routing decisions.

  Health metrics (latency, success/failure) are tracked in :lasso_instance_state ETS.
  This module focuses solely on block height tracking.
  """

  require Logger

  alias Lasso.BlockSync.ObservationProjection
  alias Lasso.Core.BlockSync.BlockTimeMeasurement
  alias Lasso.Observations.{HeadComparison, HeadObservation, HeadScope, HeadSnapshot}
  alias Lasso.Providers.{Catalog, HeadEvidence}

  @table :block_sync_registry
  @default_freshness_ms 30_000
  @cache_retries 4
  @observation_retries 4

  ## Client API

  @doc """
  Store a block height from a provider.

  ## Parameters
  - `chain_id` - Chain identifier (EIP-155 integer, e.g. 1 for Ethereum mainnet)
  - `provider_id` - Provider identifier
  - `height` - Block height (integer)
  - `source` - `:ws` or `:http`
  - `metadata` - Optional map with additional data (hash, timestamp, latency_ms)
  """
  @spec put_height(pos_integer(), String.t(), integer(), :ws | :http, map()) :: :ok
  def put_height(chain_id, provider_id, height, source, metadata \\ %{})
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) and
             is_integer(height) do
    _result =
      put_height_at(
        chain_id,
        provider_id,
        height,
        System.system_time(:millisecond),
        source,
        metadata
      )

    :ok
  end

  @doc "Store a report using its source observation time, ignoring delayed older reports."
  @spec put_height_at(pos_integer(), String.t(), integer(), integer(), :ws | :http, map()) ::
          :ok | :ignored
  def put_height_at(chain_id, provider_id, height, observed_at_ms, source, metadata)
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) and
             is_integer(height) and is_integer(observed_at_ms) and observed_at_ms >= 0 and
             source in [:http, :ws] and is_map(metadata) do
    key = {:height, chain_id, provider_id}
    value = {height, observed_at_ms, source, metadata}
    stored? = store_newer_height(key, value, @observation_retries)
    store_observation(chain_id, provider_id, height, observed_at_ms, source, metadata)
    refresh_scope_cache(chain_id, provider_id)

    if stored? do
      update_block_time(chain_id, height)
      revision = next_consensus_revision(chain_id)
      refresh_consensus_cache(chain_id, System.system_time(:millisecond), revision)
      :ok
    else
      :ignored
    end
  end

  @doc "Store a validated source observation while maintaining legacy height consumers."
  @spec put_observation(HeadObservation.t()) :: :ok | :ignored
  def put_observation(%HeadObservation{} = observation) do
    metadata = observation_metadata(observation)
    chain_id = observation.chain_id
    key = {:height, chain_id, observation.instance_id}

    stored? =
      store_newer_height(
        key,
        {observation.height, observation.observed_at_ms, observation.transport, metadata},
        @observation_retries
      )

    store_newer_observation(
      {:head_observation, chain_id, observation.instance_id, observation.transport},
      observation,
      @observation_retries
    )

    refresh_scope_cache(chain_id, observation.instance_id)

    if stored? do
      update_block_time(chain_id, observation.height)
      revision = next_consensus_revision(chain_id)
      refresh_consensus_cache(chain_id, System.system_time(:millisecond), revision)
      :ok
    else
      :ignored
    end
  end

  @doc """
  Get the stored height for a specific provider.

  Returns `{:ok, {height, timestamp, source, metadata}}` or `{:error, :not_found}`.
  """
  @spec get_height(pos_integer(), String.t()) ::
          {:ok, {integer(), integer(), :ws | :http, map()}} | {:error, :not_found}
  def get_height(chain_id, provider_id)
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) do
    case :ets.lookup(@table, {:height, chain_id, provider_id}) do
      [{_key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @doc "Get the latest valid head fact for one upstream transport."
  @spec get_observation(pos_integer(), String.t(), :http | :ws) ::
          {:ok, HeadObservation.t()} | {:error, :not_found}
  def get_observation(chain_id, provider_id, transport)
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) and
             transport in [:http, :ws] do
    case :ets.lookup(@table, {:head_observation, chain_id, provider_id, transport}) do
      [{_key, %HeadObservation{} = observation}] -> {:ok, observation}
      [] -> {:error, :not_found}
    end
  end

  @doc "Get at most one current HTTP and WebSocket fact for an upstream."
  @spec get_observations(pos_integer(), String.t()) :: [HeadObservation.t()]
  def get_observations(chain_id, provider_id)
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) do
    Enum.flat_map([:http, :ws], fn transport ->
      case get_observation(chain_id, provider_id, transport) do
        {:ok, observation} -> [observation]
        {:error, :not_found} -> []
      end
    end)
  end

  @doc "Read a current profile-scoped snapshot, deriving only on a cold or expired cache."
  @spec get_head_snapshot(HeadScope.t(), non_neg_integer(), integer()) ::
          {:ok, HeadSnapshot.t()} | {:error, :unstable}
  def get_head_snapshot(%HeadScope{} = scope, generation, now_ms)
      when is_integer(generation) and generation >= 0 and is_integer(now_ms) do
    revision = current_head_revision(scope.chain_id)

    case :ets.lookup(@table, scope.cache_key) do
      [{_key, ^revision, ^generation, %HeadSnapshot{} = snapshot}]
      when now_ms <= snapshot.valid_through_ms ->
        if current_head_revision(scope.chain_id) == revision,
          do: {:ok, snapshot},
          else: refresh_head_snapshot(scope, generation, now_ms, @cache_retries)

      _missing_or_expired ->
        refresh_head_snapshot(scope, generation, now_ms, @cache_retries)
    end
  end

  @doc "Reads a still-valid scoped snapshot without deriving a cold comparison."
  @spec get_cached_head_snapshot(HeadScope.t()) ::
          {:ok, HeadSnapshot.t()} | {:error, :no_data}
  def get_cached_head_snapshot(%HeadScope{} = scope) do
    now_ms = System.system_time(:millisecond)

    with %{generation: generation} <- Catalog.snapshot(),
         revision <- current_head_revision(scope.chain_id),
         [{_key, ^revision, ^generation, %HeadSnapshot{} = snapshot}] <-
           :ets.lookup(@table, scope.cache_key),
         true <- now_ms <= snapshot.valid_through_ms,
         ^revision <- current_head_revision(scope.chain_id) do
      {:ok, snapshot}
    else
      _ -> {:error, :no_data}
    end
  end

  @doc "Clear scoped snapshot rows after an atomic catalog generation swap."
  @spec clear_scoped_head_snapshots() :: :ok
  def clear_scoped_head_snapshots do
    :ets.match_delete(@table, {{:head_snapshot_scope, :_, :_, :_, :_, :_, :_}, :_, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Get the time-aligned consensus block height for a chain using P75.

  With 1-3 providers, returns MAX (same as before). With 4+ providers, returns
  the second-highest height — filtering out one outlier fast provider that could
  make all others appear lagged. When dynamic block time is available, fresh
  HTTP samples are first advanced toward the highest actually observed height
  by no more than their elapsed-time budget. WebSocket samples remain direct
  evidence and no sample can be advanced beyond a real observation.

  Each observation carries the effective freshness window from its worker
  configuration. The explicit two-argument form overrides that window.

  Returns `{:ok, height}` or `{:error, :no_data}`.
  """
  @spec get_consensus_height(pos_integer()) :: {:ok, integer()} | {:error, :no_data}
  def get_consensus_height(chain_id) when is_integer(chain_id) and chain_id > 0 do
    now_ms = System.system_time(:millisecond)
    key = consensus_key(chain_id)

    case :ets.lookup(@table, key) do
      [{^key, revision, revision, height, valid_through_ms}]
      when now_ms <= valid_through_ms ->
        {:ok, height}

      _missing_or_expired ->
        refresh_consensus_cache(chain_id, now_ms, current_consensus_revision(chain_id))
    end
  end

  @spec get_consensus_height(pos_integer(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :no_data}
  def get_consensus_height(chain_id, freshness_ms)
      when is_integer(chain_id) and chain_id > 0 and is_integer(freshness_ms) and
             freshness_ms >= 0 do
    calculate_consensus(chain_id, nil, freshness_ms)
  end

  @doc """
  Get consensus height filtered by specific providers.

  Returns `{:ok, height}` or `{:error, :no_data}`.
  """
  @spec get_consensus_height_filtered(
          pos_integer(),
          [String.t()] | nil,
          non_neg_integer() | nil
        ) ::
          {:ok, integer()} | {:error, :no_data}
  def get_consensus_height_filtered(chain_id, provider_ids, freshness_ms \\ nil)
      when is_integer(chain_id) and chain_id > 0 and
             (is_nil(freshness_ms) or
                (is_integer(freshness_ms) and freshness_ms >= 0)) do
    if is_nil(freshness_ms),
      do: calculate_current_consensus(chain_id, provider_ids),
      else: calculate_consensus(chain_id, provider_ids, freshness_ms)
  end

  @doc """
  Calculate provider's lag compared to consensus height.

  Returns:
  - `{:ok, lag}` where lag is `provider_height - consensus_height`
    (negative means behind, positive means ahead)
  - `{:error, :no_provider_data}` if provider has no height data
  - `{:error, :no_consensus}` if no consensus can be calculated
  """
  @spec get_provider_lag(pos_integer(), String.t(), non_neg_integer() | nil) ::
          {:ok, integer()} | {:error, :no_provider_data | :no_consensus | :stale_data}
  def get_provider_lag(chain_id, provider_id, freshness_ms \\ nil)
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) and
             (is_nil(freshness_ms) or
                (is_integer(freshness_ms) and freshness_ms >= 0)) do
    now_ms = System.system_time(:millisecond)

    with {:ok, {height, timestamp, _source, metadata}} <- get_height(chain_id, provider_id),
         true <- observation_fresh?(timestamp, metadata, freshness_ms, now_ms),
         {:ok, consensus} <- consensus_height(chain_id, freshness_ms) do
      {:ok, height - consensus}
    else
      false -> {:error, :stale_data}
      {:error, :not_found} -> {:error, :no_provider_data}
      {:error, :no_data} -> {:error, :no_consensus}
    end
  end

  @doc """
  Get all heights for a chain (for dashboard/debugging).

  Returns a map of `provider_id => {height, timestamp, source, metadata}`.
  """
  @spec get_all_heights(pos_integer()) :: %{
          String.t() => {integer(), integer(), :ws | :http, map()}
        }
  def get_all_heights(chain_id) when is_integer(chain_id) and chain_id > 0 do
    match_spec = [
      {{{:height, chain_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    :ets.select(@table, match_spec)
    |> Map.new()
  end

  @doc """
  Get a comprehensive status for all providers on a chain.

  Returns a map of provider_id => %{height: ..., source: ..., lag: ..., ...}
  """
  @spec get_chain_status(pos_integer()) :: %{String.t() => map()}
  def get_chain_status(chain_id) when is_integer(chain_id) and chain_id > 0 do
    heights = get_all_heights(chain_id)
    now = System.system_time(:millisecond)

    consensus =
      case get_consensus_height(chain_id) do
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
  @spec clear_chain(pos_integer()) :: :ok
  def clear_chain(chain_id) when is_integer(chain_id) and chain_id > 0 do
    :ets.match_delete(@table, {{:height, chain_id, :_}, :_})
    :ets.match_delete(@table, {{:head_observation, chain_id, :_, :_}, :_})
    :ets.delete(@table, {:block_time, chain_id})
    :ets.delete(@table, consensus_key(chain_id))
    :ets.delete(@table, {:head_revision, chain_id})

    :ets.match_delete(
      @table,
      {{:head_snapshot_scope, :_, chain_id, :_, :_, :_, :_}, :_, :_, :_}
    )

    :ok
  end

  @doc "Remove retained head facts after the final profile releases an upstream."
  @spec remove_instance(pos_integer(), String.t()) :: :ok
  def remove_instance(chain_id, provider_id)
      when is_integer(chain_id) and chain_id > 0 and is_binary(provider_id) do
    :ets.delete(@table, {:height, chain_id, provider_id})
    :ets.delete(@table, {:head_observation, chain_id, provider_id, :http})
    :ets.delete(@table, {:head_observation, chain_id, provider_id, :ws})
    next_head_revision(chain_id)

    :ets.match_delete(
      @table,
      {{:head_snapshot_scope, :_, chain_id, :_, :_, :_, :_}, :_, :_, :_}
    )

    revision = next_consensus_revision(chain_id)
    refresh_consensus_cache(chain_id, System.system_time(:millisecond), revision)
    :ok
  end

  ## Block Time Measurement

  @doc """
  Get the dynamically measured block time for a chain.

  Returns the measured block time if enough samples have been collected,
  otherwise returns nil.
  """
  @spec get_block_time_ms(pos_integer()) :: non_neg_integer() | nil
  def get_block_time_ms(chain_id) when is_integer(chain_id) and chain_id > 0 do
    case :ets.lookup(@table, {:block_time, chain_id}) do
      [{{:block_time, ^chain_id}, measurement}] ->
        BlockTimeMeasurement.get_block_time_ms(measurement, nil)

      [] ->
        nil
    end
  end

  @doc """
  Record a consensus height observation for block time measurement.

  Should be called whenever the consensus height changes to track
  inter-block timing.
  """
  @spec update_block_time(pos_integer(), non_neg_integer()) :: :ok
  def update_block_time(chain_id, height)
      when is_integer(chain_id) and chain_id > 0 and is_integer(height) do
    measurement =
      case :ets.lookup(@table, {:block_time, chain_id}) do
        [{{:block_time, ^chain_id}, m}] -> m
        [] -> %BlockTimeMeasurement{}
      end

    updated = BlockTimeMeasurement.record(measurement, height)
    :ets.insert(@table, {{:block_time, chain_id}, updated})
    :ok
  end

  ## Private Functions

  defp observation_metadata(%HeadObservation{} = observation) do
    observation.attributes
    |> Map.put(:origin_member_id, observation.origin_member_id)
    |> Map.put(:hash, observation.block_hash)
    |> Map.put(:parent_hash, observation.parent_hash)
    |> Map.put(:timestamp, observation.block_timestamp)
    |> Map.put(:latency_ms, observation.latency_ms)
    |> Map.put(:poll_references, observation.poll_references)
  end

  defp store_newer_height(key, {_height, observed_at_ms, _source, _metadata} = value, retries)
       when retries > 0 do
    case :ets.lookup(@table, key) do
      [{^key, {_height, current_at_ms, _source, _metadata}}]
      when current_at_ms > observed_at_ms ->
        false

      [{^key, _value} = current] ->
        updated = {key, value}

        case :ets.select_replace(@table, [{current, [], [{:const, updated}]}]) do
          1 -> true
          0 -> store_newer_height(key, value, retries - 1)
        end

      [] ->
        if :ets.insert_new(@table, {key, value}),
          do: true,
          else: store_newer_height(key, value, retries - 1)
    end
  end

  defp store_newer_height(_key, _value, 0), do: false

  defp store_observation(chain_id, provider_id, height, timestamp, transport, metadata)
       when transport in [:http, :ws] and is_map(metadata) do
    attrs = %{
      chain_id: chain_id,
      instance_id: provider_id,
      height: height,
      observed_at_ms: timestamp,
      transport: transport,
      block_hash: Map.get(metadata, :hash),
      parent_hash: Map.get(metadata, :parent_hash),
      block_timestamp: Map.get(metadata, :timestamp),
      latency_ms: Map.get(metadata, :latency_ms),
      sample_interval_ms: Map.get(metadata, :optimistic_credit_ms),
      origin_member_id: Map.get(metadata, :origin_member_id),
      poll_references: Map.get(metadata, :poll_references, []),
      attributes: metadata
    }

    case HeadObservation.new(attrs) do
      {:ok, observation} ->
        key = {:head_observation, chain_id, provider_id, transport}
        store_newer_observation(key, observation, @observation_retries)

      {:error, _invalid_legacy_fact} ->
        :ok
    end
  end

  defp store_observation(_chain_id, _provider_id, _height, _timestamp, _transport, _metadata),
    do: :ok

  defp store_newer_observation(key, %HeadObservation{} = observation, retries)
       when retries > 0 do
    case :ets.lookup(@table, key) do
      [{^key, %HeadObservation{observed_at_ms: current_at_ms}}]
      when current_at_ms > observation.observed_at_ms ->
        :ok

      [{^key, %HeadObservation{}} = current] ->
        updated = {key, observation}

        case :ets.select_replace(@table, [{current, [], [{:const, updated}]}]) do
          1 -> :ok
          0 -> store_newer_observation(key, observation, retries - 1)
        end

      [] ->
        if :ets.insert_new(@table, {key, observation}),
          do: :ok,
          else: store_newer_observation(key, observation, retries - 1)
    end
  end

  defp store_newer_observation(_key, _observation, 0), do: :ok

  defp refresh_scope_cache(chain_id, instance_id) do
    next_head_revision(chain_id)
    HeadEvidence.refresh_for_instance(chain_id, instance_id)
  end

  defp refresh_head_snapshot(scope, generation, now_ms, retries) when retries > 0 do
    revision = current_head_revision(scope.chain_id)

    observations =
      Enum.flat_map(scope.instance_ids, &get_observations(scope.chain_id, &1))

    snapshot = HeadComparison.derive(scope, observations, now_ms, generation)

    if current_head_revision(scope.chain_id) == revision do
      :ets.insert(@table, {scope.cache_key, revision, generation, snapshot})

      if current_head_revision(scope.chain_id) == revision,
        do: {:ok, snapshot},
        else: refresh_head_snapshot(scope, generation, now_ms, retries - 1)
    else
      refresh_head_snapshot(scope, generation, now_ms, retries - 1)
    end
  end

  defp refresh_head_snapshot(_scope, _generation, _now_ms, 0), do: {:error, :unstable}

  defp next_head_revision(chain_id) do
    :ets.update_counter(
      @table,
      {:head_revision, chain_id},
      {2, 1},
      {{:head_revision, chain_id}, 0}
    )
  end

  defp current_head_revision(chain_id) do
    case :ets.lookup(@table, {:head_revision, chain_id}) do
      [{{:head_revision, ^chain_id}, revision}] -> revision
      [] -> 0
    end
  end

  defp refresh_consensus_cache(chain_id, now_ms, revision) do
    case select_current_samples(chain_id, nil, now_ms) do
      [] ->
        {:error, :no_data}

      samples ->
        height = consensus_for_samples(samples, chain_id, now_ms)

        valid_through_ms =
          samples
          |> Enum.map(fn {_height, timestamp, _source, metadata} ->
            timestamp + stale_after_ms(metadata)
          end)
          |> Enum.min()

        publish_consensus(
          consensus_key(chain_id),
          revision,
          height,
          valid_through_ms,
          @cache_retries
        )

        {:ok, height}
    end
  end

  defp next_consensus_revision(chain_id) do
    :ets.update_counter(
      @table,
      consensus_key(chain_id),
      {2, 1},
      {consensus_key(chain_id), 0, 0, nil, 0}
    )
  end

  defp current_consensus_revision(chain_id) do
    key = consensus_key(chain_id)

    case :ets.lookup(@table, key) do
      [{^key, revision, _published_revision, _height, _valid_through_ms}] -> revision
      [] -> 0
    end
  end

  defp publish_consensus(key, revision, height, valid_through_ms, retries)
       when retries > 0 do
    case :ets.lookup(@table, key) do
      [{^key, current_revision, _published_revision, _height, _valid_through_ms}]
      when current_revision > revision ->
        :ok

      [{^key, ^revision, _published_revision, _height, _valid_through_ms} = current] ->
        updated = {key, revision, revision, height, valid_through_ms}

        case :ets.select_replace(@table, [{current, [], [{:const, updated}]}]) do
          1 -> :ok
          0 -> publish_consensus(key, revision, height, valid_through_ms, retries - 1)
        end

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp publish_consensus(_key, _revision, _height, _valid_through_ms, 0), do: :ok

  defp calculate_consensus(chain_id, provider_ids, freshness_ms) do
    now_ms = System.system_time(:millisecond)
    samples = select_current_samples(chain_id, provider_ids, now_ms, freshness_ms)

    case samples do
      [] ->
        {:error, :no_data}

      current ->
        {:ok, consensus_for_samples(current, chain_id, now_ms)}
    end
  end

  defp calculate_current_consensus(chain_id, provider_ids) do
    now_ms = System.system_time(:millisecond)
    samples = select_current_samples(chain_id, provider_ids, now_ms)

    case samples do
      [] -> {:error, :no_data}
      current -> {:ok, consensus_for_samples(current, chain_id, now_ms)}
    end
  end

  defp consensus_for_samples(samples, chain_id, now_ms) do
    observed_height = samples |> Enum.map(&elem(&1, 0)) |> Enum.max()

    heights =
      case get_block_time_ms(chain_id) do
        block_time_ms when is_integer(block_time_ms) and block_time_ms > 0 ->
          Enum.map(samples, fn {height, timestamp, source, metadata} ->
            metadata = metadata || %{}

            %{
              height: height,
              source: source,
              observed_at_ms: timestamp,
              stale_after_ms: stale_after_ms(metadata),
              credit_window_ms: Map.get(metadata, :optimistic_credit_ms)
            }
            |> ObservationProjection.align_height(observed_height, block_time_ms, now_ms)
            |> Map.fetch!(:height)
          end)

        _unknown_block_time ->
          Enum.map(samples, &elem(&1, 0))
      end

    consensus(heights)
  end

  defp consensus([single]), do: single

  defp consensus(heights) do
    sorted = Enum.sort(heights, :desc)
    idx = max(0, floor(length(sorted) * 0.25))
    Enum.at(sorted, idx)
  end

  defp select_current_samples(chain_id, provider_ids, now_ms, freshness_ms \\ nil) do
    :ets.select(@table, [
      {
        {{:height, chain_id, :"$1"}, {:"$2", :"$3", :"$4", :"$5"}},
        [],
        [{{:"$1", :"$2", :"$3", :"$4", :"$5"}}]
      }
    ])
    |> Enum.filter(fn {provider_id, _height, timestamp, _source, metadata} ->
      provider_selected?(provider_ids, provider_id) and
        observation_fresh?(timestamp, metadata, freshness_ms, now_ms)
    end)
    |> Enum.map(fn {_provider_id, height, timestamp, source, metadata} ->
      {height, timestamp, source, metadata}
    end)
  end

  defp provider_selected?(provider_ids, _provider_id) when provider_ids in [nil, []], do: true
  defp provider_selected?(provider_ids, provider_id), do: provider_id in provider_ids

  defp observation_fresh?(timestamp, metadata, freshness_ms, now_ms) do
    freshness_ms = freshness_ms || stale_after_ms(metadata)
    now_ms - timestamp <= freshness_ms
  end

  defp stale_after_ms(metadata) when is_map(metadata) do
    case Map.get(metadata, :stale_after_ms) do
      value when is_integer(value) and value > 0 -> value
      _missing_or_invalid -> @default_freshness_ms
    end
  end

  defp stale_after_ms(_metadata), do: @default_freshness_ms

  defp consensus_height(chain_id, nil), do: get_consensus_height(chain_id)
  defp consensus_height(chain_id, freshness_ms), do: get_consensus_height(chain_id, freshness_ms)

  defp consensus_key(chain_id), do: {:consensus, chain_id}
end
