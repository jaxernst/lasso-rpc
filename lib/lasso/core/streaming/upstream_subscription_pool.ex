defmodule Lasso.RPC.UpstreamSubscriptionPool do
  @moduledoc """
  Per-chain pool that multiplexes client subscriptions onto minimal upstream
  subscriptions. MVP supports single-provider policy with priority selection,
  failover on disconnect/close, bounded backfill, and simple dedupe.

  ## Architecture

  Uses UpstreamSubscriptionManager for upstream subscription lifecycle:
  - Registers as consumer via Manager for each {provider, key} pair
  - Receives events via Registry dispatch (no PubSub filtering needed)
  - Manages failover by releasing old subscription and ensuring new one
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Events.Provider
  alias Lasso.RPC.{
    Channel,
    ClientSubscriptionRegistry,
    Selection,
    SelectionContext,
    StreamCoordinator,
    StreamSupervisor,
    UpstreamSubscriptionManager
  }

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type key :: {:newHeads} | {:logs, map()}

  def start_link(chain) when is_binary(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:pool, chain}}}

  @spec subscribe_client(chain, pid(), key) :: {:ok, String.t()} | {:error, term()}
  def subscribe_client(chain, client_pid, key) do
    GenServer.call(via(chain), {:subscribe, client_pid, key})
  end

  @spec unsubscribe_client(chain, String.t()) :: :ok | {:error, term()}
  def unsubscribe_client(chain, subscription_id) do
    GenServer.call(via(chain), {:unsubscribe, subscription_id})
  end

  # GenServer callbacks

  @impl true
  def init(chain) do
    # Subscribe to provider pool events for health/availability changes
    Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")

    # Subscribe to Manager restart events to re-establish subscriptions
    Phoenix.PubSub.subscribe(Lasso.PubSub, "upstream_sub_manager:#{chain}")

    # Load dedupe config
    dedupe_cfg =
      case ConfigStore.get_chain(chain) do
        {:ok, cfg} -> Map.get(cfg, :dedupe, %{})
        _ -> %{}
      end

    state = %{
      chain: chain,
      # key => %{refcount, primary_provider_id, status, markers, dedupe}
      keys: %{},
      # config
      dedupe_max_items: Map.get(dedupe_cfg, :max_items, 256),
      dedupe_max_age_ms: Map.get(dedupe_cfg, :max_age_ms, 30_000),
      max_backfill_blocks: 32,
      backfill_timeout: 30_000
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, client_pid, key}, _from, state) do
    # Allocate subscription id and register client immediately (non-blocking)
    subscription_id = generate_id()
    :ok = ClientSubscriptionRegistry.add_client(state.chain, subscription_id, client_pid, key)

    # Start coordinator for this key (idempotent, safe to call multiple times)
    _ = start_coordinator_for_key(state, key)

    # Handle subscription based on current key state
    new_state =
      case Map.get(state.keys, key) do
        nil ->
          # First subscriber - trigger async upstream establishment
          GenServer.cast(self(), {:establish_upstream, key, []})

          # Create entry to track the in-progress subscription
          entry = %{
            refcount: 1,
            status: :establishing,
            primary_provider_id: nil,
            markers: %{},
            dedupe: nil
          }

          telemetry_subscription_status(:establishing, state.chain, key, 1)
          %{state | keys: Map.put(state.keys, key, entry)}

        entry when entry.status == :establishing ->
          # Additional subscriber while still establishing - just increment refcount
          updated = %{entry | refcount: entry.refcount + 1}
          telemetry_subscription_status(:establishing, state.chain, key, updated.refcount)
          %{state | keys: Map.put(state.keys, key, updated)}

        entry when entry.status == :active ->
          # Subsequent subscriber - upstream already active, instant response
          updated = %{entry | refcount: entry.refcount + 1}
          telemetry_subscription_status(:active, state.chain, key, updated.refcount)
          %{state | keys: Map.put(state.keys, key, updated)}

        entry when entry.status == :failed ->
          # Previous establishment failed, retry
          GenServer.cast(self(), {:establish_upstream, key, []})

          updated = %{
            entry
            | refcount: entry.refcount + 1,
              status: :establishing
          }

          telemetry_subscription_status(:retry, state.chain, key, updated.refcount)
          %{state | keys: Map.put(state.keys, key, updated)}
      end

    {:reply, {:ok, subscription_id}, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case ClientSubscriptionRegistry.remove_client(state.chain, subscription_id) do
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

    # Get existing entry to preserve refcount
    entry = Map.get(state.keys, key)

    if entry do
      old_provider_id = entry.primary_provider_id

      # Register with new provider via Manager FIRST (before releasing old)
      # This ensures we receive events from both during transition - StreamCoordinator dedupes
      case UpstreamSubscriptionManager.ensure_subscription(state.chain, new_provider_id, key) do
        {:ok, _status} ->
          # Update entry with new provider, but track old for cleanup
          # We stay registered for old provider until coordinator confirms
          updated_entry = %{
            entry
            | primary_provider_id: new_provider_id,
              status: :active,
              # Track old provider for deferred cleanup
              transitioning_from: old_provider_id
          }

          new_state = %{state | keys: Map.put(state.keys, key, updated_entry)}

          # Confirm to coordinator
          send(coordinator_pid, {:subscription_confirmed, new_provider_id, nil})

          telemetry_resubscribe_success(state.chain, key, new_provider_id)

          # Schedule deferred release of old subscription after StreamCoordinator has drained buffer
          # This gives time for in-flight events to arrive and be forwarded
          if old_provider_id do
            Process.send_after(self(), {:deferred_release, key, old_provider_id}, 5_000)
          end

          {:noreply, new_state}

        {:error, reason} ->
          Logger.error(
            "Resubscription failed for #{inspect(key)} to #{new_provider_id}: #{inspect(reason)}"
          )

          # Notify coordinator of failure
          send(coordinator_pid, {:subscription_failed, reason})

          telemetry_resubscribe_failed(state.chain, key, new_provider_id, reason)

          {:noreply, state}
      end
    else
      # Key no longer exists (all clients unsubscribed during failover)
      Logger.debug("Resubscription skipped: key #{inspect(key)} no longer active")
      send(coordinator_pid, {:subscription_failed, :key_inactive})
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:establish_upstream, key, excluded_providers}, state) do
    with {:ok, entry} <- validate_entry_for_establishment(state.keys[key]),
         {:ok, provider_id} <- select_available_provider(state.chain, excluded_providers),
         {:ok, _status} <- attempt_upstream_subscribe(state.chain, provider_id, key) do
      # Happy path: subscription established successfully
      new_state = activate_subscription(state, key, entry, provider_id)

      Logger.info(
        "Upstream subscription established for key #{inspect(key)} on provider #{provider_id}"
      )

      telemetry_upstream(:subscribe, state.chain, provider_id, key)
      telemetry_subscription_status(:active, state.chain, key, entry.refcount)

      {:noreply, new_state}
    else
      {:error, :entry_invalid} ->
        # Entry cleaned up, wrong status, or no clients - skip silently
        {:noreply, state}

      {:error, :no_providers} ->
        # No providers available after exclusions
        new_state = mark_subscription_failed(state, key, "No available providers")
        {:noreply, new_state}

      {:error, {:subscribe_failed, provider_id, _reason}} ->
        # Subscription attempt failed - retry or fail
        new_excluded = [provider_id | excluded_providers]
        handle_subscription_failure(state, key, new_excluded)
    end
  end

  # Validate that entry exists and is ready for establishment
  defp validate_entry_for_establishment(nil), do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry) when entry.status != :establishing,
    do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry) when entry.refcount < 1,
    do: {:error, :entry_invalid}

  defp validate_entry_for_establishment(entry), do: {:ok, entry}

  # Select an available provider, excluding failed attempts
  defp select_available_provider(chain, excluded_providers) do
    channels =
      Selection.select_channels(chain, "eth_subscribe",
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

  # Attempt upstream subscription via Manager
  defp attempt_upstream_subscribe(chain, provider_id, key) do
    Logger.debug("Attempting upstream subscribe to #{provider_id} for key #{inspect(key)}")

    case UpstreamSubscriptionManager.ensure_subscription(chain, provider_id, key) do
      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        Logger.warning("Upstream subscribe failed on #{provider_id}: #{inspect(reason)}")
        {:error, {:subscribe_failed, provider_id, reason}}
    end
  end

  # Activate subscription after successful establishment
  defp activate_subscription(state, key, entry, provider_id) do
    updated_entry = %{
      entry
      | status: :active,
        primary_provider_id: provider_id
    }

    %{state | keys: Map.put(state.keys, key, updated_entry)}
  end

  # Handle subscription failure with retry logic
  defp handle_subscription_failure(state, key, excluded_providers) do
    max_attempts = 3

    if length(excluded_providers) < max_attempts do
      Logger.info(
        "Retrying upstream establishment for #{inspect(key)} (attempt #{length(excluded_providers) + 1}/#{max_attempts})"
      )

      GenServer.cast(self(), {:establish_upstream, key, excluded_providers})
      {:noreply, state}
    else
      Logger.error("Failed to establish upstream for #{inspect(key)} after #{max_attempts} attempts")
      new_state = mark_subscription_failed(state, key, "Max retries exceeded")
      {:noreply, new_state}
    end
  end

  # Mark subscription as failed
  defp mark_subscription_failed(state, key, reason) do
    case state.keys[key] do
      nil ->
        state

      entry ->
        updated_entry = %{entry | status: :failed}
        telemetry_subscription_status(:failed, state.chain, key, entry.refcount)
        Logger.error("Subscription failed for #{inspect(key)}: #{reason}")
        %{state | keys: Map.put(state.keys, key, updated_entry)}
    end
  end

  @impl true
  # Handle subscription events from UpstreamSubscriptionManager via Registry.dispatch
  # Format: {:upstream_subscription_event, provider_id, sub_key, payload, received_at}
  def handle_info(
        {:upstream_subscription_event, provider_id, key, payload, received_at},
        state
      )
      when is_map(payload) do
    # Forward events from active subscription or from old provider during transition
    # StreamCoordinator handles buffering and deduplication
    case Map.get(state.keys, key) do
      %{primary_provider_id: ^provider_id, status: :active} ->
        # Event from current primary provider
        StreamCoordinator.upstream_event(state.chain, key, provider_id, nil, payload, received_at)
        {:noreply, state}

      %{transitioning_from: ^provider_id, status: :active} ->
        # Event from old provider during transition - forward for deduplication
        # StreamCoordinator will buffer or dedupe as appropriate
        StreamCoordinator.upstream_event(state.chain, key, provider_id, nil, payload, received_at)
        {:noreply, state}

      _ ->
        # Not our active subscription (stale event or key doesn't exist)
        {:noreply, state}
    end
  end

  # Handle deferred release timer
  def handle_info({:deferred_release, key, old_provider_id}, state) do
    case Map.get(state.keys, key) do
      %{transitioning_from: ^old_provider_id} = entry ->
        # Release old subscription now that transition is complete
        UpstreamSubscriptionManager.release_subscription(state.chain, old_provider_id, key)

        # Clear the transitioning_from field
        updated_entry = Map.delete(entry, :transitioning_from)
        new_state = %{state | keys: Map.put(state.keys, key, updated_entry)}

        Logger.debug("Deferred release of old provider #{old_provider_id} for key #{inspect(key)}")

        {:noreply, new_state}

      _ ->
        # Key doesn't exist or already transitioned elsewhere
        {:noreply, state}
    end
  end

  def handle_info(evt, state)
      when is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.HealthCheckFailed) or
             is_struct(evt, Provider.WSClosed) or
             is_struct(evt, Provider.WSDisconnected) do
    provider_id = Map.get(evt, :provider_id)

    keys_to_failover =
      state.keys
      |> Enum.filter(fn {_key, entry} -> entry.primary_provider_id == provider_id end)
      |> Enum.map(fn {key, _} -> key end)

    Enum.each(keys_to_failover, fn key ->
      StreamCoordinator.provider_unhealthy(
        state.chain,
        key,
        provider_id,
        pick_next_provider(state, provider_id)
      )
    end)

    {:noreply, state}
  end

  # Handle subscription invalidation from UpstreamSubscriptionManager
  # Dispatched when subscription becomes stale or provider disconnects
  def handle_info({:upstream_subscription_invalidated, provider_id, key, reason}, state) do
    # Check if this affects one of our subscriptions
    case Map.get(state.keys, key) do
      %{primary_provider_id: ^provider_id} ->
        handle_subscription_invalidation(state, provider_id, key, reason)

      _ ->
        # Not our primary provider (already failed over or different subscription)
        :ok
    end

    {:noreply, state}
  end

  # Staleness: Provider is likely healthy, subscription just expired (e.g., DRPC ~21h TTL)
  # Resubscribe to the same provider to maintain priority order
  defp handle_subscription_invalidation(state, provider_id, key, :subscription_stale) do
    Logger.info("Subscription stale, resubscribing to same provider",
      chain: state.chain,
      provider_id: provider_id,
      key: inspect(key)
    )

    # Resubscribe to the same provider (don't failover)
    case UpstreamSubscriptionManager.ensure_subscription(state.chain, provider_id, key) do
      {:ok, _status} ->
        Logger.debug("Resubscribed after staleness",
          chain: state.chain,
          provider_id: provider_id,
          key: inspect(key)
        )

      {:error, reason} ->
        # Resubscription failed - now failover to next provider
        Logger.warning("Resubscription failed after staleness, failing over",
          chain: state.chain,
          provider_id: provider_id,
          key: inspect(key),
          reason: inspect(reason)
        )

        StreamCoordinator.provider_unhealthy(
          state.chain,
          key,
          provider_id,
          pick_next_provider(state, provider_id)
        )
    end
  end

  # Provider disconnected: Actual connectivity issue, failover to next provider
  defp handle_subscription_invalidation(state, provider_id, key, :provider_disconnected) do
    Logger.info("Provider disconnected, failing over",
      chain: state.chain,
      provider_id: provider_id,
      key: inspect(key)
    )

    StreamCoordinator.provider_unhealthy(
      state.chain,
      key,
      provider_id,
      pick_next_provider(state, provider_id)
    )
  end

  # Unknown reason: Default to failover for safety
  defp handle_subscription_invalidation(state, provider_id, key, reason) do
    Logger.info("Subscription invalidated with unknown reason, failing over",
      chain: state.chain,
      provider_id: provider_id,
      key: inspect(key),
      reason: reason
    )

    StreamCoordinator.provider_unhealthy(
      state.chain,
      key,
      provider_id,
      pick_next_provider(state, provider_id)
    )
  end

  # Handle Manager restart - re-establish all active subscriptions
  def handle_info({:upstream_sub_manager_restarted, _chain}, state) do
    active_keys =
      state.keys
      |> Enum.filter(fn {_key, entry} ->
        entry.status == :active and entry.primary_provider_id != nil
      end)
      |> Enum.map(fn {key, entry} -> {key, entry.primary_provider_id} end)

    if active_keys != [] do
      Logger.info("Manager restarted, re-establishing #{length(active_keys)} active subscriptions",
        chain: state.chain
      )

      # Re-register each active subscription with the Manager
      Enum.each(active_keys, fn {key, provider_id} ->
        case UpstreamSubscriptionManager.ensure_subscription(state.chain, provider_id, key) do
          {:ok, _status} ->
            Logger.debug("Re-established subscription after Manager restart",
              chain: state.chain,
              key: inspect(key),
              provider_id: provider_id
            )

          {:error, reason} ->
            # If re-establishment fails, trigger failover
            Logger.warning("Failed to re-establish subscription after Manager restart",
              chain: state.chain,
              key: inspect(key),
              provider_id: provider_id,
              reason: inspect(reason)
            )

            # Trigger failover to another provider
            StreamCoordinator.provider_unhealthy(
              state.chain,
              key,
              provider_id,
              pick_next_provider(state, provider_id)
            )
        end
      end)
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

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

    StreamSupervisor.ensure_coordinator(state.chain, key, opts)
  end

  defp pick_next_provider(state, failed_provider_id) do
    case Selection.select_provider(
           SelectionContext.new(state.chain, "eth_subscribe",
             strategy: :priority,
             protocol: :ws,
             exclude: [failed_provider_id]
           )
         ) do
      {:ok, provider} -> provider
      _ -> failed_provider_id
    end
  end

  defp maybe_drop_upstream_when_unref(state, key) do
    case Map.get(state.keys, key) do
      nil ->
        state

      %{refcount: 1, primary_provider_id: provider_id} when not is_nil(provider_id) ->
        # Release subscription from Manager
        UpstreamSubscriptionManager.release_subscription(state.chain, provider_id, key)

        telemetry_upstream(:unsubscribe, state.chain, provider_id, key)

        # Stop the StreamCoordinator for this key (async to avoid blocking)
        Task.start(fn -> StreamSupervisor.stop_coordinator(state.chain, key) end)

        %{state | keys: Map.delete(state.keys, key)}

      %{refcount: 1} ->
        # No provider assigned yet, just clean up
        Task.start(fn -> StreamSupervisor.stop_coordinator(state.chain, key) end)
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

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
