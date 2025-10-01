defmodule Livechain.RPC.UpstreamSubscriptionPool do
  @moduledoc """
  Per-chain pool that multiplexes client subscriptions onto minimal upstream
  subscriptions. MVP supports single-provider policy with priority selection,
  failover on disconnect/close, bounded backfill, and simple dedupe.
  """

  use GenServer
  require Logger

  alias Livechain.RPC.{Selection, SelectionContext, ClientSubscriptionRegistry}
  alias Livechain.RPC.StreamSupervisor
  alias Livechain.RPC.StreamCoordinator
  alias Livechain.RPC.{TransportRegistry, Channel}
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
      # request_id => {provider_id, key, timestamp}
      pending_subscribe: %{},
      # provider capabilities discovered at runtime, e.g., %{provider_id => %{newHeads: true/false, logs: true/false}}
      provider_caps: %{},
      # config
      max_backfill_blocks: Map.get(failover_cfg, :max_backfill_blocks, 32),
      backfill_timeout: Map.get(failover_cfg, :backfill_timeout, 30_000),
      failover_enabled: Map.get(failover_cfg, :enabled, true),
      dedupe_max_items: Map.get(dedupe_cfg, :max_items, 256),
      dedupe_max_age_ms: Map.get(dedupe_cfg, :max_age_ms, 30_000),
      # Subscription confirmation timeout
      subscription_timeout_ms: 30_000
    }

    # Schedule periodic cleanup of stale pending subscriptions
    schedule_pending_cleanup()

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
  # Handle subscription events WITH subscription ID (most common case) - must come BEFORE the fallback handler
  def handle_info(
        {:raw_message, provider_id,
         %{
           "method" => "eth_subscription",
           "params" => %{"subscription" => upstream_id, "result" => payload}
         }, received_at},
        state
      ) do
    Logger.debug(
      "Received subscription event: provider=#{provider_id}, upstream_id=#{upstream_id}, upstream_index=#{inspect(state.upstream_index)}"
    )

    case get_in(state.upstream_index, [provider_id, upstream_id]) do
      nil ->
        Logger.warning(
          "No key found for subscription event: provider=#{provider_id}, upstream_id=#{upstream_id}"
        )

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

  # Fallback handler for subscription events WITHOUT subscription ID (unusual case)
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
    Logger.debug(
      "Received subscription confirmation: provider=#{provider_id}, request_id=#{request_id}, upstream_id=#{upstream_id}"
    )

    with {{expected_provider, key, _timestamp}, new_pending} <-
           Map.pop(state.pending_subscribe, request_id),
         :ok <- validate_provider_match(expected_provider, provider_id, new_pending),
         {:ok, entry} <- fetch_key_entry(state.keys, key, new_pending) do
      # Success path: confirmation for active subscription
      handle_successful_confirmation(state, new_pending, key, provider_id, upstream_id, entry)
    else
      {nil, _} ->
        handle_unknown_confirmation(state, request_id, provider_id)

      {:error, :provider_mismatch, new_pending} ->
        handle_provider_mismatch(state, new_pending)

      {:error, :key_not_found, new_pending, key} ->
        handle_orphaned_confirmation(state, new_pending, key, provider_id, upstream_id)
    end
  end

  # Handle subscription errors (e.g., provider does not support specific subscription type)
  def handle_info(
        {:raw_message, provider_id, %{"id" => request_id, "error" => error}, _received_at},
        state
      ) do
    case Map.pop(state.pending_subscribe, request_id) do
      {nil, _} ->
        {:noreply, state}

      {{prov, key, _timestamp}, new_pending} ->
        if prov == provider_id do
          Logger.warning(
            "Upstream subscribe failed on #{provider_id} for #{inspect(key)}: #{inspect(error)}"
          )

          cap = capability_from_key(key)

          provider_caps =
            Map.update(state.provider_caps, provider_id, %{cap => false}, fn caps ->
              Map.put(caps, cap, false)
            end)

          entry = Map.get(state.keys, key)
          already_tried = Map.keys(entry.upstream)

          exclude = Enum.uniq([provider_id | already_tried])

          case Selection.select_provider(
                 SelectionContext.new(state.chain, "eth_subscribe",
                   strategy: :priority,
                   protocol: :ws,
                   exclude: exclude
                 )
               ) do
            {:ok, next_provider} ->
              request_id2 = send_upstream_subscribe(state.chain, next_provider, key)
              telemetry_upstream(:subscribe, state.chain, next_provider, key)
              timestamp = System.monotonic_time(:millisecond)

              updated_entry =
                entry
                |> Map.put(:primary_provider_id, next_provider)
                |> update_in([:upstream], &Map.put(&1, next_provider, nil))

              new_state = %{
                state
                | keys: Map.put(state.keys, key, updated_entry),
                  pending_subscribe:
                    Map.put(new_pending, request_id2, {next_provider, key, timestamp}),
                  provider_caps: provider_caps
              }

              {:noreply, new_state}

            {:error, reason} ->
              Logger.error(
                "No alternative provider available for #{inspect(key)} after failure on #{provider_id}: #{inspect(reason)}"
              )

              {:noreply, %{state | pending_subscribe: new_pending, provider_caps: provider_caps}}
          end
        else
          {:noreply, %{state | pending_subscribe: new_pending}}
        end
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

  # Periodic cleanup of stale pending subscriptions
  def handle_info(:cleanup_stale_pending, state) do
    now = System.monotonic_time(:millisecond)
    timeout_ms = state.subscription_timeout_ms

    {stale, valid} =
      Enum.split_with(state.pending_subscribe, fn {_req_id, {_prov, _key, ts}} ->
        now - ts > timeout_ms
      end)

    # Log and emit telemetry for stale entries
    Enum.each(stale, fn {req_id, {provider_id, key, _ts}} ->
      Logger.warning(
        "Timeout waiting for subscription confirmation: provider=#{provider_id}, key=#{inspect(key)}, req_id=#{req_id}"
      )

      :telemetry.execute(
        [:livechain, :subs, :confirmation_timeout],
        %{count: 1},
        %{chain: state.chain, provider_id: provider_id, key: inspect(key)}
      )
    end)

    # Emit state size telemetry for leak detection
    upstream_index_size = calculate_nested_map_size(state.upstream_index)
    valid_map = Map.new(valid)

    :telemetry.execute(
      [:livechain, :subs, :pool_state],
      %{
        keys_count: map_size(state.keys),
        pending_count: map_size(valid_map),
        upstream_index_size: upstream_index_size,
        stale_cleaned: length(stale)
      },
      %{chain: state.chain}
    )

    # Schedule next cleanup
    schedule_pending_cleanup()

    {:noreply, %{state | pending_subscribe: valid_map}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Legacy no-op; failover is delegated to StreamCoordinator
  # Legacy no-op removed; failover handled via StreamCoordinator

  # Provider close/disconnect signals propagate via WSConnection topics; rely on reconnect.
  # Explicit failover path: Upstream re-establish on next healthy provider when connection dies.

  # Internal helpers

  # Confirmation handler helpers - cleaner separation of concerns

  defp validate_provider_match(expected, actual, _new_pending) when expected == actual, do: :ok

  defp validate_provider_match(_expected, _actual, new_pending),
    do: {:error, :provider_mismatch, new_pending}

  defp fetch_key_entry(keys, key, new_pending) do
    case Map.get(keys, key) do
      nil -> {:error, :key_not_found, new_pending, key}
      entry -> {:ok, entry}
    end
  end

  defp handle_unknown_confirmation(state, request_id, provider_id) do
    Logger.warning(
      "Subscription confirmation for unknown request_id: #{request_id}, provider=#{provider_id}"
    )

    {:noreply, state}
  end

  defp handle_provider_mismatch(state, new_pending) do
    # Provider mismatch - likely a delayed response, just clean up pending
    {:noreply, %{state | pending_subscribe: new_pending}}
  end

  defp handle_orphaned_confirmation(state, new_pending, key, provider_id, upstream_id) do
    # Subscription was cancelled before confirmation arrived - clean up orphaned upstream
    Logger.warning(
      "Late confirmation for cancelled subscription: provider=#{provider_id}, upstream_id=#{upstream_id}, key=#{inspect(key)}. Cleaning up."
    )

    # Send eth_unsubscribe to provider
    _ = send_upstream_unsubscribe(state.chain, provider_id, key, upstream_id)

    # Emit telemetry for monitoring
    :telemetry.execute(
      [:livechain, :subs, :orphaned_upstream],
      %{count: 1},
      %{chain: state.chain, provider_id: provider_id, upstream_id: upstream_id}
    )

    {:noreply, %{state | pending_subscribe: new_pending}}
  end

  defp handle_successful_confirmation(state, new_pending, key, provider_id, upstream_id, entry) do
    # Update entry with confirmed upstream_id
    updated_entry = put_in(entry, [:upstream, provider_id], upstream_id)

    # Build nested upstream_index map
    upstream_index =
      Map.update(
        state.upstream_index,
        provider_id,
        %{upstream_id => key},
        &Map.put(&1, upstream_id, key)
      )

    # Mark capability as supported
    cap = capability_from_key(key)

    provider_caps =
      Map.update(state.provider_caps, provider_id, %{cap => true}, &Map.put(&1, cap, true))

    # Notify coordinator
    StreamCoordinator.upstream_confirmed(state.chain, key, provider_id, upstream_id)

    {:noreply,
     %{
       state
       | keys: Map.put(state.keys, key, updated_entry),
         upstream_index: upstream_index,
         pending_subscribe: new_pending,
         provider_caps: provider_caps
     }}
  end

  defp ensure_upstream_for_key(state, key) do
    case Map.get(state.keys, key) do
      nil ->
        _ = start_coordinator_for_key(state, key)

        with {:ok, provider_id} <-
               Selection.select_provider(
                 SelectionContext.new(state.chain, "eth_subscribe",
                   strategy: :priority,
                   protocol: :ws
                 )
               ) do
          request_id = send_upstream_subscribe(state.chain, provider_id, key)
          telemetry_upstream(:subscribe, state.chain, provider_id, key)

          entry = %{
            refcount: 1,
            primary_provider_id: provider_id,
            upstream: %{provider_id => nil},
            markers: %{},
            dedupe: nil
          }

          timestamp = System.monotonic_time(:millisecond)

          new_state = %{
            state
            | keys: Map.put(state.keys, key, entry),
              pending_subscribe:
                Map.put(state.pending_subscribe, request_id, {provider_id, key, timestamp})
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

      %{refcount: 1, upstream: upstream, primary_provider_id: provider_id} ->
        # Best-effort unsubscribe on current provider
        upstream_id = Map.get(upstream, provider_id)
        _ = send_upstream_unsubscribe(state.chain, provider_id, key, upstream_id)
        telemetry_upstream(:unsubscribe, state.chain, provider_id, key)

        # Clean up upstream_index for all providers in the upstream map
        new_upstream_index =
          Enum.reduce(upstream, state.upstream_index, fn {prov_id, up_id}, acc ->
            case up_id do
              nil ->
                # No upstream_id was assigned yet, nothing to clean
                acc

              _ ->
                # Remove this upstream_id from the provider's map
                case Map.get(acc, prov_id) do
                  nil ->
                    acc

                  provider_map ->
                    updated_map = Map.delete(provider_map, up_id)

                    if map_size(updated_map) == 0 do
                      # Provider has no more subscriptions, remove it entirely
                      Map.delete(acc, prov_id)
                    else
                      Map.put(acc, prov_id, updated_map)
                    end
                end
            end
          end)

        # Stop the StreamCoordinator for this key
        StreamSupervisor.stop_coordinator(state.chain, key)

        %{state | keys: Map.delete(state.keys, key), upstream_index: new_upstream_index}

      entry ->
        updated = %{entry | refcount: entry.refcount - 1}
        %{state | keys: Map.put(state.keys, key, updated)}
    end
  end

  defp send_upstream_subscribe(chain, provider_id, {:newHeads}) do
    id = generate_id()

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }

    Logger.debug("Sending upstream eth_subscribe to #{provider_id} with id #{id}")

    # Use Channel abstraction instead of direct WSConnection call
    # This supports dynamic providers that weren't started via ChainSupervisor init
    result = send_via_channel(chain, provider_id, message)

    Logger.debug("Channel send result: #{inspect(result)}")
    id
  end

  defp send_upstream_subscribe(chain, provider_id, {:logs, filter}) do
    id = generate_id()
    normalized = FilterNormalizer.normalize(filter)

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "eth_subscribe",
      "params" => ["logs", normalized]
    }

    Logger.debug("Sending upstream eth_subscribe (logs) to #{provider_id} with id #{id}")

    # Use Channel abstraction instead of direct WSConnection call
    result = send_via_channel(chain, provider_id, message)

    Logger.debug("Channel send result: #{inspect(result)}")
    id
  end

  # Helper to send message via Channel (falls back to WSConnection for compatibility)
  defp send_via_channel(chain, provider_id, message) do
    case TransportRegistry.get_channel(chain, provider_id, :ws) do
      {:ok, channel} ->
        # Channel exists, use it
        case Channel.request(channel, message, 5_000) do
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, _reason} ->
        # Fall back to direct WSConnection for providers started by ChainSupervisor
        # This maintains backward compatibility during transition
        case GenServer.whereis({:via, Registry, {Livechain.Registry, {:ws_conn, provider_id}}}) do
          nil ->
            {:error, :no_ws_connection}

          _pid ->
            # WSConnection exists, send directly (fire and forget style)
            Livechain.RPC.WSConnection.send_message(provider_id, message)
        end
    end
  end

  defp send_upstream_unsubscribe(chain, provider_id, _key, upstream_id)
       when is_binary(upstream_id) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_unsubscribe",
      "params" => [upstream_id]
    }

    Logger.debug("Sending upstream eth_unsubscribe to #{provider_id} for #{upstream_id}")

    # Best-effort send via channel, fire-and-forget (don't wait for response)
    _ = send_via_channel(chain, provider_id, message)
    :ok
  end

  defp send_upstream_unsubscribe(_chain, _provider_id, _key, _upstream_id) do
    # No upstream_id available, nothing to unsubscribe
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

  defp capability_from_key({:newHeads}), do: :newHeads
  defp capability_from_key({:logs, _}), do: :logs

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # Stale pending subscription cleanup

  defp schedule_pending_cleanup do
    # Check every 30 seconds
    Process.send_after(self(), :cleanup_stale_pending, 30_000)
  end

  defp calculate_nested_map_size(nested_map) do
    Enum.reduce(nested_map, 0, fn {_provider, inner_map}, acc ->
      acc + map_size(inner_map)
    end)
  end
end
