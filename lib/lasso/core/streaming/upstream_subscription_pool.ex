defmodule Lasso.Core.Streaming.UpstreamSubscriptionPool do
  @moduledoc """
  Per-chain pool that multiplexes client subscriptions onto minimal upstream
  subscriptions. Supports single-provider policy with priority selection,
  failover on disconnect/close, bounded backfill, and simple dedupe.

  ## Architecture

  Uses InstanceSubscriptionManager for upstream subscription lifecycle:
  - Resolves provider_id → instance_id via Catalog
  - Calls InstanceSubscriptionManager.ensure_subscription for shared upstream subs
  - Registers in InstanceSubscriptionRegistry to receive events
  - Translates instance_id events back to profile-specific provider_id
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Events.{Provider, Subscription}
  alias Lasso.Providers.Catalog

  alias Lasso.RPC.{
    Channel,
    Selection
  }

  alias Lasso.Core.Streaming.{
    ClientSubscriptionRegistry,
    InstanceSubscriptionManager,
    InstanceSubscriptionRegistry,
    StreamCoordinator,
    StreamSupervisor
  }

  @max_noproc_retries 5

  @type profile :: String.t()
  @type chain :: String.t()
  @type provider_id :: String.t()
  @type key :: {:newHeads} | {:logs, map()}

  @spec start_link({String.t(), String.t()}) :: GenServer.on_start()
  def start_link({profile, chain}) when is_binary(profile) and is_binary(chain) do
    GenServer.start_link(__MODULE__, {profile, chain}, name: via(profile, chain))
  end

  @spec via(String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain) when is_binary(profile) and is_binary(chain) do
    {:via, Registry, {Lasso.Registry, {:pool, profile, chain}}}
  end

  @spec subscribe_client(profile, chain, pid(), key) :: {:ok, String.t()} | {:error, term()}
  def subscribe_client(profile, chain, client_pid, key)
      when is_binary(profile) and is_binary(chain) do
    GenServer.call(via(profile, chain), {:subscribe, client_pid, key})
  end

  @spec unsubscribe_client(profile, chain, String.t()) :: :ok | {:error, term()}
  def unsubscribe_client(profile, chain, subscription_id)
      when is_binary(profile) and is_binary(chain) do
    GenServer.call(via(profile, chain), {:unsubscribe, subscription_id})
  end

  # GenServer callbacks

  @impl true
  def init({profile, chain}) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, Provider.topic(profile, chain))

    # Chain-scoped restart topic (Pool doesn't know instance_ids at init)
    Phoenix.PubSub.subscribe(Lasso.PubSub, "instance_sub_manager:restarted:#{chain}")

    dedupe_cfg =
      case ConfigStore.get_chain(profile, chain) do
        {:ok, cfg} -> Map.get(cfg, :dedupe, %{})
        _ -> %{}
      end

    state = %{
      profile: profile,
      chain: chain,
      # key => %{refcount, primary_provider_id, instance_id, status, markers, dedupe, noproc_retries}
      keys: %{},
      dedupe_max_items: Map.get(dedupe_cfg, :max_items, 256),
      dedupe_max_age_ms: Map.get(dedupe_cfg, :max_age_ms, 30_000),
      max_backfill_blocks: 32,
      backfill_timeout: 30_000
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, client_pid, key}, _from, state) do
    subscription_id = generate_id()

    :ok =
      ClientSubscriptionRegistry.add_client(
        state.profile,
        state.chain,
        subscription_id,
        client_pid,
        key
      )

    _ = start_coordinator_for_key(state, key)

    new_state =
      case Map.get(state.keys, key) do
        nil ->
          GenServer.cast(self(), {:establish_upstream, key, []})

          entry = %{
            refcount: 1,
            status: :establishing,
            primary_provider_id: nil,
            instance_id: nil,
            markers: %{},
            dedupe: nil,
            noproc_retries: 0
          }

          telemetry_subscription_status(:establishing, state.chain, key, 1)
          %{state | keys: Map.put(state.keys, key, entry)}

        entry when entry.status in [:establishing, :active] ->
          updated = %{entry | refcount: entry.refcount + 1}
          telemetry_subscription_status(entry.status, state.chain, key, updated.refcount)
          %{state | keys: Map.put(state.keys, key, updated)}

        entry when entry.status == :failed ->
          GenServer.cast(self(), {:establish_upstream, key, []})

          updated = %{
            entry
            | refcount: entry.refcount + 1,
              status: :establishing,
              noproc_retries: 0
          }

          telemetry_subscription_status(:retry, state.chain, key, updated.refcount)
          %{state | keys: Map.put(state.keys, key, updated)}
      end

    {:reply, {:ok, subscription_id}, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case ClientSubscriptionRegistry.remove_client(state.profile, state.chain, subscription_id) do
      {:ok, nil} ->
        {:reply, :ok, state}

      {:ok, key} ->
        new_state = maybe_drop_upstream_when_unref(state, key)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:resubscribe, key, new_provider_id, coordinator_pid}, state) do
    Logger.info("Resubscribing key #{inspect(key)} to provider #{new_provider_id}")

    entry = Map.get(state.keys, key)

    if entry do
      old_provider_id = entry.primary_provider_id
      old_instance_id = entry.instance_id

      new_instance_id =
        Catalog.lookup_instance_id(state.profile, state.chain, new_provider_id)

      if is_nil(new_instance_id) do
        Logger.error("Cannot resolve instance_id for provider #{new_provider_id}")
        send(coordinator_pid, {:subscription_failed, :no_instance})
        {:noreply, state}
      else
        # Register in InstanceSubscriptionRegistry for events from new instance
        InstanceSubscriptionRegistry.register_consumer(new_instance_id, key)

        case InstanceSubscriptionManager.ensure_subscription(new_instance_id, key) do
          {:ok, _status} ->
            updated_entry =
              Map.merge(entry, %{
                primary_provider_id: new_provider_id,
                instance_id: new_instance_id,
                status: :active,
                transitioning_from: old_provider_id,
                transitioning_from_instance_id: old_instance_id
              })

            new_state = %{state | keys: Map.put(state.keys, key, updated_entry)}

            send(coordinator_pid, {:subscription_confirmed, new_provider_id, nil})
            telemetry_resubscribe_success(state.chain, key, new_provider_id)

            if old_instance_id do
              Process.send_after(
                self(),
                {:deferred_release, key, old_provider_id, old_instance_id},
                5_000
              )
            end

            {:noreply, new_state}

          {:error, reason} ->
            InstanceSubscriptionRegistry.unregister_consumer(new_instance_id, key)

            Logger.error(
              "Resubscription failed for #{inspect(key)} to #{new_provider_id}: #{inspect(reason)}"
            )

            send(coordinator_pid, {:subscription_failed, reason})
            telemetry_resubscribe_failed(state.chain, key, new_provider_id, reason)
            {:noreply, state}
        end
      end
    else
      Logger.debug("Resubscription skipped: key #{inspect(key)} no longer active")
      send(coordinator_pid, {:subscription_failed, :key_inactive})
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:establish_upstream, key, excluded_providers}, state) do
    with {:ok, entry} <- validate_entry_for_establishment(state.keys[key]),
         {:ok, provider_id} <-
           select_available_provider(state.profile, state.chain, excluded_providers),
         {:ok, instance_id} <- resolve_instance_id(state, provider_id),
         {:ok, _status} <- attempt_upstream_subscribe(provider_id, instance_id, key) do
      InstanceSubscriptionRegistry.register_consumer(instance_id, key)

      new_state = activate_subscription(state, key, entry, provider_id, instance_id)

      Logger.info(
        "Upstream subscription established for key #{inspect(key)} on provider #{provider_id}"
      )

      broadcast_subscription_event(state, %Subscription.Established{
        ts: System.system_time(:millisecond),
        chain: state.chain,
        provider_id: provider_id,
        subscription_type: Subscription.subscription_type(key)
      })

      telemetry_upstream(:subscribe, state.chain, provider_id, key)
      telemetry_subscription_status(:active, state.chain, key, entry.refcount)

      {:noreply, new_state}
    else
      {:error, :entry_invalid} ->
        {:noreply, state}

      {:error, :no_providers} ->
        new_state = mark_subscription_failed(state, key, "No available providers")
        {:noreply, new_state}

      {:error, :no_instance} ->
        new_state = mark_subscription_failed(state, key, "Cannot resolve instance")
        {:noreply, new_state}

      {:error, {:noproc, _instance_id}} ->
        entry = state.keys[key]
        retries = if entry, do: entry.noproc_retries, else: 0

        if retries < @max_noproc_retries do
          Process.send_after(self(), {:retry_establish, key}, 1_000)
          new_state = update_entry_field(state, key, entry, :noproc_retries, retries + 1)
          {:noreply, new_state}
        else
          new_state = update_entry_field(state, key, entry, :noproc_retries, 0)
          do_handle_subscription_failure(new_state, key, excluded_providers)
        end

      {:error, {:subscribe_failed, provider_id, _reason}} ->
        new_excluded = [provider_id | excluded_providers]
        do_handle_subscription_failure(state, key, new_excluded)
    end
  end

  defp validate_entry_for_establishment(nil), do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry) when entry.status != :establishing,
    do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry) when entry.refcount < 1,
    do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry), do: {:ok, entry}

  defp select_available_provider(profile, chain, excluded_providers) do
    channels =
      Selection.select_channels(profile, chain, "eth_subscribe",
        strategy: :priority,
        transport: :ws,
        limit: 1
      )

    case Enum.find(channels, fn ch -> ch.provider_id not in excluded_providers end) do
      %Channel{provider_id: provider_id} ->
        {:ok, provider_id}

      nil ->
        Logger.error("No available WS channels (excluded: #{inspect(excluded_providers)})")
        {:error, :no_providers}
    end
  end

  defp resolve_instance_id(state, provider_id) do
    case Catalog.lookup_instance_id(state.profile, state.chain, provider_id) do
      nil ->
        Logger.error("Cannot resolve instance_id for provider #{provider_id}")
        {:error, :no_instance}

      instance_id ->
        {:ok, instance_id}
    end
  end

  defp attempt_upstream_subscribe(provider_id, instance_id, key) do
    Logger.debug(
      "Attempting upstream subscribe via instance #{instance_id} for key #{inspect(key)}"
    )

    case InstanceSubscriptionManager.ensure_subscription(instance_id, key) do
      {:ok, status} ->
        {:ok, status}

      {:error, :noproc} ->
        {:error, {:noproc, instance_id}}

      {:error, reason} ->
        Logger.warning("Upstream subscribe failed on instance #{instance_id}: #{inspect(reason)}")
        {:error, {:subscribe_failed, provider_id, reason}}
    end
  end

  defp update_entry_field(state, _key, nil, _field, _value), do: state

  defp update_entry_field(state, key, entry, field, value) do
    updated = Map.put(entry, field, value)
    %{state | keys: Map.put(state.keys, key, updated)}
  end

  defp activate_subscription(state, key, entry, provider_id, instance_id) do
    updated_entry = %{
      entry
      | status: :active,
        primary_provider_id: provider_id,
        instance_id: instance_id,
        noproc_retries: 0
    }

    %{state | keys: Map.put(state.keys, key, updated_entry)}
  end

  defp do_handle_subscription_failure(state, key, excluded_providers) do
    max_attempts = 3

    if length(excluded_providers) < max_attempts do
      Logger.info(
        "Retrying upstream establishment for #{inspect(key)} (attempt #{length(excluded_providers) + 1}/#{max_attempts})"
      )

      GenServer.cast(self(), {:establish_upstream, key, excluded_providers})
      {:noreply, state}
    else
      Logger.error(
        "Failed to establish upstream for #{inspect(key)} after #{max_attempts} attempts"
      )

      new_state = mark_subscription_failed(state, key, "Max retries exceeded")
      {:noreply, new_state}
    end
  end

  defp mark_subscription_failed(state, key, reason) do
    case state.keys[key] do
      nil ->
        state

      entry ->
        updated_entry = %{entry | status: :failed}

        broadcast_subscription_event(state, %Subscription.Failed{
          ts: System.system_time(:millisecond),
          chain: state.chain,
          provider_id: entry.primary_provider_id,
          subscription_type: Subscription.subscription_type(key),
          reason: reason
        })

        telemetry_subscription_status(:failed, state.chain, key, entry.refcount)
        Logger.error("Subscription failed for #{inspect(key)}: #{reason}")
        %{state | keys: Map.put(state.keys, key, updated_entry)}
    end
  end

  @impl true
  # Events from InstanceSubscriptionManager via InstanceSubscriptionRegistry
  def handle_info(
        {:instance_subscription_event, instance_id, key, payload, received_at},
        state
      )
      when is_map(payload) do
    case Map.get(state.keys, key) do
      %{instance_id: ^instance_id, status: :active} = entry ->
        StreamCoordinator.upstream_event(
          state.profile,
          state.chain,
          key,
          entry.primary_provider_id,
          nil,
          payload,
          received_at
        )

        {:noreply, state}

      %{transitioning_from_instance_id: ^instance_id, status: :active} = entry ->
        StreamCoordinator.upstream_event(
          state.profile,
          state.chain,
          key,
          entry.transitioning_from,
          nil,
          payload,
          received_at
        )

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Deferred release of old instance subscription after transition
  def handle_info({:deferred_release, key, old_provider_id, old_instance_id}, state) do
    case Map.get(state.keys, key) do
      %{transitioning_from: ^old_provider_id} = entry ->
        InstanceSubscriptionManager.release_subscription(old_instance_id, key)
        InstanceSubscriptionRegistry.unregister_consumer(old_instance_id, key)

        updated_entry =
          entry
          |> Map.delete(:transitioning_from)
          |> Map.delete(:transitioning_from_instance_id)

        new_state = %{state | keys: Map.put(state.keys, key, updated_entry)}

        Logger.debug(
          "Deferred release of old provider #{old_provider_id} for key #{inspect(key)}"
        )

        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  # Retry establishment after noproc
  def handle_info({:retry_establish, key}, state) do
    case Map.get(state.keys, key) do
      %{status: :establishing} ->
        GenServer.cast(self(), {:establish_upstream, key, []})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(evt, state)
      when is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.HealthCheckFailed) or
             is_struct(evt, Provider.WSClosed) or
             is_struct(evt, Provider.WSDisconnected) do
    provider_id = Map.get(evt, :provider_id)

    for {key, entry} <- state.keys,
        entry.primary_provider_id == provider_id do
      StreamCoordinator.provider_unhealthy(
        state.profile,
        state.chain,
        key,
        provider_id,
        pick_next_provider(state, provider_id)
      )
    end

    {:noreply, state}
  end

  # Invalidation from InstanceSubscriptionManager
  def handle_info(
        {:instance_subscription_invalidated, instance_id, key, reason},
        state
      ) do
    new_state =
      case Map.get(state.keys, key) do
        %{instance_id: ^instance_id} = entry ->
          handle_subscription_invalidation(
            state,
            entry.primary_provider_id,
            instance_id,
            key,
            reason
          )

        _ ->
          state
      end

    {:noreply, new_state}
  end

  # InstanceSubscriptionManager restarted - schedule async re-establishment for each affected key
  def handle_info({:instance_sub_manager_restarted, instance_id}, state) do
    affected_keys =
      state.keys
      |> Enum.filter(fn {_key, entry} ->
        entry.status == :active and entry.instance_id == instance_id
      end)

    if affected_keys != [] do
      Logger.info(
        "InstanceSubscriptionManager restarted, scheduling re-establishment for #{length(affected_keys)} subscriptions",
        chain: state.chain,
        instance_id: instance_id
      )

      Enum.each(affected_keys, fn {key, _entry} ->
        Process.send_after(self(), {:reestablish_after_restart, key, instance_id}, 100)
      end)
    end

    {:noreply, state}
  end

  # Async re-establishment after Manager restart (one per key, non-blocking)
  def handle_info({:reestablish_after_restart, key, instance_id}, state) do
    case Map.get(state.keys, key) do
      %{instance_id: ^instance_id, status: :active} = entry ->
        InstanceSubscriptionRegistry.register_consumer(instance_id, key)

        case InstanceSubscriptionManager.ensure_subscription(instance_id, key) do
          {:ok, _status} ->
            Logger.debug("Re-established subscription after Manager restart",
              chain: state.chain,
              key: inspect(key),
              instance_id: instance_id
            )

          {:error, reason} ->
            Logger.warning("Failed to re-establish subscription after Manager restart",
              chain: state.chain,
              key: inspect(key),
              instance_id: instance_id,
              reason: inspect(reason)
            )

            StreamCoordinator.provider_unhealthy(
              state.profile,
              state.chain,
              key,
              entry.primary_provider_id,
              pick_next_provider(state, entry.primary_provider_id)
            )
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Staleness: resubscribe to same instance
  defp handle_subscription_invalidation(state, provider_id, instance_id, key, :subscription_stale) do
    Logger.info("Subscription stale, resubscribing to same instance",
      chain: state.chain,
      provider_id: provider_id,
      instance_id: instance_id,
      key: inspect(key)
    )

    case InstanceSubscriptionManager.ensure_subscription(instance_id, key) do
      {:ok, _status} ->
        Logger.debug("Resubscribed after staleness",
          chain: state.chain,
          instance_id: instance_id,
          key: inspect(key)
        )

        state

      {:error, reason} ->
        Logger.warning("Resubscription failed after staleness, failing over",
          chain: state.chain,
          provider_id: provider_id,
          key: inspect(key),
          reason: inspect(reason)
        )

        StreamCoordinator.provider_unhealthy(
          state.profile,
          state.chain,
          key,
          provider_id,
          pick_next_provider(state, provider_id)
        )

        state
    end
  end

  defp handle_subscription_invalidation(state, provider_id, _instance_id, key, reason) do
    Logger.info("Subscription invalidated, failing over",
      chain: state.chain,
      provider_id: provider_id,
      key: inspect(key),
      reason: reason
    )

    StreamCoordinator.provider_unhealthy(
      state.profile,
      state.chain,
      key,
      provider_id,
      pick_next_provider(state, provider_id)
    )

    state
  end

  # Internal helpers

  defp start_coordinator_for_key(state, key) do
    opts = [
      primary_provider_id: Map.get(state.keys[key] || %{}, :primary_provider_id),
      dedupe_max_items: state.dedupe_max_items,
      dedupe_max_age_ms: state.dedupe_max_age_ms,
      max_backfill_blocks: state.max_backfill_blocks,
      backfill_timeout: state.backfill_timeout,
      continuity_policy: :best_effort
    ]

    StreamSupervisor.ensure_coordinator(state.profile, state.chain, key, opts)
  end

  defp pick_next_provider(state, failed_provider_id) do
    case Selection.select_provider(
           state.profile,
           state.chain,
           "eth_subscribe",
           strategy: :priority,
           protocol: :ws,
           exclude: [failed_provider_id]
         ) do
      {:ok, provider} -> provider
      _ -> failed_provider_id
    end
  end

  defp maybe_drop_upstream_when_unref(state, key) do
    case Map.get(state.keys, key) do
      nil ->
        state

      %{refcount: 1, primary_provider_id: provider_id, instance_id: instance_id}
      when not is_nil(provider_id) and not is_nil(instance_id) ->
        InstanceSubscriptionManager.release_subscription(instance_id, key)
        InstanceSubscriptionRegistry.unregister_consumer(instance_id, key)

        telemetry_upstream(:unsubscribe, state.chain, provider_id, key)

        profile = state.profile
        Task.start(fn -> StreamSupervisor.stop_coordinator(profile, state.chain, key) end)

        %{state | keys: Map.delete(state.keys, key)}

      %{refcount: 1} ->
        profile = state.profile
        Task.start(fn -> StreamSupervisor.stop_coordinator(profile, state.chain, key) end)
        %{state | keys: Map.delete(state.keys, key)}

      entry ->
        updated = %{entry | refcount: entry.refcount - 1}
        %{state | keys: Map.put(state.keys, key, updated)}
    end
  end

  defp telemetry_upstream(action, chain, provider_id, key) do
    :telemetry.execute([:lasso, :subs, :upstream, action], %{count: 1}, %{
      chain: chain,
      provider_id: provider_id,
      key: inspect(key)
    })
  end

  defp telemetry_resubscribe_success(chain, key, provider_id) do
    :telemetry.execute([:lasso, :subs, :resubscribe, :success], %{count: 1}, %{
      chain: chain,
      key: inspect(key),
      provider_id: provider_id
    })
  end

  defp telemetry_resubscribe_failed(chain, key, provider_id, reason) do
    :telemetry.execute([:lasso, :subs, :resubscribe, :failed], %{count: 1}, %{
      chain: chain,
      key: inspect(key),
      provider_id: provider_id,
      reason: inspect(reason)
    })
  end

  defp telemetry_subscription_status(status, chain, key, refcount) do
    :telemetry.execute([:lasso, :subs, :status], %{refcount: refcount}, %{
      chain: chain,
      key: inspect(key),
      status: status
    })
  end

  defp broadcast_subscription_event(state, event) do
    topic = Subscription.topic(state.profile, state.chain)
    Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
