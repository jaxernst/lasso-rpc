defmodule Lasso.BlockSync.Worker do
  @moduledoc """
  Per-instance GenServer that orchestrates block sync strategies.

  Each unique provider instance gets one Worker that:
  1. Always runs HTTP polling for reliable block height tracking
  2. Optionally runs WS subscription for real-time updates
  3. Reports heights to BlockSync.Registry
  4. Fan-out broadcasts to all profiles referencing this instance

  ## State Machine

  The Worker operates in one of two modes:
  - `:http_only` - HTTP polling only (WS unavailable or disabled)
  - `:http_with_ws` - HTTP polling + WS subscription (real-time layer)
  """

  use GenServer
  require Logger

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.BlockSync.Strategies.{HttpStrategy, WsStrategy}
  alias Lasso.Config.{ChainConfig, ConfigStore}
  alias Lasso.Providers.Catalog

  @reconnect_delay_ms 5_000

  @type mode :: :http_only | :http_with_ws
  @type config :: %{
          subscribe_new_heads: boolean(),
          poll_interval_ms: pos_integer(),
          staleness_threshold_ms: pos_integer()
        }

  @type t :: %__MODULE__{
          chain: String.t(),
          instance_id: String.t(),
          mode: mode() | nil,
          ws_strategy: pid() | nil,
          http_strategy: pid() | nil,
          config: config(),
          ws_retry_count: non_neg_integer()
        }

  defstruct [
    :chain,
    :instance_id,
    :mode,
    :ws_strategy,
    :http_strategy,
    :config,
    :ws_retry_count
  ]

  ## Client API

  @spec start_link({String.t(), String.t()}) :: GenServer.on_start()
  def start_link({chain, instance_id}) when is_binary(chain) and is_binary(instance_id) do
    GenServer.start_link(__MODULE__, {chain, instance_id}, name: via(chain, instance_id))
  end

  @spec via(String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(chain, instance_id) when is_binary(instance_id) do
    {:via, Registry, {Lasso.Registry, {:block_sync_worker, chain, instance_id}}}
  end

  @spec get_status(String.t(), String.t()) :: map() | {:error, :not_running}
  def get_status(chain, instance_id) when is_binary(instance_id) do
    GenServer.call(via(chain, instance_id), :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  ## GenServer Callbacks

  @impl true
  def init({chain, instance_id}) do
    # Instance-scoped WS connection events
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:instance:#{instance_id}")

    # Chain-scoped manager restart topic
    Phoenix.PubSub.subscribe(Lasso.PubSub, "instance_sub_manager:restarted:#{chain}")

    config = load_config(instance_id, chain)

    state = %__MODULE__{
      chain: chain,
      instance_id: instance_id,
      mode: nil,
      ws_strategy: nil,
      http_strategy: nil,
      config: config,
      ws_retry_count: 0
    }

    Process.send_after(self(), :start_strategies, 2_000)

    Logger.debug("BlockSync.Worker started",
      chain: chain,
      instance_id: instance_id,
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

  # Block height reports from strategies
  def handle_info({:block_height, instance_id, height, metadata}, state)
      when instance_id == state.instance_id do
    source = if metadata[:latency_ms], do: :http, else: :ws

    BlockSyncRegistry.put_height(state.chain, instance_id, height, source, metadata)
    broadcast_height_update(state, height, source)

    {:noreply, state}
  end

  # Status changes from strategies
  def handle_info({:status, instance_id, transport, status}, state)
      when instance_id == state.instance_id do
    state = handle_strategy_status(state, transport, status)
    {:noreply, state}
  end

  # HTTP strategy poll timer
  def handle_info({:http_strategy, :poll, instance_id}, state)
      when instance_id == state.instance_id and state.http_strategy != nil do
    {:ok, new_http_state} = HttpStrategy.handle_message(:poll, state.http_strategy)
    {:noreply, %{state | http_strategy: new_http_state}}
  end

  def handle_info({:http_strategy, :poll, instance_id}, state)
      when instance_id == state.instance_id and state.http_strategy == nil do
    {:noreply, state}
  end

  # WS strategy staleness check timer
  def handle_info({:ws_strategy, :check_staleness, instance_id}, state)
      when instance_id == state.instance_id and state.ws_strategy != nil do
    {:ok, new_ws_state} = WsStrategy.handle_message(:check_staleness, state.ws_strategy)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  def handle_info({:ws_strategy, :check_staleness, instance_id}, state)
      when instance_id == state.instance_id and state.ws_strategy == nil do
    {:noreply, state}
  end

  # newHeads events from InstanceSubscriptionManager via InstanceSubscriptionRegistry
  def handle_info(
        {:instance_subscription_event, instance_id, {:newHeads}, payload, _received_at},
        state
      )
      when instance_id == state.instance_id and state.ws_strategy != nil and is_map(payload) do
    new_ws_state = WsStrategy.handle_new_head(state.ws_strategy, payload)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  def handle_info(
        {:instance_subscription_event, instance_id, {:newHeads}, _payload, _received_at},
        state
      )
      when instance_id == state.instance_id do
    {:noreply, state}
  end

  # Subscription invalidation
  def handle_info(
        {:instance_subscription_invalidated, instance_id, {:newHeads}, reason},
        state
      )
      when instance_id == state.instance_id and state.ws_strategy != nil do
    new_ws_state = WsStrategy.handle_invalidation(state.ws_strategy, reason)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  # WS reconnected
  def handle_info({:ws_connected, instance_id, _connection_id}, state)
      when instance_id == state.instance_id do
    state = handle_ws_reconnected(state)
    {:noreply, state}
  end

  # WS disconnected
  def handle_info({:ws_disconnected, instance_id, _error}, state)
      when instance_id == state.instance_id do
    state = handle_ws_disconnected(state)
    {:noreply, state}
  end

  def handle_info({:ws_closed, instance_id, _code, _error}, state)
      when instance_id == state.instance_id do
    state = handle_ws_disconnected(state)
    {:noreply, state}
  end

  # Manager restart - re-establish WS subscription if the restarted manager is ours
  def handle_info({:instance_sub_manager_restarted, instance_id}, state)
      when instance_id == state.instance_id do
    state = handle_manager_restarted(state)
    {:noreply, state}
  end

  # Ignore restarts for other instances on the same chain
  def handle_info({:instance_sub_manager_restarted, _other_instance_id}, state) do
    {:noreply, state}
  end

  # WS reconnect attempt timer
  def handle_info(:attempt_ws_reconnect, state) do
    state = attempt_ws_reconnect(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp broadcast_height_update(state, height, source) do
    profiles = Catalog.get_instance_refs(state.instance_id)
    timestamp = System.system_time(:millisecond)

    for profile <- profiles do
      provider_id =
        Catalog.reverse_lookup_provider_id(profile, state.chain, state.instance_id) ||
          state.instance_id

      provider_key = {profile, provider_id}
      msg = {:block_height_update, provider_key, height, source, timestamp}
      Phoenix.PubSub.broadcast(Lasso.PubSub, "block_sync:#{profile}:#{state.chain}", msg)

      sync_msg = %{chain: state.chain, provider_id: provider_id, block_height: height}
      Phoenix.PubSub.broadcast(Lasso.PubSub, "sync:updates:#{profile}", sync_msg)
    end
  end

  defp load_config(instance_id, chain) do
    refs = Catalog.get_instance_refs(instance_id)
    has_ws = instance_has_ws?(instance_id)

    default_config = %{
      subscribe_new_heads: has_ws,
      poll_interval_ms: 15_000,
      staleness_threshold_ms: 35_000
    }

    with [ref_profile | _] <- refs,
         {:ok, chain_config} <- ConfigStore.get_chain(ref_profile, chain) do
      subscribe_new_heads =
        resolve_subscribe_new_heads(chain_config, ref_profile, chain, instance_id) or
          Enum.any?(refs, &check_profile_subscribe_new_heads(&1, chain, instance_id))

      %{
        subscribe_new_heads: subscribe_new_heads and has_ws,
        poll_interval_ms: chain_config.monitoring.probe_interval_ms,
        staleness_threshold_ms: chain_config.websocket.new_heads_timeout_ms
      }
    else
      _ -> default_config
    end
  end

  defp instance_has_ws?(instance_id) do
    case Catalog.get_instance(instance_id) do
      {:ok, inst} -> is_binary(Map.get(inst, :ws_url))
      _ -> false
    end
  end

  defp resolve_subscribe_new_heads(chain_config, profile, chain, instance_id) do
    provider_id = Catalog.reverse_lookup_provider_id(profile, chain, instance_id)

    if provider_id do
      case ChainConfig.get_provider_by_id(chain_config, provider_id) do
        {:ok, provider} -> ChainConfig.should_subscribe_new_heads?(chain_config, provider)
        {:error, _} -> chain_config.websocket.subscribe_new_heads
      end
    else
      chain_config.websocket.subscribe_new_heads
    end
  end

  defp check_profile_subscribe_new_heads(profile, chain, instance_id) do
    case ConfigStore.get_chain(profile, chain) do
      {:ok, chain_config} ->
        resolve_subscribe_new_heads(chain_config, profile, chain, instance_id)

      _ ->
        false
    end
  end

  defp start_strategies(state) do
    state = start_http_polling(state)

    if state.config.subscribe_new_heads do
      add_ws_subscription(state)
    else
      state
    end
  end

  defp start_http_polling(state) do
    http_opts = [
      instance_id: state.instance_id,
      parent: self(),
      poll_interval_ms: state.config.poll_interval_ms
    ]

    {:ok, http_state} = HttpStrategy.start(state.chain, state.instance_id, http_opts)

    Logger.debug("HTTP polling started",
      chain: state.chain,
      instance_id: state.instance_id,
      poll_interval_ms: state.config.poll_interval_ms
    )

    %{state | mode: :http_only, http_strategy: http_state}
  end

  defp add_ws_subscription(state) do
    ws_opts = [
      instance_id: state.instance_id,
      parent: self(),
      staleness_threshold_ms: state.config.staleness_threshold_ms
    ]

    case WsStrategy.start(state.chain, state.instance_id, ws_opts) do
      {:ok, ws_state} ->
        %{state | mode: :http_with_ws, ws_strategy: ws_state, ws_retry_count: 0}

      {:error, :connection_unknown} ->
        Logger.debug("WS connection state unknown, will retry shortly",
          chain: state.chain,
          instance_id: state.instance_id
        )

        Process.send_after(self(), :attempt_ws_reconnect, 1_000)
        state

      {:error, reason} ->
        level = if state.ws_retry_count > 0, do: :debug, else: :warning

        Logger.log(level, "WS subscription failed to start, HTTP polling continues",
          chain: state.chain,
          instance_id: state.instance_id,
          reason: inspect(reason)
        )

        schedule_ws_reconnect(state.ws_retry_count)
        %{state | ws_retry_count: state.ws_retry_count + 1}
    end
  end

  defp handle_strategy_status(state, :ws, :active) do
    %{state | mode: :http_with_ws, ws_retry_count: 0}
  end

  defp handle_strategy_status(state, :ws, :failed) do
    Logger.debug("WS subscription failed, HTTP polling continues",
      chain: state.chain,
      instance_id: state.instance_id
    )

    state
  end

  defp handle_strategy_status(state, :ws, status) when status in [:stale, :degraded] do
    Logger.info("WS subscription #{status}, HTTP polling continues",
      chain: state.chain,
      instance_id: state.instance_id
    )

    state
  end

  defp handle_strategy_status(state, :http, :degraded) do
    Logger.warning("HTTP polling degraded",
      chain: state.chain,
      instance_id: state.instance_id
    )

    state
  end

  defp handle_strategy_status(state, :http, :healthy) do
    Logger.debug("HTTP polling recovered",
      chain: state.chain,
      instance_id: state.instance_id
    )

    state
  end

  defp handle_strategy_status(state, _transport, _status) do
    state
  end

  defp handle_ws_reconnected(%{mode: nil} = state), do: state

  defp handle_ws_reconnected(state) do
    if state.config.subscribe_new_heads do
      case state.ws_strategy do
        nil ->
          add_ws_subscription(state)

        ws_state ->
          case WsStrategy.resubscribe(ws_state) do
            {:ok, new_ws_state} ->
              %{state | mode: :http_with_ws, ws_strategy: new_ws_state, ws_retry_count: 0}

            {:error, _} ->
              schedule_ws_reconnect(state.ws_retry_count)
              %{state | ws_retry_count: state.ws_retry_count + 1}
          end
      end
    else
      state
    end
  end

  defp handle_ws_disconnected(%{mode: nil} = state), do: state

  defp handle_ws_disconnected(state) do
    if state.ws_strategy do
      Logger.info("WS subscription disconnected, HTTP polling continues",
        chain: state.chain,
        instance_id: state.instance_id
      )

      schedule_ws_reconnect(state.ws_retry_count)
    end

    state
  end

  defp handle_manager_restarted(state) do
    if state.ws_strategy && state.mode == :http_with_ws do
      case WsStrategy.resubscribe(state.ws_strategy) do
        {:ok, new_ws_state} ->
          %{state | ws_strategy: new_ws_state}

        {:error, _} ->
          schedule_ws_reconnect(state.ws_retry_count)
          %{state | ws_retry_count: state.ws_retry_count + 1}
      end
    else
      state
    end
  end

  defp attempt_ws_reconnect(state) do
    if state.config.subscribe_new_heads and state.ws_strategy == nil do
      ws_opts = [
        instance_id: state.instance_id,
        parent: self(),
        staleness_threshold_ms: state.config.staleness_threshold_ms
      ]

      case WsStrategy.start(state.chain, state.instance_id, ws_opts) do
        {:ok, ws_state} ->
          Logger.info("WS subscription reconnected",
            chain: state.chain,
            instance_id: state.instance_id
          )

          %{state | mode: :http_with_ws, ws_strategy: ws_state, ws_retry_count: 0}

        {:error, reason} ->
          Logger.debug("WS subscription reconnect failed, will retry",
            chain: state.chain,
            instance_id: state.instance_id,
            reason: inspect(reason),
            retry_count: state.ws_retry_count + 1
          )

          schedule_ws_reconnect(state.ws_retry_count)
          %{state | ws_retry_count: state.ws_retry_count + 1}
      end
    else
      state
    end
  end

  defp schedule_ws_reconnect(retry_count) do
    delay = min(@reconnect_delay_ms * :math.pow(2, retry_count), 60_000) |> trunc()
    Process.send_after(self(), :attempt_ws_reconnect, delay)
  end
end
