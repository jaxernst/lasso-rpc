#!/usr/bin/env elixir

# Multi-Provider Base Streaming Demo
# 
# This script demonstrates the new multi-provider architecture with
# automatic failover, deduplication, and speed optimization.
#
# Run with: elixir examples/multi_provider_demo.exs

Mix.install([
  {:yaml_elixir, "~> 2.9"},
  {:jason, "~> 1.4"},
  {:websockex, "~> 0.4"}
])

defmodule MultiProviderDemo do
  @moduledoc """
  Demonstrates connecting to multiple Base RPC providers simultaneously
  with automatic deduplication and fastest-message-wins logic.
  """

  require Logger

  # Multiple Base providers for redundancy
  @providers [
    %{
      id: "base_publicnode",
      name: "PublicNode",
      ws_url: "wss://base-rpc.publicnode.com"
    },
    %{
      id: "base_ankr", 
      name: "Ankr",
      ws_url: "wss://rpc.ankr.com/base/ws"
    }
  ]

  def run do
    Logger.info("🚀 Starting Multi-Provider Base Demo")
    Logger.info("📡 Connecting to #{length(@providers)} providers simultaneously...")

    # Start connections to all providers
    connections = 
      @providers
      |> Enum.map(&start_provider_connection/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, {provider, pid}} -> {provider, pid} end)

    if length(connections) == 0 do
      Logger.error("❌ No providers connected successfully")
      return
    end

    Logger.info("✅ Connected to #{length(connections)} providers")
    
    # Subscribe to new heads on all providers
    Enum.each(connections, fn {provider, pid} ->
      subscribe_to_new_heads(pid, provider.id)
    end)

    # Start message deduplication process
    {:ok, dedup_pid} = start_deduplication_process()

    # Run demo for 60 seconds
    Logger.info("🔄 Streaming for 60 seconds with deduplication...")
    Logger.info("📊 Watch for duplicate block detection and speed comparison")
    
    Process.sleep(60_000)

    # Clean up
    Enum.each(connections, fn {_provider, pid} ->
      WebSockex.cast(pid, :close)
    end)
    GenServer.stop(dedup_pid)

    Logger.info("🛑 Demo completed!")
  end

  defp start_provider_connection(provider) do
    case WebSockex.start_link(provider.ws_url, __MODULE__, provider) do
      {:ok, pid} ->
        Logger.info("✅ Connected to #{provider.name}")
        {:ok, {provider, pid}}
        
      {:error, reason} ->
        Logger.error("❌ Failed to connect to #{provider.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp subscribe_to_new_heads(pid, provider_id) do
    subscription = %{
      "jsonrpc" => "2.0",
      "id" => "newheads_#{provider_id}",
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }
    
    WebSockex.send_frame(pid, {:text, Jason.encode!(subscription)})
    Logger.info("📡 Subscribed to new heads on #{provider_id}")
  end

  defp start_deduplication_process do
    GenServer.start_link(__MODULE__.Deduplicator, %{})
  end

  # WebSockex callbacks
  def handle_connect(_conn, provider) do
    Logger.info("🔗 WebSocket connected: #{provider.name}")
    {:ok, provider}
  end

  def handle_frame({:text, message}, provider) do
    case Jason.decode(message) do
      {:ok, %{"method" => "eth_subscription", "params" => params}} ->
        handle_block_message(provider, params)
        {:ok, provider}
        
      {:ok, %{"result" => result, "id" => id}} ->
        Logger.debug("📬 Subscription result from #{provider.name}: #{id}")
        {:ok, provider}
        
      {:ok, data} ->
        Logger.debug("📨 Other message from #{provider.name}: #{inspect(data)}")
        {:ok, provider}
        
      {:error, reason} ->
        Logger.error("❌ Failed to decode message from #{provider.name}: #{reason}")
        {:ok, provider}
    end
  end

  def handle_disconnect(%{reason: reason}, provider) do
    Logger.warning("🔌 #{provider.name} disconnected: #{inspect(reason)}")
    {:ok, provider}
  end

  defp handle_block_message(provider, %{"result" => block_data}) when is_map(block_data) do
    block_hash = Map.get(block_data, "hash")
    block_number = Map.get(block_data, "number")
    received_at = System.monotonic_time(:millisecond)
    
    if block_hash && block_number do
      # Send to deduplicator
      GenServer.cast(__MODULE__.Deduplicator, {
        :new_block, 
        provider.id, 
        block_hash, 
        block_number, 
        received_at
      })
    end
  end
  defp handle_block_message(_provider, _params), do: :ok

  # Deduplication process
  defmodule Deduplicator do
    use GenServer
    require Logger

    def init(_) do
      state = %{
        seen_blocks: %{},
        stats: %{
          total_messages: 0,
          duplicates_filtered: 0,
          provider_speeds: %{}
        }
      }
      {:ok, state}
    end

    def handle_cast({:new_block, provider_id, block_hash, block_number, received_at}, state) do
      block_num = hex_to_int(block_number)
      
      case Map.get(state.seen_blocks, block_hash) do
        nil ->
          # First time seeing this block
          Logger.info("🧱 NEW Block ##{block_num} from #{provider_id} | Hash: #{String.slice(block_hash, 0..9)}...")
          
          new_seen = Map.put(state.seen_blocks, block_hash, {provider_id, received_at})
          new_stats = %{state.stats | total_messages: state.stats.total_messages + 1}
          
          {:noreply, %{state | seen_blocks: new_seen, stats: new_stats}}
          
        {first_provider, first_time} ->
          # Duplicate detected
          latency_diff = received_at - first_time
          
          Logger.info(
            "🔄 DUPLICATE Block ##{block_num} from #{provider_id} " <>
            "(#{latency_diff}ms after #{first_provider}) | Hash: #{String.slice(block_hash, 0..9)}..."
          )
          
          new_stats = %{state.stats | 
            total_messages: state.stats.total_messages + 1,
            duplicates_filtered: state.stats.duplicates_filtered + 1
          }
          
          # Update provider speed stats
          speed_stats = Map.get(state.stats.provider_speeds, provider_id, [])
          new_speed_stats = [latency_diff | Enum.take(speed_stats, 9)]  # Keep last 10
          new_provider_speeds = Map.put(state.stats.provider_speeds, provider_id, new_speed_stats)
          
          final_stats = %{new_stats | provider_speeds: new_provider_speeds}
          
          {:noreply, %{state | stats: final_stats}}
      end
    end

    def handle_call(:get_stats, _from, state) do
      # Calculate average latencies
      avg_latencies = 
        Enum.map(state.stats.provider_speeds, fn {provider, latencies} ->
          avg = if length(latencies) > 0 do
            Enum.sum(latencies) / length(latencies)
          else
            0
          end
          {provider, Float.round(avg, 1)}
        end)
        |> Enum.into(%{})
      
      stats = Map.put(state.stats, :avg_latencies, avg_latencies)
      {:reply, stats, state}
    end

    defp hex_to_int("0x" <> hex), do: String.to_integer(hex, 16)
    defp hex_to_int(hex), do: String.to_integer(hex, 16)
  end
end

# Run the demo
MultiProviderDemo.run()