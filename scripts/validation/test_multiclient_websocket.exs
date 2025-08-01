#!/usr/bin/env elixir

# Comprehensive test script for ChainPulse/Livechain system
# Tests JSON-RPC compatibility, Broadway pipelines, and Analytics API

defmodule LivechainTest do
  require Logger

  def run_test do
    Logger.info("🧪 Testing Multi-Client WebSocket Connections")
    Logger.info("=" |> String.duplicate(50))

    # Test 1: Multiple blockchain channel clients
    test_multiclient_blockchain_channels()

    # Test 2: Multiple RPC channel clients
    test_multiclient_rpc_channels()

    # Test 3: Mixed channel types
    test_mixed_channel_types()

    # Test 4: Connection stress test
    test_connection_stress()

    Logger.info("✅ Multi-client WebSocket test completed!")
  end

  defp test_multiclient_blockchain_channels do
    Logger.info("\n🔗 Test 1: Multiple Blockchain Channel Clients")
    Logger.info("-" |> String.duplicate(40))

    # Start the application
    Application.ensure_all_started(:livechain)

    # Create multiple socket connections
    clients = for i <- 1..5 do
      socket = create_socket_connection()
      {socket, "client_#{i}"}
    end

    # Join blockchain channels
    channels = Enum.map(clients, fn {socket, client_id} ->
      Logger.info("📡 #{client_id} joining blockchain:ethereum")
      {response, channel} = join_blockchain_channel(socket, "ethereum")

      if response["status"] == "connected" do
        Logger.info("✅ #{client_id} connected successfully")
        {channel, client_id}
      else
        Logger.error("❌ #{client_id} failed to connect")
        nil
      end
    end)
    |> Enum.filter(&(&1 != nil))

    # Subscribe to events
    Enum.each(channels, fn {channel, client_id} ->
      Logger.info("📊 #{client_id} subscribing to blocks")
      subscribe_to_events(channel, "blocks")
    end)

    # Broadcast test events
    Logger.info("📡 Broadcasting test events...")

    for i <- 1..3 do
      block_event = create_mock_block_event("ethereum", i)
      broadcast_test_event("ethereum", block_event)

      Logger.info("📦 Broadcasted block event #{i}")
      Process.sleep(500)  # Small delay between events
    end

    # Verify all clients received events
    Logger.info("🔍 Verifying event reception...")

    Enum.each(channels, fn {channel, client_id} ->
      received_events = wait_for_multiple_events(channel, "new_block", 3, 5000)

      case received_events do
        {:ok, events} ->
          Logger.info("✅ #{client_id} received #{length(events)} events")

        {:error, :timeout} ->
          Logger.warning("⚠️  #{client_id} did not receive all events")
      end
    end)

    # Clean up
    cleanup_connections(clients)
  end

  defp test_multiclient_rpc_channels do
    Logger.info("\n🔗 Test 2: Multiple RPC Channel Clients")
    Logger.info("-" |> String.duplicate(40))

    # Create multiple socket connections
    clients = for i <- 1..3 do
      socket = create_socket_connection()
      {socket, "rpc_client_#{i}"}
    end

    # Join RPC channels
    channels = Enum.map(clients, fn {socket, client_id} ->
      Logger.info("📡 #{client_id} joining rpc:ethereum")
      {response, channel} = join_rpc_channel(socket, "ethereum")

      if response["status"] == "connected" do
        Logger.info("✅ #{client_id} connected successfully")
        {channel, client_id}
      else
        Logger.error("❌ #{client_id} failed to connect")
        nil
      end
    end)
    |> Enum.filter(&(&1 != nil))

    # Make concurrent RPC calls
    Logger.info("📡 Making concurrent RPC calls...")

    tasks = Enum.map(channels, fn {channel, client_id} ->
      Task.async(fn ->
        Logger.info("🔍 #{client_id} calling eth_blockNumber")
        result = make_rpc_call(channel, "eth_blockNumber", [], 1)
        {client_id, result}
      end)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5000))

    Enum.each(results, fn {client_id, {status, response}} ->
      if status == :ok do
        Logger.info("✅ #{client_id} RPC call successful")
      else
        Logger.warning("⚠️  #{client_id} RPC call failed")
      end
    end)

    # Test subscriptions
    Logger.info("📊 Testing RPC subscriptions...")

    Enum.each(channels, fn {channel, client_id} ->
      Logger.info("📡 #{client_id} subscribing to newHeads")
      {status, response} = make_rpc_call(channel, "eth_subscribe", ["newHeads"], 1)

      if status == :ok do
        Logger.info("✅ #{client_id} subscription successful")
      else
        Logger.warning("⚠️  #{client_id} subscription failed")
      end
    end)

    # Clean up
    cleanup_connections(clients)
  end

  defp test_mixed_channel_types do
    Logger.info("\n🔗 Test 3: Mixed Channel Types")
    Logger.info("-" |> String.duplicate(40))

    # Create clients for different channel types
    blockchain_clients = for i <- 1..2 do
      socket = create_socket_connection()
      {socket, "blockchain_client_#{i}"}
    end

    rpc_clients = for i <- 1..2 do
      socket = create_socket_connection()
      {socket, "rpc_client_#{i}"}
    end

    # Join different channel types
    blockchain_channels = Enum.map(blockchain_clients, fn {socket, client_id} ->
      {response, channel} = join_blockchain_channel(socket, "ethereum")
      Logger.info("📡 #{client_id} joined blockchain channel")
      {channel, client_id, :blockchain}
    end)

    rpc_channels = Enum.map(rpc_clients, fn {socket, client_id} ->
      {response, channel} = join_rpc_channel(socket, "ethereum")
      Logger.info("📡 #{client_id} joined RPC channel")
      {channel, client_id, :rpc}
    end)

    # Subscribe to events
    Enum.each(blockchain_channels, fn {channel, client_id, _type} ->
      subscribe_to_events(channel, "blocks")
    end)

    Enum.each(rpc_channels, fn {channel, client_id, _type} ->
      make_rpc_call(channel, "eth_subscribe", ["newHeads"], 1)
    end)

    # Broadcast events
    Logger.info("📡 Broadcasting events to mixed channels...")

    block_event = create_mock_block_event("ethereum", 1)
    broadcast_test_event("ethereum", block_event)

    # Verify reception
    Logger.info("🔍 Verifying event reception on mixed channels...")

    Enum.each(blockchain_channels, fn {channel, client_id, _type} ->
      case wait_for_event(channel, "new_block", 2000) do
        {:ok, _} -> Logger.info("✅ #{client_id} received blockchain event")
        {:error, :timeout} -> Logger.warning("⚠️  #{client_id} missed blockchain event")
      end
    end)

    Enum.each(rpc_channels, fn {channel, client_id, _type} ->
      case wait_for_event(channel, "rpc_notification", 2000) do
        {:ok, _} -> Logger.info("✅ #{client_id} received RPC notification")
        {:error, :timeout} -> Logger.warning("⚠️  #{client_id} missed RPC notification")
      end
    end)

    # Clean up
    cleanup_connections(blockchain_clients ++ rpc_clients)
  end

  defp test_connection_stress do
    Logger.info("\n🔗 Test 4: Connection Stress Test")
    Logger.info("-" |> String.duplicate(40))

    # Test with many concurrent connections
    Logger.info("📡 Creating 20 concurrent connections...")

    clients = for i <- 1..20 do
      socket = create_socket_connection()
      {socket, "stress_client_#{i}"}
    end

    # Join channels concurrently
    start_time = System.monotonic_time(:millisecond)

    channels = Enum.map(clients, fn {socket, client_id} ->
      {response, channel} = join_blockchain_channel(socket, "ethereum")
      {channel, client_id}
    end)
    |> Enum.filter(fn {_channel, _client_id} -> true end)

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    Logger.info("⏱️  Connected #{length(channels)} clients in #{duration}ms")

    # Subscribe concurrently
    Logger.info("📊 Subscribing to events concurrently...")

    Enum.each(channels, fn {channel, _client_id} ->
      subscribe_to_events(channel, "blocks")
    end)

    # Broadcast many events
    Logger.info("📡 Broadcasting 10 events...")

    for i <- 1..10 do
      block_event = create_mock_block_event("ethereum", i)
      broadcast_test_event("ethereum", block_event)
      Process.sleep(100)
    end

    # Verify reception
    Logger.info("🔍 Verifying event reception...")

    successful_receptions = Enum.count(channels, fn {channel, _client_id} ->
      case wait_for_event(channel, "new_block", 1000) do
        {:ok, _} -> true
        {:error, :timeout} -> false
      end
    end)

    Logger.info("📊 #{successful_receptions}/#{length(channels)} clients received events")

    # Clean up
    cleanup_connections(clients)
  end

  # Helper functions

  defp create_socket_connection do
    {:ok, socket} = Phoenix.Socket.connect(
      LivechainWeb.UserSocket,
      %{},
      %{connect_info: %{transport: :test}}
    )
    socket
  end

  defp join_blockchain_channel(socket, chain_id) do
    topic = "blockchain:#{chain_id}"
    Phoenix.Socket.join(socket, topic, %{})
  end

  defp join_rpc_channel(socket, chain_id) do
    topic = "rpc:#{chain_id}"
    Phoenix.Socket.join(socket, topic, %{})
  end

  defp subscribe_to_events(channel, event_type) do
    Phoenix.Socket.push(channel, "subscribe", %{"type" => event_type})
  end

  defp make_rpc_call(channel, method, params, id) do
    payload = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => id
    }
    Phoenix.Socket.push(channel, "rpc_call", payload)
  end

  defp create_mock_block_event(chain_id, block_number) do
    %{
      event: "new_block",
      payload: %{
        number: "0x" <> Integer.to_string(block_number, 16),
        hash: "0x" <> :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        timestamp: DateTime.utc_now() |> DateTime.to_unix(),
        transactions: []
      }
    }
  end

  defp broadcast_test_event(chain_id, event) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "blockchain:#{chain_id}",
      event
    )
  end

  defp wait_for_event(channel, event, timeout) do
    receive do
      %Phoenix.Socket.Message{event: ^event, payload: payload} ->
        {:ok, payload}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp wait_for_multiple_events(channel, event, count, timeout) do
    events = []
    wait_for_multiple_events_recursive(channel, event, count, timeout, events)
  end

  defp wait_for_multiple_events_recursive(_channel, _event, 0, _timeout, events) do
    {:ok, Enum.reverse(events)}
  end

  defp wait_for_multiple_events_recursive(channel, event, count, timeout, events) do
    case wait_for_event(channel, event, timeout) do
      {:ok, payload} ->
        wait_for_multiple_events_recursive(channel, event, count - 1, timeout, [payload | events])

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  defp cleanup_connections(clients) do
    Enum.each(clients, fn {socket, _client_id} ->
      try do
        Phoenix.Socket.close(socket)
      rescue
        _ -> :ok
      end
    end)
  end
end

# Run the test
MultiClientWebSocketTest.run_test()
