defmodule Livechain.RPC.LiveStreamTest do
  @moduledoc """
  Live integration tests demonstrating real-time blockchain event streaming.
  
  These tests connect to actual blockchain networks and stream live data.
  They are tagged as :live and :integration to run separately from unit tests.
  
  Run with: mix test --only live --only integration
  """
  
  use ExUnit.Case
  
  alias Livechain.RPC.{WSConnection, RealEndpoints}
  
  require Logger
  
  @moduletag :live
  @moduletag :integration
  @moduletag timeout: 60_000
  
  # Skip these tests by default since they require network access
  @moduletag :skip
  
  describe "Base Network Live Streaming" do
    @tag :base_mainnet
    test "streams new blocks from Base mainnet using public RPC" do
      endpoint = RealEndpoints.base_mainnet_public()
      
      # Start the WebSocket connection
      {:ok, connection_pid} = WSConnection.start_link(endpoint)
      
      # Wait for connection to establish
      Process.sleep(2000)
      
      # Check connection status
      status = WSConnection.status(endpoint.id)
      assert status.connected == true
      
      # Subscribe to new block headers
      :ok = WSConnection.subscribe(endpoint.id, "newHeads")
      
      # Subscribe to contract logs (for token transfers, DEX trades, etc.)
      logs_filter = %{
        "address" => ["0xA0b86a33E6417c8a8aB9d74D46DBF3B6bbea5BBE"], # USDC on Base
        "topics" => [
          "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" # Transfer event
        ]
      }
      
      # Subscribe to logs for USDC transfers
      logs_subscription = %{
        "jsonrpc" => "2.0",
        "id" => "logs_sub_1", 
        "method" => "eth_subscribe",
        "params" => ["logs", logs_filter]
      }
      
      WSConnection.send_message(endpoint.id, logs_subscription)
      
      # Wait and collect events for demonstration
      receive_events_for_seconds(30)
      
      # Clean up
      GenServer.stop(connection_pid)
    end
    
    @tag :base_ankr
    test "streams events from Base using Ankr RPC" do
      endpoint = RealEndpoints.base_mainnet_ankr()
      
      {:ok, connection_pid} = WSConnection.start_link(endpoint)
      Process.sleep(2000)
      
      status = WSConnection.status(endpoint.id)
      assert status.connected == true
      
      # Subscribe to new pending transactions
      :ok = WSConnection.subscribe(endpoint.id, "newPendingTransactions")
      
      # Monitor for 15 seconds
      receive_events_for_seconds(15)
      
      GenServer.stop(connection_pid)
    end
    
    @tag :base_sepolia 
    test "streams testnet events from Base Sepolia" do
      endpoint = RealEndpoints.base_sepolia_public()
      
      {:ok, connection_pid} = WSConnection.start_link(endpoint)
      Process.sleep(2000)
      
      status = WSConnection.status(endpoint.id)
      assert status.connected == true
      
      # Subscribe to new blocks on testnet
      :ok = WSConnection.subscribe(endpoint.id, "newHeads")
      
      # Testnet blocks come faster, so shorter wait time
      receive_events_for_seconds(20)
      
      GenServer.stop(connection_pid)
    end
    
    @tag :multi_chain
    test "demonstrates multi-chain streaming with Base and Ethereum" do
      # Start Base connection
      base_endpoint = RealEndpoints.base_mainnet_public()
      {:ok, base_pid} = WSConnection.start_link(base_endpoint)
      
      # Start Ethereum connection  
      eth_endpoint = RealEndpoints.ethereum_mainnet_public()
      {:ok, eth_pid} = WSConnection.start_link(eth_endpoint)
      
      Process.sleep(3000)
      
      # Verify both connections
      base_status = WSConnection.status(base_endpoint.id)
      eth_status = WSConnection.status(eth_endpoint.id)
      
      assert base_status.connected == true
      assert eth_status.connected == true
      
      # Subscribe to new blocks on both chains
      :ok = WSConnection.subscribe(base_endpoint.id, "newHeads")
      :ok = WSConnection.subscribe(eth_endpoint.id, "newHeads")
      
      Logger.info("🚀 Streaming live blocks from Base and Ethereum...")
      Logger.info("📊 Watch for cross-chain activity patterns and block timing differences")
      
      # Monitor both chains simultaneously
      receive_events_for_seconds(45)
      
      # Clean up
      GenServer.stop(base_pid)
      GenServer.stop(eth_pid)
    end
  end
  
  describe "DeFi Activity Monitoring" do
    @tag :defi_streams
    test "monitors live DeFi activity on Base" do
      endpoint = RealEndpoints.base_mainnet_public()
      {:ok, connection_pid} = WSConnection.start_link(endpoint)
      Process.sleep(2000)
      
      # Popular DeFi contracts on Base
      uniswap_v3_factory = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD"
      aerodrome_factory = "0x420DD381b31aEf6683db6B902084cB0FFECe40Da"
      
      # Subscribe to Uniswap V3 pool creation events
      uniswap_filter = %{
        "address" => [uniswap_v3_factory],
        "topics" => [
          "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118" # PoolCreated event
        ]
      }
      
      # Subscribe to Aerodrome factory events
      aerodrome_filter = %{
        "address" => [aerodrome_factory],
        "topics" => [
          "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9" # PairCreated event
        ]
      }
      
      # Send subscription requests
      WSConnection.send_message(endpoint.id, %{
        "jsonrpc" => "2.0",
        "id" => "uniswap_pools",
        "method" => "eth_subscribe", 
        "params" => ["logs", uniswap_filter]
      })
      
      WSConnection.send_message(endpoint.id, %{
        "jsonrpc" => "2.0",
        "id" => "aerodrome_pools",
        "method" => "eth_subscribe",
        "params" => ["logs", aerodrome_filter] 
      })
      
      Logger.info("🦄 Monitoring DeFi pool creation on Base...")
      Logger.info("💫 Watching for new Uniswap V3 and Aerodrome pairs")
      
      receive_events_for_seconds(60)
      
      GenServer.stop(connection_pid)
    end
  end
  
  # Helper function to receive and log events for demonstration
  defp receive_events_for_seconds(seconds) do
    end_time = System.monotonic_time(:millisecond) + (seconds * 1000)
    receive_events_until(end_time, 0, seconds)
  end
  
  defp receive_events_until(end_time, event_count, original_seconds) do
    current_time = System.monotonic_time(:millisecond)
    
    if current_time < end_time do
      timeout = min(end_time - current_time, 5000)
      
      receive do
        %{event: "new_block", payload: block_data} = message ->
          Logger.info("🧱 New block received on #{extract_chain_name(message)}: #{block_data["number"]}")
          receive_events_until(end_time, event_count + 1, original_seconds)
          
        %{event: _event_type, payload: _data} = message ->
          Logger.info("📡 Event received: #{inspect(message)}")
          receive_events_until(end_time, event_count + 1, original_seconds)
          
        other ->
          Logger.debug("📨 Other message: #{inspect(other)}")
          receive_events_until(end_time, event_count, original_seconds)
          
      after
        timeout ->
          if event_count == 0 do
            Logger.info("⏱️  No events received in #{original_seconds} seconds (this is normal for some chains)")
          else
            Logger.info("✅ Received #{event_count} events in #{original_seconds} seconds")
          end
      end
    else
      if event_count == 0 do
        Logger.info("⏱️  No events received in #{original_seconds} seconds (this is normal for some chains)")
      else
        Logger.info("✅ Received #{event_count} events in #{original_seconds} seconds")
      end
    end
  end
  
  defp extract_chain_name(message) do
    # Extract chain info from the message or default to "unknown"
    Map.get(message, :chain, "unknown")
  end
end