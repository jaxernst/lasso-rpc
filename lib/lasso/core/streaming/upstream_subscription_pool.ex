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

  @readiness_retry_base_ms 100
  @readiness_retry_cap_ms 5_000
  @establishment_timeout_ms 4_000

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
    GenServer.call(via(profile, chain_id), subscribe_message(client_pid, key, opts))
  end

  @spec subscribe_client_request(profile, chain_id, pid(), key, keyword()) :: term()
  def subscribe_client_request(profile, chain_id, client_pid, key, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    :gen.send_request(
      via(profile, chain_id),
      :"$gen_call",
      subscribe_message(client_pid, key, opts)
    )
  end

  @spec unsubscribe_client(profile, chain_id, String.t()) :: :ok | {:error, term()}
  def unsubscribe_client(profile, chain_id, subscription_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), {:unsubscribe, subscription_id})
  end

  @spec unsubscribe_client_checked(profile, chain_id, String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def unsubscribe_client_checked(profile, chain_id, subscription_id, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), unsubscribe_checked_message(subscription_id, opts))
  end

  @spec unsubscribe_client_checked_request(profile, chain_id, String.t(), keyword()) :: term()
  def unsubscribe_client_checked_request(profile, chain_id, subscription_id, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    :gen.send_request(
      via(profile, chain_id),
      :"$gen_call",
      unsubscribe_checked_message(subscription_id, opts)
    )
  end

  @spec check_response(term(), term()) :: term()
  def check_response(message, request_id), do: :gen.check_response(message, request_id)

  # GenServer callbacks

  @impl true
  def init({profile, chain_id}) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.provider_event(profile, chain_id))
    Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.ws_connection(profile, chain_id))
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
      coordinator_monitors: %{},
      dedupe_max_items: Map.get(dedupe_cfg, :max_items, 256),
      dedupe_max_age_ms: Map.get(dedupe_cfg, :max_age_ms, 30_000),
      max_backfill_blocks: 32,
      backfill_timeout: 30_000
    }

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:subscribe, client_pid, pool_key, subscription_key, provider_constraint,
         request_owner_pid, deadline_us},
        from,
        state
      ) do
    with :ok <- authorize_operation(request_owner_pid, client_pid, deadline_us),
         :ok <- validate_provider_constraint(state, subscription_key, provider_constraint) do
      subscription_id = generate_id()

      case register_owned_client(
             state,
             subscription_id,
             client_pid,
             pool_key,
             request_owner_pid,
             deadline_us
           ) do
        :ok ->
          published_state =
            publish_client_subscription(
              state,
              pool_key,
              subscription_key,
              provider_constraint
            )

          case published_state.keys[pool_key] do
            %{status: :active} ->
              {:reply, {:ok, subscription_id}, published_state}

            %{status: :establishing} ->
              new_state =
                add_pending_subscriber(
                  published_state,
                  pool_key,
                  subscription_id,
                  from,
                  deadline_us
                )

              {:noreply, new_state}
          end

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    {_removed?, state} = remove_client_subscription(state, subscription_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(
        {:unsubscribe_checked, subscription_id, request_owner_pid, client_pid, deadline_us},
        _from,
        state
      ) do
    case remove_owned_client_subscription(
           state,
           subscription_id,
           request_owner_pid,
           client_pid,
           deadline_us
         ) do
      {:ok, removed?, state} ->
        {:reply, {:ok, removed?}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp authorize_operation(nil, _client_pid, nil), do: :ok

  defp authorize_operation(request_owner_pid, client_pid, deadline_us) do
    cond do
      not is_pid(request_owner_pid) or not Process.alive?(request_owner_pid) ->
        {:error, :owner_down}

      is_pid(client_pid) and not Process.alive?(client_pid) ->
        {:error, :client_down}

      not is_integer(deadline_us) or System.monotonic_time(:microsecond) >= deadline_us ->
        {:error, :deadline_expired}

      true ->
        :ok
    end
  end

  defp register_owned_client(
         state,
         subscription_id,
         client_pid,
         pool_key,
         nil,
         nil
       ) do
    ClientSubscriptionRegistry.add_client(
      state.profile,
      state.chain_id,
      subscription_id,
      client_pid,
      pool_key
    )
  end

  defp register_owned_client(
         state,
         subscription_id,
         client_pid,
         pool_key,
         request_owner_pid,
         deadline_us
       ) do
    result =
      ClientSubscriptionRegistry.add_client_owned(
        state.profile,
        state.chain_id,
        subscription_id,
        client_pid,
        pool_key,
        request_owner_pid,
        deadline_us
      )

    case {result, authorize_operation(request_owner_pid, client_pid, deadline_us)} do
      {:ok, :ok} ->
        :ok

      {_, {:error, reason}} ->
        ClientSubscriptionRegistry.remove_client(state.profile, state.chain_id, subscription_id)
        {:error, reason}

      {{:error, reason}, _authorization} ->
        {:error, reason}
    end
  end

  defp publish_client_subscription(state, pool_key, subscription_key, provider_constraint) do
    send(self(), {:ensure_coordinator, pool_key})

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
          retry_token: nil,
          transient_excluded_providers: MapSet.new(),
          markers: %{},
          dedupe: nil,
          noproc_retries: 0,
          pending_subscribers: [],
          establishment_attempt_token: nil,
          establishment_attempt_pid: nil,
          establishment_attempt_ref: nil,
          establishment_attempt_exclusions: [],
          resubscribe_token: nil,
          resubscribe_pid: nil,
          resubscribe_ref: nil,
          resubscribe_coordinator_pid: nil
        }

        %{state | keys: Map.put(state.keys, pool_key, entry)}

      entry when entry.status in [:establishing, :active] ->
        updated = %{entry | refcount: entry.refcount + 1}
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
            retry_token: nil,
            transient_excluded_providers: MapSet.new(),
            noproc_retries: 0,
            establishment_attempt_token: nil,
            establishment_attempt_pid: nil,
            establishment_attempt_ref: nil,
            establishment_attempt_exclusions: [],
            resubscribe_token: nil,
            resubscribe_pid: nil,
            resubscribe_ref: nil,
            resubscribe_coordinator_pid: nil
        }

        %{state | keys: Map.put(state.keys, pool_key, updated)}
    end
  end

  defp subscribe_message(client_pid, key, opts) do
    provider_constraint = Keyword.get(opts, :provider_id)

    {:subscribe, client_pid, pool_key(key, provider_constraint), key, provider_constraint,
     Keyword.get(opts, :request_owner_pid), Keyword.get(opts, :deadline_us)}
  end

  defp unsubscribe_checked_message(subscription_id, opts) do
    {:unsubscribe_checked, subscription_id, Keyword.get(opts, :request_owner_pid),
     Keyword.get(opts, :client_pid), Keyword.get(opts, :deadline_us)}
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

    case Map.get(state.keys, pool_key) do
      nil ->
        Logger.debug("Resubscription skipped: key #{inspect(pool_key)} no longer active")
        send(coordinator_pid, {:subscription_failed, :key_inactive})
        {:noreply, state}

      %{resubscribe_pid: pid} when is_pid(pid) ->
        send(coordinator_pid, {:subscription_failed, :replacement_in_progress})
        {:noreply, state}

      entry ->
        new_instance_id =
          Catalog.lookup_instance_id(state.profile, state.chain_id, new_provider_id)

        if is_nil(new_instance_id) do
          Logger.error("Cannot resolve instance_id for provider #{new_provider_id}")
          send(coordinator_pid, {:subscription_failed, :no_instance})
          {:noreply, state}
        else
          token = make_ref()
          pool_pid = self()
          subscription_key = entry.subscription_key

          {owner_pid, owner_ref} =
            spawn_monitor(fn ->
              result =
                InstanceSubscriptionManager.ensure_subscription(
                  new_instance_id,
                  subscription_key
                )

              send(
                pool_pid,
                {:resubscribe_result, pool_key, token, self(), coordinator_pid, new_provider_id,
                 new_instance_id, result}
              )
            end)

          updated_entry = %{
            entry
            | resubscribe_token: token,
              resubscribe_pid: owner_pid,
              resubscribe_ref: owner_ref,
              resubscribe_coordinator_pid: coordinator_pid
          }

          {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated_entry)}}
        end
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
         {:ok, instance_id} <- resolve_instance_id(state, provider_id) do
      start_establishment_attempt(
        state,
        pool_key,
        generation,
        excluded_providers,
        entry,
        provider_id,
        instance_id
      )
    else
      {:error, :entry_invalid} ->
        {:noreply, state}

      {:error, :no_providers} ->
        {new_state, retry_exclusions} =
          recycle_transient_exclusions(state, pool_key, excluded_providers)

        retry_readiness(new_state, pool_key, generation, retry_exclusions)

      {:error, :no_instance} ->
        retry_readiness(state, pool_key, generation, excluded_providers)
    end
  end

  defp start_establishment_attempt(
         state,
         pool_key,
         generation,
         excluded_providers,
         entry,
         provider_id,
         instance_id
       ) do
    token = make_ref()
    pool_pid = self()
    timeout_ms = establishment_attempt_timeout(entry)
    subscription_key = entry.subscription_key

    {owner_pid, owner_ref} =
      spawn_monitor(fn ->
        result =
          attempt_upstream_subscribe(provider_id, instance_id, subscription_key, timeout_ms)

        send(
          pool_pid,
          {:establishment_result, pool_key, generation, token, self(), provider_id, instance_id,
           excluded_providers, result}
        )
      end)

    updated_entry = %{
      entry
      | establishment_attempt_token: token,
        establishment_attempt_pid: owner_pid,
        establishment_attempt_ref: owner_ref,
        establishment_attempt_exclusions: excluded_providers
    }

    {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated_entry)}}
  end

  defp handle_establishment_result(
         state,
         pool_key,
         _generation,
         _excluded_providers,
         entry,
         provider_id,
         instance_id,
         {:ok, _status}
       ) do
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

    {:noreply, new_state}
  end

  defp handle_establishment_result(
         state,
         pool_key,
         generation,
         excluded_providers,
         _entry,
         _provider_id,
         _resolved_instance_id,
         {:error, {:noproc, _failed_instance_id}}
       ) do
    retry_readiness(state, pool_key, generation, excluded_providers)
  end

  defp handle_establishment_result(
         state,
         pool_key,
         generation,
         excluded_providers,
         _entry,
         provider_id,
         _instance_id,
         {:error, {:subscribe_failed, provider_id, reason}}
       )
       when reason in [:connection_unknown, :not_connected, :timeout] do
    retry_transient_failure(state, pool_key, generation, excluded_providers, provider_id)
  end

  defp handle_establishment_result(
         state,
         pool_key,
         generation,
         excluded_providers,
         _entry,
         provider_id,
         _instance_id,
         {:error, {:subscribe_failed, provider_id, %JError{retriable?: true}}}
       ) do
    retry_transient_failure(state, pool_key, generation, excluded_providers, provider_id)
  end

  defp handle_establishment_result(
         state,
         pool_key,
         generation,
         excluded_providers,
         entry,
         provider_id,
         _instance_id,
         {:error, {:subscribe_failed, provider_id, _reason}}
       ) do
    if entry.provider_constraint do
      new_state = mark_subscription_failed(state, pool_key, "Constrained provider rejected")
      {:noreply, new_state}
    else
      new_excluded = [provider_id | excluded_providers]
      do_handle_subscription_failure(state, pool_key, generation, new_excluded)
    end
  end

  defp validate_entry_for_establishment(nil, _generation), do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry, generation)
       when entry.status != :establishing or entry.establishment_generation != generation,
       do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry, _generation) when entry.refcount < 1,
    do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(%{establishment_attempt_pid: pid}, _generation)
       when is_pid(pid),
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

  defp attempt_upstream_subscribe(provider_id, instance_id, key, timeout_ms) do
    Logger.debug(
      "Attempting upstream subscribe via instance #{instance_id} for key #{inspect(key)}"
    )

    case InstanceSubscriptionManager.ensure_subscription(instance_id, key, timeout_ms) do
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
        retry_token: nil,
        transient_excluded_providers: MapSet.new(),
        noproc_retries: 0,
        establishment_attempt_token: nil,
        establishment_attempt_pid: nil,
        establishment_attempt_ref: nil,
        establishment_attempt_exclusions: []
    }

    state = ensure_coordinator_monitored(state, pool_key)

    StreamCoordinator.upstream_established(
      state.profile,
      state.chain_id,
      pool_key,
      provider_id
    )

    send(
      self(),
      {:settle_subscription_established, pool_key, entry.establishment_generation}
    )

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
      %{status: :establishing, establishment_generation: ^generation, retry_token: nil} = entry ->
        attempt = entry.readiness_retries

        delay =
          min(@readiness_retry_base_ms * Integer.pow(2, min(attempt, 6)), @readiness_retry_cap_ms)

        token = make_ref()

        Process.send_after(
          self(),
          {:retry_establish, pool_key, generation, token, excluded_providers},
          delay
        )

        updated = %{entry | readiness_retries: attempt + 1, retry_token: token}
        {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated)}}

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
        pending_subscribers = Map.get(entry, :pending_subscribers, [])

        Enum.each(pending_subscribers, fn waiter ->
          ClientSubscriptionRegistry.remove_client(
            state.profile,
            state.chain_id,
            waiter.subscription_id
          )
        end)

        updated_entry =
          entry
          |> Map.put(:status, :failed)
          |> Map.put(:establishment_generation, make_ref())
          |> settle_pending_subscribers({:error, :upstream_establishment_failed})
          |> Map.update!(:refcount, &max(&1 - length(pending_subscribers), 0))

        broadcast_subscription_event(state, %Subscription.Failed{
          ts: System.system_time(:millisecond),
          chain_id: state.chain_id,
          provider_id: entry.provider_constraint || entry.primary_provider_id,
          subscription_type: Subscription.subscription_type(entry.subscription_key),
          reason: reason
        })

        Logger.error("Subscription failed for #{inspect(key)}: #{reason}")

        if updated_entry.refcount == 0 do
          send(self(), {:stop_coordinator_if_unused, key})

          state
          |> release_coordinator_monitor(key)
          |> Map.update!(:keys, &Map.delete(&1, key))
        else
          %{state | keys: Map.put(state.keys, key, updated_entry)}
        end
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

  def handle_info({:retry_establish, pool_key, generation, token, excluded_providers}, state) do
    case Map.get(state.keys, pool_key) do
      %{status: :establishing, establishment_generation: ^generation, retry_token: ^token} = entry ->
        updated = %{entry | retry_token: nil}
        new_state = %{state | keys: Map.put(state.keys, pool_key, updated)}
        GenServer.cast(self(), {:establish_upstream, pool_key, generation, excluded_providers})
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:establishment_result, pool_key, generation, token, owner_pid, provider_id, instance_id,
         excluded_providers, result},
        state
      ) do
    case Map.get(state.keys, pool_key) do
      %{
        status: :establishing,
        establishment_generation: ^generation,
        establishment_attempt_token: ^token,
        establishment_attempt_pid: ^owner_pid
      } = entry ->
        Process.demonitor(entry.establishment_attempt_ref, [:flush])

        cleared_entry = clear_establishment_attempt(entry)
        new_state = %{state | keys: Map.put(state.keys, pool_key, cleared_entry)}

        handle_establishment_result(
          new_state,
          pool_key,
          generation,
          excluded_providers,
          cleared_entry,
          provider_id,
          instance_id,
          result
        )

      _stale ->
        if match?({:ok, _status}, result) do
          InstanceSubscriptionManager.release_subscription(
            instance_id,
            subscription_key(pool_key)
          )
        end

        {:noreply, state}
    end
  end

  def handle_info(
        {:resubscribe_result, pool_key, token, owner_pid, coordinator_pid, new_provider_id,
         new_instance_id, result},
        state
      ) do
    case Map.get(state.keys, pool_key) do
      %{
        resubscribe_token: ^token,
        resubscribe_pid: ^owner_pid,
        resubscribe_coordinator_pid: ^coordinator_pid
      } = entry ->
        Process.demonitor(entry.resubscribe_ref, [:flush])
        cleared_entry = clear_resubscribe_attempt(entry)
        new_state = %{state | keys: Map.put(state.keys, pool_key, cleared_entry)}

        settle_resubscribe(
          new_state,
          pool_key,
          cleared_entry,
          coordinator_pid,
          new_provider_id,
          new_instance_id,
          result
        )

      _stale ->
        if match?({:ok, _status}, result) do
          InstanceSubscriptionManager.release_subscription(
            new_instance_id,
            subscription_key(pool_key)
          )
        end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, owner_pid, _reason}, state) do
    case Enum.find(state.keys, fn {_pool_key, entry} ->
           Map.get(entry, :establishment_attempt_ref) == ref and
             Map.get(entry, :establishment_attempt_pid) == owner_pid
         end) do
      {pool_key, entry} ->
        generation = entry.establishment_generation
        exclusions = Map.get(entry, :establishment_attempt_exclusions, [])
        cleared_entry = clear_establishment_attempt(entry)
        new_state = %{state | keys: Map.put(state.keys, pool_key, cleared_entry)}
        retry_readiness(new_state, pool_key, generation, exclusions)

      nil ->
        case Enum.find(state.keys, fn {_pool_key, entry} ->
               Map.get(entry, :resubscribe_ref) == ref and
                 Map.get(entry, :resubscribe_pid) == owner_pid
             end) do
          {pool_key, entry} ->
            coordinator_pid = entry.resubscribe_coordinator_pid
            cleared_entry = clear_resubscribe_attempt(entry)
            send(coordinator_pid, {:subscription_failed, :replacement_owner_down})
            {:noreply, %{state | keys: Map.put(state.keys, pool_key, cleared_entry)}}

          nil ->
            case Enum.find(state.coordinator_monitors, fn {_pool_key, monitor} ->
                   monitor.ref == ref and monitor.pid == owner_pid
                 end) do
              {pool_key, _monitor} ->
                ClientSubscriptionRegistry.terminate(
                  state.profile,
                  state.chain_id,
                  pool_key,
                  :continuity_exhausted
                )

                {:noreply,
                 %{
                   state
                   | coordinator_monitors: Map.delete(state.coordinator_monitors, pool_key)
                 }}

              nil ->
                {:noreply, state}
            end
        end
    end
  end

  def handle_info(
        {:subscription_establishment_timeout, pool_key, generation, subscription_id, token},
        state
      ) do
    case Map.get(state.keys, pool_key) do
      %{status: :establishing, establishment_generation: ^generation} = entry ->
        case Enum.split_with(Map.get(entry, :pending_subscribers, []), fn waiter ->
               waiter.subscription_id == subscription_id and waiter.token == token
             end) do
          {[waiter], remaining} ->
            GenServer.reply(waiter.from, {:error, :timeout})

            {_removed?, reduced_state} =
              remove_client_subscription(
                %{
                  state
                  | keys: Map.put(state.keys, pool_key, %{entry | pending_subscribers: remaining})
                },
                subscription_id
              )

            {:noreply, reduced_state}

          _ ->
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:settle_subscription_established, pool_key, generation}, state) do
    case Map.get(state.keys, pool_key) do
      %{status: :active, establishment_generation: ^generation} = entry ->
        settled_entry = settle_pending_subscribers(entry, :established)
        {:noreply, %{state | keys: Map.put(state.keys, pool_key, settled_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:stop_coordinator_if_unused, pool_key}, state) do
    if Map.has_key?(state.keys, pool_key) do
      {:noreply, state}
    else
      _ = StreamSupervisor.stop_coordinator(state.profile, state.chain_id, pool_key)
      {:noreply, state}
    end
  end

  def handle_info({:ws_connected, provider_id, _connection_id}, state) do
    new_state =
      Enum.reduce(state.keys, state, fn {pool_key, entry}, acc ->
        should_wake? =
          entry.status == :establishing and entry.retry_token != :wake_pending and
            (is_nil(entry.provider_constraint) or entry.provider_constraint == provider_id)

        if should_wake? do
          Process.send_after(
            self(),
            {:wake_establish, pool_key, entry.establishment_generation},
            @readiness_retry_base_ms
          )

          updated = %{entry | retry_token: :wake_pending}
          %{acc | keys: Map.put(acc.keys, pool_key, updated)}
        else
          acc
        end
      end)

    {:noreply, new_state}
  end

  def handle_info({:wake_establish, pool_key, generation}, state) do
    case Map.get(state.keys, pool_key) do
      %{
        status: :establishing,
        establishment_generation: ^generation,
        retry_token: :wake_pending
      } = entry ->
        updated = %{entry | retry_token: nil}
        GenServer.cast(self(), {:establish_upstream, pool_key, generation, []})
        {:noreply, %{state | keys: Map.put(state.keys, pool_key, updated)}}

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
    {:noreply, ensure_coordinator_monitored(state, key)}
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
      continuity_policy: :strict_abort
    ]

    StreamSupervisor.ensure_coordinator(state.profile, state.chain_id, pool_key, opts)
  end

  defp ensure_coordinator_monitored(state, pool_key) do
    case start_coordinator_for_key(state, pool_key) do
      {:ok, pid} ->
        case Map.get(state.coordinator_monitors, pool_key) do
          %{pid: ^pid} ->
            state

          existing ->
            if existing, do: Process.demonitor(existing.ref, [:flush])
            monitor = %{pid: pid, ref: Process.monitor(pid)}

            %{
              state
              | coordinator_monitors: Map.put(state.coordinator_monitors, pool_key, monitor)
            }
        end

      {:error, _reason} ->
        state
    end
  end

  defp release_coordinator_monitor(state, pool_key) do
    case Map.pop(state.coordinator_monitors, pool_key) do
      {nil, monitors} ->
        %{state | coordinator_monitors: monitors}

      {%{ref: ref}, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | coordinator_monitors: monitors}
    end
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

  defp dispatch_failover(state, pool_key, failed_provider_id, nil) do
    StreamCoordinator.provider_unhealthy(
      state.profile,
      state.chain_id,
      pool_key,
      failed_provider_id,
      nil
    )

    case Map.get(state.keys, pool_key) do
      nil ->
        state

      entry ->
        release_entry_upstreams(state, pool_key, entry)

        updated = %{
          entry
          | status: :failed,
            primary_provider_id: nil,
            instance_id: nil
        }

        %{state | keys: Map.put(state.keys, pool_key, updated)}
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
        %{state | keys: Map.put(state.keys, key, updated)}
    end
  end

  defp maybe_drop_upstream_when_unref(state, pool_key) do
    case Map.get(state.keys, pool_key) do
      nil ->
        state

      %{refcount: 1} = entry ->
        release_entry_upstreams(state, pool_key, entry)
        _entry = settle_pending_subscribers(entry, {:error, :subscription_inactive})
        send(self(), {:stop_coordinator_if_unused, pool_key})

        state
        |> release_coordinator_monitor(pool_key)
        |> Map.update!(:keys, &Map.delete(&1, pool_key))

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

  defp retry_constrained_subscription(state, pool_key),
    do: retry_pending_subscription(state, pool_key)

  defp retry_pending_subscription(state, pool_key) do
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
            retry_token: nil,
            transient_excluded_providers: MapSet.new()
        }

        new_state = %{state | keys: Map.put(state.keys, pool_key, updated)}
        {:noreply, scheduled_state} = retry_readiness(new_state, pool_key, generation, [])
        scheduled_state
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

  defp remove_client_subscription(state, subscription_id) do
    case ClientSubscriptionRegistry.remove_client(state.profile, state.chain_id, subscription_id) do
      {:ok, nil} -> {false, state}
      {:ok, key} -> {true, maybe_drop_upstream_when_unref(state, key)}
    end
  end

  defp add_pending_subscriber(state, pool_key, subscription_id, from, deadline_us) do
    entry = state.keys[pool_key]
    token = make_ref()
    timeout_ms = establishment_timeout_ms(deadline_us)

    timer_ref =
      Process.send_after(
        self(),
        {:subscription_establishment_timeout, pool_key, entry.establishment_generation,
         subscription_id, token},
        timeout_ms
      )

    waiter = %{
      subscription_id: subscription_id,
      from: from,
      token: token,
      timer_ref: timer_ref,
      deadline_us: deadline_us
    }

    pending = [waiter | Map.get(entry, :pending_subscribers, [])]
    %{state | keys: Map.put(state.keys, pool_key, Map.put(entry, :pending_subscribers, pending))}
  end

  defp settle_pending_subscribers(entry, outcome) do
    Enum.each(Map.get(entry, :pending_subscribers, []), fn waiter ->
      Process.cancel_timer(waiter.timer_ref)

      reply =
        case outcome do
          :established -> {:ok, waiter.subscription_id}
          {:error, reason} -> {:error, reason}
        end

      GenServer.reply(waiter.from, reply)
    end)

    Map.put(entry, :pending_subscribers, [])
  end

  defp establishment_timeout_ms(deadline_us) when is_integer(deadline_us) do
    remaining = div(deadline_us - System.monotonic_time(:microsecond) + 999, 1_000)
    max(min(remaining, @establishment_timeout_ms), 0)
  end

  defp establishment_timeout_ms(_deadline_us), do: @establishment_timeout_ms

  defp establishment_attempt_timeout(entry) do
    now_us = System.monotonic_time(:microsecond)

    entry
    |> Map.get(:pending_subscribers, [])
    |> Enum.map(fn
      %{deadline_us: deadline_us} when is_integer(deadline_us) ->
        max(div(deadline_us - now_us + 999, 1_000), 1)

      _waiter ->
        @establishment_timeout_ms
    end)
    |> Enum.min(fn -> @establishment_timeout_ms end)
    |> min(@establishment_timeout_ms)
  end

  defp clear_establishment_attempt(entry) do
    %{
      entry
      | establishment_attempt_token: nil,
        establishment_attempt_pid: nil,
        establishment_attempt_ref: nil,
        establishment_attempt_exclusions: []
    }
  end

  defp settle_resubscribe(
         state,
         pool_key,
         entry,
         coordinator_pid,
         new_provider_id,
         new_instance_id,
         {:ok, _status}
       ) do
    old_provider_id = entry.primary_provider_id
    old_instance_id = entry.instance_id
    subscription_key = entry.subscription_key
    InstanceSubscriptionRegistry.register_consumer(new_instance_id, subscription_key)

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

    if old_instance_id && old_instance_id != new_instance_id do
      Process.send_after(
        self(),
        {:deferred_release, pool_key, old_provider_id, old_instance_id},
        5_000
      )
    end

    {:noreply, new_state}
  end

  defp settle_resubscribe(
         state,
         pool_key,
         _entry,
         coordinator_pid,
         new_provider_id,
         _new_instance_id,
         {:error, reason}
       ) do
    Logger.error(
      "Resubscription failed for #{inspect(pool_key)} to #{new_provider_id}: #{inspect(reason)}"
    )

    send(coordinator_pid, {:subscription_failed, reason})
    {:noreply, state}
  end

  defp clear_resubscribe_attempt(entry) do
    %{
      entry
      | resubscribe_token: nil,
        resubscribe_pid: nil,
        resubscribe_ref: nil,
        resubscribe_coordinator_pid: nil
    }
  end

  defp subscription_key({:route, _provider_id, key}), do: key
  defp subscription_key(key), do: key

  defp remove_owned_client_subscription(state, subscription_id, nil, _client_pid, nil) do
    {removed?, state} = remove_client_subscription(state, subscription_id)
    {:ok, removed?, state}
  end

  defp remove_owned_client_subscription(
         state,
         subscription_id,
         request_owner_pid,
         client_pid,
         deadline_us
       ) do
    case ClientSubscriptionRegistry.remove_client_owned(
           state.profile,
           state.chain_id,
           subscription_id,
           request_owner_pid,
           client_pid,
           deadline_us
         ) do
      {:ok, nil} ->
        {:ok, false, state}

      {:ok, key} ->
        {:ok, true, maybe_drop_upstream_when_unref(state, key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_subscription_event(state, event) do
    topic = Lasso.Topics.subscription_event(state.profile, state.chain_id)
    Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)
  end

  defp pool_key(subscription_key, nil), do: subscription_key
  defp pool_key(subscription_key, provider_id), do: {:route, provider_id, subscription_key}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
