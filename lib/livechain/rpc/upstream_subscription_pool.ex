defmodule Livechain.RPC.UpstreamSubscriptionPool do
  @moduledoc """
  Per-chain pool that multiplexes client subscriptions onto minimal upstream
  subscriptions. MVP supports single-provider policy with priority selection,
  failover on disconnect/close, bounded backfill, and simple dedupe.
  """

  use GenServer
  require Logger

  alias Livechain.RPC.{Selection, ClientSubscriptionRegistry}
  alias Livechain.RPC.StreamSupervisor
  alias Livechain.RPC.StreamCoordinator
  alias Livechain.RPC.ChainSupervisor
  alias Livechain.RPC.FilterNormalizer
  alias Livechain.Config.ConfigStore
  alias Livechain.Events.Provider

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type upstream_id :: String.t()
  @type key :: {:newHeads} | {:logs, map()}

  def start_link(chain) when is_binary(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Livechain.Registry, {:pool, chain}}}

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
    Logger.info("Starting ProviderSubscriptionPool for #{chain}")
    Phoenix.PubSub.subscribe(Livechain.PubSub, "raw_messages:#{chain}")
    Phoenix.PubSub.subscribe(Livechain.PubSub, "provider_pool:events:#{chain}")

    # Load backfill config
    failover_cfg =
      case ConfigStore.get_chain(chain) do
        {:ok, cfg} -> Map.get(cfg, :failover, %{})
        _ -> %{}
      end

    dedupe_cfg =
      case ConfigStore.get_chain(chain) do
        {:ok, cfg} -> Map.get(cfg, :dedupe, %{})
        _ -> %{}
      end

    state = %{
      chain: chain,
      # key => %{refcount, primary_provider_id, upstream: %{provider_id => upstream_id | nil}, markers, dedupe}
      keys: %{},
      # provider_id => %{upstream_id => key}
      upstream_index: %{},
      # request_id => {provider_id, key}
      pending_subscribe: %{},
      # config
      max_backfill_blocks: Map.get(failover_cfg, :max_backfill_blocks, 32),
      backfill_timeout: Map.get(failover_cfg, :backfill_timeout, 30_000),
      failover_enabled: Map.get(failover_cfg, :enabled, true),
      dedupe_max_items: Map.get(dedupe_cfg, :max_items, 256),
      dedupe_max_age_ms: Map.get(dedupe_cfg, :max_age_ms, 30_000)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, client_pid, key}, _from, state) do
    # Allocate subscription id and register client
    subscription_id = generate_id()
    :ok = ClientSubscriptionRegistry.add_client(state.chain, subscription_id, client_pid, key)

    {new_state, _} = ensure_upstream_for_key(state, key)

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
  def handle_info(
        {:raw_message, _provider_id,
         %{"method" => "eth_subscription", "params" => %{"result" => payload}}, received_at},
        state
      ) do
    # Determine key for routing and update markers/dedupe
    case detect_key_from_payload(payload) do
      {:ok, key} ->
        StreamCoordinator.upstream_event(
          state.chain,
          key,
          _provider_id = nil,
          _upstream_id = nil,
          payload,
          received_at
        )

        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:raw_message, provider_id, %{"id" => request_id, "result" => upstream_id}, _received_at},
        state
      )
      when is_binary(upstream_id) do
    case Map.pop(state.pending_subscribe, request_id) do
      {nil, _} ->
        {:noreply, state}

      {{prov, key}, new_pending} ->
        # Only proceed if this confirmation matches the provider we expect
        if prov == provider_id do
          entry = Map.get(state.keys, key)
          updated_entry = put_in(entry, [:upstream, provider_id], upstream_id)
          upstream_index = put_in(state.upstream_index, [provider_id, upstream_id], key)

          # Notify coordinator that upstream is confirmed
          StreamCoordinator.upstream_confirmed(state.chain, key, provider_id, upstream_id)

          {:noreply,
           %{
             state
             | keys: Map.put(state.keys, key, updated_entry),
               upstream_index: upstream_index,
               pending_subscribe: new_pending
           }}
        else
          {:noreply, %{state | pending_subscribe: new_pending}}
        end
    end
  end

  def handle_info(
        {:raw_message, provider_id,
         %{
           "method" => "eth_subscription",
           "params" => %{"subscription" => upstream_id, "result" => payload}
         }, received_at},
        state
      ) do
    case get_in(state.upstream_index, [provider_id, upstream_id]) do
      nil ->
        {:noreply, state}

      key ->
        StreamCoordinator.upstream_event(
          state.chain,
          key,
          provider_id,
          upstream_id,
          payload,
          received_at
        )

        {:noreply, state}
    end
  end

  def handle_info({:raw_message, provider_id, other, received_at}, state) do
    Logger.warning(
      "Unexpected raw message received from provider #{provider_id} at #{received_at}: #{inspect(other)}"
    )

    {:noreply, state}
  end

  def handle_info(evt, state)
      when is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.CooldownStart) or
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

  def handle_info(_, state), do: {:noreply, state}

  # Legacy no-op; failover is delegated to StreamCoordinator
  # Legacy no-op removed; failover handled via StreamCoordinator

  # Provider close/disconnect signals propagate via WSConnection topics; rely on reconnect.
  # Explicit failover path: Upstream re-establish on next healthy provider when connection dies.

  # Internal helpers

  defp ensure_upstream_for_key(state, key) do
    case Map.get(state.keys, key) do
      nil ->
        _ = start_coordinator_for_key(state, key)

        with {:ok, provider_id} <-
               Selection.pick_provider(state.chain, "eth_subscribe",
                 strategy: :priority,
                 protocol: :ws
               ) do
          request_id = send_upstream_subscribe(provider_id, key)
          telemetry_upstream(:subscribe, state.chain, provider_id, key)

          entry = %{
            refcount: 1,
            primary_provider_id: provider_id,
            upstream: %{provider_id => nil},
            markers: %{},
            dedupe: nil
          }

          new_state = %{
            state
            | keys: Map.put(state.keys, key, entry),
              pending_subscribe: Map.put(state.pending_subscribe, request_id, {provider_id, key})
          }

          {new_state, provider_id}
        else
          {:error, reason} ->
            Logger.error("Failed to select provider for #{inspect(key)}: #{inspect(reason)}")
            {state, nil}
        end

      entry ->
        updated = %{entry | refcount: entry.refcount + 1}
        {%{state | keys: Map.put(state.keys, key, updated)}, entry.primary_provider_id}
    end
  end

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
    case Selection.pick_provider(state.chain, "eth_subscribe",
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

      %{refcount: 1, upstream: upstream, primary_provider_id: provider_id} ->
        # Best-effort unsubscribe on current provider
        _ = send_upstream_unsubscribe(provider_id, key, Map.get(upstream, provider_id))
        telemetry_upstream(:unsubscribe, state.chain, provider_id, key)
        %{state | keys: Map.delete(state.keys, key)}

      entry ->
        updated = %{entry | refcount: entry.refcount - 1}
        %{state | keys: Map.put(state.keys, key, updated)}
    end
  end

  defp send_upstream_subscribe(provider_id, {:newHeads}) do
    id = generate_id()

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }

    ChainSupervisor.forward_ws_message("_ignored_", provider_id, message)
    id
  end

  defp send_upstream_subscribe(provider_id, {:logs, filter}) do
    id = generate_id()
    normalized = FilterNormalizer.normalize(filter)

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "eth_subscribe",
      "params" => ["logs", normalized]
    }

    ChainSupervisor.forward_ws_message("_ignored_", provider_id, message)
    id
  end

  defp send_upstream_unsubscribe(_provider_id, _key, _upstream_id) do
    # Many providers ignore ws eth_unsubscribe; best-effort or skip for MVP
    :ok
  end

  defp detect_key_from_payload(%{"blockHash" => _} = header) when is_map(header),
    do: {:ok, {:newHeads}}

  defp detect_key_from_payload(%{"topics" => _} = log) do
    {:ok,
     {:logs,
      FilterNormalizer.normalize(%{
        "address" => Map.get(log, "address"),
        "topics" => Map.get(log, "topics")
      })}}
  end

  defp detect_key_from_payload(_), do: :unknown

  # All dedupe/markers/backfill moved into StreamCoordinator

  defp telemetry_upstream(action, chain, provider_id, key) do
    :telemetry.execute([:livechain, :subs, :upstream, action], %{count: 1}, %{
      chain: chain,
      provider_id: provider_id,
      key: inspect(key)
    })
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
