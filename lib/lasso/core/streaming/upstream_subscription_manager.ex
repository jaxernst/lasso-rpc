defmodule Lasso.Core.Streaming.UpstreamSubscriptionManager do
  @moduledoc """
  Per-chain manager for upstream WebSocket subscriptions.

  Multiplexes a single upstream subscription to multiple consumers.
  Handles subscription lifecycle (create on first consumer, teardown after grace period).

  ## Architecture

  This manager sits between consumers (BlockHeightMonitor, UpstreamSubscriptionPool) and
  the upstream WebSocket connections. It ensures:

  1. **Single subscription per key:** Each `{provider_id, sub_key}` has exactly one upstream subscription
  2. **Automatic multiplexing:** Events are dispatched to all registered consumers via Registry
  3. **Lifecycle management:** Subscriptions are created on first consumer, torn down when no consumers remain
  4. **Grace period:** A delay before tearing down to handle temporary consumer absence

  ## Message Flow

      WSConnection receives event
          │
          └─► PubSub broadcast to "ws:subs:{chain}"
                  │
                  └─► UpstreamSubscriptionManager
                          │
                          └─► Registry.dispatch to consumers
                                  │
                                  ├─► BlockHeightMonitor
                                  └─► UpstreamSubscriptionPool

  ## Usage

      # Consumer registers for subscription
      {:ok, :new | :existing} = UpstreamSubscriptionManager.ensure_subscription(
        "ethereum",
        "alchemy",
        {:newHeads}
      )

      # Consumer receives events as:
      {:upstream_subscription_event, provider_id, sub_key, payload, received_at}

      # Consumer unregisters when done
      :ok = UpstreamSubscriptionManager.release_subscription("ethereum", "alchemy", {:newHeads})
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Streaming.UpstreamSubscriptionRegistry
  alias Lasso.RPC.{TransportRegistry, Channel}
  alias Lasso.RPC.Response

  @cleanup_interval_ms 30_000
  @teardown_grace_period_ms 60_000
  # Remove disconnected connection states after 5 minutes to prevent memory growth
  @stale_connection_cleanup_ms 300_000

  # Subscription liveness monitoring
  # Grace period for new subscriptions before staleness check starts
  @new_subscription_grace_ms 30_000
  # Default staleness threshold if config unavailable (Ethereum mainnet: ~4 blocks + margin)
  @default_new_heads_staleness_threshold_ms 42_000

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type sub_key :: {:newHeads} | {:logs, map()}
  @type upstream_id :: String.t()

  @type t :: %__MODULE__{
          profile: String.t(),
          chain: String.t(),
          active_subscriptions: map(),
          upstream_index: map(),
          connection_states: map(),
          new_heads_staleness_threshold_ms: pos_integer() | nil
        }

  defstruct [
    :profile,
    :chain,
    # %{{provider_id, sub_key} => %{upstream_id, connection_id, created_at, marked_for_teardown_at, last_event_at, staleness_timer_ref}}
    active_subscriptions: %{},
    # %{upstream_id => {provider_id, sub_key}} - reverse lookup for incoming events
    upstream_index: %{},
    # %{provider_id => %{connection_id, status, connected_at}} - track connection state per provider
    # Used to detect stale subscriptions after reconnect
    connection_states: %{},
    # Staleness threshold in ms (read from chain config's new_heads_staleness_threshold_ms)
    new_heads_staleness_threshold_ms: nil
  ]

  # Client API

  def start_link({profile, chain}) when is_binary(profile) and is_binary(chain) do
    GenServer.start_link(__MODULE__, {profile, chain}, name: via(profile, chain))
  end

  def via(profile, chain) when is_binary(profile) and is_binary(chain) do
    {:via, Registry, {Lasso.Registry, {:upstream_sub_manager, profile, chain}}}
  end

  @doc """
  Ensure a subscription exists and register caller as consumer.

  This is the primary API for consumers. It:
  1. Registers the caller in the UpstreamSubscriptionRegistry
  2. Creates the upstream subscription if it doesn't exist
  3. Cancels any pending teardown if the subscription was marked for removal

  Returns:
  - `{:ok, :new}` if a new upstream subscription was created
  - `{:ok, :existing}` if joining an existing subscription
  - `{:error, reason}` if subscription creation failed
  """
  @spec ensure_subscription(String.t(), chain(), provider_id(), sub_key()) ::
          {:ok, :new | :existing} | {:error, term()}
  def ensure_subscription(profile, chain, provider_id, sub_key)
      when is_binary(profile) and is_binary(chain) do
    # Register as consumer first (idempotent per-process)
    case UpstreamSubscriptionRegistry.register_consumer(profile, chain, provider_id, sub_key) do
      :ok ->
        # Use :infinity - the inner Channel.request has its own bounded timeout (10s)
        # and will return {:error, :timeout} which propagates up cleanly
        GenServer.call(via(profile, chain), {:ensure_subscription, provider_id, sub_key}, :infinity)

      {:error, reason} ->
        {:error, {:registry_error, reason}}
    end
  end

  @doc """
  Unregister caller as consumer.

  Subscription will be torn down after grace period if no consumers remain.
  """
  @spec release_subscription(String.t(), chain(), provider_id(), sub_key()) :: :ok
  def release_subscription(profile, chain, provider_id, sub_key)
      when is_binary(profile) and is_binary(chain) do
    UpstreamSubscriptionRegistry.unregister_consumer(profile, chain, provider_id, sub_key)
    GenServer.cast(via(profile, chain), {:check_teardown, provider_id, sub_key})
  end

  @doc """
  Get status of all active subscriptions for this chain.
  """
  @spec get_status(String.t(), chain()) :: map()
  def get_status(profile, chain) when is_binary(profile) and is_binary(chain) do
    GenServer.call(via(profile, chain), :get_status)
  catch
    :exit, _ -> %{error: :not_running}
  end

  # GenServer Callbacks

  @impl true
  @spec init({String.t(), String.t()}) :: {:ok, t()}
  def init({profile, chain}) do
    # Subscribe to all subscription events for this chain (profile-scoped)
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:subs:#{profile}:#{chain}")

    # Subscribe to connection events for connection state tracking
    # This enables connection_id validation to detect stale subscriptions after reconnect
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{profile}:#{chain}")

    # Schedule periodic cleanup check
    Process.send_after(self(), :cleanup_check, @cleanup_interval_ms)

    # Broadcast restart event so consumers can re-register their subscriptions
    # This handles the case where Manager crashed/restarted but consumers are still alive
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "upstream_sub_manager:#{profile}:#{chain}",
      {:upstream_sub_manager_restarted, chain}
    )

    new_heads_staleness_threshold_ms = calculate_staleness_threshold(profile, chain)

    {:ok,
     %__MODULE__{
       profile: profile,
       chain: chain,
       new_heads_staleness_threshold_ms: new_heads_staleness_threshold_ms
     }}
  end

  @impl true
  def handle_call({:ensure_subscription, provider_id, sub_key}, _from, state) do
    key = {provider_id, sub_key}

    # Connection state is required for subscription validation
    case Map.get(state.connection_states, provider_id) do
      nil ->
        # Connection state unknown - consumer called before we received ws_connected
        # Consumer should retry after short delay
        {:reply, {:error, :connection_unknown}, state}

      %{status: :disconnected} ->
        # Provider is disconnected - cannot create subscription
        {:reply, {:error, :not_connected}, state}

      %{connection_id: current_conn_id} = _conn_state ->
        handle_subscription_request(state, provider_id, sub_key, key, current_conn_id)
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      profile: state.profile,
      chain: state.chain,
      connection_states: state.connection_states,
      active_subscriptions:
        Map.new(state.active_subscriptions, fn {{provider_id, sub_key}, info} ->
          consumer_count =
            UpstreamSubscriptionRegistry.count_consumers(state.profile, state.chain, provider_id, sub_key)

          {{provider_id, sub_key},
           %{
             upstream_id: info.upstream_id,
             connection_id: info.connection_id,
             created_at: info.created_at,
             marked_for_teardown: info.marked_for_teardown_at != nil,
             consumer_count: consumer_count
           }}
        end)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:check_teardown, provider_id, sub_key}, state) do
    key = {provider_id, sub_key}

    case Map.get(state.active_subscriptions, key) do
      nil ->
        {:noreply, state}

      sub_info ->
        consumer_count =
          UpstreamSubscriptionRegistry.count_consumers(state.profile, state.chain, provider_id, sub_key)

        if consumer_count == 0 do
          # Mark for teardown (will be cleaned up by periodic check)
          Logger.debug("Marking subscription for teardown",
            chain: state.chain,
            provider_id: provider_id,
            sub_key: inspect(sub_key)
          )

          new_sub_info = %{sub_info | marked_for_teardown_at: System.monotonic_time(:millisecond)}
          new_subs = Map.put(state.active_subscriptions, key, new_sub_info)
          {:noreply, %{state | active_subscriptions: new_subs}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:subscription_event, provider_id, upstream_id, payload, received_at}, state) do
    # Find which subscription this event belongs to using reverse lookup
    case Map.get(state.upstream_index, upstream_id) do
      {^provider_id, sub_key} = key ->
        # Dispatch to all consumers via Registry
        UpstreamSubscriptionRegistry.dispatch(
          state.profile,
          state.chain,
          provider_id,
          sub_key,
          {:upstream_subscription_event, provider_id, sub_key, payload, received_at}
        )

        state = update_subscription_liveness(state, key, received_at)

        {:noreply, state}

      nil ->
        # Orphaned subscription event
        Logger.debug("Received event for unknown subscription",
          chain: state.chain,
          provider_id: provider_id,
          upstream_id: upstream_id,
          active_subscription_count: map_size(state.active_subscriptions)
        )

        emit_telemetry(:orphaned_event, state.chain, provider_id, nil)
        {:noreply, state}

      _mismatch ->
        # Provider mismatch in index - shouldn't happen
        Logger.warning("Provider mismatch in upstream index",
          chain: state.chain,
          expected_provider: provider_id,
          upstream_id: upstream_id
        )

        {:noreply, state}
    end
  end

  def handle_info(:cleanup_check, state) do
    now = System.monotonic_time(:millisecond)

    # Cleanup subscriptions marked for teardown
    {to_teardown, to_keep} =
      Enum.split_with(state.active_subscriptions, fn {_key, sub_info} ->
        sub_info.marked_for_teardown_at != nil and
          now - sub_info.marked_for_teardown_at >= @teardown_grace_period_ms
      end)

    new_upstream_index =
      Enum.reduce(to_teardown, state.upstream_index, fn {{provider_id, sub_key}, sub_info}, acc ->
        # Cancel staleness timer before teardown
        if sub_info.staleness_timer_ref, do: Process.cancel_timer(sub_info.staleness_timer_ref)

        teardown_upstream_subscription(state.profile, state.chain, provider_id, sub_key, sub_info.upstream_id)
        emit_telemetry(:subscription_destroyed, state.chain, provider_id, sub_key)
        Map.delete(acc, sub_info.upstream_id)
      end)

    # Cleanup stale disconnected connection states to prevent memory growth
    new_connection_states =
      Map.filter(state.connection_states, fn {_provider_id, conn_state} ->
        case conn_state do
          %{status: :disconnected, disconnected_at: disconnected_at} ->
            now - disconnected_at < @stale_connection_cleanup_ms

          _ ->
            true
        end
      end)

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_check, @cleanup_interval_ms)

    {:noreply,
     %{
       state
       | active_subscriptions: Map.new(to_keep),
         upstream_index: new_upstream_index,
         connection_states: new_connection_states
     }}
  end

  # Connection established - track connection state for subscription validation
  def handle_info({:ws_connected, provider_id, connection_id}, state) do
    conn_state = %{
      connection_id: connection_id,
      status: :connected,
      connected_at: System.monotonic_time(:millisecond)
    }

    new_connection_states = Map.put(state.connection_states, provider_id, conn_state)
    {:noreply, %{state | connection_states: new_connection_states}}
  end

  # Connection lost - invalidate subscriptions and update state
  def handle_info({:ws_disconnected, provider_id, _error}, state) do
    handle_disconnect(state, provider_id)
  end

  def handle_info({:ws_closed, provider_id, _code, _error}, state) do
    handle_disconnect(state, provider_id)
  end

  # Staleness timer fired - subscription hasn't received events within threshold
  # Note: logs subscriptions don't have staleness monitoring (they can legitimately go silent)
  def handle_info({:staleness_check, _provider_id, {:logs, _filter}, _timer_ref}, state) do
    # Ignore staleness checks for logs subscriptions
    {:noreply, state}
  end

  def handle_info({:staleness_check, provider_id, sub_key, timer_ref}, state) do
    key = {provider_id, sub_key}

    case Map.get(state.active_subscriptions, key) do
      nil ->
        # Subscription no longer exists
        {:noreply, state}

      %{staleness_timer_ref: current_ref} when current_ref != timer_ref ->
        # Stale timer message (timer was cancelled/replaced but message was already in mailbox)
        {:noreply, state}

      %{marked_for_teardown_at: teardown_at} when not is_nil(teardown_at) ->
        # Already marked for teardown, don't invalidate
        {:noreply, state}

      sub_info ->
        # Subscription is stale - invalidate it
        handle_stale_subscription(state, key, sub_info)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_disconnect(state, provider_id) do
    # Update connection state
    conn_state = %{
      connection_id: nil,
      status: :disconnected,
      disconnected_at: System.monotonic_time(:millisecond)
    }

    state = %{
      state
      | connection_states: Map.put(state.connection_states, provider_id, conn_state)
    }

    # Find and invalidate all subscriptions for this provider
    affected =
      Enum.filter(state.active_subscriptions, fn {{prov_id, _sub_key}, _info} ->
        prov_id == provider_id
      end)

    if affected == [] do
      {:noreply, state}
    else
      Logger.info("Provider disconnected, invalidating subscriptions",
        chain: state.chain,
        provider_id: provider_id,
        affected_count: length(affected)
      )

      # Cancel timers and notify consumers so they can re-subscribe when connection returns
      Enum.each(affected, fn {{prov_id, sub_key}, info} ->
        # Cancel staleness timer
        if info.staleness_timer_ref, do: Process.cancel_timer(info.staleness_timer_ref)

        UpstreamSubscriptionRegistry.dispatch(
          state.profile,
          state.chain,
          prov_id,
          sub_key,
          {:upstream_subscription_invalidated, prov_id, sub_key, :provider_disconnected}
        )
      end)

      # Remove subscriptions from state
      new_subs =
        Enum.reduce(affected, state.active_subscriptions, fn {key, _}, acc ->
          Map.delete(acc, key)
        end)

      new_index =
        Enum.reduce(affected, state.upstream_index, fn {_key, info}, acc ->
          Map.delete(acc, info.upstream_id)
        end)

      {:noreply, %{state | active_subscriptions: new_subs, upstream_index: new_index}}
    end
  end

  # Private helpers

  # Handle subscription request when we have a valid connection
  defp handle_subscription_request(state, provider_id, sub_key, key, current_conn_id) do
    case Map.get(state.active_subscriptions, key) do
      nil ->
        # First consumer - create upstream subscription
        create_new_subscription(state, provider_id, sub_key, key, current_conn_id)

      %{marked_for_teardown_at: nil, connection_id: ^current_conn_id} ->
        # Subscription exists for current connection - reuse it
        {:reply, {:ok, :existing}, state}

      %{marked_for_teardown_at: nil, connection_id: stale_conn_id} = sub_info ->
        # Stale subscription from previous connection - remove and recreate
        Logger.info("Detected stale subscription, recreating",
          chain: state.chain,
          provider_id: provider_id,
          sub_key: inspect(sub_key),
          stale_conn_id: stale_conn_id,
          current_conn_id: current_conn_id
        )

        emit_telemetry(:stale_subscription_detected, state.chain, provider_id, sub_key)

        state = remove_subscription(state, key, sub_info.upstream_id)
        create_new_subscription(state, provider_id, sub_key, key, current_conn_id)

      %{connection_id: ^current_conn_id} = sub_info ->
        # Marked for teardown but connection still valid - cancel teardown
        Logger.debug("Cancelling teardown for subscription",
          chain: state.chain,
          provider_id: provider_id,
          sub_key: inspect(sub_key)
        )

        new_sub_info = %{sub_info | marked_for_teardown_at: nil}
        new_subs = Map.put(state.active_subscriptions, key, new_sub_info)
        {:reply, {:ok, :existing}, %{state | active_subscriptions: new_subs}}

      %{upstream_id: upstream_id} ->
        # Stale subscription marked for teardown - remove and recreate
        state = remove_subscription(state, key, upstream_id)
        create_new_subscription(state, provider_id, sub_key, key, current_conn_id)
    end
  end

  defp remove_subscription(state, key, upstream_id) do
    # Cancel staleness timer before removing subscription
    case Map.get(state.active_subscriptions, key) do
      %{staleness_timer_ref: ref} when not is_nil(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    new_subs = Map.delete(state.active_subscriptions, key)
    new_index = Map.delete(state.upstream_index, upstream_id)
    %{state | active_subscriptions: new_subs, upstream_index: new_index}
  end

  defp create_new_subscription(state, provider_id, sub_key, key, connection_id) do
    case create_upstream_subscription(state.profile, state.chain, provider_id, sub_key) do
      {:ok, upstream_id} ->
        now = System.monotonic_time(:millisecond)

        # Start staleness timer for newHeads subscriptions
        # Use grace period for initial timer to allow subscription to warm up
        staleness_timer_ref =
          schedule_staleness_check(state, provider_id, sub_key, @new_subscription_grace_ms)

        sub_info = %{
          upstream_id: upstream_id,
          connection_id: connection_id,
          created_at: now,
          marked_for_teardown_at: nil,
          last_event_at: now,
          staleness_timer_ref: staleness_timer_ref
        }

        new_subs = Map.put(state.active_subscriptions, key, sub_info)
        new_index = Map.put(state.upstream_index, upstream_id, key)

        Logger.info("Created upstream subscription",
          chain: state.chain,
          provider_id: provider_id,
          sub_key: inspect(sub_key),
          upstream_id: upstream_id,
          connection_id: connection_id
        )

        emit_telemetry(:subscription_created, state.chain, provider_id, sub_key)

        {:reply, {:ok, :new},
         %{state | active_subscriptions: new_subs, upstream_index: new_index}}

      {:error, reason} ->
        Logger.debug("Failed to create upstream subscription",
          chain: state.chain,
          provider_id: provider_id,
          sub_key: inspect(sub_key),
          reason: inspect(reason)
        )

        # If the error indicates the connection is dead, update connection_states
        # to prevent infinite retry loops where we keep trying to use a dead connection
        state =
          if connection_dead_error?(reason) do
            Logger.debug("Detected dead connection during subscription, marking disconnected",
              chain: state.chain,
              provider_id: provider_id
            )

            conn_state = %{
              connection_id: nil,
              status: :disconnected,
              disconnected_at: System.monotonic_time(:millisecond)
            }

            %{state | connection_states: Map.put(state.connection_states, provider_id, conn_state)}
          else
            state
          end

        {:reply, {:error, reason}, state}
    end
  end

  # Detect errors that indicate the WebSocket connection process is dead
  # These errors mean the connection_states is stale and should be updated
  defp connection_dead_error?(%Lasso.JSONRPC.Error{message: message}) when is_binary(message) do
    message_lower = String.downcase(message)

    String.contains?(message_lower, "noproc") or
      String.contains?(message_lower, "not connected") or
      String.contains?(message_lower, "process not alive")
  end

  defp connection_dead_error?(:noproc), do: true
  defp connection_dead_error?(:not_connected), do: true
  defp connection_dead_error?({:noproc, _}), do: true
  defp connection_dead_error?(_), do: false

  defp create_upstream_subscription(profile, chain, provider_id, {:newHeads}) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }

    with {:ok, channel} <- TransportRegistry.get_channel(profile, chain, provider_id, :ws),
         {:ok, %Response.Success{} = response, _io_ms} <- Channel.request(channel, message, 10_000),
         {:ok, upstream_id} <- Response.Success.decode_result(response) do
      {:ok, upstream_id}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _io_ms} -> {:error, reason}
    end
  end

  defp create_upstream_subscription(profile, chain, provider_id, {:logs, filter}) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_subscribe",
      "params" => ["logs", filter]
    }

    with {:ok, channel} <- TransportRegistry.get_channel(profile, chain, provider_id, :ws),
         {:ok, %Response.Success{} = response, _io_ms} <- Channel.request(channel, message, 10_000),
         {:ok, upstream_id} <- Response.Success.decode_result(response) do
      {:ok, upstream_id}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _io_ms} -> {:error, reason}
    end
  end

  defp teardown_upstream_subscription(profile, chain, provider_id, sub_key, upstream_id) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_unsubscribe",
      "params" => [upstream_id]
    }

    case TransportRegistry.get_channel(profile, chain, provider_id, :ws) do
      {:ok, channel} ->
        _ = Channel.request(channel, message, 5_000)

        Logger.info("Tore down upstream subscription",
          chain: chain,
          provider_id: provider_id,
          sub_key: inspect(sub_key),
          upstream_id: upstream_id
        )

      {:error, _} ->
        # Channel not available (provider disconnected) - subscription already gone
        :ok
    end
  end

  defp emit_telemetry(event, chain, provider_id, sub_key) do
    :telemetry.execute(
      [:lasso, :upstream_subscriptions, event],
      %{count: 1},
      %{chain: chain, provider_id: provider_id, sub_key: inspect(sub_key)}
    )
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # Subscription liveness monitoring helpers

  defp calculate_staleness_threshold(profile, chain) do
    case ConfigStore.get_chain(profile, chain) do
      {:ok, config} ->
        config.monitoring.new_heads_staleness_threshold_ms

      _ ->
        @default_new_heads_staleness_threshold_ms
    end
  end

  # Schedule a staleness check timer for newHeads subscriptions
  # Returns nil for logs subscriptions (staleness detection not supported yet)
  # Returns the timer ref which is also included in the message for race condition prevention
  defp schedule_staleness_check(_state, _provider_id, {:logs, _filter}, _delay_ms), do: nil

  defp schedule_staleness_check(_state, provider_id, sub_key, delay_ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {:staleness_check, provider_id, sub_key, timer_ref}, delay_ms)
    timer_ref
  end

  # Update last_event_at and reset staleness timer when an event is received
  defp update_subscription_liveness(state, {provider_id, sub_key} = key, received_at) do
    case Map.get(state.active_subscriptions, key) do
      nil ->
        state

      sub_info ->
        # Cancel existing timer
        if sub_info.staleness_timer_ref do
          Process.cancel_timer(sub_info.staleness_timer_ref)
        end

        # Schedule new staleness check (only for newHeads)
        new_timer_ref =
          schedule_staleness_check(
            state,
            provider_id,
            sub_key,
            state.new_heads_staleness_threshold_ms
          )

        updated_info = %{
          sub_info
          | last_event_at: received_at,
            staleness_timer_ref: new_timer_ref
        }

        %{state | active_subscriptions: Map.put(state.active_subscriptions, key, updated_info)}
    end
  end

  # Handle a subscription that hasn't received events within the staleness threshold
  defp handle_stale_subscription(state, {provider_id, sub_key} = key, sub_info) do
    now = System.monotonic_time(:millisecond)
    stale_duration_ms = now - sub_info.last_event_at

    Logger.warning("Subscription stale - no events received",
      chain: state.chain,
      provider_id: provider_id,
      sub_key: inspect(sub_key),
      stale_duration_ms: stale_duration_ms,
      threshold_ms: state.new_heads_staleness_threshold_ms,
      last_event_at: sub_info.last_event_at,
      upstream_id: sub_info.upstream_id
    )

    # Emit telemetry
    :telemetry.execute(
      [:lasso, :upstream_subscriptions, :staleness_detected],
      %{count: 1, stale_duration_ms: stale_duration_ms},
      %{chain: state.chain, provider_id: provider_id, sub_key: inspect(sub_key)}
    )

    # Cancel staleness timer
    if sub_info.staleness_timer_ref do
      Process.cancel_timer(sub_info.staleness_timer_ref)
    end

    # Unsubscribe from the upstream provider to clean up their resources
    # Do this asynchronously to avoid blocking the GenServer
    spawn(fn ->
      teardown_upstream_subscription(state.profile, state.chain, provider_id, sub_key, sub_info.upstream_id)
    end)

    # Notify consumers so they can failover
    UpstreamSubscriptionRegistry.dispatch(
      state.profile,
      state.chain,
      provider_id,
      sub_key,
      {:upstream_subscription_invalidated, provider_id, sub_key, :subscription_stale}
    )

    # Remove subscription from state (consumers will re-subscribe to a different provider)
    new_subs = Map.delete(state.active_subscriptions, key)
    new_index = Map.delete(state.upstream_index, sub_info.upstream_id)

    {:noreply, %{state | active_subscriptions: new_subs, upstream_index: new_index}}
  end
end
