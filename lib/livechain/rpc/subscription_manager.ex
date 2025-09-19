defmodule Livechain.RPC.SubscriptionManager do
  @moduledoc """
  Manages real-time event subscriptions for JSON-RPC endpoints.

  This module handles:
  - WebSocket subscriptions to blockchain events
  - Subscription lifecycle management
  - Event routing to connected clients
  - Subscription deduplication and filtering
  """

  use GenServer
  require Logger

  alias Livechain.RPC.{ChainRegistry, ChainSupervisor}

  @stall_check_interval_ms 20000

  defmodule SubscriptionState do
    @moduledoc """
    Provider-agnostic subscription state with block height tracking for bulletproof failover.
    """

    @type t :: %__MODULE__{
            # subscription_id
            id: String.t(),
            # websocket channel process
            client_pid: pid(),
            # subscription type
            type: :newHeads | :logs,
            # log filter criteria (nil for newHeads)
            filter: map() | nil,
            # chain name
            chain: String.t(),
            # last successfully delivered block to client
            last_delivered_block: non_neg_integer() | nil,
            # hash for reorg detection
            last_delivered_block_hash: String.t() | nil,
            # subscription status
            status: :active | :migrating | :backfilling | :failed,
            # when subscription was created
            created_at: DateTime.t(),
            # providers currently serving this subscription
            provider_ids: [String.t()],
            # true if currently backfilling missed events
            backfill_in_progress: boolean()
          }

    defstruct [
      :id,
      :client_pid,
      :type,
      :filter,
      :chain,
      :last_delivered_block,
      :last_delivered_block_hash,
      :created_at,
      status: :active,
      provider_ids: [],
      backfill_in_progress: false
    ]
  end

  defstruct [
    # %{subscription_id => SubscriptionState.t()}
    :subscriptions,
    :subscription_counter,
    :event_cache,
    :active_filters,
    # %{chain => [subscription_id]}
    :chain_subscriptions
  ]

  @doc """
  Starts the SubscriptionManager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to log events on a specific chain.
  """
  def subscribe_to_logs(chain, filter) do
    GenServer.call(__MODULE__, {:subscribe_logs, chain, filter})
  end

  @doc """
  Subscribe to new block headers on a specific chain.
  """
  def subscribe_to_new_heads(chain) do
    GenServer.call(__MODULE__, {:subscribe_new_heads, chain})
  end

  @doc """
  Unsubscribe from an event subscription.
  """
  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Get active subscriptions.
  """
  def get_subscriptions do
    GenServer.call(__MODULE__, :get_subscriptions)
  end

  @doc """
  Handle incoming blockchain events and route to subscribers.
  """
  def handle_event(chain, event_type, event_data) do
    GenServer.cast(__MODULE__, {:handle_event, chain, event_type, event_data})
  end

  @doc """
  Handle provider failover - migrate all subscriptions from failed provider to healthy ones.
  This is the core function for bulletproof subscription continuity.
  """
  def handle_provider_failover(chain, failed_provider_id, healthy_provider_ids) do
    GenServer.cast(
      __MODULE__,
      {:handle_provider_failover, chain, failed_provider_id, healthy_provider_ids}
    )
  end

  @doc """
  Update the last delivered block for a subscription - critical for continuity tracking.
  Called after successfully delivering an event to the client.
  """
  def update_subscription_block(subscription_id, block_number, block_hash) do
    GenServer.cast(
      __MODULE__,
      {:update_subscription_block, subscription_id, block_number, block_hash}
    )
  end

  @doc """
  Get all active subscriptions for a chain - used by failover logic.
  """
  def get_chain_subscriptions(chain) do
    GenServer.call(__MODULE__, {:get_chain_subscriptions, chain})
  end

  @impl true
  def init(_opts) do
    # Initialize ETS tables for subscriptions and event cache
    :ets.new(:subscriptions, [:set, :protected, :named_table])
    :ets.new(:event_cache, [:ordered_set, :protected, :named_table])

    # Subscribe to aggregated events from MessageAggregator
    # We'll subscribe to specific chains as subscriptions are created

    # Subscribe to provider pool events for failover handling
    # Use defensive subscription to handle timing issues in test environment
    case safe_pubsub_subscribe("provider_pool:events") do
      :ok ->
        Logger.debug("Successfully subscribed to provider pool events")

      {:error, reason} ->
        Logger.warning("Failed to subscribe to provider pool events: #{inspect(reason)}")
        # Continue initialization - we'll retry subscription when needed
    end

    state = %__MODULE__{
      subscriptions: %{},
      subscription_counter: 1,
      event_cache: [],
      active_filters: %{},
      chain_subscriptions: %{}
    }

    # Schedule periodic stall checks
    Process.send_after(self(), :stall_check, @stall_check_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe_logs, chain, filter}, {client_pid, _}, state) do
    subscription_id = "logs_#{chain}_#{state.subscription_counter}"

    # Create subscription record with block tracking
    subscription = %SubscriptionState{
      id: subscription_id,
      client_pid: client_pid,
      type: :logs,
      chain: chain,
      filter: filter,
      created_at: DateTime.utc_now(),
      status: :active,
      # Will be set after first event delivered
      last_delivered_block: nil,
      last_delivered_block_hash: nil
    }

    # Store subscription
    updated_subscriptions = Map.put(state.subscriptions, subscription_id, subscription)

    # Add to chain subscriptions index
    updated_chain_subscriptions =
      Map.update(
        state.chain_subscriptions,
        chain,
        [subscription_id],
        &[subscription_id | &1]
      )

    # Add to active filters for this chain
    updated_filters = Map.update(state.active_filters, chain, [filter], &[filter | &1])

    # Ensure chain is running and subscribe to events
    ensure_chain_subscription(chain, filter)

    # Trigger upstream subscription to provider and record chosen provider
    updated_subscriptions =
      case trigger_upstream_subscription(chain, :logs, filter) do
        {:ok, provider_id} ->
          case Map.get(updated_subscriptions, subscription_id) do
            %SubscriptionState{} = sub ->
              Map.put(updated_subscriptions, subscription_id, %{sub | provider_ids: [provider_id]})

            _ ->
              updated_subscriptions
          end

        _ ->
          updated_subscriptions
      end

    Logger.info("Created log subscription",
      subscription_id: subscription_id,
      chain: chain,
      filter: filter,
      client_pid: inspect(client_pid)
    )

    {:reply, {:ok, subscription_id},
     %{
       state
       | subscriptions: updated_subscriptions,
         subscription_counter: state.subscription_counter + 1,
         active_filters: updated_filters,
         chain_subscriptions: updated_chain_subscriptions
     }}
  end

  @impl true
  def handle_call({:subscribe_new_heads, chain}, {client_pid, _}, state) do
    subscription_id = "newHeads_#{chain}_#{state.subscription_counter}"

    # Create subscription record with block tracking
    subscription = %SubscriptionState{
      id: subscription_id,
      client_pid: client_pid,
      type: :newHeads,
      chain: chain,
      # newHeads doesn't use filters
      filter: nil,
      created_at: DateTime.utc_now(),
      status: :active,
      # Will be set after first event delivered
      last_delivered_block: nil,
      last_delivered_block_hash: nil
    }

    # Store subscription
    updated_subscriptions = Map.put(state.subscriptions, subscription_id, subscription)

    # Add to chain subscriptions index
    updated_chain_subscriptions =
      Map.update(
        state.chain_subscriptions,
        chain,
        [subscription_id],
        &[subscription_id | &1]
      )

    # Ensure chain is running and subscribe to new heads
    ensure_chain_subscription(chain, :new_heads)

    # Trigger upstream subscription to provider and record chosen provider
    updated_subscriptions =
      case trigger_upstream_subscription(chain, :newHeads, nil) do
        {:ok, provider_id} ->
          case Map.get(updated_subscriptions, subscription_id) do
            %SubscriptionState{} = sub ->
              Map.put(updated_subscriptions, subscription_id, %{sub | provider_ids: [provider_id]})

            _ ->
              updated_subscriptions
          end

        _ ->
          updated_subscriptions
      end

    Logger.info("Created new heads subscription",
      subscription_id: subscription_id,
      chain: chain,
      client_pid: inspect(client_pid)
    )

    {:reply, {:ok, subscription_id},
     %{
       state
       | subscriptions: updated_subscriptions,
         subscription_counter: state.subscription_counter + 1,
         chain_subscriptions: updated_chain_subscriptions
     }}
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:reply, {:error, "Subscription not found"}, state}

      %SubscriptionState{chain: chain, type: type, filter: filter, provider_ids: provider_ids} =
          _subscription ->
        # Remove subscription
        updated_subscriptions = Map.delete(state.subscriptions, subscription_id)

        # Remove from chain subscriptions index
        updated_chain_subscriptions =
          Map.update(
            state.chain_subscriptions,
            chain,
            [],
            &List.delete(&1, subscription_id)
          )

        # Update active filters if needed
        updated_filters =
          case type do
            :logs ->
              chain_filters = Map.get(state.active_filters, chain, [])
              filtered_filters = Enum.reject(chain_filters, &(&1 == filter))
              Map.put(state.active_filters, chain, filtered_filters)

            _ ->
              state.active_filters
          end

        # Best-effort upstream unsubscribe to avoid leaks
        try do
          Enum.each(provider_ids || [], fn provider_id ->
            case Livechain.RPC.ProcessRegistry.lookup(
                   Livechain.RPC.ProcessRegistry,
                   :ws_connection,
                   provider_id
                 ) do
              {:ok, pid} ->
                unsub_msg = %{
                  "jsonrpc" => "2.0",
                  "id" => generate_request_id(),
                  "method" => "eth_unsubscribe",
                  "params" => [subscription_id]
                }

                GenServer.cast(pid, {:send_message, unsub_msg})

              _ ->
                :ok
            end
          end)
        rescue
          _ -> :ok
        end

        Logger.info("Unsubscribed", subscription_id: subscription_id, chain: chain)

        {:reply, {:ok, true},
         %{
           state
           | subscriptions: updated_subscriptions,
             active_filters: updated_filters,
             chain_subscriptions: updated_chain_subscriptions
         }}
    end
  end

  @impl true
  def handle_call(:get_subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl true
  def handle_call({:get_chain_subscriptions, chain}, _from, state) do
    subscription_ids = Map.get(state.chain_subscriptions, chain, [])

    subscriptions =
      subscription_ids
      |> Enum.map(&Map.get(state.subscriptions, &1))
      |> Enum.reject(&is_nil/1)

    {:reply, subscriptions, state}
  end

  @doc """
  Handle provider failover - migrate all subscriptions from failed provider to healthy ones.
  This is the core function for bulletproof subscription continuity.

  This function ensures that active subscriptions survive provider failures by:
  1. Identifying all subscriptions using the failed provider
  2. Marking them as migrating to prevent race conditions
  3. Performing backfill of missed events if enabled
  4. Updating subscriptions to use healthy providers
  5. Sending new upstream subscription requests

  The failover process is designed to be atomic and recoverable.
  """
  @impl true
  def handle_cast(
        {:handle_provider_failover, chain, failed_provider_id, healthy_provider_ids},
        state
      ) do
    # Validate input parameters
    cond do
      not is_list(healthy_provider_ids) or healthy_provider_ids == [] ->
        Logger.error("Provider failover failed: no healthy providers available",
          chain: chain,
          failed_provider: failed_provider_id
        )

        {:noreply, state}

      true ->
        # Get all subscriptions for this chain
        chain_subscription_ids = Map.get(state.chain_subscriptions, chain, [])

        Logger.warning("Handling provider failover for chain #{chain}",
          failed_provider: failed_provider_id,
          healthy_providers: healthy_provider_ids,
          affected_subscriptions: length(chain_subscription_ids)
        )

        do_provider_failover(
          chain,
          failed_provider_id,
          healthy_provider_ids,
          chain_subscription_ids,
          state
        )
    end
  end

  # Handle subscription block updates for continuity tracking
  @impl true
  def handle_cast({:update_subscription_block, subscription_id, block_number, block_hash}, state) do
    case Map.get(state.subscriptions, subscription_id) do
      %SubscriptionState{} = subscription ->
        updated_subscription = %{
          subscription
          | last_delivered_block: block_number,
            last_delivered_block_hash: block_hash
        }

        updated_subscriptions =
          Map.put(state.subscriptions, subscription_id, updated_subscription)

        {:noreply, %{state | subscriptions: updated_subscriptions}}

      nil ->
        Logger.warning("Attempted to update non-existent subscription",
          subscription_id: subscription_id
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:handle_event, chain, event_type, event_data}, state) do
    # Find subscriptions that match this event
    matching_subscriptions = find_matching_subscriptions(chain, event_type, event_data, state)

    # Route event to matching subscribers and track delivered blocks
    Enum.each(matching_subscriptions, fn subscription ->
      route_event_to_subscriber(subscription, event_data)

      # Update last delivered block if this event has block info
      case extract_block_info(event_data) do
        {block_number, block_hash} ->
          GenServer.cast(__MODULE__, {
            :update_subscription_block,
            subscription.id,
            block_number,
            block_hash
          })

        nil ->
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_reorg, chain, rollback_to_block}, state) do
    # Identify subscriptions on this chain
    sub_ids = Map.get(state.chain_subscriptions, chain, [])
    # Reset markers to rollback_to_block for all affected subscriptions
    updated_subscriptions =
      Enum.reduce(sub_ids, state.subscriptions, fn sub_id, acc ->
        case Map.get(acc, sub_id) do
          %SubscriptionState{} = sub ->
            Map.put(acc, sub_id, %{
              sub
              | last_delivered_block: rollback_to_block,
                last_delivered_block_hash: nil
            })

          _ ->
            acc
        end
      end)

    # Attempt backfill from rollback_to_block to current head
    case perform_subscription_backfill(
           %{state | subscriptions: updated_subscriptions},
           chain,
           sub_ids,
           get_active_providers_safe(chain)
         ) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _} ->
        {:noreply, %{state | subscriptions: updated_subscriptions}}
    end
  end

  # Private functions for backfill implementation

  defp perform_subscription_backfill(state, chain, subscription_ids, healthy_provider_ids) do
    case Livechain.Config.ConfigStore.get_chain(chain) do
      {:ok, chain_config} ->
        if chain_config.failover.enabled do
          run_with_timeout(chain_config.failover.backfill_timeout, fn ->
            do_backfill_for_subscriptions(
              state,
              chain,
              subscription_ids,
              healthy_provider_ids,
              chain_config
            )
          end)
        else
          # Backfill disabled, just mark subscriptions as active
          activate_subscriptions_after_failover(state, subscription_ids, healthy_provider_ids)
        end

      {:error, :not_found} ->
        Logger.warning("Chain config not found for #{chain}, skipping backfill")
        activate_subscriptions_after_failover(state, subscription_ids, healthy_provider_ids)

      {:error, reason} ->
        Logger.error("Failed to load config for backfill: #{inspect(reason)}")
        {:error, :config_load_failed}
    end
  end

  defp do_backfill_for_subscriptions(
         state,
         chain,
         subscription_ids,
         healthy_provider_ids,
         chain_config
       ) do
    # Find the earliest block we need to backfill from
    earliest_missing_block =
      subscription_ids
      |> Enum.map(&Map.get(state.subscriptions, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.last_delivered_block)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] ->
          Logger.info("No subscriptions have delivered blocks yet, skipping backfill")
          nil

        blocks ->
          # Start from the earliest last_delivered_block + 1
          Enum.min(blocks) + 1
      end

    if earliest_missing_block do
      # Get current block number
      case rpc_call(chain, "eth_blockNumber", []) do
        {:ok, current_block_hex} ->
          current_block = hex_to_integer(current_block_hex)
          blocks_to_backfill = current_block - earliest_missing_block + 1

          if blocks_to_backfill <= chain_config.failover.max_backfill_blocks do
            Logger.info(
              "Starting backfill for chain #{chain}: blocks #{earliest_missing_block}..#{current_block}"
            )

            with {:ok, _} <-
                   backfill_events_for_subscriptions(
                     state,
                     chain,
                     subscription_ids,
                     earliest_missing_block,
                     current_block,
                     healthy_provider_ids
                   ),
                 {:ok, _} <-
                   backfill_new_heads(
                     state,
                     chain,
                     subscription_ids,
                     earliest_missing_block,
                     current_block
                   ),
                 {:ok, new_state} <-
                   activate_subscriptions_after_failover(
                     state,
                     subscription_ids,
                     healthy_provider_ids
                   ) do
              {:ok, new_state}
            else
              {:error, reason} -> {:error, reason}
            end
          else
            Logger.error(
              "Too many blocks to backfill for chain #{chain}: #{blocks_to_backfill} > #{chain_config.failover.max_backfill_blocks}"
            )

            {:error, :too_many_blocks_to_backfill}
          end

        {:error, reason} ->
          Logger.error("Failed to get current block number for backfill: #{reason}")
          {:error, :current_block_fetch_failed}
      end
    else
      # No backfill needed, just activate subscriptions
      activate_subscriptions_after_failover(state, subscription_ids, healthy_provider_ids)
    end
  end

  defp backfill_events_for_subscriptions(
         state,
         chain,
         subscription_ids,
         from_block,
         to_block,
         _healthy_provider_ids
       ) do
    # Get all unique log filters from subscriptions that need backfill
    log_filters =
      subscription_ids
      |> Enum.map(&Map.get(state.subscriptions, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.type == :logs))
      |> Enum.map(& &1.filter)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Backfill logs for each filter
    backfill_results =
      Enum.map(log_filters, fn filter ->
        enhanced_filter =
          Map.merge(filter, %{
            "fromBlock" => "0x" <> Integer.to_string(from_block, 16),
            "toBlock" => "0x" <> Integer.to_string(to_block, 16)
          })

        case rpc_call(chain, "eth_getLogs", [enhanced_filter]) do
          {:ok, logs} ->
            # Deliver backfilled logs to matching subscriptions
            deliver_backfilled_logs(state, subscription_ids, logs)
            {:ok, length(logs)}

          {:error, reason} ->
            Logger.error("Failed to backfill logs for filter #{inspect(filter)}: #{reason}")
            {:error, reason}
        end
      end)

    # Check if all backfills succeeded
    case Enum.find(backfill_results, &match?({:error, _}, &1)) do
      nil ->
        total_logs = backfill_results |> Enum.map(fn {:ok, count} -> count end) |> Enum.sum()
        Logger.info("Backfilled #{total_logs} logs for chain #{chain}")
        {:ok, :logs_backfilled}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_backfilled_logs(state, subscription_ids, logs) do
    # Group logs by block number and deliver in order
    logs
    |> Enum.group_by(&Map.get(&1, "blockNumber"))
    |> Enum.sort_by(fn {block_hex, _} -> hex_to_integer(block_hex) end)
    |> Enum.each(fn {block_hex, block_logs} ->
      block_number = hex_to_integer(block_hex)
      block_hash = block_logs |> List.first() |> Map.get("blockHash")

      # Deliver each log to matching subscriptions
      Enum.each(block_logs, fn log ->
        matching_subscriptions = find_subscriptions_for_log(state, subscription_ids, log)

        Enum.each(matching_subscriptions, fn subscription ->
          route_event_to_subscriber(subscription, log)
          # Update the subscription's last delivered block
          update_subscription_block(subscription.id, block_number, block_hash)
        end)
      end)
    end)
  end

  defp find_subscriptions_for_log(state, subscription_ids, log) do
    subscription_ids
    |> Enum.map(&Map.get(state.subscriptions, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn subscription ->
      subscription.type == :logs && matches_log_filter(subscription.filter, log)
    end)
  end

  defp activate_subscriptions_after_failover(state, subscription_ids, healthy_provider_ids) do
    updated_subscriptions =
      Enum.reduce(subscription_ids, state.subscriptions, fn sub_id, acc ->
        case Map.get(acc, sub_id) do
          %SubscriptionState{} = sub ->
            updated_sub = %{
              sub
              | status: :active,
                provider_ids: healthy_provider_ids,
                backfill_in_progress: false
            }

            Map.put(acc, sub_id, updated_sub)

          nil ->
            acc
        end
      end)

    {:ok, %{state | subscriptions: updated_subscriptions}}
  end

  defp hex_to_integer("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex_to_integer(hex) when is_binary(hex), do: String.to_integer(hex, 16)
  defp hex_to_integer(int) when is_integer(int), do: int

  defp extract_block_info(event_data) when is_map(event_data) do
    # Support logs and newHeads shapes, and wrapped payloads
    cond do
      is_binary(Map.get(event_data, "blockNumber")) and
          is_binary(Map.get(event_data, "blockHash")) ->
        number_hex = Map.get(event_data, "blockNumber")
        hash = Map.get(event_data, "blockHash")

        try do
          {hex_to_integer(number_hex), hash}
        rescue
          _ -> nil
        end

      is_binary(Map.get(event_data, "number")) and is_binary(Map.get(event_data, "hash")) ->
        number_hex = Map.get(event_data, "number")
        hash = Map.get(event_data, "hash")

        try do
          {hex_to_integer(number_hex), hash}
        rescue
          _ -> nil
        end

      is_map(Map.get(event_data, "params")) and is_map(get_in(event_data, ["params", "result"])) ->
        extract_block_info(get_in(event_data, ["params", "result"]))

      is_map(Map.get(event_data, "result")) ->
        extract_block_info(Map.get(event_data, "result"))

      true ->
        nil
    end
  end

  defp extract_block_info(_), do: nil

  @impl true
  def handle_info({:fastest_message, _provider_id, message}, state) do
    # Handle aggregated events from MessageAggregator
    chain_name = extract_chain_from_message(message)
    event_type = detect_subscription_event_type(message)

    if chain_name && event_type do
      GenServer.cast(self(), {:handle_event, chain_name, event_type, message})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:blockchain_event, chain, event_type, event_data}, state) do
    # Handle events from legacy PubSub (backward compatibility)
    GenServer.cast(self(), {:handle_event, chain, event_type, event_data})
    {:noreply, state}
  end

  @impl true
  def handle_info({:provider_unhealthy, chain, provider_id}, state) do
    # Handle provider becoming unhealthy
    Logger.info("Provider became unhealthy, triggering failover",
      chain: chain,
      provider_id: provider_id
    )

    # Get healthy providers for failover
    case get_active_providers_safe(chain) do
      [_ | _] = healthy_providers ->
        # Use cast instead of call to avoid deadlock
        GenServer.cast(self(), {:handle_provider_failover, chain, provider_id, healthy_providers})

      _ ->
        Logger.error("Failed to get healthy providers for failover",
          chain: chain,
          provider_id: provider_id
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:stall_check, state) do
    chains = Map.keys(state.chain_subscriptions)

    new_state =
      Enum.reduce(chains, state, fn chain, acc_state ->
        sub_ids = Map.get(acc_state.chain_subscriptions, chain, [])

        new_heads_subs =
          sub_ids
          |> Enum.map(&Map.get(acc_state.subscriptions, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(&(&1.type == :newHeads))

        case new_heads_subs do
          [] ->
            acc_state

          subs ->
            last_block =
              subs
              |> Enum.map(& &1.last_delivered_block)
              |> Enum.reject(&is_nil/1)
              |> case do
                [] -> nil
                blocks -> Enum.max(blocks)
              end

            case last_block do
              nil ->
                acc_state

              last_seen when is_integer(last_seen) ->
                case rpc_call(chain, "eth_blockNumber", []) do
                  {:ok, head_hex} ->
                    head = hex_to_integer(head_hex)

                    if head > last_seen + 1 do
                      case perform_subscription_backfill(
                             acc_state,
                             chain,
                             sub_ids,
                             get_active_providers_safe(chain)
                           ) do
                        {:ok, ns} -> ns
                        {:error, _} -> acc_state
                      end
                    else
                      acc_state
                    end

                  _ ->
                    acc_state
                end
            end
        end
      end)

    Process.send_after(self(), :stall_check, @stall_check_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:provider_disconnected, chain, provider_id}, state) do
    # Handle provider disconnection - same as unhealthy
    send(self(), {:provider_unhealthy, chain, provider_id})
    {:noreply, state}
  end

  @impl true
  def handle_info(%{event: :healthy, provider_id: _provider_id, chain: _chain} = _event, state) do
    # Handle provider becoming healthy - just log for now
    # No special action needed as healthy providers will be used automatically
    {:noreply, state}
  end

  @impl true
  def handle_info(%{event: :unhealthy, provider_id: provider_id, chain: chain} = _event, state) do
    # Handle provider becoming unhealthy via provider pool events
    send(self(), {:provider_unhealthy, chain, provider_id})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{event: :cooldown_start, provider_id: provider_id, chain: chain} = _event,
        state
      ) do
    # Handle provider entering cooldown - treat similar to unhealthy
    send(self(), {:provider_unhealthy, chain, provider_id})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{event: _event, provider_id: _provider_id, chain: _chain} = _provider_event,
        state
      ) do
    # Catch-all for other provider pool events - just ignore them
    {:noreply, state}
  end

  # Extracted failover logic for better readability
  defp do_provider_failover(
         chain,
         failed_provider_id,
         healthy_provider_ids,
         chain_subscription_ids,
         state
       ) do
    # Mark all chain subscriptions as migrating and remove failed provider
    updated_state = %{
      state
      | subscriptions:
          Enum.reduce(chain_subscription_ids, state.subscriptions, fn sub_id, acc ->
            case Map.get(acc, sub_id) do
              %SubscriptionState{status: :active} = sub ->
                updated_sub = %{
                  sub
                  | status: :migrating,
                    provider_ids: List.delete(sub.provider_ids, failed_provider_id)
                }

                Map.put(acc, sub_id, updated_sub)

              %SubscriptionState{status: status} = sub
              when status in [:migrating, :backfilling] ->
                # Already in transition, just remove failed provider
                updated_sub = %{
                  sub
                  | provider_ids: List.delete(sub.provider_ids, failed_provider_id)
                }

                Map.put(acc, sub_id, updated_sub)

              _ ->
                acc
            end
          end)
    }

    # Start backfill process for affected subscriptions
    final_state =
      case perform_subscription_backfill(
             updated_state,
             chain,
             chain_subscription_ids,
             healthy_provider_ids
           ) do
        {:ok, new_state} ->
          Logger.info("Provider failover and backfill completed for chain #{chain}")
          new_state

        {:error, reason} ->
          Logger.error("Backfill failed during failover for chain #{chain}: #{reason}")
          # Mark subscriptions as failed if backfill fails
          failed_subscriptions =
            Enum.reduce(chain_subscription_ids, updated_state.subscriptions, fn sub_id, acc ->
              case Map.get(acc, sub_id) do
                %SubscriptionState{} = sub ->
                  Map.put(acc, sub_id, %{sub | status: :failed})

                nil ->
                  acc
              end
            end)

          %{updated_state | subscriptions: failed_subscriptions}
      end

    {:noreply, final_state}
  end

  defp ensure_chain_subscription(chain, filter) do
    # Try to start the chain supervisor idempotently. If already started, proceed.
    case ChainRegistry.start_chain(chain) do
      {:ok, _} -> subscribe_to_chain_events(chain, filter)
      {:error, {:already_started, _}} -> subscribe_to_chain_events(chain, filter)
      {:error, _reason} -> subscribe_to_chain_events(chain, filter)
    end
  end

  defp subscribe_to_chain_events(chain, _filter) do
    # Subscribe to aggregated events from MessageAggregator for this chain
    case safe_pubsub_subscribe("aggregated:#{chain}") do
      :ok ->
        Logger.debug("Subscribed to aggregated events for chain #{chain}")

      {:error, reason} ->
        Logger.warning(
          "Failed to subscribe to aggregated events for chain #{chain}: #{inspect(reason)}"
        )
    end
  end

  defp find_matching_subscriptions(chain, event_type, event_data, state) do
    Enum.filter(state.subscriptions, fn {_id, subscription} ->
      case subscription do
        %SubscriptionState{chain: ^chain, status: :active} ->
          matches_subscription_filter(subscription, event_type, event_data)

        _ ->
          false
      end
    end)
    |> Enum.map(fn {_id, subscription} -> subscription end)
  end

  defp matches_subscription_filter(subscription, event_type, event_data) do
    case subscription.type do
      :newHeads ->
        event_type == :new_heads || event_type == :newHeads

      :logs ->
        event_type == :logs && matches_log_filter(subscription.filter, event_data)

      _ ->
        false
    end
  end

  defp matches_log_filter(filter, log_data) do
    # Check if log matches the filter criteria
    address_match =
      case filter["address"] do
        nil ->
          true

        address when is_list(address) ->
          log_data["address"] in address

        address ->
          log_data["address"] == address
      end

    topics_match =
      case filter["topics"] do
        nil ->
          true

        topics when is_list(topics) ->
          # Simple topic matching - can be enhanced
          true

        _ ->
          true
      end

    address_match && topics_match
  end

  defp route_event_to_subscriber(subscription, event_data) do
    # Create subscription notification
    notification = %{
      jsonrpc: "2.0",
      method: "eth_subscription",
      params: %{
        subscription: subscription.id,
        result: event_data
      }
    }

    # Broadcast to subscribers via PubSub
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "subscription:#{subscription.id}",
      {:subscription_event, notification}
    )

    Logger.debug("Routed event to subscriber",
      subscription_id: subscription.id,
      event_type: "subscription"
    )

    # Reorg detection for headers/logs with block info
    case extract_block_info(event_data) do
      {block_number, block_hash} when is_integer(block_number) and is_binary(block_hash) ->
        # If we delivered block N before with a different hash, roll back to N-1 and backfill
        case :ets.lookup(:subscriptions, subscription.id) do
          [
            {_,
             %SubscriptionState{
               last_delivered_block: ^block_number,
               last_delivered_block_hash: prev_hash
             } = sub}
          ]
          when is_binary(prev_hash) and prev_hash != block_hash ->
            GenServer.cast(__MODULE__, {:handle_reorg, sub.chain, block_number - 1})

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp backfill_new_heads(state, chain, subscription_ids, from_block, to_block) do
    new_heads_subs =
      subscription_ids
      |> Enum.map(&Map.get(state.subscriptions, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.type == :newHeads))

    case new_heads_subs do
      [] ->
        {:ok, 0}

      subs ->
        results =
          from_block..to_block
          |> Enum.map(fn block_num ->
            hex = "0x" <> Integer.to_string(block_num, 16)

            case rpc_call(chain, "eth_getBlockByNumber", [hex, false]) do
              {:ok, %{"number" => _} = header} ->
                Enum.each(subs, fn subscription ->
                  route_event_to_subscriber(subscription, header)
                  update_subscription_block(subscription.id, block_num, Map.get(header, "hash"))
                end)

                {:ok, 1}

              {:ok, nil} ->
                {:ok, 0}

              {:error, reason} ->
                Logger.error("Failed to backfill newHeads for block #{hex}: #{inspect(reason)}")
                {:error, reason}
            end
          end)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil ->
            count = results |> Enum.map(fn {:ok, c} -> c end) |> Enum.sum()
            Logger.info("Backfilled #{count} headers for chain #{chain}")
            {:ok, count}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp extract_chain_from_message(message) when is_map(message) do
    # Extract chain from the Livechain metadata
    case Map.get(message, "_livechain_meta") do
      %{"chain_name" => chain_name} -> chain_name
      _ -> nil
    end
  end

  defp extract_chain_from_message(_), do: nil

  defp detect_subscription_event_type(message) when is_map(message) do
    case message do
      # newHeads subscription event
      %{"method" => "eth_subscription", "params" => %{"result" => %{"number" => _}}} ->
        :newHeads

      # logs subscription event
      %{"method" => "eth_subscription", "params" => %{"result" => %{"transactionHash" => _}}} ->
        :logs

      # Direct block result (not subscription)
      %{"result" => %{"number" => _}} ->
        :newHeads

      _ ->
        :other
    end
  end

  defp detect_subscription_event_type(_), do: :other

  defp trigger_upstream_subscription(chain, subscription_type, filter) do
    # Get best provider for this chain to send the subscription request
    case get_active_providers_safe(chain) do
      [provider_id | _] ->
        subscription_params =
          case subscription_type do
            :newHeads -> ["newHeads"]
            :logs -> ["logs", filter || %{}]
          end

        subscription_message = %{
          "jsonrpc" => "2.0",
          "id" => generate_request_id(),
          "method" => "eth_subscribe",
          "params" => subscription_params
        }

        # Send subscription request to the provider via WSConnection
        case Livechain.RPC.ProcessRegistry.lookup(
               Livechain.RPC.ProcessRegistry,
               :ws_connection,
               provider_id
             ) do
          {:ok, pid} ->
            GenServer.cast(pid, {:send_message, subscription_message})

            Logger.debug("Sent upstream subscription request to #{provider_id}",
              chain: chain,
              type: subscription_type
            )

          {:error, reason} ->
            Logger.warning("Provider connection not found for upstream subscription",
              chain: chain,
              provider_id: provider_id,
              reason: reason
            )
        end

        {:ok, provider_id}

      [] ->
        Logger.error("No providers available for upstream subscription", chain: chain)
        {:error, :no_provider}

      _ ->
        Logger.error("Failed to get providers for upstream subscription", chain: chain)
        {:error, :provider_selection_failed}
    end
  end

  defp generate_request_id do
    :rand.uniform(1_000_000) |> to_string()
  end

  # Helper function for safe PubSub subscription with retry logic
  defp safe_pubsub_subscribe(topic) do
    try do
      case Phoenix.PubSub.subscribe(Livechain.PubSub, topic) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      error ->
        Logger.debug("PubSub subscribe failed: #{inspect(error)}")
        {:error, error}
    catch
      :exit, reason ->
        Logger.debug("PubSub subscribe exit: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Internal helpers for provider selection and RPC forwarding
  defp get_active_providers_safe(chain) do
    try do
      ChainSupervisor.get_active_providers(chain) || []
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp rpc_call(chain, method, params) do
    case get_active_providers_safe(chain) do
      [provider_id | _] ->
        ChainSupervisor.forward_rpc_request(chain, provider_id, method, params)

      [] ->
        {:error, :no_providers_available}
    end
  end

  defp run_with_timeout(timeout_ms, fun) when is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fun)

    try do
      Task.await(task, timeout_ms)
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
