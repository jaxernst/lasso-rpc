defmodule Lasso.RPC.UpstreamSubscriptionManager do
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

  alias Lasso.Core.Streaming.UpstreamSubscriptionRegistry
  alias Lasso.RPC.{TransportRegistry, Channel}

  @cleanup_interval_ms 30_000
  @teardown_grace_period_ms 60_000

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type sub_key :: {:newHeads} | {:logs, map()}
  @type upstream_id :: String.t()

  defstruct [
    :chain,
    # %{{provider_id, sub_key} => %{upstream_id, created_at, marked_for_teardown_at}}
    active_subscriptions: %{},
    # %{upstream_id => {provider_id, sub_key}} - reverse lookup for incoming events
    upstream_index: %{}
  ]

  # Client API

  def start_link(chain) when is_binary(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:upstream_sub_manager, chain}}}

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
  @spec ensure_subscription(chain(), provider_id(), sub_key()) ::
          {:ok, :new | :existing} | {:error, term()}
  def ensure_subscription(chain, provider_id, sub_key) do
    # Register as consumer first (idempotent per-process)
    case UpstreamSubscriptionRegistry.register_consumer(chain, provider_id, sub_key) do
      :ok ->
        # Use :infinity - the inner Channel.request has its own bounded timeout (10s)
        # and will return {:error, :timeout} which propagates up cleanly
        GenServer.call(via(chain), {:ensure_subscription, provider_id, sub_key}, :infinity)

      {:error, reason} ->
        {:error, {:registry_error, reason}}
    end
  end

  @doc """
  Unregister caller as consumer.

  Subscription will be torn down after grace period if no consumers remain.
  """
  @spec release_subscription(chain(), provider_id(), sub_key()) :: :ok
  def release_subscription(chain, provider_id, sub_key) do
    UpstreamSubscriptionRegistry.unregister_consumer(chain, provider_id, sub_key)
    GenServer.cast(via(chain), {:check_teardown, provider_id, sub_key})
  end

  @doc """
  Get status of all active subscriptions for this chain.
  """
  @spec get_status(chain()) :: map()
  def get_status(chain) do
    GenServer.call(via(chain), :get_status)
  catch
    :exit, _ -> %{error: :not_running}
  end

  # GenServer Callbacks

  @impl true
  def init(chain) do
    # Subscribe to all subscription events for this chain
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:subs:#{chain}")

    # Subscribe to provider events for disconnect handling
    Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")

    # Schedule periodic cleanup check
    Process.send_after(self(), :cleanup_check, @cleanup_interval_ms)

    # Broadcast restart event so consumers can re-register their subscriptions
    # This handles the case where Manager crashed/restarted but consumers are still alive
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "upstream_sub_manager:#{chain}",
      {:upstream_sub_manager_restarted, chain}
    )

    Logger.debug("UpstreamSubscriptionManager started", chain: chain)

    {:ok, %__MODULE__{chain: chain}}
  end

  @impl true
  def handle_call({:ensure_subscription, provider_id, sub_key}, _from, state) do
    key = {provider_id, sub_key}

    case Map.get(state.active_subscriptions, key) do
      nil ->
        # First consumer - create upstream subscription
        case create_upstream_subscription(state.chain, provider_id, sub_key) do
          {:ok, upstream_id} ->
            sub_info = %{
              upstream_id: upstream_id,
              created_at: System.monotonic_time(:millisecond),
              marked_for_teardown_at: nil
            }

            new_subs = Map.put(state.active_subscriptions, key, sub_info)
            new_index = Map.put(state.upstream_index, upstream_id, key)

            Logger.info("Created upstream subscription",
              chain: state.chain,
              provider_id: provider_id,
              sub_key: inspect(sub_key),
              upstream_id: upstream_id
            )

            emit_telemetry(:subscription_created, state.chain, provider_id, sub_key)

            {:reply, {:ok, :new},
             %{state | active_subscriptions: new_subs, upstream_index: new_index}}

          {:error, reason} ->
            Logger.warning("Failed to create upstream subscription",
              chain: state.chain,
              provider_id: provider_id,
              sub_key: inspect(sub_key),
              reason: inspect(reason)
            )

            {:reply, {:error, reason}, state}
        end

      %{marked_for_teardown_at: nil} ->
        # Already exists and not marked for teardown
        {:reply, {:ok, :existing}, state}

      sub_info ->
        # Was marked for teardown, cancel it
        Logger.debug("Cancelling teardown for subscription",
          chain: state.chain,
          provider_id: provider_id,
          sub_key: inspect(sub_key)
        )

        new_sub_info = %{sub_info | marked_for_teardown_at: nil}
        new_subs = Map.put(state.active_subscriptions, key, new_sub_info)
        {:reply, {:ok, :existing}, %{state | active_subscriptions: new_subs}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      chain: state.chain,
      active_subscriptions:
        Map.new(state.active_subscriptions, fn {{provider_id, sub_key}, info} ->
          consumer_count =
            UpstreamSubscriptionRegistry.count_consumers(state.chain, provider_id, sub_key)

          {{provider_id, sub_key},
           %{
             upstream_id: info.upstream_id,
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
          UpstreamSubscriptionRegistry.count_consumers(state.chain, provider_id, sub_key)

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
      {^provider_id, sub_key} ->
        # Dispatch to all consumers via Registry
        UpstreamSubscriptionRegistry.dispatch(
          state.chain,
          provider_id,
          sub_key,
          {:upstream_subscription_event, provider_id, sub_key, payload, received_at}
        )

        {:noreply, state}

      nil ->
        # Orphaned subscription event - likely from before we started or race condition
        # This is expected during startup or after provider reconnect
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

    {to_teardown, to_keep} =
      Enum.split_with(state.active_subscriptions, fn {_key, sub_info} ->
        sub_info.marked_for_teardown_at != nil and
          now - sub_info.marked_for_teardown_at >= @teardown_grace_period_ms
      end)

    # Teardown expired subscriptions
    new_upstream_index =
      Enum.reduce(to_teardown, state.upstream_index, fn {{provider_id, sub_key}, sub_info}, acc ->
        teardown_upstream_subscription(state.chain, provider_id, sub_key, sub_info.upstream_id)
        emit_telemetry(:subscription_destroyed, state.chain, provider_id, sub_key)
        Map.delete(acc, sub_info.upstream_id)
      end)

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_check, @cleanup_interval_ms)

    {:noreply,
     %{state | active_subscriptions: Map.new(to_keep), upstream_index: new_upstream_index}}
  end

  # Handle provider disconnect events - mark affected subscriptions for teardown
  def handle_info({:provider_event, %{type: type, provider_id: provider_id}}, state)
      when type in [:ws_disconnected, :ws_closed] do
    # Find all subscriptions for this provider
    affected =
      Enum.filter(state.active_subscriptions, fn {{prov_id, _sub_key}, _info} ->
        prov_id == provider_id
      end)

    if affected != [] do
      Logger.info("Provider disconnected, cleaning up subscriptions",
        chain: state.chain,
        provider_id: provider_id,
        affected_count: length(affected)
      )

      # Remove subscriptions and index entries for this provider
      new_subs =
        Enum.reduce(affected, state.active_subscriptions, fn {key, _}, acc ->
          Map.delete(acc, key)
        end)

      new_index =
        Enum.reduce(affected, state.upstream_index, fn {_key, info}, acc ->
          Map.delete(acc, info.upstream_id)
        end)

      {:noreply, %{state | active_subscriptions: new_subs, upstream_index: new_index}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helpers

  defp create_upstream_subscription(chain, provider_id, {:newHeads}) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }

    with {:ok, channel} <- TransportRegistry.get_channel(chain, provider_id, :ws),
         {:ok, upstream_id, _io_ms} <- Channel.request(channel, message, 10_000) do
      {:ok, upstream_id}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _io_ms} -> {:error, reason}
    end
  end

  defp create_upstream_subscription(chain, provider_id, {:logs, filter}) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_subscribe",
      "params" => ["logs", filter]
    }

    with {:ok, channel} <- TransportRegistry.get_channel(chain, provider_id, :ws),
         {:ok, upstream_id, _io_ms} <- Channel.request(channel, message, 10_000) do
      {:ok, upstream_id}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _io_ms} -> {:error, reason}
    end
  end

  defp teardown_upstream_subscription(chain, provider_id, sub_key, upstream_id) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_unsubscribe",
      "params" => [upstream_id]
    }

    case TransportRegistry.get_channel(chain, provider_id, :ws) do
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
end
