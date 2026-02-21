defmodule Lasso.Core.Streaming.InstanceSubscriptionManager do
  @moduledoc """
  Per-instance manager for upstream WebSocket subscriptions.

  One manager per `instance_id`, living under InstanceSupervisor. Owns the upstream
  subscription lifecycle (eth_subscribe/eth_unsubscribe), connection tracking,
  staleness detection, and teardown grace period.

  Consumers (UpstreamSubscriptionPool, BlockSync.Worker) interact via the
  InstanceSubscriptionRegistry. Events are dispatched to all registered consumers.

  ## Message Flow

      WSConnection receives event
          │
          └─► PubSub broadcast to "ws:subs:instance:{instance_id}"
                  │
                  └─► InstanceSubscriptionManager
                          │
                          └─► InstanceSubscriptionRegistry.dispatch to consumers
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Streaming.InstanceSubscriptionRegistry
  alias Lasso.Events.Subscription
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Response
  alias Lasso.RPC.Transport.WebSocket.Connection

  @cleanup_interval_ms 30_000
  @teardown_grace_period_ms 60_000
  @stale_connection_cleanup_ms 300_000
  @new_subscription_grace_ms 30_000
  @default_new_heads_staleness_threshold_ms 42_000

  @type sub_key :: {:newHeads} | {:logs, map()}

  defstruct [
    :instance_id,
    :chain,
    active_subscriptions: %{},
    upstream_index: %{},
    connection_state: nil,
    new_heads_staleness_threshold_ms: nil,
    orphan_event_count: 0
  ]

  # Client API

  @spec start_link({String.t(), String.t()}) :: GenServer.on_start()
  def start_link({chain, instance_id}) when is_binary(chain) and is_binary(instance_id) do
    GenServer.start_link(__MODULE__, {chain, instance_id}, name: via(instance_id))
  end

  @spec via(String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(instance_id) when is_binary(instance_id) do
    {:via, Registry, {Lasso.Registry, {:instance_sub_manager, instance_id}}}
  end

  @doc """
  Ensure a subscription exists for this instance. Caller must separately
  register in InstanceSubscriptionRegistry.
  """
  @spec ensure_subscription(String.t(), sub_key()) ::
          {:ok, :new | :existing} | {:error, term()}
  def ensure_subscription(instance_id, sub_key) when is_binary(instance_id) do
    GenServer.call(via(instance_id), {:ensure_subscription, sub_key}, 15_000)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Release a subscription. Subscription tears down after grace period if no consumers remain.
  """
  @spec release_subscription(String.t(), sub_key()) :: :ok
  def release_subscription(instance_id, sub_key) when is_binary(instance_id) do
    GenServer.cast(via(instance_id), {:check_teardown, sub_key})
  end

  @spec get_status(String.t()) :: map()
  def get_status(instance_id) when is_binary(instance_id) do
    GenServer.call(via(instance_id), :get_status)
  catch
    :exit, _ -> %{error: :not_running}
  end

  # GenServer Callbacks

  @impl true
  def init({chain, instance_id}) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:subs:instance:#{instance_id}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:instance:#{instance_id}")

    Process.send_after(self(), :cleanup_check, @cleanup_interval_ms)

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "instance_sub_manager:restarted:#{chain}",
      {:instance_sub_manager_restarted, instance_id}
    )

    new_heads_staleness_threshold_ms = calculate_staleness_threshold(instance_id, chain)

    {:ok,
     %__MODULE__{
       instance_id: instance_id,
       chain: chain,
       new_heads_staleness_threshold_ms: new_heads_staleness_threshold_ms
     }}
  end

  @impl true
  def handle_call({:ensure_subscription, sub_key}, _from, state) do
    case state.connection_state do
      nil ->
        {:reply, {:error, :connection_unknown}, state}

      %{status: :disconnected} ->
        {:reply, {:error, :not_connected}, state}

      %{connection_id: current_conn_id} ->
        handle_subscription_request(state, sub_key, current_conn_id)
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      instance_id: state.instance_id,
      chain: state.chain,
      connection_state: state.connection_state,
      active_subscriptions:
        Map.new(state.active_subscriptions, fn {sub_key, info} ->
          consumer_count =
            InstanceSubscriptionRegistry.count_consumers(state.instance_id, sub_key)

          {sub_key,
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
  def handle_cast({:check_teardown, sub_key}, state) do
    case Map.get(state.active_subscriptions, sub_key) do
      nil ->
        {:noreply, state}

      sub_info ->
        consumer_count =
          InstanceSubscriptionRegistry.count_consumers(state.instance_id, sub_key)

        if consumer_count == 0 do
          Logger.debug("Marking subscription for teardown",
            instance_id: state.instance_id,
            sub_key: inspect(sub_key)
          )

          new_sub_info = %{sub_info | marked_for_teardown_at: System.monotonic_time(:millisecond)}
          new_subs = Map.put(state.active_subscriptions, sub_key, new_sub_info)
          {:noreply, %{state | active_subscriptions: new_subs}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:subscription_event, instance_id, upstream_id, payload, received_at}, state)
      when instance_id == state.instance_id do
    case Map.get(state.upstream_index, upstream_id) do
      nil ->
        orphan_count = state.orphan_event_count + 1

        if orphan_count == 1 or rem(orphan_count, 100) == 0 do
          Logger.debug("Orphaned subscription events",
            instance_id: state.instance_id,
            count: orphan_count
          )
        end

        emit_telemetry(:orphaned_event, state, nil)
        {:noreply, %{state | orphan_event_count: orphan_count}}

      sub_key ->
        InstanceSubscriptionRegistry.dispatch(
          state.instance_id,
          sub_key,
          {:instance_subscription_event, state.instance_id, sub_key, payload, received_at}
        )

        state = update_subscription_liveness(state, sub_key, received_at)
        {:noreply, state}
    end
  end

  def handle_info(:cleanup_check, state) do
    now = System.monotonic_time(:millisecond)

    {to_teardown, to_keep} =
      Enum.split_with(state.active_subscriptions, fn {_key, sub_info} ->
        sub_info.marked_for_teardown_at != nil and
          now - sub_info.marked_for_teardown_at >= @teardown_grace_period_ms
      end)

    new_upstream_index =
      Enum.reduce(to_teardown, state.upstream_index, fn {sub_key, sub_info}, acc ->
        if sub_info.staleness_timer_ref, do: Process.cancel_timer(sub_info.staleness_timer_ref)

        teardown_upstream_subscription(state.instance_id, sub_key, sub_info.upstream_id)
        emit_telemetry(:subscription_destroyed, state, sub_key)
        Map.delete(acc, sub_info.upstream_id)
      end)

    new_connection_state =
      case state.connection_state do
        %{status: :disconnected, disconnected_at: disconnected_at}
        when now - disconnected_at >= @stale_connection_cleanup_ms ->
          nil

        other ->
          other
      end

    Process.send_after(self(), :cleanup_check, @cleanup_interval_ms)

    {:noreply,
     %{
       state
       | active_subscriptions: Map.new(to_keep),
         upstream_index: new_upstream_index,
         connection_state: new_connection_state
     }}
  end

  # Connection established - track state and invalidate stale subscriptions
  def handle_info({:ws_connected, instance_id, connection_id}, state)
      when instance_id == state.instance_id do
    stale_subs =
      Enum.filter(state.active_subscriptions, fn {_sub_key, info} ->
        info.connection_id != connection_id
      end)

    {new_subs, new_index} =
      if stale_subs == [] do
        {state.active_subscriptions, state.upstream_index}
      else
        Logger.debug("Invalidating stale subscriptions on new connection",
          instance_id: state.instance_id,
          new_connection_id: connection_id,
          stale_count: length(stale_subs)
        )

        Enum.each(stale_subs, fn {sub_key, info} ->
          if info.staleness_timer_ref, do: Process.cancel_timer(info.staleness_timer_ref)

          InstanceSubscriptionRegistry.dispatch(
            state.instance_id,
            sub_key,
            {:instance_subscription_invalidated, state.instance_id, sub_key, :connection_replaced}
          )
        end)

        subs =
          Enum.reduce(stale_subs, state.active_subscriptions, fn {key, _}, acc ->
            Map.delete(acc, key)
          end)

        index =
          Enum.reduce(stale_subs, state.upstream_index, fn {_key, info}, acc ->
            Map.delete(acc, info.upstream_id)
          end)

        {subs, index}
      end

    conn_state = %{
      connection_id: connection_id,
      status: :connected,
      connected_at: System.monotonic_time(:millisecond)
    }

    {:noreply,
     %{
       state
       | connection_state: conn_state,
         active_subscriptions: new_subs,
         upstream_index: new_index
     }}
  end

  def handle_info({:ws_disconnected, instance_id, _error}, state)
      when instance_id == state.instance_id do
    handle_disconnect(state)
  end

  def handle_info({:ws_closed, instance_id, _code, _error}, state)
      when instance_id == state.instance_id do
    handle_disconnect(state)
  end

  # Staleness timer - ignore for logs subscriptions
  def handle_info({:staleness_check, {:logs, _filter}, _timer_ref}, state) do
    {:noreply, state}
  end

  def handle_info({:staleness_check, sub_key, timer_ref}, state) do
    case Map.get(state.active_subscriptions, sub_key) do
      nil ->
        {:noreply, state}

      %{staleness_timer_ref: current_ref} when current_ref != timer_ref ->
        {:noreply, state}

      %{marked_for_teardown_at: teardown_at} when not is_nil(teardown_at) ->
        {:noreply, state}

      sub_info ->
        handle_stale_subscription(state, sub_key, sub_info)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helpers

  defp handle_disconnect(state) do
    conn_state = %{
      connection_id: nil,
      status: :disconnected,
      disconnected_at: System.monotonic_time(:millisecond)
    }

    state = %{state | connection_state: conn_state}

    affected = Map.to_list(state.active_subscriptions)

    if affected == [] do
      {:noreply, state}
    else
      Logger.info("Instance disconnected, invalidating subscriptions",
        instance_id: state.instance_id,
        affected_count: length(affected)
      )

      Enum.each(affected, fn {sub_key, info} ->
        if info.staleness_timer_ref, do: Process.cancel_timer(info.staleness_timer_ref)

        InstanceSubscriptionRegistry.dispatch(
          state.instance_id,
          sub_key,
          {:instance_subscription_invalidated, state.instance_id, sub_key, :provider_disconnected}
        )
      end)

      {:noreply, %{state | active_subscriptions: %{}, upstream_index: %{}}}
    end
  end

  defp handle_subscription_request(state, sub_key, current_conn_id) do
    case Map.get(state.active_subscriptions, sub_key) do
      nil ->
        create_new_subscription(state, sub_key, current_conn_id)

      %{marked_for_teardown_at: nil, connection_id: ^current_conn_id} ->
        {:reply, {:ok, :existing}, state}

      %{marked_for_teardown_at: nil, connection_id: _stale_conn_id} = sub_info ->
        Logger.info("Detected stale subscription, recreating",
          instance_id: state.instance_id,
          sub_key: inspect(sub_key)
        )

        emit_telemetry(:stale_subscription_detected, state, sub_key)
        state = remove_subscription(state, sub_key, sub_info.upstream_id)
        create_new_subscription(state, sub_key, current_conn_id)

      %{connection_id: ^current_conn_id} = sub_info ->
        Logger.debug("Cancelling teardown for subscription",
          instance_id: state.instance_id,
          sub_key: inspect(sub_key)
        )

        new_sub_info = %{sub_info | marked_for_teardown_at: nil}
        new_subs = Map.put(state.active_subscriptions, sub_key, new_sub_info)
        {:reply, {:ok, :existing}, %{state | active_subscriptions: new_subs}}

      %{upstream_id: upstream_id} ->
        state = remove_subscription(state, sub_key, upstream_id)
        create_new_subscription(state, sub_key, current_conn_id)
    end
  end

  defp remove_subscription(state, sub_key, upstream_id) do
    case Map.get(state.active_subscriptions, sub_key) do
      %{staleness_timer_ref: ref} when not is_nil(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    new_subs = Map.delete(state.active_subscriptions, sub_key)
    new_index = Map.delete(state.upstream_index, upstream_id)
    %{state | active_subscriptions: new_subs, upstream_index: new_index}
  end

  defp create_new_subscription(state, sub_key, connection_id) do
    case create_upstream_subscription(state.instance_id, sub_key) do
      {:ok, upstream_id} ->
        now = System.monotonic_time(:millisecond)

        staleness_timer_ref =
          schedule_staleness_check(state, sub_key, @new_subscription_grace_ms)

        sub_info = %{
          upstream_id: upstream_id,
          connection_id: connection_id,
          created_at: now,
          marked_for_teardown_at: nil,
          last_event_at: now,
          staleness_timer_ref: staleness_timer_ref
        }

        new_subs = Map.put(state.active_subscriptions, sub_key, sub_info)
        new_index = Map.put(state.upstream_index, upstream_id, sub_key)

        Logger.info("Created upstream subscription",
          instance_id: state.instance_id,
          sub_key: inspect(sub_key),
          upstream_id: upstream_id,
          connection_id: connection_id
        )

        emit_telemetry(:subscription_created, state, sub_key)

        {:reply, {:ok, :new},
         %{state | active_subscriptions: new_subs, upstream_index: new_index}}

      {:error, reason} ->
        Logger.debug("Failed to create upstream subscription",
          instance_id: state.instance_id,
          sub_key: inspect(sub_key),
          reason: inspect(reason)
        )

        state =
          if connection_dead_error?(reason) do
            Logger.debug("Detected dead connection during subscription, marking disconnected",
              instance_id: state.instance_id
            )

            %{
              state
              | connection_state: %{
                  connection_id: nil,
                  status: :disconnected,
                  disconnected_at: System.monotonic_time(:millisecond)
                }
            }
          else
            state
          end

        {:reply, {:error, reason}, state}
    end
  end

  defp create_upstream_subscription(instance_id, sub_key) do
    params = subscription_params(sub_key)

    case Connection.request(instance_id, "eth_subscribe", params, 10_000) do
      {:ok, %Response.Success{} = response} ->
        Response.Success.decode_result(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp subscription_params({:newHeads}), do: ["newHeads"]
  defp subscription_params({:logs, filter}), do: ["logs", filter]

  defp teardown_upstream_subscription(instance_id, sub_key, upstream_id) do
    Task.start(fn ->
      case Connection.request(instance_id, "eth_unsubscribe", [upstream_id], 5_000) do
        {:ok, _} ->
          Logger.info("Tore down upstream subscription",
            instance_id: instance_id,
            sub_key: inspect(sub_key),
            upstream_id: upstream_id
          )

        {:error, _} ->
          :ok
      end
    end)
  end

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

  defp emit_telemetry(event, state, sub_key) do
    :telemetry.execute(
      [:lasso, :upstream_subscriptions, event],
      %{count: 1},
      %{instance_id: state.instance_id, chain: state.chain, sub_key: inspect(sub_key)}
    )
  end

  defp calculate_staleness_threshold(instance_id, chain) do
    case Catalog.get_instance_refs(instance_id) do
      [ref_profile | _] ->
        case ConfigStore.get_chain(ref_profile, chain) do
          {:ok, config} -> config.websocket.new_heads_timeout_ms
          _ -> @default_new_heads_staleness_threshold_ms
        end

      _ ->
        @default_new_heads_staleness_threshold_ms
    end
  end

  defp schedule_staleness_check(_state, {:logs, _filter}, _delay_ms), do: nil

  defp schedule_staleness_check(_state, sub_key, delay_ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {:staleness_check, sub_key, timer_ref}, delay_ms)
    timer_ref
  end

  defp update_subscription_liveness(state, sub_key, received_at) do
    case Map.get(state.active_subscriptions, sub_key) do
      nil ->
        state

      sub_info ->
        if sub_info.staleness_timer_ref do
          Process.cancel_timer(sub_info.staleness_timer_ref)
        end

        new_timer_ref =
          schedule_staleness_check(
            state,
            sub_key,
            state.new_heads_staleness_threshold_ms
          )

        updated_info = %{
          sub_info
          | last_event_at: received_at,
            staleness_timer_ref: new_timer_ref
        }

        %{
          state
          | active_subscriptions: Map.put(state.active_subscriptions, sub_key, updated_info)
        }
    end
  end

  defp handle_stale_subscription(state, sub_key, sub_info) do
    now = System.monotonic_time(:millisecond)
    stale_duration_ms = now - sub_info.last_event_at

    Logger.warning("Subscription stale - no events received",
      instance_id: state.instance_id,
      sub_key: inspect(sub_key),
      stale_duration_ms: stale_duration_ms,
      threshold_ms: state.new_heads_staleness_threshold_ms,
      upstream_id: sub_info.upstream_id
    )

    :telemetry.execute(
      [:lasso, :upstream_subscriptions, :staleness_detected],
      %{count: 1, stale_duration_ms: stale_duration_ms},
      %{instance_id: state.instance_id, chain: state.chain, sub_key: inspect(sub_key)}
    )

    # Fan out Subscription.Stale to all profiles referencing this instance
    broadcast_stale_to_profiles(state, sub_key, stale_duration_ms)

    if sub_info.staleness_timer_ref do
      Process.cancel_timer(sub_info.staleness_timer_ref)
    end

    teardown_upstream_subscription(state.instance_id, sub_key, sub_info.upstream_id)

    InstanceSubscriptionRegistry.dispatch(
      state.instance_id,
      sub_key,
      {:instance_subscription_invalidated, state.instance_id, sub_key, :subscription_stale}
    )

    new_subs = Map.delete(state.active_subscriptions, sub_key)
    new_index = Map.delete(state.upstream_index, sub_info.upstream_id)

    {:noreply, %{state | active_subscriptions: new_subs, upstream_index: new_index}}
  end

  defp broadcast_stale_to_profiles(state, sub_key, stale_duration_ms) do
    profiles = Catalog.get_instance_refs(state.instance_id)

    for profile <- profiles do
      provider_id =
        Catalog.reverse_lookup_provider_id(profile, state.chain, state.instance_id) ||
          state.instance_id

      event = %Subscription.Stale{
        ts: System.system_time(:millisecond),
        chain: state.chain,
        provider_id: provider_id,
        subscription_type: Subscription.subscription_type(sub_key),
        stale_duration_ms: stale_duration_ms
      }

      topic = Subscription.topic(profile, state.chain)
      Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)
    end
  end
end
