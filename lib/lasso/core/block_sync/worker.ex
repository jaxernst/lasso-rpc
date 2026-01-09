defmodule Lasso.BlockSync.Worker do
  @moduledoc """
  Per-provider GenServer that orchestrates block sync strategies.

  Each provider gets one Worker that:
  1. Determines which strategy to use (WS, HTTP, or both)
  2. Starts appropriate strategies based on config
  3. Handles WS → HTTP fallback when WS degrades
  4. Reports heights and health to BlockSync.Registry

  ## State Machine

  The Worker operates in one of three modes:
  - `:ws_only` - WS subscription active and healthy
  - `:ws_with_http` - WS degraded/stale, HTTP fallback running
  - `:http_only` - WS unavailable or disabled by config

  ## Configuration

  Uses `subscribe_new_heads` from chains.yml:
  - Per-provider override: `provider.subscribe_new_heads`
  - Per-chain default: `monitoring.subscribe_new_heads`

  If `subscribe_new_heads: false`, Worker runs HTTP-only mode.
  """

  use GenServer
  require Logger

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.BlockSync.Strategies.{HttpStrategy, WsStrategy}
  alias Lasso.Config.{ChainConfig, ConfigStore}

  @reconnect_delay_ms 5_000

  @type mode :: :ws_only | :ws_with_http | :http_only
  @type config :: %{
          subscribe_new_heads: boolean(),
          poll_interval_ms: pos_integer(),
          staleness_threshold_ms: pos_integer()
        }

  @type t :: %__MODULE__{
          chain: String.t(),
          profile: String.t(),
          provider_id: String.t(),
          mode: mode() | nil,
          ws_strategy: pid() | nil,
          http_strategy: pid() | nil,
          config: config(),
          ws_retry_count: non_neg_integer()
        }

  defstruct [
    :chain,
    :profile,
    :provider_id,
    :mode,
    :ws_strategy,
    :http_strategy,
    :config,
    :ws_retry_count
  ]

  ## Client API

  @spec start_link({atom(), String.t(), String.t()}) :: GenServer.on_start()
  def start_link({chain, profile, provider_id}) when is_binary(profile) do
    GenServer.start_link(__MODULE__, {chain, profile, provider_id},
      name: via(chain, profile, provider_id)
    )
  end

  @spec via(String.t(), String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(chain, profile, provider_id) when is_binary(profile) do
    {:via, Registry, {Lasso.Registry, {:block_sync_worker, chain, profile, provider_id}}}
  end

  @doc """
  Get the current status of a worker.
  """
  @spec get_status(atom(), String.t(), String.t()) :: map() | {:error, :not_running}
  def get_status(chain, profile, provider_id) when is_binary(profile) do
    GenServer.call(via(chain, profile, provider_id), :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  ## GenServer Callbacks

  @impl true
  @spec init({String.t(), String.t(), String.t()}) :: {:ok, t()}
  def init({chain, profile, provider_id}) when is_binary(profile) do
    # Subscribe to WebSocket connection events (profile-scoped)
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{profile}:#{chain}")

    # Subscribe to Manager restart events (profile-scoped)
    Phoenix.PubSub.subscribe(Lasso.PubSub, "upstream_sub_manager:#{profile}:#{chain}")

    config = load_config(profile, chain, provider_id)

    state = %__MODULE__{
      chain: chain,
      profile: profile,
      provider_id: provider_id,
      mode: nil,
      ws_strategy: nil,
      http_strategy: nil,
      config: config,
      ws_retry_count: 0
    }

    # Delay strategy start to allow connections to establish
    Process.send_after(self(), :start_strategies, 2_000)

    Logger.debug("BlockSync.Worker started",
      chain: chain,
      profile: profile,
      provider_id: provider_id,
      subscribe_new_heads: config.subscribe_new_heads
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      mode: state.mode,
      ws_status: if(state.ws_strategy, do: WsStrategy.get_status(state.ws_strategy), else: nil),
      http_status:
        if(state.http_strategy, do: HttpStrategy.get_status(state.http_strategy), else: nil),
      config: state.config
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info(:start_strategies, state) do
    state = start_strategies(state)
    {:noreply, state}
  end

  # Handle block height reports from strategies
  def handle_info({:block_height, provider_id, height, metadata}, state)
      when provider_id == state.provider_id do
    source = if metadata[:latency_ms], do: :http, else: :ws

    # Store in BlockSync Registry (health metrics tracked by ProviderPool)
    BlockSyncRegistry.put_height(state.chain, provider_id, height, source, metadata)

    # Broadcast to subscribers (Dashboard, ProviderPool)
    broadcast_height_update(state, height, source)

    {:noreply, state}
  end

  # Handle status changes from strategies
  def handle_info({:status, provider_id, transport, status}, state)
      when provider_id == state.provider_id do
    state = handle_strategy_status(state, transport, status)
    {:noreply, state}
  end

  # Handle HTTP strategy poll timer
  def handle_info({:http_strategy, :poll, provider_id}, state)
      when provider_id == state.provider_id and state.http_strategy != nil do
    {:ok, new_http_state} = HttpStrategy.handle_message(:poll, state.http_strategy)
    {:noreply, %{state | http_strategy: new_http_state}}
  end

  # Handle stale HTTP poll message when strategy was stopped (e.g., WS recovered)
  def handle_info({:http_strategy, :poll, provider_id}, state)
      when provider_id == state.provider_id and state.http_strategy == nil do
    # HTTP strategy was stopped, ignore stale poll message
    {:noreply, state}
  end

  # Handle WS strategy staleness check timer
  def handle_info({:ws_strategy, :check_staleness, provider_id}, state)
      when provider_id == state.provider_id and state.ws_strategy != nil do
    {:ok, new_ws_state} = WsStrategy.handle_message(:check_staleness, state.ws_strategy)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  # Handle stale WS staleness check when strategy was stopped
  def handle_info({:ws_strategy, :check_staleness, provider_id}, state)
      when provider_id == state.provider_id and state.ws_strategy == nil do
    # WS strategy was stopped, ignore stale message
    {:noreply, state}
  end

  # Handle incoming newHeads events from UpstreamSubscriptionManager via Registry.dispatch
  def handle_info(
        {:upstream_subscription_event, provider_id, {:newHeads}, payload, _received_at},
        state
      )
      when provider_id == state.provider_id and state.ws_strategy != nil do
    new_ws_state = WsStrategy.handle_new_head(state.ws_strategy, payload)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  # Handle subscription invalidation
  def handle_info({:upstream_subscription_invalidated, provider_id, {:newHeads}, reason}, state)
      when provider_id == state.provider_id and state.ws_strategy != nil do
    new_ws_state = WsStrategy.handle_invalidation(state.ws_strategy, reason)
    state = %{state | ws_strategy: new_ws_state}
    state = handle_strategy_status(state, :ws, :failed)
    {:noreply, state}
  end

  # Handle WebSocket reconnected - re-establish WS subscription
  def handle_info({:ws_connected, provider_id, _connection_id}, state)
      when provider_id == state.provider_id do
    state = handle_ws_reconnected(state)
    {:noreply, state}
  end

  # Handle WebSocket disconnected
  def handle_info({:ws_disconnected, provider_id, _error}, state)
      when provider_id == state.provider_id do
    state = handle_ws_disconnected(state)
    {:noreply, state}
  end

  def handle_info({:ws_closed, provider_id, _code, _error}, state)
      when provider_id == state.provider_id do
    state = handle_ws_disconnected(state)
    {:noreply, state}
  end

  # Handle Manager restart - re-establish WS subscription
  def handle_info({:upstream_sub_manager_restarted, _chain}, state) do
    state = handle_manager_restarted(state)
    {:noreply, state}
  end

  # Handle WS reconnect attempt timer
  def handle_info(:attempt_ws_reconnect, state) do
    state = attempt_ws_reconnect(state)
    {:noreply, state}
  end

  # Catch-all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp broadcast_height_update(state, height, source) do
    provider_key = {state.profile, state.provider_id}
    timestamp = System.system_time(:millisecond)
    msg = {:block_height_update, provider_key, height, source, timestamp}

    Phoenix.PubSub.broadcast(Lasso.PubSub, "block_sync:#{state.profile}:#{state.chain}", msg)
  end

  @spec load_config(String.t(), String.t(), String.t()) :: config()
  defp load_config(profile, chain, provider_id) do
    case ConfigStore.get_chain(profile, chain) do
      {:ok, chain_config} ->
        {subscribe_new_heads, poll_interval, staleness_threshold} =
          case ChainConfig.get_provider_by_id(chain_config, provider_id) do
            {:ok, provider} ->
              {
                ChainConfig.should_subscribe_new_heads?(chain_config, provider),
                chain_config.monitoring.probe_interval_ms,
                chain_config.monitoring.new_heads_staleness_threshold_ms
              }

            {:error, _} ->
              {
                chain_config.monitoring.subscribe_new_heads,
                chain_config.monitoring.probe_interval_ms,
                chain_config.monitoring.new_heads_staleness_threshold_ms
              }
          end

        # Check if provider has WS capability
        has_ws = has_ws_capability?(profile, chain, provider_id)

        %{
          subscribe_new_heads: subscribe_new_heads and has_ws,
          poll_interval_ms: poll_interval,
          staleness_threshold_ms: staleness_threshold
        }

      {:error, _} ->
        # Fallback defaults
        %{
          subscribe_new_heads: has_ws_capability?(profile, chain, provider_id),
          poll_interval_ms: 12_000,
          staleness_threshold_ms: 35_000
        }
    end
  end

  @spec has_ws_capability?(String.t(), String.t(), String.t()) :: boolean()
  defp has_ws_capability?(profile, chain, provider_id) do
    case Lasso.RPC.TransportRegistry.get_channel(profile, chain, provider_id, :ws) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp start_strategies(state) do
    if state.config.subscribe_new_heads do
      # Start WS strategy
      start_ws_strategy(state)
    else
      # HTTP only mode
      start_http_only(state)
    end
  end

  defp start_ws_strategy(state) do
    ws_opts = [
      profile: state.profile,
      parent: self(),
      staleness_threshold_ms: state.config.staleness_threshold_ms
    ]

    case WsStrategy.start(state.chain, state.provider_id, ws_opts) do
      {:ok, ws_state} ->
        Logger.debug("WS strategy started",
          chain: state.chain,
          provider_id: state.provider_id
        )

        %{state | mode: :ws_only, ws_strategy: ws_state, ws_retry_count: 0}

      {:error, :connection_unknown} ->
        # Connection state not yet available - use short retry delay
        Logger.debug("WS connection state unknown, will retry shortly",
          chain: state.chain,
          provider_id: state.provider_id
        )

        start_http_fallback_with_quick_retry(state)

      {:error, reason} ->
        Logger.warning("WS strategy failed to start, falling back to HTTP",
          chain: state.chain,
          provider_id: state.provider_id,
          reason: inspect(reason)
        )

        start_http_fallback(%{state | ws_retry_count: state.ws_retry_count + 1})
    end
  end

  defp start_http_only(state) do
    http_opts = [
      profile: state.profile,
      parent: self(),
      poll_interval_ms: state.config.poll_interval_ms
    ]

    {:ok, http_state} = HttpStrategy.start(state.chain, state.provider_id, http_opts)

    Logger.debug("HTTP strategy started (WS disabled)",
      chain: state.chain,
      provider_id: state.provider_id
    )

    %{state | mode: :http_only, http_strategy: http_state}
  end

  defp start_http_fallback(state) do
    http_opts = [
      profile: state.profile,
      parent: self(),
      poll_interval_ms: state.config.poll_interval_ms
    ]

    {:ok, http_state} = HttpStrategy.start(state.chain, state.provider_id, http_opts)

    Logger.info("Started HTTP fallback for WS provider",
      chain: state.chain,
      provider_id: state.provider_id
    )

    # Schedule WS reconnect attempt
    schedule_ws_reconnect(state.ws_retry_count)

    %{state | mode: :ws_with_http, http_strategy: http_state}
  end

  # Quick retry for connection_unknown - connection state arrives shortly
  defp start_http_fallback_with_quick_retry(state) do
    http_opts = [
      profile: state.profile,
      parent: self(),
      poll_interval_ms: state.config.poll_interval_ms
    ]

    {:ok, http_state} = HttpStrategy.start(state.chain, state.provider_id, http_opts)

    # Short delay (1 second) for connection_unknown since state should arrive soon
    Process.send_after(self(), :attempt_ws_reconnect, 1_000)

    %{state | mode: :ws_with_http, http_strategy: http_state, ws_retry_count: 0}
  end

  defp handle_strategy_status(state, :ws, :active) do
    # WS recovered, stop HTTP fallback if running
    if state.mode == :ws_with_http and state.http_strategy do
      HttpStrategy.stop(state.http_strategy)

      Logger.info("WS recovered, stopping HTTP fallback",
        chain: state.chain,
        provider_id: state.provider_id
      )

      %{state | mode: :ws_only, http_strategy: nil, ws_retry_count: 0}
    else
      %{state | ws_retry_count: 0}
    end
  end

  defp handle_strategy_status(state, :ws, status) when status in [:stale, :failed, :degraded] do
    # WS degraded, start HTTP fallback if not already running
    if state.mode == :ws_only and state.http_strategy == nil do
      start_http_fallback(state)
    else
      state
    end
  end

  defp handle_strategy_status(state, :http, :degraded) do
    Logger.warning("HTTP polling degraded",
      chain: state.chain,
      provider_id: state.provider_id
    )

    state
  end

  defp handle_strategy_status(state, :http, :healthy) do
    Logger.debug("HTTP polling recovered",
      chain: state.chain,
      provider_id: state.provider_id
    )

    state
  end

  defp handle_strategy_status(state, _transport, _status) do
    state
  end

  defp handle_ws_reconnected(state) do
    if state.config.subscribe_new_heads and state.mode in [:ws_with_http, nil] do
      case state.ws_strategy do
        nil ->
          # Start fresh WS strategy
          start_ws_strategy(state)

        ws_state ->
          # Re-subscribe existing strategy
          case WsStrategy.resubscribe(ws_state) do
            {:ok, new_ws_state} ->
              %{state | ws_strategy: new_ws_state, ws_retry_count: 0}

            {:error, _} ->
              schedule_ws_reconnect(state.ws_retry_count)
              %{state | ws_retry_count: state.ws_retry_count + 1}
          end
      end
    else
      state
    end
  end

  defp handle_ws_disconnected(state) do
    if state.ws_strategy do
      # WS disconnected, start HTTP fallback
      start_http_fallback(state)
    else
      state
    end
  end

  defp handle_manager_restarted(state) do
    if state.ws_strategy and state.mode in [:ws_only, :ws_with_http] do
      case WsStrategy.resubscribe(state.ws_strategy) do
        {:ok, new_ws_state} ->
          %{state | ws_strategy: new_ws_state}

        {:error, _} ->
          start_http_fallback(state)
      end
    else
      state
    end
  end

  defp attempt_ws_reconnect(state) do
    if state.config.subscribe_new_heads and state.mode == :ws_with_http do
      ws_opts = [
        profile: state.profile,
        parent: self(),
        staleness_threshold_ms: state.config.staleness_threshold_ms
      ]

      case WsStrategy.start(state.chain, state.provider_id, ws_opts) do
        {:ok, ws_state} ->
          Logger.info("WS reconnected successfully",
            chain: state.chain,
            provider_id: state.provider_id
          )

          # WS recovered - stop HTTP fallback
          if state.http_strategy, do: HttpStrategy.stop(state.http_strategy)

          %{state | mode: :ws_only, ws_strategy: ws_state, http_strategy: nil, ws_retry_count: 0}

        {:error, reason} ->
          Logger.debug("WS reconnect attempt failed, will retry",
            chain: state.chain,
            provider_id: state.provider_id,
            reason: inspect(reason),
            retry_count: state.ws_retry_count + 1
          )

          # Schedule another attempt
          schedule_ws_reconnect(state.ws_retry_count)
          %{state | ws_retry_count: state.ws_retry_count + 1}
      end
    else
      state
    end
  end

  defp schedule_ws_reconnect(retry_count) do
    # Exponential backoff with max 60s
    delay = min(@reconnect_delay_ms * :math.pow(2, retry_count), 60_000) |> trunc()
    Process.send_after(self(), :attempt_ws_reconnect, delay)
  end
end
