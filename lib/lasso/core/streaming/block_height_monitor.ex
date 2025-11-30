defmodule Lasso.RPC.BlockHeightMonitor do
  @moduledoc """
  Per-chain GenServer that manages internal newHeads subscriptions for block height tracking.

  Unlike client subscriptions that go through UpstreamSubscriptionPool, this module
  subscribes to track block heights from all WebSocket-enabled providers. This enables:

  - Real-time block height tracking (vs 12s HTTP probes)
  - Per-provider sync status monitoring
  - Consensus height calculation from live data
  - Rich block data caching for system-wide use

  ## Architecture

  Each chain gets one BlockHeightMonitor that:
  1. Discovers all WebSocket-enabled providers
  2. Registers as a consumer via UpstreamSubscriptionManager for each
  3. Receives subscription events via Registry dispatch
  4. Updates BlockCache with incoming block data
  5. Handles provider disconnects and reconnection

  ## Usage

  Started automatically by supervision tree for each configured chain.
  Other processes query BlockCache directly or subscribe to "block_cache:updates".
  """

  use GenServer
  require Logger

  alias Lasso.Core.BlockCache
  alias Lasso.RPC.{CircuitBreaker, Selection, UpstreamSubscriptionManager}

  @type chain :: String.t()
  @type provider_id :: String.t()

  # Reconnect delay after subscription failure
  @reconnect_delay_ms 5_000

  # Check for new providers periodically
  @provider_discovery_interval_ms 30_000

  ## Client API

  def start_link(chain) when is_binary(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:block_height_monitor, chain}}}

  @doc """
  Get subscription status for all providers.
  """
  @spec get_status(chain()) :: %{provider_id() => :active | :connecting | :failed}
  def get_status(chain) do
    GenServer.call(via(chain), :get_status)
  catch
    :exit, _ -> %{}
  end

  @doc """
  Force reconnection attempt for a specific provider.
  """
  @spec reconnect_provider(chain(), provider_id()) :: :ok
  def reconnect_provider(chain, provider_id) do
    GenServer.cast(via(chain), {:reconnect_provider, provider_id})
  end

  ## GenServer Callbacks

  @impl true
  def init(chain) do
    # Subscribe to WebSocket connection events (to know when connections are ready)
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain}")

    # Subscribe to provider pool events for health/availability changes
    Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")

    # Subscribe to Manager restart events to re-establish subscriptions
    Phoenix.PubSub.subscribe(Lasso.PubSub, "upstream_sub_manager:#{chain}")

    state = %{
      chain: chain,
      # provider_id => %{status, last_error, retry_count}
      subscriptions: %{}
    }

    # Delay initial subscription attempt to allow connections to establish
    # Provider connections start after BlockHeightMonitor in supervision tree
    Process.send_after(self(), :establish_subscriptions, 5_000)

    # Schedule periodic provider discovery
    Process.send_after(self(), :discover_providers, @provider_discovery_interval_ms)

    Logger.debug("BlockHeightMonitor started", chain: chain)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status =
      Map.new(state.subscriptions, fn {provider_id, sub} ->
        {provider_id, sub.status}
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_info(:establish_subscriptions, state) do
    state = establish_all_subscriptions(state)
    {:noreply, state}
  end

  def handle_info(:discover_providers, state) do
    # Re-discover providers and establish new subscriptions
    state = discover_and_subscribe_new_providers(state)

    # Schedule next discovery
    Process.send_after(self(), :discover_providers, @provider_discovery_interval_ms)

    {:noreply, state}
  end

  def handle_info({:reconnect_provider, provider_id}, state) do
    state = attempt_subscription(state, provider_id)
    {:noreply, state}
  end

  # Handle incoming subscription events from UpstreamSubscriptionManager via Registry.dispatch
  # Format: {:upstream_subscription_event, provider_id, sub_key, payload, received_at}
  def handle_info(
        {:upstream_subscription_event, provider_id, {:newHeads}, payload, _received_at},
        state
      )
      when is_map(payload) do
    process_new_head(state.chain, provider_id, payload)
    {:noreply, state}
  end

  # Handle WebSocket connection established - trigger subscription
  def handle_info({:ws_connected, provider_id}, state) do
    # Attempt to subscribe to this provider if we haven't already
    state = attempt_subscription(state, provider_id)
    {:noreply, state}
  end

  # Handle WebSocket disconnection - mark subscription as failed and release
  def handle_info({:ws_disconnected, provider_id, _error}, state) do
    state = handle_provider_disconnect(state, provider_id)
    {:noreply, state}
  end

  # Handle WebSocket closed
  def handle_info({:ws_closed, provider_id, _code, _error}, state) do
    state = handle_provider_disconnect(state, provider_id)
    {:noreply, state}
  end

  # Handle provider health events
  def handle_info({:provider_event, event}, state) do
    state = handle_provider_event(state, event)
    {:noreply, state}
  end

  # Handle Manager restart - re-establish all active subscriptions
  def handle_info({:upstream_sub_manager_restarted, _chain}, state) do
    active_providers =
      state.subscriptions
      |> Enum.filter(fn {_provider_id, sub} -> sub.status == :active end)
      |> Enum.map(fn {provider_id, _sub} -> provider_id end)

    if active_providers != [] do
      Logger.info("Manager restarted, re-establishing #{length(active_providers)} subscriptions",
        chain: state.chain
      )

      # Re-register each active subscription with the Manager
      new_state =
        Enum.reduce(active_providers, state, fn provider_id, acc ->
          # Reset to connecting and attempt resubscription
          sub = %{status: :connecting, last_error: nil, retry_count: 0}
          acc = %{acc | subscriptions: Map.put(acc.subscriptions, provider_id, sub)}

          case UpstreamSubscriptionManager.ensure_subscription(acc.chain, provider_id, {:newHeads}) do
            {:ok, _status} ->
              updated_sub = %{sub | status: :active}
              %{acc | subscriptions: Map.put(acc.subscriptions, provider_id, updated_sub)}

            {:error, reason} ->
              Logger.warning("Failed to re-establish subscription after Manager restart",
                chain: acc.chain,
                provider_id: provider_id,
                reason: inspect(reason)
              )

              # Schedule retry
              Process.send_after(self(), {:reconnect_provider, provider_id}, @reconnect_delay_ms)
              updated_sub = %{sub | status: :failed, last_error: reason, retry_count: 1}
              %{acc | subscriptions: Map.put(acc.subscriptions, provider_id, updated_sub)}
          end
        end)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Catch-all for other messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:reconnect_provider, provider_id}, state) do
    state = attempt_subscription(state, provider_id)
    {:noreply, state}
  end

  ## Private Functions

  defp establish_all_subscriptions(state) do
    ws_providers = get_ws_providers(state.chain)

    Logger.info("Establishing block height subscriptions",
      chain: state.chain,
      provider_count: length(ws_providers)
    )

    Enum.reduce(ws_providers, state, fn provider_id, acc ->
      attempt_subscription(acc, provider_id)
    end)
  end

  defp discover_and_subscribe_new_providers(state) do
    ws_providers = get_ws_providers(state.chain)
    existing = Map.keys(state.subscriptions)
    new_providers = ws_providers -- existing

    if new_providers != [] do
      Logger.info("Discovered new WebSocket providers",
        chain: state.chain,
        new_providers: new_providers
      )
    end

    Enum.reduce(new_providers, state, fn provider_id, acc ->
      attempt_subscription(acc, provider_id)
    end)
  end

  defp get_ws_providers(chain) do
    # Get all channels with WebSocket transport
    Selection.select_channels(chain, "eth_subscribe",
      transport: :ws,
      limit: 100
    )
    |> Enum.map(& &1.provider_id)
    |> Enum.uniq()
  end

  defp attempt_subscription(state, provider_id) do
    # Skip if already active or connecting to avoid duplicate subscription attempts
    case Map.get(state.subscriptions, provider_id) do
      %{status: :active} ->
        state

      %{status: :connecting} ->
        state

      _ ->
        do_subscribe(state, provider_id)
    end
  end

  defp do_subscribe(state, provider_id) do
    # Update state to connecting
    current = Map.get(state.subscriptions, provider_id, %{retry_count: 0})

    sub = %{
      status: :connecting,
      last_error: nil,
      retry_count: Map.get(current, :retry_count, 0)
    }

    state = %{state | subscriptions: Map.put(state.subscriptions, provider_id, sub)}

    # Register with UpstreamSubscriptionManager (this creates the upstream sub if needed)
    case UpstreamSubscriptionManager.ensure_subscription(state.chain, provider_id, {:newHeads}) do
      {:ok, status} ->
        Logger.debug("BlockHeightMonitor subscription registered",
          chain: state.chain,
          provider_id: provider_id,
          status: status
        )

        # Mark as active
        updated_sub = %{sub | status: :active, retry_count: 0}
        %{state | subscriptions: Map.put(state.subscriptions, provider_id, updated_sub)}

      {:error, reason} ->
        # Schedule retry with exponential backoff
        retry_count = sub.retry_count + 1

        # Only log warning on first failure, demote retries to debug
        if retry_count == 1 do
          Logger.warning("BlockHeightMonitor subscription failed",
            chain: state.chain,
            provider_id: provider_id,
            reason: inspect(reason)
          )
        else
          Logger.debug("BlockHeightMonitor subscription retry failed",
            chain: state.chain,
            provider_id: provider_id,
            retry_count: retry_count,
            reason: inspect(reason)
          )
        end
        delay = min(@reconnect_delay_ms * :math.pow(2, retry_count - 1), 60_000) |> trunc()
        Process.send_after(self(), {:reconnect_provider, provider_id}, delay)

        # Mark as failed
        updated_sub = %{sub | status: :failed, last_error: reason, retry_count: retry_count}
        %{state | subscriptions: Map.put(state.subscriptions, provider_id, updated_sub)}
    end
  end

  defp handle_provider_disconnect(state, provider_id) do
    case Map.get(state.subscriptions, provider_id) do
      nil ->
        state

      sub ->
        # Release our subscription from the manager
        # (this is also automatic via Registry when we crash, but explicit is clearer)
        UpstreamSubscriptionManager.release_subscription(state.chain, provider_id, {:newHeads})

        # Mark as failed and schedule reconnection
        updated_sub = %{sub | status: :failed}
        state = %{state | subscriptions: Map.put(state.subscriptions, provider_id, updated_sub)}

        Process.send_after(self(), {:reconnect_provider, provider_id}, @reconnect_delay_ms)

        Logger.info("BlockHeightMonitor provider disconnected, scheduling reconnect",
          chain: state.chain,
          provider_id: provider_id
        )

        state
    end
  end

  defp handle_provider_event(state, %{type: :ws_disconnected, provider_id: provider_id}) do
    handle_provider_disconnect(state, provider_id)
  end

  defp handle_provider_event(state, %{type: :ws_connected, provider_id: provider_id}) do
    # Provider reconnected, attempt to resubscribe if we were tracking it
    case Map.get(state.subscriptions, provider_id) do
      %{status: status} when status != :active ->
        attempt_subscription(state, provider_id)

      _ ->
        state
    end
  end

  defp handle_provider_event(state, _event), do: state

  defp process_new_head(chain, provider_id, payload) do
    # Update BlockCache with the new block data
    BlockCache.put_block(chain, provider_id, payload)

    # Record circuit breaker success for WS transport recovery
    # Each newHeads event proves the WS connection is healthy
    CircuitBreaker.record_success({chain, provider_id, :ws})

    # Also update ProviderPool sync state for compatibility with existing lag calculation
    # This bridges the WS data into the probe-based consensus system
    case Map.get(payload, "number") do
      "0x" <> hex ->
        block_height = String.to_integer(hex, 16)
        Lasso.RPC.ProviderPool.report_newheads(chain, provider_id, block_height)

      _ ->
        :ok
    end
  end
end
