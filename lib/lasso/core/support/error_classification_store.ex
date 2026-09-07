defmodule Lasso.Core.Support.ErrorClassificationStore do
  @moduledoc """
  GenServer + ETS store collecting bounded error-classification drift evidence.

  Attaches to `[:lasso, :error_classification, :classified]` telemetry events
  and samples entries based on configurable rules. Entries are deduped by
  `{provider_id, code, category, classification_path, control_category,
  shared_control?, message_fingerprint}` and bounded by LRU eviction.
  Raw provider messages and response data are never retained.
  """

  use GenServer

  @table :lasso_error_classification_store
  @admission_table :lasso_error_classification_admission
  @queue_limit 1_024
  @metadata_byte_limit 2_048

  @default_config %{
    sample_all_codes: [-32_000],
    random_sample_rate: 0.01,
    max_entries: 1000,
    enabled: true
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec dump() :: [map()]
  def dump, do: dump([])

  @spec dump(keyword()) :: [map()]
  def dump(filters) do
    entries = :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))

    Enum.reduce(filters, entries, fn
      {:provider_id, pid}, acc -> Enum.filter(acc, &(&1.provider_id == pid))
      {:category, cat}, acc -> Enum.filter(acc, &(&1.category == cat))
      {:code, code}, acc -> Enum.filter(acc, &(&1.code == code))
      {:classification_path, path}, acc -> Enum.filter(acc, &(&1.classification_path == path))
      {:control_category, cat}, acc -> Enum.filter(acc, &(&1.control_category == cat))
      {:shared_control?, shared?}, acc -> Enum.filter(acc, &(&1.shared_control? == shared?))
      _, acc -> acc
    end)
  end

  @spec clear() :: true
  def clear, do: :ets.delete_all_objects(@table)

  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc "Returns bounded diagnostic ingress counters."
  @spec ingress_stats() :: %{
          queued: non_neg_integer(),
          dropped: non_neg_integer(),
          limit: pos_integer()
        }
  def ingress_stats do
    case :ets.lookup(@admission_table, :queue) do
      [{:queue, queued, dropped}] -> %{queued: queued, dropped: dropped, limit: @queue_limit}
    end
  end

  @spec configure(map()) :: :ok
  def configure(new_config) when is_map(new_config) do
    GenServer.call(__MODULE__, {:configure, new_config})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    admission =
      :ets.new(@admission_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(admission, [{:config, @default_config, self()}, {:queue, 0, 0}])

    :telemetry.attach(
      "error-classification-store",
      [:lasso, :error_classification, :classified],
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    {:ok, %{table: table, admission: :ets.whereis(admission), config: @default_config}}
  end

  @spec handle_telemetry_event(term(), term(), map(), term()) :: :ok
  def handle_telemetry_event(_event, _measurements, metadata, _handler_config) do
    admission = :ets.whereis(@admission_table)
    [{:config, config, owner}] = :ets.lookup(admission, :config)

    if should_sample?(metadata, config) do
      metadata =
        Map.take(metadata, [
          :code,
          :message_fingerprint,
          :data_kind,
          :provider_id,
          :category,
          :classification_path,
          :control_category,
          :shared_control?
        ])

      if :erlang.external_size(metadata) <= @metadata_byte_limit do
        queued = :ets.update_counter(admission, :queue, {2, 1})

        if queued <= @queue_limit do
          GenServer.cast(owner, {:record_admitted, metadata})
        else
          :ets.update_counter(admission, :queue, [{2, -1}, {3, 1}])
        end
      else
        :ets.update_counter(admission, :queue, {3, 1})
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_cast({:record_admitted, metadata}, state) do
    :ets.update_counter(state.admission, :queue, {2, -1})
    record_entry(metadata, state)

    {:noreply, state}
  end

  @impl true
  def handle_call({:configure, new_config}, _from, state) do
    merged = Map.merge(state.config, new_config)

    if is_integer(merged.max_entries) and merged.max_entries > 0 and
         is_number(merged.random_sample_rate) and merged.random_sample_rate >= 0 and
         merged.random_sample_rate <= 1 and
         is_list(merged.sample_all_codes) and is_boolean(merged.enabled) do
      :ets.insert(@admission_table, {:config, merged, self()})
      {:reply, :ok, %{state | config: merged}}
    else
      {:reply, {:error, :invalid_config}, state}
    end
  end

  defp should_sample?(_metadata, %{enabled: false}), do: false

  defp should_sample?(%{code: code}, %{sample_all_codes: codes, random_sample_rate: rate}) do
    code in codes or :rand.uniform() < rate
  end

  defp should_sample?(_, _), do: false

  defp record_entry(metadata, state) do
    fingerprint = metadata[:message_fingerprint]
    category = metadata[:category]
    classification_path = metadata[:classification_path]
    control_category = metadata[:control_category] || category
    shared_control? = metadata[:shared_control?] || false

    key =
      {metadata[:provider_id], metadata[:code], category, classification_path, control_category,
       shared_control?, fingerprint}

    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, existing}] ->
        updated = %{existing | last_seen: now, count: existing.count + 1}
        :ets.insert(@table, {key, updated})

      [] ->
        maybe_evict(state)

        entry = %{
          code: metadata[:code],
          message_fingerprint: fingerprint,
          data_kind: metadata[:data_kind],
          provider_id: metadata[:provider_id],
          category: category,
          classification_path: classification_path,
          control_category: control_category,
          shared_control?: shared_control?,
          retriable?: Lasso.Core.Support.ErrorClassification.retriable_for_category?(category),
          first_seen: now,
          last_seen: now,
          count: 1
        }

        :ets.insert(@table, {key, entry})
    end
  end

  defp maybe_evict(%{config: %{max_entries: max}}) do
    if :ets.info(@table, :size) >= max do
      oldest =
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_k, v} -> v.last_seen end)
        |> Enum.take(max(div(max, 10), 1))

      Enum.each(oldest, fn {k, _v} -> :ets.delete(@table, k) end)
    end
  end
end
