defmodule Lasso.Core.Support.CredentialHealth do
  @moduledoc """
  Bounded health evidence for operator-managed upstream credentials.

  Three authentication failures from one dispatched instance within two minutes
  activate a credential alert. A successful attempt from that same instance
  resolves it. The tracker reads terminal attempts, so a request that succeeds
  after failover still records the failed upstream. Active states are shared
  across connected nodes for operator views. It never changes routing.
  """

  use GenServer

  require Logger

  alias Lasso.Providers.Catalog

  @health_event [:lasso, :provider, :credential_health]
  @topic "lasso:provider:credential_health"
  @markers :lasso_credential_health_markers
  @window_ms 120_000
  @heartbeat_ms 60_000
  @remote_stale_ms 180_000
  @max_local_instances 2_048
  @max_remote_instances 4_096
  @threshold 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Active credential failures, grouped by profile and provider across connected nodes."
  @spec active(String.t() | nil) :: [map()]
  def active(profile \\ nil), do: GenServer.call(__MODULE__, {:active, profile})

  @doc "Clears a failed instance after an observed successful upstream attempt."
  @spec observe_success(term()) :: :ok
  def observe_success(instance_id) when is_binary(instance_id) do
    if :ets.member(@markers, instance_id) do
      GenServer.cast(__MODULE__, {:success, instance_id})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def observe_success(_instance_id), do: :ok

  @doc "Records a dispatched upstream authentication failure without changing routing."
  @spec observe_failure(term()) :: :ok
  def observe_failure(%{error_category: :auth_error} = attempt) do
    GenServer.cast(
      __MODULE__,
      {:auth_error, Map.take(attempt, [:upstream_instance_id, :provider_id, :chain_id])}
    )

    :ok
  end

  def observe_failure(_attempt), do: :ok

  @impl true
  def init(_opts) do
    :ets.new(@markers, [:named_table, :set, :public, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, @topic)
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:ok, %{instances: %{}, remote: %{}}}
  end

  @impl true
  def handle_cast(
        {:auth_error,
         %{upstream_instance_id: instance_id, provider_id: provider_id, chain_id: chain_id}},
        state
      )
      when is_binary(instance_id) and is_binary(provider_id) and is_integer(chain_id) do
    profiles = monitored_profiles(instance_id)

    if profiles == [] do
      {:noreply, state}
    else
      now_ms = System.system_time(:millisecond)
      previous = Map.get(state.instances, instance_id)

      if is_nil(previous) and map_size(state.instances) >= @max_local_instances do
        {:noreply, state}
      else
        entry =
          cond do
            is_nil(previous) ->
              new_entry(instance_id, provider_id, chain_id, profiles, now_ms)

            previous.active? ->
              %{previous | last_seen_ms: now_ms, count: previous.count + 1}

            now_ms - previous.first_seen_ms > @window_ms ->
              new_entry(instance_id, provider_id, chain_id, profiles, now_ms)

            true ->
              %{previous | last_seen_ms: now_ms, count: previous.count + 1}
          end

        entry = %{entry | active?: entry.count >= @threshold}
        :ets.insert(@markers, {instance_id, true})
        state = put_in(state.instances[instance_id], entry)

        if entry.active? and not (previous && previous.active?) do
          emit_transition(:active, entry, state)
        end

        {:noreply, state}
      end
    end
  end

  def handle_cast({:auth_error, _metadata}, state), do: {:noreply, state}

  def handle_cast({:success, instance_id}, state) do
    {entry, instances} = Map.pop(state.instances, instance_id)
    :ets.delete(@markers, instance_id)
    state = %{state | instances: instances}

    if entry && entry.active?, do: emit_transition(:resolved, entry, state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:credential_health, origin, status, entry}, state)
      when origin != node() and status in [:active, :resolved] do
    key = {origin, entry.instance_id}

    remote =
      case status do
        :resolved ->
          Map.delete(state.remote, key)

        :active
        when map_size(state.remote) < @max_remote_instances or is_map_key(state.remote, key) ->
          Map.put(
            state.remote,
            key,
            Map.put(entry, :reported_at_ms, System.system_time(:millisecond))
          )

        :active ->
          state.remote
      end

    {:noreply, %{state | remote: remote}}
  end

  def handle_info({:credential_health, _origin, _status, _entry}, state), do: {:noreply, state}

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
      :ets.delete(@markers, entry.instance_id)
      if entry.active?, do: broadcast(:resolved, entry)
    end)

    remote =
      Map.reject(state.remote, fn {_key, entry} ->
        now_ms - entry.reported_at_ms > @remote_stale_ms
      end)

    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, %{state | instances: instances, remote: remote}}
  end

  @impl true
  def handle_call({:active, profile}, _from, state) do
    active =
      (Map.values(state.instances) ++ Map.values(state.remote))
      |> Enum.filter(& &1.active?)
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

    {:reply, active, state}
  end

  defp new_entry(instance_id, provider_id, chain_id, profiles, now_ms) do
    %{
      instance_id: instance_id,
      provider_id: provider_id,
      chain_id: chain_id,
      profiles: profiles,
      first_seen_ms: now_ms,
      last_seen_ms: now_ms,
      count: 1,
      active?: false
    }
  end

  defp monitored_profiles(instance_id) do
    configured = Application.get_env(:lasso, :credential_health_profiles, :all)

    instance_id
    |> Catalog.get_instance_refs()
    |> Enum.filter(fn profile -> configured == :all or profile in configured end)
  end

  defp emit_transition(status, entry, state) do
    affected =
      (Map.values(state.instances) ++ Map.values(state.remote))
      |> Enum.filter(fn candidate ->
        candidate.active? and candidate.provider_id == entry.provider_id and
          Enum.any?(candidate.profiles, &(&1 in entry.profiles))
      end)

    first_seen_ms =
      [entry | affected]
      |> Enum.map(& &1.first_seen_ms)
      |> Enum.min()

    chain_count = affected |> Enum.map(& &1.chain_id) |> Enum.uniq() |> length()

    metadata = %{
      status: status,
      provider_id: entry.provider_id,
      profiles: entry.profiles,
      chain_count: chain_count,
      first_seen_ms: first_seen_ms
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
