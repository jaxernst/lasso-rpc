#!/usr/bin/env elixir

# Base Network Live Streaming Demo
# 
# This script demonstrates real-time blockchain event streaming from Base network
# using Livechain's WebSocket connection capabilities.
#
# Run with: elixir examples/base_live_demo.exs

Mix.install([
  {:websockex, "~> 0.4"},
  {:jason, "~> 1.4"}
])

defmodule BaseLiveDemo do
  @moduledoc """
  Simple demonstration of live Base network streaming without full Livechain setup.
  """

  require Logger

  # Base mainnet public RPC endpoints
  @base_mainnet_ws "wss://base-rpc.publicnode.com"
  @base_ankr_ws "wss://rpc.ankr.com/base/ws"

  def run do
    Logger.info("🚀 Starting Base Network Live Stream Demo")
    Logger.info("📡 Connecting to Base mainnet...")

    # Connect to Base mainnet
    case WebSockex.start_link(@base_mainnet_ws, __MODULE__, %{}) do
      {:ok, pid} ->
        Logger.info("✅ Connected to Base mainnet!")
        
        # Subscribe to new block headers
        subscribe_to_new_heads(pid)
        
        # Subscribe to USDC transfer events on Base
        subscribe_to_usdc_transfers(pid)
        
        # Keep the demo running for 60 seconds
        Logger.info("🔄 Streaming events for 60 seconds...")
        Process.sleep(60_000)
        
        Logger.info("🛑 Demo completed!")
        WebSockex.cast(pid, :close)
        
      {:error, reason} ->
        Logger.error("❌ Failed to connect: #{inspect(reason)}")
    end
  end

  def handle_connect(_conn, state) do
    Logger.info("🔗 WebSocket connected to Base network")
    {:ok, state}
  end

  def handle_frame({:text, message}, state) do
    case Jason.decode(message) do
      {:ok, %{"method" => "eth_subscription", "params" => params}} ->
        handle_subscription_event(params)
        {:ok, state}
        
      {:ok, %{"result" => result, "id" => id}} ->
        Logger.debug("📬 Subscription result for #{id}: #{inspect(result)}")
        {:ok, state}
        
      {:ok, data} ->
        Logger.debug("📨 Other message: #{inspect(data)}")
        {:ok, state}
        
      {:error, reason} ->
        Logger.error("❌ Failed to decode message: #{reason}")
        {:ok, state}
    end
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("🔌 Disconnected: #{inspect(reason)}")
    {:ok, state}
  end

  defp subscribe_to_new_heads(pid) do
    subscription = %{
      "jsonrpc" => "2.0",
      "id" => "newheads_sub",
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }
    
    WebSockex.send_frame(pid, {:text, Jason.encode!(subscription)})
    Logger.info("📡 Subscribed to new block headers")
  end

  defp subscribe_to_usdc_transfers(pid) do
    # USDC contract on Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    usdc_filter = %{
      "address" => ["0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"],
      "topics" => [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" # Transfer event signature
      ]
    }
    
    subscription = %{
      "jsonrpc" => "2.0", 
      "id" => "usdc_transfers",
      "method" => "eth_subscribe",
      "params" => ["logs", usdc_filter]
    }
    
    WebSockex.send_frame(pid, {:text, Jason.encode!(subscription)})
    Logger.info("💰 Subscribed to USDC transfers on Base")
  end

  defp handle_subscription_event(%{"result" => block_data, "subscription" => _sub_id}) when is_map(block_data) do
    block_number = Map.get(block_data, "number", "unknown")
    block_hash = Map.get(block_data, "hash", "unknown")
    
    if Map.has_key?(block_data, "number") do
      # This is a new block
      block_num = String.to_integer(String.slice(block_number, 2..-1), 16)
      Logger.info("🧱 New Base block ##{block_num} | Hash: #{String.slice(block_hash, 0..9)}...")
    else
      # This might be a log event
      Logger.info("📜 Transaction log event: #{inspect(block_data)}")
    end
  end

  defp handle_subscription_event(params) do
    Logger.debug("📡 Subscription event: #{inspect(params)}")
  end
end

# Run the demo
BaseLiveDemo.run()