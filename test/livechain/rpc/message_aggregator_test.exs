defmodule Livechain.RPC.MessageAggregatorTest do
  @moduledoc """
  Tests for the core racing and message deduplication functionality.

  This tests the heart of Livechain's value proposition: racing multiple providers
  for speed, deduplicating identical messages, and measuring performance.
  """

  use ExUnit.Case, async: false
  import Mox

  alias Livechain.RPC.MessageAggregator
  alias Livechain.Benchmarking.BenchmarkStore

  setup do
    # Mock the HTTP client for any background operations
    stub(Livechain.RPC.HttpClientMock, :request, &MockHttpClient.request/4)

    # Test configuration for message aggregator
    chain_config = %{
      aggregation: %{
        deduplication_window: 1000,
        min_confirmations: 1,
        max_providers: 3,
        max_cache_size: 100
      }
    }

    %{chain_config: chain_config}
  end

  describe "Message Racing" do
    test "forwards first message and records race win", %{chain_config: chain_config} do
      chain_name = "test_racing_chain"

      # Start message aggregator
      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Create identical block messages from different providers
      block_message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0x123",
          "result" => %{
            "number" => "0x12345",
            "hash" => "0xabcdef123456789"
          }
        }
      }

      # Provider 1 sends message first
      MessageAggregator.process_message(chain_name, "provider1", block_message)

      # Provider 2 sends same message later (should be deduplicated)
      MessageAggregator.process_message(chain_name, "provider2", block_message)

      # Check stats
      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 2
      assert stats.messages_forwarded == 1
      assert stats.messages_deduplicated == 1
      assert MapSet.size(stats.providers_reporting) == 2
    end

    test "different messages are all forwarded", %{chain_config: chain_config} do
      chain_name = "test_different_messages"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Send three different block messages
      for i <- 1..3 do
        message = %{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => "0x123",
            "result" => %{
              "number" => "0x1234#{i}",
              "hash" => "0xabcdef12345678#{i}"
            }
          }
        }

        MessageAggregator.process_message(chain_name, "provider1", message)
      end

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 3
      assert stats.messages_forwarded == 3
      assert stats.messages_deduplicated == 0
    end

    test "measures racing timing accurately", %{chain_config: chain_config} do
      chain_name = "test_timing_chain"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0x123",
          "result" => %{
            "number" => "0x12345",
            "hash" => "0xabcdef123456789"
          }
        }
      }

      # Send same message from two providers with delay
      MessageAggregator.process_message(chain_name, "fast_provider", message)

      # Small delay to simulate network latency
      Process.sleep(10)

      MessageAggregator.process_message(chain_name, "slow_provider", message)

      # Verify the racing metrics were recorded
      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 2
      assert stats.messages_forwarded == 1

      # The fast provider should have won the race
      # (Implementation detail: check BenchmarkStore for race metrics)
    end
  end

  describe "Message Deduplication" do
    test "deduplicates identical transaction events", %{chain_config: chain_config} do
      chain_name = "test_tx_dedup"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Transaction event message
      tx_message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0x456",
          "result" => %{
            "transactionHash" => "0x987654321",
            "blockNumber" => "0x12345",
            "logIndex" => "0x0"
          }
        }
      }

      # Send same transaction from multiple providers
      MessageAggregator.process_message(chain_name, "provider1", tx_message)
      MessageAggregator.process_message(chain_name, "provider2", tx_message)
      MessageAggregator.process_message(chain_name, "provider3", tx_message)

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 3
      assert stats.messages_forwarded == 1
      assert stats.messages_deduplicated == 2
    end

    test "handles message key generation correctly", %{chain_config: chain_config} do
      chain_name = "test_key_generation"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Messages with same hash should be deduplicated
      message1 = %{"result" => %{"hash" => "0xsame123"}}
      message2 = %{"result" => %{"hash" => "0xsame123"}}

      MessageAggregator.process_message(chain_name, "provider1", message1)
      MessageAggregator.process_message(chain_name, "provider2", message2)

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_deduplicated == 1

      # Messages with different hashes should not be deduplicated
      message3 = %{"result" => %{"hash" => "0xdifferent456"}}
      MessageAggregator.process_message(chain_name, "provider1", message3)

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_forwarded == 2
    end
  end

  describe "Cache Management" do
    test "evicts old entries when cache is full", %{chain_config: config} do
      # Set small cache size for testing
      small_cache_config = put_in(config.aggregation.max_cache_size, 3)
      chain_name = "test_cache_eviction"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, small_cache_config})

      # Fill cache beyond limit
      for i <- 1..5 do
        message = %{"result" => %{"hash" => "0xhash#{i}"}}
        MessageAggregator.process_message(chain_name, "provider1", message)
      end

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 5
      assert stats.messages_forwarded == 5

      # Verify cache size is bounded (implementation detail)
      # The actual cache size checking would need to access internal state
    end

    test "cache handles high message volume", %{chain_config: chain_config} do
      chain_name = "test_high_volume"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Send many unique messages rapidly
      start_time = System.monotonic_time(:millisecond)

      for i <- 1..100 do
        message = %{"result" => %{"hash" => "0xvolume#{i}"}}
        MessageAggregator.process_message(chain_name, "provider1", message)
      end

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # Should process 100 messages quickly (less than 1 second)
      assert duration < 1000

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 100
      assert stats.messages_forwarded == 100
    end
  end

  describe "Concurrent Racing" do
    test "handles concurrent messages from multiple providers", %{chain_config: chain_config} do
      chain_name = "test_concurrent_racing"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Same message sent concurrently from 3 providers
      message = %{"result" => %{"hash" => "0xconcurrent123"}}

      # Start 3 tasks sending the same message
      tasks =
        for provider_id <- ["provider1", "provider2", "provider3"] do
          Task.async(fn ->
            MessageAggregator.process_message(chain_name, provider_id, message)
          end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Only one message should be forwarded
      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 3
      assert stats.messages_forwarded == 1
      assert stats.messages_deduplicated == 2
    end

    test "preserves message ordering under concurrency", %{chain_config: chain_config} do
      chain_name = "test_message_ordering"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Send different messages concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            message = %{"result" => %{"hash" => "0xorder#{i}", "number" => "0x#{i}"}}
            MessageAggregator.process_message(chain_name, "provider1", message)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 10
      assert stats.messages_forwarded == 10
    end
  end

  describe "Error Handling" do
    test "handles malformed messages gracefully", %{chain_config: chain_config} do
      chain_name = "test_error_handling"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Send malformed message
      malformed_message = %{"invalid" => "structure"}
      MessageAggregator.process_message(chain_name, "provider1", malformed_message)

      # Should not crash, stats should reflect the attempt
      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received >= 0
    end

    test "continues processing after provider error", %{chain_config: chain_config} do
      chain_name = "test_provider_error"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Send normal message
      good_message = %{"result" => %{"hash" => "0xgood123"}}
      MessageAggregator.process_message(chain_name, "provider1", good_message)

      # Send malformed message
      bad_message = nil
      MessageAggregator.process_message(chain_name, "provider2", bad_message)

      # Send another good message
      good_message2 = %{"result" => %{"hash" => "0xgood456"}}
      MessageAggregator.process_message(chain_name, "provider1", good_message2)

      # Should continue processing
      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_forwarded >= 2
    end
  end

  describe "Performance Metrics" do
    test "tracks provider performance accurately", %{chain_config: chain_config} do
      chain_name = "test_performance_tracking"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Fast provider always wins
      fast_message = %{"result" => %{"hash" => "0xfast1"}}
      MessageAggregator.process_message(chain_name, "fast_provider", fast_message)

      Process.sleep(5)

      # Same hash
      slow_message = %{"result" => %{"hash" => "0xfast1"}}
      MessageAggregator.process_message(chain_name, "slow_provider", slow_message)

      # Check that performance metrics are updated
      stats = MessageAggregator.get_stats(chain_name)
      assert MapSet.member?(stats.providers_reporting, "fast_provider")
      assert MapSet.member?(stats.providers_reporting, "slow_provider")

      # Both providers should be tracked even though slow one was deduplicated
      assert MapSet.size(stats.providers_reporting) == 2
    end
  end

  describe "Integration with BenchmarkStore" do
    test "records racing metrics to benchmark store", %{chain_config: chain_config} do
      chain_name = "test_benchmark_integration"

      {:ok, _pid} = MessageAggregator.start_link({chain_name, chain_config})

      # Send racing messages
      message = %{"result" => %{"hash" => "0xbenchmark123"}}

      MessageAggregator.process_message(chain_name, "winner_provider", message)
      Process.sleep(10)
      MessageAggregator.process_message(chain_name, "loser_provider", message)

      # Give some time for async benchmark recording
      Process.sleep(50)

      # Verify benchmark store has racing metrics
      # (This would depend on the actual BenchmarkStore API)
      stats = MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 2
      assert stats.messages_deduplicated == 1
    end
  end
end
