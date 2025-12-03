defmodule Lasso.Testing.MockWSProvider do
  @moduledoc """
  Mock WebSocket provider for testing subscription functionality.

  Creates a GenServer that simulates a WebSocket connection and responds to
  eth_subscribe/eth_unsubscribe requests. Integrates with the provider
  infrastructure via Registry.

  ## Features

  - ✅ Responds to eth_subscribe with subscription confirmations
  - ✅ Sends mock subscription events (newHeads, logs)
  - ✅ Handles eth_unsubscribe
  - ✅ Integrates with ProviderPool and UpstreamSubscriptionPool
  - ✅ Automatic cleanup on test exit

  ## Usage

      test "websocket subscriptions" do
        # Start mock WS provider
        {:ok, "mock_ws"} = MockWSProvider.start_mock("test_chain", %{
          id: "mock_ws",
          auto_confirm: true  # Auto-confirm subscriptions
        })

        # Subscribe via UpstreamSubscriptionPool
        {:ok, sub_id} = UpstreamSubscriptionPool.subscribe_client(
          "test_chain", self(), {:newHeads}
        )

        # Send a mock block
        MockWSProvider.send_block("test_chain", "mock_ws", %{
          "number" => "0x100",
          "hash" => "0xabc..."
        })

        # Client receives the event
        assert_receive {:subscription_event, ^sub_id, block}
      end
  """

  use GenServer
  require Logger

  @doc """
  Starts a mock WebSocket provider and registers it with the chain.

  Options:
  - `:id` (required) - Provider identifier
  - `:auto_confirm` - Automatically confirm subscriptions (default: true)
  - `:confirm_delay` - Delay before confirming subscriptions in ms (default: 0)
  - `:priority` - Provider priority (default: 100)
  """
  def start_mock(chain, spec) when is_map(spec) do
    provider_id = Map.get(spec, :id) || raise "Mock WS provider requires :id field"

    # Start the mock WS connection GenServer with the WSConnection-compatible name
    {:ok, pid} =
      GenServer.start_link(
        __MODULE__,
        {chain, spec},
        name: {:via, Registry, {Lasso.Registry, {:ws_conn, provider_id}}}
      )

    # Create provider config
    provider_config = %{
      id: provider_id,
      name: "Mock WS Provider #{provider_id}",
      url: "http://mock-#{provider_id}.test",
      # Mock HTTP endpoint
      ws_url: "ws://mock-#{provider_id}.test",
      type: "test",
      priority: Map.get(spec, :priority, 100)
    }

    # Ensure chain exists (auto-create if needed) and register provider
    with :ok <- ensure_chain_exists(chain),
         :ok <- Lasso.Config.ConfigStore.register_provider_runtime(chain, provider_config),
         :ok <- Lasso.RPC.ProviderPool.register_provider(chain, provider_id, provider_config) do
      # Mark as healthy so it can be selected
      Lasso.RPC.ProviderPool.report_success(chain, provider_id)

      # Generate connection_id and broadcast ws_connected event
      # This is required by UpstreamSubscriptionManager to allow subscriptions
      connection_id = "conn_mock_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:conn:#{chain}",
        {:ws_connected, provider_id, connection_id}
      )

      # Set up cleanup monitor
      setup_cleanup_monitor(chain, provider_id, pid)

      Logger.debug("Started mock WS provider #{provider_id} for #{chain}")
      {:ok, provider_id}
    else
      {:error, reason} ->
        GenServer.stop(pid)
        {:error, {:registration_failed, reason}}
    end
  end

  @doc """
  Sends a subscription request to the mock provider.
  Used internally by WSConnection.
  """
  def send_message(provider_id, message) do
    case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:send_message, message})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Sends a mock newHeads block to all subscribers.
  """
  def send_block(chain, provider_id, block_header) when is_map(block_header) do
    case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:broadcast_block, chain, block_header})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Sends a sequence of blocks to all subscribers.

  Useful for testing ordered delivery and backfill scenarios.
  """
  def send_block_sequence(chain, provider_id, start_block, count, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 10)

    Enum.each(start_block..(start_block + count - 1), fn block_num ->
      send_block(chain, provider_id, %{
        "number" => "0x" <> String.downcase(Integer.to_string(block_num, 16)),
        "hash" => "0x" <> String.downcase(Integer.to_string(block_num * 1000, 16)),
        "timestamp" => "0x" <> String.downcase(Integer.to_string(:os.system_time(:second), 16))
      })

      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end
    end)

    :ok
  end

  @doc """
  Simulates a disconnect by stopping the mock provider.
  """
  def simulate_disconnect(chain, provider_id) do
    stop_mock(chain, provider_id)
  end

  @doc """
  Simulates a provider failure by emitting WSDisconnected event.

  This triggers the failover mechanism in UpstreamSubscriptionPool
  and StreamCoordinator, matching what happens when a real WebSocket
  connection fails.

  Use this in tests instead of directly killing the GenServer, as it
  allows the production failover code to execute and be tested.

  ## Example

      # Send blocks from primary
      MockWSProvider.send_block_sequence(chain, "primary", 1000, 5)

      # Simulate primary failure - triggers failover
      MockWSProvider.simulate_provider_failure(chain, "primary")

      # Wait for failover completion
      assert_receive {:telemetry, [:lasso, :subs, :failover, :completed], _, _}

      # Send blocks from backup
      MockWSProvider.send_block_sequence(chain, "backup", 1005, 5)
  """
  def simulate_provider_failure(chain, provider_id, reason \\ :test_failure) do
    # Emit the same WSDisconnected event that real WS connections emit
    event = %Lasso.Events.Provider.WSDisconnected{
      ts: System.system_time(:millisecond),
      chain: chain,
      provider_id: provider_id,
      reason: reason
    }

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      Lasso.Events.Provider.topic(chain),
      event
    )

    Logger.debug(
      "Simulated provider failure: #{provider_id} on #{chain} (reason: #{inspect(reason)})"
    )

    :ok
  end

  @doc """
  Sends a mock log event to all log subscribers.
  """
  def send_log(chain, provider_id, log) when is_map(log) do
    case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:broadcast_log, chain, log})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops a mock WebSocket provider.
  """
  def stop_mock(chain, provider_id) do
    # Remove from ConfigStore
    Lasso.Config.ConfigStore.unregister_provider_runtime(chain, provider_id)

    # Stop the GenServer
    case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            _, _ -> :ok
          end
        else
          :ok
        end

      [] ->
        :ok
    end

    :ok
  end

  # Private helper to ensure chain exists (auto-create if needed)
  defp ensure_chain_exists(chain_name) do
    case Lasso.Config.ConfigStore.get_chain(chain_name) do
      {:ok, _chain_config} ->
        :ok

      {:error, :not_found} ->
        # Create chain with default config
        Logger.info("Chain '#{chain_name}' not found, creating for mock provider")

        default_config = %{
          chain_id: nil,
          name: chain_name,
          providers: [],
          connection: %{
            heartbeat_interval: 30_000,
            reconnect_interval: 5_000,
            max_reconnect_attempts: 5
          },
          failover: %{
            enabled: false,
            max_backfill_blocks: 100,
            backfill_timeout: 30_000
          }
        }

        with :ok <-
               Lasso.Config.ConfigStore.register_chain_runtime(chain_name, default_config),
             {:ok, chain_config} <- Lasso.Config.ConfigStore.get_chain(chain_name),
             {:ok, _pid} <-
               DynamicSupervisor.start_child(
                 Lasso.RPC.Supervisor,
                 {Lasso.RPC.ChainSupervisor, {chain_name, chain_config}}
               ) do
          Logger.info("Successfully started chain supervisor for '#{chain_name}'")
          :ok
        else
          {:error, reason} = error ->
            Logger.error("Failed to start chain '#{chain_name}': #{inspect(reason)}")
            error
        end
    end
  end

  # GenServer callbacks

  @impl true
  def init({chain, spec}) do
    state = %{
      chain: chain,
      provider_id: Map.get(spec, :id),
      subscriptions: %{},
      auto_confirm: Map.get(spec, :auto_confirm, true),
      confirm_delay: Map.get(spec, :confirm_delay, 0),
      next_sub_id: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, message}, _from, state) do
    # Support WSConnection.send_message/2 compatibility (synchronous)
    new_state = handle_rpc_request(message, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:request, method, params, _timeout_ms, provided_id}, _from, state) do
    # Support WSConnection.request/5 compatibility used by Transport.WebSocket.request/3
    request_id = provided_id || :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => params || []
    }

    # Handle eth_subscribe specially to return subscription ID synchronously
    case method do
      "eth_subscribe" ->
        # Generate subscription ID first
        sub_id = generate_sub_id(state)

        # Process the subscription and update state
        new_state = handle_rpc_request(message, state)

        # Broadcast confirmation immediately
        send_response(state.chain, state.provider_id, request_id, sub_id)

        # Return subscription ID
        {:reply, {:ok, sub_id}, new_state}

      _ ->
        # For other methods, process normally
        new_state = handle_rpc_request(message, state)
        # Mock response - in real implementation this would wait for upstream
        {:reply, {:ok, %{"mock" => true}}, new_state}
    end
  end

  @impl true
  def handle_call({:subscribe, _topic}, _from, state) do
    # Minimal compatibility: acknowledge subscription API
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    # Health/status endpoint used by Transport.WebSocket.healthy?/1
    status = %{
      connected: true,
      endpoint_id: state.provider_id,
      reconnect_attempts: 0
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    # Handle incoming JSON-RPC requests
    new_state = handle_rpc_request(message, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:broadcast_block, chain, block_header}, state) do
    # Send block to all newHeads subscribers
    state.subscriptions
    |> Enum.filter(fn {_sub_id, sub} -> sub.type == :newHeads end)
    |> Enum.each(fn {sub_id, _sub} ->
      send_subscription_event(chain, state.provider_id, sub_id, block_header)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:broadcast_log, chain, log}, state) do
    # Send log to all logs subscribers (with filter matching)
    state.subscriptions
    |> Enum.filter(fn {_sub_id, sub} -> sub.type == :logs end)
    |> Enum.each(fn {sub_id, _sub} ->
      send_subscription_event(chain, state.provider_id, sub_id, log)
    end)

    {:noreply, state}
  end

  # Private functions

  defp handle_rpc_request(
         %{"method" => "eth_subscribe", "params" => params, "id" => request_id},
         state
       ) do
    [subscription_type | rest] = params

    case subscription_type do
      "newHeads" ->
        handle_new_heads_subscribe(request_id, state)

      "logs" ->
        [filter | _] = rest
        handle_logs_subscribe(request_id, filter, state)

      _ ->
        send_error_response(state.chain, state.provider_id, request_id, %{
          "code" => -32_601,
          "message" => "Subscription type not supported"
        })

        state
    end
  end

  defp handle_rpc_request(
         %{"method" => "eth_unsubscribe", "params" => [sub_id], "id" => request_id},
         state
       ) do
    new_subscriptions = Map.delete(state.subscriptions, sub_id)

    # Send confirmation
    send_response(state.chain, state.provider_id, request_id, true)

    %{state | subscriptions: new_subscriptions}
  end

  defp handle_rpc_request(_message, state) do
    # Ignore unknown messages
    state
  end

  defp handle_new_heads_subscribe(request_id, state) do
    sub_id = generate_sub_id(state)

    subscription = %{
      type: :newHeads,
      filter: nil,
      request_id: request_id
    }

    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, sub_id, subscription),
        next_sub_id: state.next_sub_id + 1
    }

    # Auto-confirm if enabled
    if state.auto_confirm do
      if state.confirm_delay > 0 do
        Process.send_after(
          self(),
          {:confirm_subscription, request_id, sub_id},
          state.confirm_delay
        )
      else
        send_response(new_state.chain, new_state.provider_id, request_id, sub_id)
      end
    end

    new_state
  end

  defp handle_logs_subscribe(request_id, filter, state) do
    sub_id = generate_sub_id(state)

    subscription = %{
      type: :logs,
      filter: filter,
      request_id: request_id
    }

    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, sub_id, subscription),
        next_sub_id: state.next_sub_id + 1
    }

    # Auto-confirm if enabled
    if state.auto_confirm do
      if state.confirm_delay > 0 do
        Process.send_after(
          self(),
          {:confirm_subscription, request_id, sub_id},
          state.confirm_delay
        )
      else
        send_response(new_state.chain, new_state.provider_id, request_id, sub_id)
      end
    end

    new_state
  end

  @impl true
  def handle_info({:confirm_subscription, request_id, sub_id}, state) do
    send_response(state.chain, state.provider_id, request_id, sub_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp send_response(chain, provider_id, request_id, result) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => result
    }

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "raw_messages:#{chain}",
      {:raw_message, provider_id, message, System.monotonic_time(:millisecond)}
    )
  end

  defp send_error_response(chain, provider_id, request_id, error) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => error
    }

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "raw_messages:#{chain}",
      {:raw_message, provider_id, message, System.monotonic_time(:millisecond)}
    )
  end

  defp send_subscription_event(chain, provider_id, subscription_id, payload) do
    received_at = System.monotonic_time(:millisecond)

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:subs:#{chain}",
      {:subscription_event, provider_id, subscription_id, payload, received_at}
    )
  end

  defp generate_sub_id(state) do
    "0x" <> Integer.to_string(state.next_sub_id, 16)
  end

  defp setup_cleanup_monitor(chain, provider_id, _ws_pid) do
    test_pid = self()

    spawn(fn ->
      ref = Process.monitor(test_pid)

      receive do
        {:DOWN, ^ref, :process, ^test_pid, _reason} ->
          Logger.debug("Test process exited, cleaning up mock WS provider #{provider_id}")
          stop_mock(chain, provider_id)
      end
    end)
  end
end
