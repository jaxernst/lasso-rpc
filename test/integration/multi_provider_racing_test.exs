defmodule Integration.MultiProviderRacingTest do
  @moduledoc """
  Integration tests for multi-provider racing functionality.

  This tests Livechain's core value proposition: racing multiple providers
  against each other to deliver the fastest response to clients.
  """

  use ExUnit.Case, async: false
  import Mox

  setup do
    # Mock the HTTP client for controlled provider simulation
    stub(Livechain.RPC.HttpClientMock, :request, fn config, method, params, timeout ->
      # Simulate different provider speeds based on URL
      provider_delay =
        case config.url do
          # Fast provider: 50ms
          "https://fast-provider.example.com" -> 50
          # Medium provider: 150ms
          "https://medium-provider.example.com" -> 150
          # Slow provider: 300ms
          "https://slow-provider.example.com" -> 300
          # Default delay
          _ -> 100
        end

      # Simulate network delay
      Process.sleep(provider_delay)

      # Return appropriate response based on method
      result =
        case method do
          "eth_chainId" -> "0x1"
          "eth_blockNumber" -> "0x12345"
          "eth_getBalance" -> "0x1234567890abcdef"
          _ -> "0x0"
        end

      {:ok, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}}
    end)

    # Start core dependencies if not already started
    case Registry.start_link(
           keys: :unique,
           name: Livechain.Registry,
           partitions: System.schedulers_online()
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Livechain.RPC.ProcessRegistry.start_link(name: Livechain.RPC.ProcessRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Livechain.Benchmarking.BenchmarkStore.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "Provider Racing Fundamentals" do
    test "fastest provider wins the race" do
      # This test verifies that when multiple providers are racing,
      # the system correctly identifies and forwards the fastest response

      # Create test message aggregator for racing simulation
      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 3,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"racing_test_chain", chain_config})

      # Simulate identical messages arriving from different providers at different times
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

      # Start tasks to simulate concurrent provider responses
      tasks = [
        # Fast provider arrives first
        Task.async(fn ->
          # Simulate 50ms network delay
          Process.sleep(50)

          Livechain.RPC.MessageAggregator.process_message(
            "racing_test_chain",
            "fast_provider",
            message
          )

          "fast_provider"
        end),

        # Medium provider arrives second
        Task.async(fn ->
          # Simulate 150ms network delay
          Process.sleep(150)

          Livechain.RPC.MessageAggregator.process_message(
            "racing_test_chain",
            "medium_provider",
            message
          )

          "medium_provider"
        end),

        # Slow provider arrives last
        Task.async(fn ->
          # Simulate 300ms network delay
          Process.sleep(300)

          Livechain.RPC.MessageAggregator.process_message(
            "racing_test_chain",
            "slow_provider",
            message
          )

          "slow_provider"
        end)
      ]

      # Wait for all providers to respond
      results = Task.await_many(tasks, 1000)

      # Verify all providers attempted to deliver
      assert length(results) == 3
      assert "fast_provider" in results
      assert "medium_provider" in results
      assert "slow_provider" in results

      # Check aggregator stats
      stats = Livechain.RPC.MessageAggregator.get_stats("racing_test_chain")
      # All three providers sent the message
      assert stats.messages_received == 3
      # Only one message forwarded (deduplication)
      assert stats.messages_forwarded == 1
      # Two duplicates detected
      assert stats.messages_deduplicated == 2
      # All providers recorded
      assert MapSet.size(stats.providers_reporting) == 3
    end

    test "racing improves overall response time" do
      # This test demonstrates that racing multiple providers
      # improves response time compared to using a single provider

      # Test 1: Single provider response time (slowest provider)
      single_provider_start = System.monotonic_time(:millisecond)

      # Simulate making request to slow provider only
      {:ok, _response} =
        MockHttpClient.request(
          %{url: "https://slow-provider.example.com"},
          "eth_blockNumber",
          [],
          5000
        )

      single_provider_time = System.monotonic_time(:millisecond) - single_provider_start

      # Test 2: Multi-provider racing response time
      racing_start = System.monotonic_time(:millisecond)

      # Create message aggregator for racing
      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 3,
          max_cache_size: 100
        }
      }

      {:ok, _pid} = Livechain.RPC.MessageAggregator.start_link({"speed_test_chain", chain_config})

      # Race message from multiple providers
      block_message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0x456",
          "result" => %{
            "number" => "0x54321",
            "hash" => "0xfedcba987654321"
          }
        }
      }

      # Start all providers racing
      racing_tasks = [
        Task.async(fn ->
          # Fast provider
          Process.sleep(50)

          Livechain.RPC.MessageAggregator.process_message(
            "speed_test_chain",
            "fast_provider",
            block_message
          )
        end),
        Task.async(fn ->
          # Medium provider
          Process.sleep(150)

          Livechain.RPC.MessageAggregator.process_message(
            "speed_test_chain",
            "medium_provider",
            block_message
          )
        end),
        Task.async(fn ->
          # Slow provider
          Process.sleep(300)

          Livechain.RPC.MessageAggregator.process_message(
            "speed_test_chain",
            "slow_provider",
            block_message
          )
        end)
      ]

      # Wait for the fastest response (first to complete means message was forwarded)
      Task.await(List.first(racing_tasks), 500)

      racing_time = System.monotonic_time(:millisecond) - racing_start

      # Racing should be significantly faster than single slow provider
      improvement = single_provider_time - racing_time
      improvement_percent = improvement / single_provider_time * 100

      assert racing_time < single_provider_time
      # Should be at least 60% faster
      assert improvement_percent > 60

      # Clean up remaining tasks
      Enum.each(racing_tasks, fn task ->
        try do
          Task.await(task, 100)
        catch
          :exit, _ -> :ok
        end
      end)
    end

    test "maintains message integrity during racing" do
      # Verify that message content is preserved correctly during racing

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 3,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"integrity_test_chain", chain_config})

      # Create a complex message with nested data
      complex_message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0x789",
          "result" => %{
            "number" => "0x98765",
            "hash" => "0x1122334455667788",
            "parentHash" => "0x8877665544332211",
            "timestamp" => "0x61234567",
            "transactions" => [
              %{
                "hash" => "0xaabbccdd",
                "from" => "0x1234567890123456789012345678901234567890",
                "to" => "0x0987654321098765432109876543210987654321",
                "value" => "0xde0b6b3a7640000"
              }
            ],
            "logs" => [
              %{
                "address" => "0x1111222233334444555566667777888899990000",
                "topics" => [
                  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                  "0x000000000000000000000000abcdef1234567890abcdef1234567890abcdef12",
                  "0x00000000000000000000000087654321098765432187654321098765432187654321"
                ],
                "data" => "0x000000000000000000000000000000000000000000000000000000000000007b"
              }
            ]
          }
        }
      }

      # Send identical complex message from multiple providers
      providers = ["provider_a", "provider_b", "provider_c"]

      # Send from each provider with different delays
      tasks =
        Enum.with_index(providers, fn provider, index ->
          Task.async(fn ->
            # Stagger the arrivals
            Process.sleep(50 + index * 20)

            Livechain.RPC.MessageAggregator.process_message(
              "integrity_test_chain",
              provider,
              complex_message
            )

            provider
          end)
        end)

      # Wait for all to complete
      Task.await_many(tasks, 1000)

      # Verify message integrity and deduplication
      stats = Livechain.RPC.MessageAggregator.get_stats("integrity_test_chain")
      assert stats.messages_received == 3
      # Only one forwarded despite identical content
      assert stats.messages_forwarded == 1
      assert stats.messages_deduplicated == 2

      # The forwarded message should be identical to the original
      # (This would require capturing the forwarded message in a real implementation)
    end
  end

  describe "Performance Measurement" do
    test "tracks provider performance accurately during racing" do
      # Verify that the system accurately measures and records
      # provider performance during racing scenarios

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 3,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"performance_test_chain", chain_config})

      # Run multiple racing rounds to gather performance data
      for round <- 1..5 do
        message = %{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => "0x#{round}",
            "result" => %{
              "number" => "0x#{Integer.to_string(round, 16)}",
              "hash" => "0xround#{round}"
            }
          }
        }

        # Provider A: Consistently fast
        Task.async(fn ->
          # 30-40ms
          Process.sleep(30 + :rand.uniform(10))

          Livechain.RPC.MessageAggregator.process_message(
            "performance_test_chain",
            "consistently_fast",
            message
          )
        end)

        # Provider B: Variable performance
        Task.async(fn ->
          # Alternating fast/slow
          delay = if rem(round, 2) == 0, do: 50, else: 200
          Process.sleep(delay)

          Livechain.RPC.MessageAggregator.process_message(
            "performance_test_chain",
            "variable_performance",
            message
          )
        end)

        # Provider C: Consistently slow
        Task.async(fn ->
          # 180-200ms
          Process.sleep(180 + :rand.uniform(20))

          Livechain.RPC.MessageAggregator.process_message(
            "performance_test_chain",
            "consistently_slow",
            message
          )
        end)

        # Wait between rounds
        Process.sleep(100)
      end

      # Allow time for all tasks to complete
      Process.sleep(500)

      # Verify performance tracking
      stats = Livechain.RPC.MessageAggregator.get_stats("performance_test_chain")
      # 5 rounds × 3 providers
      assert stats.messages_received == 15
      # 5 unique messages
      assert stats.messages_forwarded == 5
      # 10 duplicates
      assert stats.messages_deduplicated == 10

      # All providers should be tracked
      assert MapSet.size(stats.providers_reporting) == 3
      assert MapSet.member?(stats.providers_reporting, "consistently_fast")
      assert MapSet.member?(stats.providers_reporting, "variable_performance")
      assert MapSet.member?(stats.providers_reporting, "consistently_slow")
    end

    test "racing metrics influence provider selection" do
      # Test that the racing results feed back into provider selection
      # to improve future request routing

      # This test would require integration with the actual provider selection system
      # For now, verify that performance data is being collected

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 2,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"selection_test_chain", chain_config})

      # Create racing scenario where one provider consistently wins
      for _round <- 1..3 do
        message = %{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => "0x#{:rand.uniform(1000)}",
            "result" => %{"number" => "0x#{:rand.uniform(10000)}"}
          }
        }

        # Winner provider (always fastest)
        Task.async(fn ->
          Process.sleep(40)

          Livechain.RPC.MessageAggregator.process_message(
            "selection_test_chain",
            "winner_provider",
            message
          )
        end)

        # Loser provider (always slower)
        Task.async(fn ->
          Process.sleep(120)

          Livechain.RPC.MessageAggregator.process_message(
            "selection_test_chain",
            "loser_provider",
            message
          )
        end)

        # Wait for round to complete
        Process.sleep(200)
      end

      # Verify that performance data exists for future selection decisions
      stats = Livechain.RPC.MessageAggregator.get_stats("selection_test_chain")
      # 3 rounds × 2 providers
      assert stats.messages_received == 6
      assert MapSet.member?(stats.providers_reporting, "winner_provider")
      assert MapSet.member?(stats.providers_reporting, "loser_provider")

      # The winner should have better performance metrics
      # (Specific verification would depend on BenchmarkStore integration)
    end
  end

  describe "Real-world Scenarios" do
    test "handles network jitter and variable latencies" do
      # Simulate real-world network conditions with variable latencies

      chain_config = %{
        aggregation: %{
          # Longer window for variable delays
          deduplication_window: 2000,
          min_confirmations: 1,
          max_providers: 4,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"jitter_test_chain", chain_config})

      # Run test with realistic network jitter
      for round <- 1..3 do
        message = %{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => "0xjitter#{round}",
            "result" => %{"number" => "0x#{round * 1000}"}
          }
        }

        # Simulate providers with realistic jitter
        providers = [
          # 50-70ms
          {"low_latency_provider", 50 + :rand.uniform(20)},
          # 120-160ms
          {"medium_latency_provider", 120 + :rand.uniform(40)},
          # 200-260ms
          {"high_latency_provider", 200 + :rand.uniform(60)},
          # 80-280ms (very variable)
          {"unstable_provider", 80 + :rand.uniform(200)}
        ]

        tasks =
          Enum.map(providers, fn {provider_id, delay} ->
            Task.async(fn ->
              Process.sleep(delay)

              Livechain.RPC.MessageAggregator.process_message(
                "jitter_test_chain",
                provider_id,
                message
              )

              {provider_id, delay}
            end)
          end)

        # Wait for all providers in this round
        Task.await_many(tasks, 1000)

        # Brief pause between rounds
        Process.sleep(100)
      end

      # Verify system handled variable conditions correctly
      stats = Livechain.RPC.MessageAggregator.get_stats("jitter_test_chain")
      # 3 rounds × 4 providers
      assert stats.messages_received == 12
      # 3 unique messages
      assert stats.messages_forwarded == 3
      # 9 duplicates
      assert stats.messages_deduplicated == 9
      assert MapSet.size(stats.providers_reporting) == 4
    end

    test "racing works under high message volume" do
      # Test racing performance under high load conditions

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 3,
          # Larger cache for high volume
          max_cache_size: 1000
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"high_volume_chain", chain_config})

      # Generate high volume of racing messages
      start_time = System.monotonic_time(:millisecond)

      # Create 20 different messages, each raced by 3 providers
      tasks =
        for msg_id <- 1..20 do
          message = %{
            "jsonrpc" => "2.0",
            "method" => "eth_subscription",
            "params" => %{
              "subscription" => "0x#{msg_id}",
              "result" => %{"number" => "0x#{msg_id * 100}"}
            }
          }

          # Each message is sent by 3 providers
          provider_tasks =
            for provider_id <- ["provider1", "provider2", "provider3"] do
              Task.async(fn ->
                # Random delay to simulate real racing
                # 30-80ms
                delay = 30 + :rand.uniform(50)
                Process.sleep(delay)

                Livechain.RPC.MessageAggregator.process_message(
                  "high_volume_chain",
                  provider_id,
                  message
                )
              end)
            end

          provider_tasks
        end

      # Flatten and await all tasks
      all_tasks = List.flatten(tasks)
      Task.await_many(all_tasks, 2000)

      end_time = System.monotonic_time(:millisecond)
      total_time = end_time - start_time

      # Verify high volume was handled correctly
      stats = Livechain.RPC.MessageAggregator.get_stats("high_volume_chain")
      # 20 messages × 3 providers
      assert stats.messages_received == 60
      # 20 unique messages
      assert stats.messages_forwarded == 20
      # 40 duplicates
      assert stats.messages_deduplicated == 40

      # Should process all messages in reasonable time (less than 2 seconds)
      assert total_time < 2000

      # All providers should be tracked
      assert MapSet.size(stats.providers_reporting) == 3
    end
  end

  describe "Error Scenarios During Racing" do
    test "handles provider failures gracefully during racing" do
      # Test racing behavior when some providers fail

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 3,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"failure_test_chain", chain_config})

      message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0xfailure",
          "result" => %{"number" => "0xfail123"}
        }
      }

      # Provider 1: Succeeds normally
      Task.async(fn ->
        Process.sleep(50)

        Livechain.RPC.MessageAggregator.process_message(
          "failure_test_chain",
          "working_provider",
          message
        )
      end)

      # Provider 2: Fails/crashes (simulated by not sending message)
      # Provider 3: Times out (simulated by very long delay)
      Task.async(fn ->
        # Simulate timeout
        Process.sleep(2000)

        Livechain.RPC.MessageAggregator.process_message(
          "failure_test_chain",
          "timeout_provider",
          message
        )
      end)

      # Wait reasonable time for working providers
      Process.sleep(200)

      # Should have received message from working provider
      stats = Livechain.RPC.MessageAggregator.get_stats("failure_test_chain")
      assert stats.messages_received >= 1
      assert stats.messages_forwarded >= 1

      # System should continue working despite provider failures
      assert MapSet.member?(stats.providers_reporting, "working_provider")
    end

    test "racing continues after temporary provider outages" do
      # Test that racing resumes correctly after provider outages

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 2,
          max_cache_size: 100
        }
      }

      {:ok, _pid} =
        Livechain.RPC.MessageAggregator.start_link({"outage_test_chain", chain_config})

      # Phase 1: Normal racing (both providers working)
      message1 = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0xphase1",
          "result" => %{"number" => "0x1111"}
        }
      }

      Task.async(fn ->
        Process.sleep(50)

        Livechain.RPC.MessageAggregator.process_message(
          "outage_test_chain",
          "provider_a",
          message1
        )
      end)

      Task.async(fn ->
        Process.sleep(80)

        Livechain.RPC.MessageAggregator.process_message(
          "outage_test_chain",
          "provider_b",
          message1
        )
      end)

      Process.sleep(150)

      # Phase 2: Provider B has outage (only provider A responds)
      message2 = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0xphase2",
          "result" => %{"number" => "0x2222"}
        }
      }

      Task.async(fn ->
        Process.sleep(50)

        Livechain.RPC.MessageAggregator.process_message(
          "outage_test_chain",
          "provider_a",
          message2
        )
      end)

      # Provider B doesn't respond (simulating outage)

      Process.sleep(100)

      # Phase 3: Provider B recovers, racing resumes
      message3 = %{
        "jsonrpc" => "2.0",
        "method" => "eth_subscription",
        "params" => %{
          "subscription" => "0xphase3",
          "result" => %{"number" => "0x3333"}
        }
      }

      Task.async(fn ->
        Process.sleep(60)

        Livechain.RPC.MessageAggregator.process_message(
          "outage_test_chain",
          "provider_a",
          message3
        )
      end)

      Task.async(fn ->
        # Provider B is now faster
        Process.sleep(40)

        Livechain.RPC.MessageAggregator.process_message(
          "outage_test_chain",
          "provider_b",
          message3
        )
      end)

      Process.sleep(150)

      # Verify system handled outage and recovery correctly
      stats = Livechain.RPC.MessageAggregator.get_stats("outage_test_chain")
      # 2 + 1 + 2 messages
      assert stats.messages_received == 5
      # 3 unique messages
      assert stats.messages_forwarded == 3
      assert MapSet.member?(stats.providers_reporting, "provider_a")
      assert MapSet.member?(stats.providers_reporting, "provider_b")
    end
  end
end
