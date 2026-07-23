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
  alias Lasso.JSONRPC.Error, as: JError
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

  @max_readiness_retries 50
  @readiness_retry_ms 100

  @type profile :: String.t()
  @type chain_id :: pos_integer()
  @type provider_id :: String.t()
  @type key :: {:newHeads} | {:logs, map()}

  @spec start_link({String.t(), pos_integer()}) :: GenServer.on_start()
  def start_link({profile, chain_id})
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.start_link(__MODULE__, {profile, chain_id}, name: via(profile, chain_id))
  end

  @spec via(String.t(), pos_integer()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain_id) when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    {:via, Registry, {Lasso.Registry, {:pool, profile, chain_id}}}
  end

  @spec subscribe_client(profile, chain_id, pid(), key, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe_client(profile, chain_id, client_pid, key, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    provider_constraint = Keyword.get(opts, :provider_id)
    pool_key = pool_key(key, provider_constraint)

    GenServer.call(
      via(profile, chain_id),
      {:subscribe, client_pid, pool_key, key, provider_constraint}
    )
  end

  @spec unsubscribe_client(profile, chain_id, String.t()) :: :ok | {:error, term()}
  def unsubscribe_client(profile, chain_id, subscription_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), {:unsubscribe, subscription_id})
  end

  # GenServer callbacks

  @impl true
  def init({profile, chain_id}) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.provider_event(profile, chain_id))
    Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.instance_sub_manager_restarted(chain_id))

    dedupe_cfg =
      case ConfigStore.get_chain(profile, chain_id) do
        {:ok, cfg} -> Map.get(cfg, :dedupe, %{})
        _ -> %{}
      end

    state = %{
      profile: profile,
      chain_id: chain_id,
      keys: %{},
      dedupe_max_items: Map.get(dedupe_cfg, :max_items, 256),
      dedupe_max_age_ms: Map.get(dedupe_cfg, :max_age_ms, 30_000),
      max_backfill_blocks: 32,
      backfill_timeout: 30_000
    }

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:subscribe, client_pid, pool_key, subscription_key, provider_constraint},
        _from,
        state
      ) do
    case validate_provider_constraint(state, subscription_key, provider_constraint) do
      :ok ->
        subscription_id = generate_id()

        :ok =
          ClientSubscriptionRegistry.add_client(
            state.profile,
            state.chain_id,
            subscription_id,
            client_pid,
            pool_key
          )

        send(self(), {:ensure_coordinator, pool_key})

        new_state =
          case Map.get(state.keys, pool_key) do
            nil ->
              generation = make_ref()
              GenServer.cast(self(), {:establish_upstream, pool_key, generation, []})

              entry = %{
                refcount: 1,
                status: :establishing,
                primary_provider_id: nil,
                instance_id: nil,
                subscription_key: subscription_key,
                provider_constraint: provider_constraint,
                establishment_generation: generation,
                readiness_retries: 0,
                transient_excluded_providers: MapSet.new(),
                markers: %{},
                dedupe: nil,
                noproc_retries: 0
              }

              telemetry_subscription_status(:establishing, state.chain_id, pool_key, 1)
              %{state | keys: Map.put(state.keys, pool_key, entry)}

            entry when entry.status in [:establishing, :active] ->
              updated = %{entry | refcount: entry.refcount + 1}

              telemetry_subscription_status(
                entry.status,
                state.chain_id,
                pool_key,
                updated.refcount
              )

              %{state | keys: Map.put(state.keys, pool_key, updated)}

            entry when entry.status == :failed ->
              generation = make_ref()
              GenServer.cast(self(), {:establish_upstream, pool_key, generation, []})

              updated = %{
                entry
                | refcount: entry.refcount + 1,
                  status: :establishing,
                  establishment_generation: generation,
                  readiness_retries: 0,
                  transient_excluded_providers: MapSet.new(),
                  noproc_retries: 0
              }

              telemetry_subscription_status(:retry, state.chain_id, pool_key, updated.refcount)
              %{state | keys: Map.put(state.keys, pool_key, updated)}
          end

        {:reply, {:ok, subscription_id}, new_state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case ClientSubscriptionRegistry.remove_client(state.profile, state.chain_id, subscription_id) do
      {:ok, nil} ->
        {:reply, :ok, state}

      {:ok, key} ->
        new_state = maybe_drop_upstream_when_unref(state, key)
        {:reply, :ok, new_state}
    end
  end

  defp validate_provider_constraint(_state, _subscription_key, nil), do: :ok

  defp validate_provider_constraint(state, subscription_key, provider_id) do
    case ConfigStore.get_provider(state.profile, state.chain_id, provider_id) do
      {:ok, provider} ->
        validate_constrained_provider(state, subscription_key, provider)

      {:error, _reason} ->
        {:error,
         invalid_provider_error(state, provider_id, "Provider '#{provider_id}' not found")}
    end
  end

  defp validate_constrained_provider(state, subscription_key, provider) do
    cond do
      not is_binary(provider.ws_url) ->
        {:error,
         invalid_provider_error(
           state,
           provider.id,
           "Provider '#{provider.id}' does not support WebSocket subscriptions"
         )}

      subscription_key == {:newHeads} and not new_heads_capable?(state, provider.id) ->
        {:error,
         invalid_provider_error(
           state,
           provider.id,
           "Provider '#{provider.id}' does not support newHeads subscriptions"
         )}

      true ->
        :ok
    end
  end

  defp new_heads_capable?(state, provider_id) do
    state.profile
    |> Catalog.get_profile_providers(state.chain_id)
    |> Enum.any?(&(&1.provider_id == provider_id and &1.subscribe_new_heads == true))
  end

  defp invalid_provider_error(state, provider_id, message) do
    JError.new(-32_602, message,
      category: :invalid_params,
      retriable?: false,
      data: %{provider_id: provider_id, chain_id: state.chain_id, profile: state.profile}
    )
  end

  @impl true
  def handle_cast({:resubscribe, pool_key, new_provider_id, coordinator_pid}, state) do
    Logger.info("Resubscribing key #{inspect(pool_key)} to provider #{new_provider_id}")

    entry = Map.get(state.keys, pool_key)

    if entry do
      old_provider_id = entry.primary_provider_id
      old_instance_id = entry.instance_id

      new_instance_id =
        Catalog.lookup_instance_id(state.profile, state.chain_id, new_provider_id)

      if is_nil(new_instance_id) do
        Logger.error("Cannot resolve instance_id for provider #{new_provider_id}")
        send(coordinator_pid, {:subscription_failed, :no_instance})
        {:noreply, state}
      else
        subscription_key = entry.subscription_key
        InstanceSubscriptionRegistry.register_consumer(new_instance_id, subscription_key)

        case InstanceSubscriptionManager.ensure_subscription(new_instance_id, subscription_key) do
          {:ok, _status} ->
            release_overwritten_transition(
              state,
              pool_key,
              entry,
              subscription_key,
              new_instance_id
            )

            transition_fields =
              if old_instance_id && old_instance_id != new_instance_id do
                %{
                  transitioning_from: old_provider_id,
                  transitioning_from_instance_id: old_instance_id
                }
              else
                %{}
              end

            updated_entry =
              entry
              |> Map.drop([:transitioning_from, :transitioning_from_instance_id])
              |> Map.merge(%{
                primary_provider_id: new_provider_id,
                instance_id: new_instance_id,
                status: :active
              })
              |> Map.merge(transition_fields)

            new_state = %{state | keys: Map.put(state.keys, pool_key, updated_entry)}

            send(coordinator_pid, {:subscription_confirmed, new_provider_id, nil})
            telemetry_resubscribe_success(state.chain_id, pool_key, new_provider_id)

            if old_instance_id && old_instance_id != new_instance_id do
              Process.send_after(
                self(),
                {:deferred_release, pool_key, old_provider_id, old_instance_id},
                5_000
              )
            end

            {:noreply, new_state}

          {:error, reason} ->
            unless instance_in_use_elsewhere?(
                     state,
                     pool_key,
                     new_instance_id,
                     subscription_key
                   ) do
              InstanceSubscriptionRegistry.unregister_consumer(new_instance_id, subscription_key)
            end

            Logger.error(
              "Resubscription failed for #{inspect(pool_key)} to #{new_provider_id}: #{inspect(reason)}"
            )

            send(coordinator_pid, {:subscription_failed, reason})
            telemetry_resubscribe_failed(state.chain_id, pool_key, new_provider_id, reason)
            {:noreply, state}
        end
      end
    else
      Logger.debug("Resubscription skipped: key #{inspect(pool_key)} no longer active")
      send(coordinator_pid, {:subscription_failed, :key_inactive})
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:clients_removed, removed_by_key}, state) when is_map(removed_by_key) do
    new_state =
      Enum.reduce(removed_by_key, state, fn {key, count}, acc ->
        maybe_drop_upstream_refs(acc, key, count)
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:establish_upstream, pool_key, generation, excluded_providers}, state) do
    with {:ok, entry} <- validate_entry_for_establishment(state.keys[pool_key], generation),
         {:ok, provider_id} <-
           select_available_provider(
             state.profile,
             state.chain_id,
             entry.subscription_key,
             excluded_providers,
             entry.provider_constraint
           ),
         {:ok, instance_id} <- resolve_instance_id(state, provider_id),
         {:ok, _status} <-
           attempt_upstream_subscribe(provider_id, instance_id, entry.subscription_key) do
      InstanceSubscriptionRegistry.register_consumer(instance_id, entry.subscription_key)

      new_state = activate_subscription(state, pool_key, entry, provider_id, instance_id)

      Logger.info(
        "Upstream subscription established for key #{inspect(pool_key)} on provider #{provider_id}"
      )

      broadcast_subscription_event(state, %Subscription.Established{
        ts: System.system_time(:millisecond),
        chain_id: state.chain_id,
        provider_id: provider_id,
        subscription_type: Subscription.subscription_type(entry.subscription_key)
      })

      telemetry_upstream(:subscribe, state.chain_id, provider_id, pool_key)
      telemetry_subscription_status(:active, state.chain_id, pool_key, entry.refcount)

      {:noreply, new_state}
    else
      {:error, :entry_invalid} ->
        {:noreply, state}

      {:error, :no_providers} ->
        {new_state, retry_exclusions} =
          recycle_transient_exclusions(state, pool_key, excluded_providers)

        retry_readiness(new_state, pool_key, generation, retry_exclusions)

      {:error, :no_instance} ->
        retry_readiness(state, pool_key, generation, excluded_providers)

      {:error, {:noproc, _instance_id}} ->
        retry_readiness(state, pool_key, generation, excluded_providers)

      {:error, {:subscribe_failed, provider_id, reason}}
      when reason in [:connection_unknown, :not_connected, :timeout] ->
        retry_transient_failure(state, pool_key, generation, excluded_providers, provider_id)

      {:error, {:subscribe_failed, provider_id, %JError{retriable?: true}}} ->
        retry_transient_failure(state, pool_key, generation, excluded_providers, provider_id)

      {:error, {:subscribe_failed, provider_id, _reason}} ->
        entry = state.keys[pool_key]

        if entry.provider_constraint do
          new_state = mark_subscription_failed(state, pool_key, "Constrained provider rejected")
          {:noreply, new_state}
        else
          new_excluded = [provider_id | excluded_providers]
          do_handle_subscription_failure(state, pool_key, generation, new_excluded)
        end
    end
  end

  defp validate_entry_for_establishment(nil, _generation), do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry, generation)
       when entry.status != :establishing or entry.establishment_generation != generation,
       do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry, _generation) when entry.refcount < 1,
    do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry, _generation), do: {:ok, entry}

  defp select_available_provider(
         profile,
         chain_id,
         subscription_key,
         excluded_providers,
         provider_constraint
       ) do
    channels =
      Selection.select_channels(profile, chain_id, "eth_subscribe",
        strategy: :priority,
        transport: :ws,
        exclude: excluded_providers,
        limit: if(provider_constraint, do: 1_000, else: 1),
        requires_subscribe_new_heads: subscription_key == {:newHeads}
      )

    channel =
      if provider_constraint do
        Enum.find(channels, &(&1.provider_id == provider_constraint))
      else
        List.first(channels)
      end

    case channel do
      %Channel{provider_id: provider_id} -> {:ok, provider_id}
      nil -> {:error, :no_providers}
    end
  end

  defp resolve_instance_id(state, provider_id) do
    case Catalog.lookup_instance_id(state.profile, state.chain_id, provider_id) do
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

  defp activate_subscription(state, pool_key, entry, provider_id, instance_id) do
    updated_entry = %{
      entry
      | status: :active,
        primary_provider_id: provider_id,
        instance_id: instance_id,
        readiness_retries: 0,
        transient_excluded_providers: MapSet.new(),
        noproc_retries: 0
    }

    %{state | keys: Map.put(state.keys, pool_key, updated_entry)}
  end

  defp retry_transient_failure(
         state,
         pool_key,
         generation,
         excluded_providers,
         provider_id
       ) do
    case Map.get(state.keys, pool_key) do
      %{provider_constraint: constraint} when is_binary(constraint) ->
        retry_readiness(state, pool_key, generation, excluded_providers)

      %{status: :establishing, establishment_generation: ^generation} = entry ->
        new_excluded = Enum.uniq([provider_id | excluded_providers])

        transient_excluded_providers =
          entry
          |> Map.get(:transient_excluded_providers, MapSet.new())
          |> MapSet.put(provider_id)

        updated_entry = %{
          entry
          | transient_excluded_providers: transient_excluded_providers
        }

        GenServer.cast(self(), {:establish_upstream, pool_key, generation, new_excluded})
        {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  defp recycle_transient_exclusions(state, pool_key, excluded_providers) do
    case Map.get(state.keys, pool_key) do
      %{provider_constraint: nil} = entry ->
        transient_excluded_providers =
          Map.get(entry, :transient_excluded_providers, MapSet.new())

        retry_exclusions =
          Enum.reject(
            excluded_providers,
            &MapSet.member?(transient_excluded_providers, &1)
          )

        updated_entry = %{entry | transient_excluded_providers: MapSet.new()}
        {%{state | keys: Map.put(state.keys, pool_key, updated_entry)}, retry_exclusions}

      _ ->
        {state, excluded_providers}
    end
  end

  defp retry_readiness(state, pool_key, generation, excluded_providers) do
    case Map.get(state.keys, pool_key) do
      %{
        status: :establishing,
        establishment_generation: ^generation,
        readiness_retries: retries
      } = entry
      when retries < @max_readiness_retries ->
        Process.send_after(
          self(),
          {:retry_establish, pool_key, generation, excluded_providers},
          @readiness_retry_ms
        )

        updated = %{entry | readiness_retries: retries + 1}
        {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated)}}

      %{status: :establishing, establishment_generation: ^generation} = entry ->
        if entry.provider_constraint do
          Process.send_after(
            self(),
            {:retry_establish, pool_key, generation, excluded_providers},
            1_000
          )

          updated = %{entry | readiness_retries: 0}
          {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated)}}
        else
          {:noreply, mark_subscription_failed(state, pool_key, "No ready providers")}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp do_handle_subscription_failure(state, pool_key, generation, excluded_providers) do
    max_attempts = 3

    if length(excluded_providers) < max_attempts do
      Logger.info(
        "Retrying upstream establishment for #{inspect(pool_key)} (attempt #{length(excluded_providers) + 1}/#{max_attempts})"
      )

      GenServer.cast(self(), {:establish_upstream, pool_key, generation, excluded_providers})
      {:noreply, state}
    else
      new_state = mark_subscription_failed(state, pool_key, "Max retries exceeded")
      {:noreply, new_state}
    end
  end

  defp mark_subscription_failed(state, key, reason) do
    case state.keys[key] do
      nil ->
        state

      entry ->
        updated_entry = %{entry | status: :failed, establishment_generation: make_ref()}

        broadcast_subscription_event(state, %Subscription.Failed{
          ts: System.system_time(:millisecond),
          chain_id: state.chain_id,
          provider_id: entry.provider_constraint || entry.primary_provider_id,
          subscription_type: Subscription.subscription_type(entry.subscription_key),
          reason: reason
        })

        telemetry_subscription_status(:failed, state.chain_id, key, entry.refcount)
        Logger.error("Subscription failed for #{inspect(key)}: #{reason}")
        %{state | keys: Map.put(state.keys, key, updated_entry)}
    end
  end

  @impl true
  # Events from InstanceSubscriptionManager via InstanceSubscriptionRegistry
  def handle_info(
        {:instance_subscription_event, instance_id, subscription_key, payload, received_at},
        state
      )
      when is_map(payload) do
    Enum.each(state.keys, fn {pool_key, entry} ->
      cond do
        entry.subscription_key != subscription_key or entry.status != :active ->
          :ok

        entry.instance_id == instance_id ->
          StreamCoordinator.upstream_event(
            state.profile,
            state.chain_id,
            pool_key,
            entry.primary_provider_id,
            nil,
            payload,
            received_at
          )

        Map.get(entry, :transitioning_from_instance_id) == instance_id ->
          StreamCoordinator.upstream_event(
            state.profile,
            state.chain_id,
            pool_key,
            entry.transitioning_from,
            nil,
            payload,
            received_at
          )

        true ->
          :ok
      end
    end)

    {:noreply, state}
  end

  # Deferred release of old instance subscription after transition
  def handle_info({:deferred_release, pool_key, old_provider_id, old_instance_id}, state) do
    case Map.get(state.keys, pool_key) do
      %{transitioning_from: ^old_provider_id} = entry ->
        unless instance_in_use_elsewhere?(
                 state,
                 pool_key,
                 old_instance_id,
                 entry.subscription_key
               ) do
          InstanceSubscriptionRegistry.unregister_consumer(
            old_instance_id,
            entry.subscription_key
          )

          InstanceSubscriptionManager.release_subscription(
            old_instance_id,
            entry.subscription_key
          )
        end

        updated_entry =
          entry
          |> Map.delete(:transitioning_from)
          |> Map.delete(:transitioning_from_instance_id)

        new_state = %{state | keys: Map.put(state.keys, pool_key, updated_entry)}

        Logger.debug(
          "Deferred release of old provider #{old_provider_id} for key #{inspect(pool_key)}"
        )

        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_establish, pool_key, generation, excluded_providers}, state) do
    case Map.get(state.keys, pool_key) do
      %{status: :establishing, establishment_generation: ^generation} ->
        GenServer.cast(self(), {:establish_upstream, pool_key, generation, excluded_providers})
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

    new_state =
      state.keys
      |> Enum.filter(fn {_key, entry} -> entry.primary_provider_id == provider_id end)
      |> Enum.reduce(state, fn {key, _entry}, acc ->
        dispatch_failover(acc, key, provider_id, pick_next_provider(acc, key, provider_id))
      end)

    {:noreply, new_state}
  end

  # Invalidation from InstanceSubscriptionManager
  def handle_info(
        {:instance_subscription_invalidated, instance_id, subscription_key, reason},
        state
      ) do
    new_state =
      Enum.reduce(state.keys, state, fn {pool_key, entry}, acc ->
        if entry.subscription_key == subscription_key and entry.instance_id == instance_id do
          handle_subscription_invalidation(
            acc,
            entry.primary_provider_id,
            instance_id,
            pool_key,
            reason
          )
        else
          acc
        end
      end)

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
        chain_id: state.chain_id,
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
    new_state =
      case Map.get(state.keys, key) do
        %{instance_id: ^instance_id, status: :active} = entry ->
          InstanceSubscriptionRegistry.register_consumer(instance_id, entry.subscription_key)

          case InstanceSubscriptionManager.ensure_subscription(
                 instance_id,
                 entry.subscription_key
               ) do
            {:ok, _status} ->
              Logger.debug("Re-established subscription after Manager restart",
                chain_id: state.chain_id,
                key: inspect(key),
                instance_id: instance_id
              )

              state

            {:error, reason} ->
              Logger.warning("Failed to re-establish subscription after Manager restart",
                chain_id: state.chain_id,
                key: inspect(key),
                instance_id: instance_id,
                reason: inspect(reason)
              )

              if entry.provider_constraint and transient_subscription_error?(reason) do
                retry_constrained_subscription(state, key)
              else
                dispatch_failover(
                  state,
                  key,
                  entry.primary_provider_id,
                  pick_next_provider(state, key, entry.primary_provider_id)
                )
              end
          end

        _ ->
          state
      end

    {:noreply, new_state}
  end

  def handle_info({:ensure_coordinator, key}, state) do
    _ = start_coordinator_for_key(state, key)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Staleness: resubscribe to same instance
  defp handle_subscription_invalidation(
         state,
         provider_id,
         instance_id,
         pool_key,
         :subscription_stale
       ) do
    entry = state.keys[pool_key]

    Logger.info("Subscription stale, resubscribing to same instance",
      chain_id: state.chain_id,
      provider_id: provider_id,
      instance_id: instance_id,
      key: inspect(pool_key)
    )

    case InstanceSubscriptionManager.ensure_subscription(instance_id, entry.subscription_key) do
      {:ok, _status} ->
        Logger.debug("Resubscribed after staleness",
          chain_id: state.chain_id,
          instance_id: instance_id,
          key: inspect(pool_key)
        )

        state

      {:error, reason} ->
        Logger.warning("Resubscription failed after staleness, failing over",
          chain_id: state.chain_id,
          provider_id: provider_id,
          key: inspect(pool_key),
          reason: inspect(reason)
        )

        dispatch_failover(
          state,
          pool_key,
          provider_id,
          pick_next_provider(state, pool_key, provider_id)
        )
    end
  end

  defp handle_subscription_invalidation(state, provider_id, _instance_id, pool_key, reason) do
    Logger.info("Subscription invalidated, failing over",
      chain_id: state.chain_id,
      provider_id: provider_id,
      key: inspect(pool_key),
      reason: reason
    )

    dispatch_failover(
      state,
      pool_key,
      provider_id,
      pick_next_provider(state, pool_key, provider_id)
    )
  end

  # Internal helpers

  defp release_overwritten_transition(state, pool_key, entry, key, new_instance_id) do
    previous_instance_id = Map.get(entry, :transitioning_from_instance_id)

    if previous_instance_id && previous_instance_id != new_instance_id &&
         not instance_in_use_elsewhere?(state, pool_key, previous_instance_id, key) do
      InstanceSubscriptionRegistry.unregister_consumer(previous_instance_id, key)
      InstanceSubscriptionManager.release_subscription(previous_instance_id, key)
    end

    :ok
  end

  defp start_coordinator_for_key(state, pool_key) do
    opts = [
      primary_provider_id: Map.get(state.keys[pool_key] || %{}, :primary_provider_id),
      dedupe_max_items: state.dedupe_max_items,
      dedupe_max_age_ms: state.dedupe_max_age_ms,
      max_backfill_blocks: state.max_backfill_blocks,
      backfill_timeout: state.backfill_timeout,
      continuity_policy: :best_effort
    ]

    StreamSupervisor.ensure_coordinator(state.profile, state.chain_id, pool_key, opts)
  end

  defp pick_next_provider(state, pool_key, failed_provider_id) do
    entry = state.keys[pool_key]
    failed_instance_id = entry.instance_id

    if entry.provider_constraint do
      nil
    else
      state.profile
      |> Selection.select_channels(state.chain_id, "eth_subscribe",
        strategy: :priority,
        transport: :ws,
        exclude: [failed_provider_id],
        requires_subscribe_new_heads: entry.subscription_key == {:newHeads}
      )
      |> Enum.find(fn %Channel{provider_id: provider_id} ->
        candidate_instance_id =
          Catalog.lookup_instance_id(state.profile, state.chain_id, provider_id)

        not is_nil(candidate_instance_id) and candidate_instance_id != failed_instance_id
      end)
      |> case do
        %Channel{provider_id: provider_id} -> provider_id
        nil -> nil
      end
    end
  end

  # Routes a failover decision: a valid replacement provider goes to the
  # StreamCoordinator for handoff; `nil` (no candidate available) marks the
  # subscription as failed so clients receive a Failed event rather than
  # silently lingering against a stale upstream.
  defp dispatch_failover(state, pool_key, _failed_provider_id, nil) do
    case Map.get(state.keys, pool_key) do
      %{provider_constraint: provider_constraint} when is_binary(provider_constraint) ->
        retry_constrained_subscription(state, pool_key)

      _ ->
        mark_subscription_failed(state, pool_key, "No replacement provider available")
    end
  end

  defp dispatch_failover(state, key, failed_provider_id, new_provider_id)
       when is_binary(new_provider_id) do
    StreamCoordinator.provider_unhealthy(
      state.profile,
      state.chain_id,
      key,
      failed_provider_id,
      new_provider_id
    )

    state
  end

  defp maybe_drop_upstream_refs(state, _key, count) when not is_integer(count) or count <= 0,
    do: state

  defp maybe_drop_upstream_refs(state, key, count) do
    case Map.get(state.keys, key) do
      nil ->
        state

      %{refcount: refcount} = entry when count >= refcount ->
        one_ref_entry = %{entry | refcount: 1}

        maybe_drop_upstream_when_unref(
          %{state | keys: Map.put(state.keys, key, one_ref_entry)},
          key
        )

      entry ->
        updated = %{entry | refcount: entry.refcount - count}
        telemetry_subscription_status(entry.status, state.chain_id, key, updated.refcount)
        %{state | keys: Map.put(state.keys, key, updated)}
    end
  end

  defp maybe_drop_upstream_when_unref(state, pool_key) do
    case Map.get(state.keys, pool_key) do
      nil ->
        state

      %{refcount: 1} = entry ->
        release_entry_upstreams(state, pool_key, entry)

        if entry.primary_provider_id do
          telemetry_upstream(:unsubscribe, state.chain_id, entry.primary_provider_id, pool_key)
        end

        profile = state.profile
        Task.start(fn -> StreamSupervisor.stop_coordinator(profile, state.chain_id, pool_key) end)
        %{state | keys: Map.delete(state.keys, pool_key)}

      entry ->
        updated = %{entry | refcount: entry.refcount - 1}
        %{state | keys: Map.put(state.keys, pool_key, updated)}
    end
  end

  defp transient_subscription_error?(reason)
       when reason in [:connection_unknown, :not_connected, :timeout, :noproc],
       do: true

  defp transient_subscription_error?(%JError{retriable?: true}), do: true
  defp transient_subscription_error?(_reason), do: false

  defp retry_constrained_subscription(state, pool_key) do
    case Map.get(state.keys, pool_key) do
      nil ->
        state

      entry ->
        release_entry_upstreams(state, pool_key, entry)
        generation = make_ref()

        updated = %{
          entry
          | status: :establishing,
            primary_provider_id: nil,
            instance_id: nil,
            establishment_generation: generation,
            readiness_retries: 0,
            transient_excluded_providers: MapSet.new()
        }

        Process.send_after(self(), {:retry_establish, pool_key, generation, []}, 100)
        %{state | keys: Map.put(state.keys, pool_key, updated)}
    end
  end

  defp release_entry_upstreams(state, pool_key, entry) do
    [entry.instance_id, Map.get(entry, :transitioning_from_instance_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn instance_id ->
      unless instance_in_use_elsewhere?(state, pool_key, instance_id, entry.subscription_key) do
        InstanceSubscriptionRegistry.unregister_consumer(instance_id, entry.subscription_key)
        InstanceSubscriptionManager.release_subscription(instance_id, entry.subscription_key)
      end
    end)
  end

  defp instance_in_use_elsewhere?(state, pool_key, instance_id, subscription_key) do
    Enum.any?(state.keys, fn {other_key, entry} ->
      other_key != pool_key and entry.subscription_key == subscription_key and
        (entry.instance_id == instance_id or
           Map.get(entry, :transitioning_from_instance_id) == instance_id)
    end)
  end

  defp telemetry_upstream(action, chain_id, provider_id, key) do
    :telemetry.execute([:lasso, :subs, :upstream, action], %{count: 1}, %{
      chain_id: chain_id,
      provider_id: provider_id,
      key: inspect(key)
    })
  end

  defp telemetry_resubscribe_success(chain_id, key, provider_id) do
    :telemetry.execute([:lasso, :subs, :resubscribe, :success], %{count: 1}, %{
      chain_id: chain_id,
      key: inspect(key),
      provider_id: provider_id
    })
  end

  defp telemetry_resubscribe_failed(chain_id, key, provider_id, reason) do
    :telemetry.execute([:lasso, :subs, :resubscribe, :failed], %{count: 1}, %{
      chain_id: chain_id,
      key: inspect(key),
      provider_id: provider_id,
      reason: inspect(reason)
    })
  end

  defp telemetry_subscription_status(status, chain_id, key, refcount) do
    :telemetry.execute([:lasso, :subs, :status], %{refcount: refcount}, %{
      chain_id: chain_id,
      key: inspect(key),
      status: status
    })
  end

  defp broadcast_subscription_event(state, event) do
    topic = Lasso.Topics.subscription_event(state.profile, state.chain_id)
    Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)
  end

  defp pool_key(subscription_key, nil), do: subscription_key
  defp pool_key(subscription_key, provider_id), do: {:route, provider_id, subscription_key}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
