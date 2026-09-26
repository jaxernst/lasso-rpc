defmodule Lasso.Core.Support.CredentialHealth do
  @moduledoc """
  Bounded evidence for operator-managed upstream credential failures.

  Three dispatched authentication failures for one instance in a rolling
  two-minute window activate an alert. A later success from that instance
  resolves it, even when failures are still queued. Connected nodes share
  active states. This observer never changes routing.
  """

  use GenServer

  require Logger

  alias Lasso.Providers.Catalog

  @health_event [:lasso, :provider, :credential_health]
  @drop_event [:lasso, :provider, :credential_health, :dropped]
  @topic "lasso:provider:credential_health"
  @markers :lasso_credential_health_markers
  @active :lasso_credential_health_active
  @queue :lasso_credential_health_queue
  @reservations :lasso_credential_health_reservations
  @successes :lasso_credential_health_pending_successes
  @window_ms 120_000
  @heartbeat_ms 60_000
  @maintenance_ms 5_000
  @reservation_ttl_ms 10_000
  @remote_stale_ms 180_000
  @max_pending_failures 1_024
  @reservation_probes 32
  @max_local_instances 2_048
  @max_markers 3_072
  @max_remote_instances 4_096
  @threshold 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Active credential failures grouped by profile and provider across connected nodes."
  @spec active(String.t() | nil) :: [map()]
  def active(profile \\ nil) do
    @active
    |> :ets.tab2list()
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.flat_map(fn entry ->
      for ref <- entry.profiles, is_nil(profile) or ref == profile do
        %{
          profile: ref,
          provider_id: entry.provider_id,
          chain_id: entry.chain_id,
          first_seen_ms: entry.first_seen_ms,
          last_seen_ms: entry.last_seen_ms,
          instance_id: entry.instance_id
        }
      end
    end)
    |> Enum.group_by(&{&1.profile, &1.provider_id})
    |> Enum.map(fn {{ref, provider_id}, entries} ->
      %{
        profile: ref,
        provider_id: provider_id,
        chain_count: entries |> Enum.map(& &1.chain_id) |> Enum.uniq() |> length(),
        first_seen_ms: entries |> Enum.map(& &1.first_seen_ms) |> Enum.min(),
        last_seen_ms: entries |> Enum.map(& &1.last_seen_ms) |> Enum.max(),
        instance_count: entries |> Enum.map(& &1.instance_id) |> Enum.uniq() |> length(),
        instance_ids: entries |> Enum.map(& &1.instance_id) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(&{&1.profile, &1.provider_id})
  rescue
    ArgumentError -> []
  end

  @doc "Queue occupancy and dropped authentication observations, available even if the observer stalls."
  @spec stats() :: %{pending_failures: non_neg_integer(), dropped_failures: non_neg_integer()}
  def stats do
    pending = :ets.info(@reservations, :size)

    %{
      pending_failures: if(is_integer(pending), do: pending, else: 0),
      dropped_failures: :ets.lookup_element(@queue, :dropped, 2)
    }
  rescue
    ArgumentError -> %{pending_failures: 0, dropped_failures: 0}
  end

  @doc "Clears failures after a successful attempt from the same upstream instance."
  @spec observe_success(term()) :: :ok
  def observe_success(instance_id) when is_binary(instance_id) do
    if :ets.member(@markers, instance_id) do
      enqueue_success(instance_id, System.unique_integer([:monotonic, :positive]))
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def observe_success(_instance_id), do: :ok

  @doc "Records a dispatched upstream authentication rejection without changing routing."
  @spec observe_failure(term()) :: :ok
  def observe_failure(%{
        error_category: :auth_error,
        upstream_instance_id: instance_id,
        provider_id: provider_id,
        chain_id: chain_id
      })
      when is_binary(instance_id) and is_binary(provider_id) and is_integer(chain_id) do
    profiles = monitored_profiles(instance_id)

    occurred_ms = System.system_time(:millisecond)
    seq = System.unique_integer([:monotonic, :positive])

    if profiles != [] and admit_marker(instance_id) do
      case reserve_failure(instance_id, seq, occurred_ms) do
        {:ok, slot} ->
          GenServer.cast(
            __MODULE__,
            {:auth_error, instance_id, provider_id, chain_id, profiles, occurred_ms, seq, slot}
          )

        :full ->
          record_drop()
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def observe_failure(_attempt), do: :ok

  @impl true
  def init(_opts) do
    :ets.new(@markers, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@active, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@queue, [:named_table, :set, :public, write_concurrency: true])
    :ets.insert(@queue, {:dropped, 0})
    :ets.new(@reservations, [:named_table, :set, :public, write_concurrency: true])
    :ets.new(@successes, [:named_table, :set, :public, write_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, @topic)
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    Process.send_after(self(), :maintenance, @maintenance_ms)
    {:ok, %{instances: %{}, remote: %{}, recoveries: %{}, reported_drops: 0}}
  end

  @impl true
  def handle_cast(
        {:auth_error, id, provider_id, chain_id, profiles, occurred_ms, seq, slot},
        state
      ) do
    if consume_failure(slot, id, seq, occurred_ms) do
      recovered_seq = state.recoveries |> Map.get(id, {0, 0}) |> elem(0)

      state =
        if pending_for_id?(id),
          do: state,
          else: %{state | recoveries: Map.delete(state.recoveries, id)}

      previous = Map.get(state.instances, id)

      cond do
        seq <= recovered_seq or System.system_time(:millisecond) - occurred_ms > @window_ms ->
          prune_marker(id, previous, seq)
          {:noreply, state}

        is_nil(previous) and map_size(state.instances) >= @max_local_instances ->
          prune_marker(id, nil, seq)
          {:noreply, state}

        true ->
          entry = record_failure(previous, id, provider_id, chain_id, profiles, occurred_ms, seq)
          state = put_in(state.instances[id], entry)

          if entry.active? do
            :ets.insert(@active, {{:local, id}, entry})
          end

          if entry.active? and not (previous != nil and previous.active?),
            do: emit_transition(:active, entry, state)

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_cast({:success, id}, state) do
    case :ets.take(@successes, id) do
      [{^id, seq}] -> {:noreply, resolve_success(state, id, seq)}
      [] -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:credential_health, origin, status, entry}, state)
      when origin != node() and status in [:active, :resolved] do
    key = {origin, entry.instance_id}

    remote =
      case status do
        :resolved ->
          :ets.delete(@active, key)
          Map.delete(state.remote, key)

        :active
        when map_size(state.remote) < @max_remote_instances or is_map_key(state.remote, key) ->
          updated = Map.put(entry, :reported_at_ms, System.system_time(:millisecond))
          :ets.insert(@active, {key, updated})
          Map.put(state.remote, key, updated)

        :active ->
          state.remote
      end

    {:noreply, %{state | remote: remote}}
  end

  def handle_info({:credential_health, _origin, _status, _entry}, state), do: {:noreply, state}

  def handle_info(:maintenance, state) do
    now_ms = System.system_time(:millisecond)

    expired =
      @reservations
      |> :ets.tab2list()
      |> Enum.count(fn {slot, id, seq, occurred_ms} ->
        now_ms - occurred_ms > @reservation_ttl_ms and
          consume_failure(slot, id, seq, occurred_ms)
      end)

    if expired > 0, do: :ets.update_counter(@queue, :dropped, {2, expired})

    state =
      @successes
      |> :ets.tab2list()
      |> Enum.reduce(state, fn {id, _seq}, acc ->
        case :ets.take(@successes, id) do
          [{^id, seq}] -> resolve_success(acc, id, seq)
          [] -> acc
        end
      end)

    state = %{
      state
      | recoveries: Map.reject(state.recoveries, fn {id, _value} -> not pending_for_id?(id) end)
    }

    Enum.each(:ets.tab2list(@markers), fn {id, marked_ms, marker_seq} ->
      if not Map.has_key?(state.instances, id) and
           now_ms - marked_ms > @reservation_ttl_ms and not pending_for_id?(id) do
        :ets.select_delete(@markers, [{{id, marked_ms, marker_seq}, [], [true]}])
      end
    end)

    Process.send_after(self(), :maintenance, @maintenance_ms)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    now_ms = System.system_time(:millisecond)

    {instances, removed} =
      Enum.reduce(state.instances, {%{}, []}, fn {id, entry}, {kept, dropped} ->
        cond do
          entry.active? and match?({:ok, _}, Catalog.get_instance(id)) ->
            broadcast(:active, entry)
            {Map.put(kept, id, entry), dropped}

          entry.active? ->
            {kept, [entry | dropped]}

          now_ms - entry.last_seen_ms <= @window_ms ->
            {Map.put(kept, id, entry), dropped}

          true ->
            {kept, [entry | dropped]}
        end
      end)

    Enum.each(removed, fn entry ->
      :ets.delete(@active, {:local, entry.instance_id})
      prune_marker(entry.instance_id, nil)
      if entry.active?, do: broadcast(:resolved, entry)
    end)

    remote =
      Map.reject(state.remote, fn {key, entry} ->
        stale? = now_ms - entry.reported_at_ms > @remote_stale_ms
        if stale?, do: :ets.delete(@active, key)
        stale?
      end)

    recoveries =
      Map.reject(state.recoveries, fn {_id, {_seq, at_ms}} ->
        now_ms - at_ms > @remote_stale_ms
      end)

    dropped = :ets.lookup_element(@queue, :dropped, 2)

    if dropped > state.reported_drops do
      count = dropped - state.reported_drops
      Logger.warning("Credential health observations dropped", dropped: count)
      :telemetry.execute(@drop_event, %{count: count}, %{})
    end

    Process.send_after(self(), :heartbeat, @heartbeat_ms)

    {:noreply,
     %{
       state
       | instances: instances,
         remote: remote,
         recoveries: recoveries,
         reported_drops: dropped
     }}
  end

  defp resolve_success(state, id, seq) do
    previous = Map.get(state.instances, id)

    retained =
      if previous,
        do: Enum.filter(previous.failures, fn {_at_ms, failure_seq} -> failure_seq > seq end),
        else: []

    entry =
      cond do
        retained == [] -> nil
        previous -> build_entry(previous, retained)
      end

    instances =
      if entry, do: Map.put(state.instances, id, entry), else: Map.delete(state.instances, id)

    recoveries =
      if pending_for_id?(id) do
        previous_seq = state.recoveries |> Map.get(id, {0, 0}) |> elem(0)

        Map.put(
          state.recoveries,
          id,
          {max(seq, previous_seq), System.system_time(:millisecond)}
        )
      else
        Map.delete(state.recoveries, id)
      end

    state = %{state | instances: instances, recoveries: recoveries}

    if entry && entry.active? do
      :ets.insert(@active, {{:local, id}, entry})
    else
      :ets.delete(@active, {:local, id})
      prune_marker(id, entry, seq)
    end

    if previous && previous.active? && not (entry != nil and entry.active?),
      do: emit_transition(:resolved, previous, state)

    state
  end

  defp record_failure(nil, id, provider_id, chain_id, profiles, occurred_ms, seq) do
    build_entry(
      %{
        instance_id: id,
        provider_id: provider_id,
        chain_id: chain_id,
        profiles: profiles
      },
      [{occurred_ms, seq}]
    )
  end

  defp record_failure(previous, _id, _provider_id, _chain_id, _profiles, occurred_ms, seq) do
    failures =
      [{occurred_ms, seq} | previous.failures]
      |> Enum.filter(fn {at_ms, _} -> occurred_ms - at_ms <= @window_ms end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(-@threshold)

    entry = build_entry(previous, failures)

    if previous.active?,
      do: %{entry | active?: true, first_seen_ms: previous.first_seen_ms},
      else: entry
  end

  defp build_entry(base, failures) do
    times = Enum.map(failures, &elem(&1, 0))

    base
    |> Map.put(:failures, failures)
    |> Map.put(:first_seen_ms, Enum.min(times))
    |> Map.put(:last_seen_ms, Enum.max(times))
    |> Map.put(:active?, length(failures) >= @threshold)
  end

  defp monitored_profiles(instance_id) do
    configured = Application.get_env(:lasso, :credential_health_profiles, :all)

    instance_id
    |> Catalog.get_instance_refs()
    |> Enum.filter(fn profile -> configured == :all or profile in configured end)
  end

  defp reserve_failure(id, seq, occurred_ms) do
    start_slot = rem(seq, @max_pending_failures)

    Enum.reduce_while(0..(@reservation_probes - 1), :full, fn offset, _acc ->
      slot = rem(start_slot + offset, @max_pending_failures)

      if :ets.insert_new(@reservations, {slot, id, seq, occurred_ms}),
        do: {:halt, {:ok, slot}},
        else: {:cont, :full}
    end)
  end

  defp consume_failure(slot, id, seq, occurred_ms) do
    :ets.select_delete(@reservations, [{{slot, id, seq, occurred_ms}, [], [true]}]) == 1
  end

  defp pending_for_id?(id), do: :ets.match_object(@reservations, {:_, id, :_, :_}) != []

  defp record_drop, do: :ets.update_counter(@queue, :dropped, {2, 1})

  defp admit_marker(id) do
    if :ets.member(@markers, id) or :ets.info(@markers, :size) < @max_markers do
      :ets.insert(
        @markers,
        {id, System.system_time(:millisecond), System.unique_integer([:monotonic, :positive])}
      )

      true
    else
      false
    end
  end

  defp prune_marker(id, entry, through_seq \\ :infinity) do
    if is_nil(entry) and not pending_for_id?(id) do
      case :ets.lookup(@markers, id) do
        [{^id, marked_ms, marker_seq}]
        when through_seq == :infinity or marker_seq <= through_seq ->
          :ets.select_delete(@markers, [{{id, marked_ms, marker_seq}, [], [true]}])

        _ ->
          :ok
      end
    end

    :ok
  end

  defp enqueue_success(id, seq) do
    if :ets.insert_new(@successes, {id, seq}) do
      GenServer.cast(__MODULE__, {:success, id})
    else
      case :ets.lookup(@successes, id) do
        [{^id, old}] when old < seq ->
          case :ets.select_replace(@successes, [{{id, old}, [], [{{id, seq}}]}]) do
            1 -> :ok
            0 -> enqueue_success(id, seq)
          end

        [{^id, _newer}] ->
          :ok

        [] ->
          enqueue_success(id, seq)
      end
    end
  end

  defp emit_transition(status, entry, state) do
    affected =
      (Map.values(state.instances) ++ Map.values(state.remote))
      |> Enum.filter(fn candidate ->
        candidate.active? and candidate.provider_id == entry.provider_id and
          Enum.any?(candidate.profiles, &(&1 in entry.profiles))
      end)

    metadata = %{
      status: status,
      provider_id: entry.provider_id,
      profiles: entry.profiles,
      chain_count: affected |> Enum.map(& &1.chain_id) |> Enum.uniq() |> length(),
      first_seen_ms: entry.first_seen_ms
    }

    if status == :active do
      Logger.error("Managed upstream credential authentication failures", Map.to_list(metadata))
    else
      Logger.info("Managed upstream credential recovered", Map.to_list(metadata))
    end

    :telemetry.execute(@health_event, %{count: 1}, metadata)
    broadcast(status, entry)
  end

  defp broadcast(status, entry) do
    Phoenix.PubSub.broadcast(Lasso.PubSub, @topic, {:credential_health, node(), status, entry})
  end
end
