defmodule Lasso.RPC.UpstreamSubscriptionPool do
  @moduledoc """
  Per-chain pool that multiplexes client subscriptions onto minimal upstream
  subscriptions. MVP supports single-provider policy with priority selection,
  failover on disconnect/close, bounded backfill, and simple dedupe.
  """

  use GenServer
  require Logger

  alias Lasso.RPC.{Selection, SelectionContext, ClientSubscriptionRegistry}
  alias Lasso.RPC.StreamSupervisor
  alias Lasso.RPC.StreamCoordinator
  alias Lasso.RPC.{TransportRegistry, Channel}
  alias Lasso.RPC.{FilterNormalizer, ErrorNormalizer}
  alias Lasso.Config.ConfigStore
  alias Lasso.Events.Provider

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type upstream_id :: String.t()
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
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:subs:#{chain}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")

    # Load dedupe config
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
  def handle_cast({:resubscribe, key, new_provider_id, coordinator_pid}, state) do
    Logger.info("Resubscribing key #{inspect(key)} to provider #{new_provider_id}")

    # Get existing entry to preserve refcount
    entry = Map.get(state.keys, key)

    if entry do
      # Get old provider info for cleanup
      {old_provider_id, old_upstream_id} =
        case Map.get(entry.upstream, entry.primary_provider_id) do
          nil -> {entry.primary_provider_id, nil}
          up_id -> {entry.primary_provider_id, up_id}
        end

      # Execute new subscription
      case send_upstream_subscribe(state.chain, new_provider_id, key) do
        {:ok, upstream_id} ->
          # Unsubscribe old upstream if present to avoid stragglers and leaks
          if old_upstream_id do
            Task.start(fn ->
              send_upstream_unsubscribe(state.chain, old_provider_id, key, old_upstream_id)
            end)
          end

          # Update entry with new provider
          updated_entry = %{
            entry
            | primary_provider_id: new_provider_id,
              upstream: Map.put(entry.upstream, new_provider_id, upstream_id)
          }

          # Clean old upstream from index
          new_upstream_index =
            if old_upstream_id do
              case Map.get(state.upstream_index, old_provider_id) do
                nil ->
                  state.upstream_index

                provider_map ->
                  updated_map = Map.delete(provider_map, old_upstream_id)

                  if map_size(updated_map) == 0 do
                    Map.delete(state.upstream_index, old_provider_id)
                  else
                    Map.put(state.upstream_index, old_provider_id, updated_map)
                  end
              end
            else
              state.upstream_index
            end

          # Add new upstream to index
          new_upstream_index =
            Map.update(new_upstream_index, new_provider_id, %{upstream_id => key}, fn m ->
              Map.put(m, upstream_id, key)
            end)

          new_state = %{
            state
            | keys: Map.put(state.keys, key, updated_entry),
              upstream_index: new_upstream_index
          }

          # Confirm to coordinator
          send(coordinator_pid, {:subscription_confirmed, new_provider_id, upstream_id})

          telemetry_resubscribe_success(state.chain, key, new_provider_id)

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
  # Handle typed subscription events from WSConnection
  def handle_info(
        {:subscription_event, provider_id, upstream_id, payload, received_at},
        state
      )
      when is_binary(upstream_id) do
    case get_in(state.upstream_index, [provider_id, upstream_id]) do
      nil ->
        Logger.warning(
          "No key found for subscription event: provider=#{provider_id}, upstream_id=#{upstream_id}, full_index=#{inspect(state.upstream_index)}"
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

  # Fallback handler for subscription events WITHOUT subscription ID (still supported if needed)
  def handle_info({:subscription_event, _provider_id, nil, payload, received_at}, state) do
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

  # Internal helpers

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
          case send_upstream_subscribe(state.chain, provider_id, key) do
            {:ok, upstream_id} ->
              telemetry_upstream(:subscribe, state.chain, provider_id, key)

              entry = %{
                refcount: 1,
                primary_provider_id: provider_id,
                upstream: %{provider_id => upstream_id},
                markers: %{},
                dedupe: nil
              }

              upstream_index =
                Map.update(state.upstream_index, provider_id, %{upstream_id => key}, fn m ->
                  Map.put(m, upstream_id, key)
                end)

              new_state = %{
                state
                | keys: Map.put(state.keys, key, entry),
                  upstream_index: upstream_index
              }

              {new_state, provider_id}

            {:error, jerr} ->
              # Try select next provider; for simplicity, return original state and nil
              Logger.warning(
                "Initial upstream subscribe failed for #{inspect(key)} on #{provider_id}: #{inspect(jerr)}"
              )

              {state, nil}
          end
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
        # Best-effort unsubscribe on current provider (async to avoid blocking)
        upstream_id = Map.get(upstream, provider_id)

        Task.start(fn ->
          send_upstream_unsubscribe(state.chain, provider_id, key, upstream_id)
        end)

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

        # Stop the StreamCoordinator for this key (async to avoid blocking)
        Task.start(fn -> StreamSupervisor.stop_coordinator(state.chain, key) end)

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

    Logger.info("Sending upstream eth_subscribe to #{provider_id} with request id #{id}")

    with {:ok, channel} <- TransportRegistry.get_channel(chain, provider_id, :ws),
         {:ok, upstream_id} <- Channel.request(channel, message, 10_000) do
      {:ok, upstream_id}
    else
      {:error, reason} ->
        {:error,
         ErrorNormalizer.normalize(reason,
           provider_id: provider_id,
           context: :transport,
           transport: :ws
         )}
    end
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

    with {:ok, channel} <- TransportRegistry.get_channel(chain, provider_id, :ws),
         {:ok, upstream_id} <- Channel.request(channel, message, 10_000) do
      {:ok, upstream_id}
    else
      {:error, reason} ->
        {:error,
         ErrorNormalizer.normalize(reason,
           provider_id: provider_id,
           context: :transport,
           transport: :ws
         )}
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

    case TransportRegistry.get_channel(chain, provider_id, :ws) do
      {:ok, channel} ->
        _ = Channel.request(channel, message, 5_000)
        :ok

      {:error, _} ->
        :ok
    end

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

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
