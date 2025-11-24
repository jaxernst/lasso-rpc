defmodule Mix.Tasks.Lasso.DiscoverLimits do
  use Mix.Task
  require Logger

  @shortdoc "Discover RPC provider limitations through automated testing"

  @moduledoc """
  Automatically discovers provider limitations by testing various edge cases.

  This tool helps identify:
  - Block range limits for eth_getLogs
  - Address count limits for eth_getLogs
  - Rate limits (requests/second)
  - Archive node support
  - Custom error codes and messages

  ## Usage

      mix lasso.discover_limits <provider_url> [options]

  ## Options

    * `--chain <name>` - Chain name for context (default: ethereum)
    * `--timeout <ms>` - Request timeout in milliseconds (default: 10000)
    * `--output <format>` - Output format: table, json, yaml (default: table)

  ## Examples

      # Discover limits for a provider
      mix lasso.discover_limits https://g.w.lavanet.xyz:443/gateway/eth/rpc-http/KEY

      # Test with specific chain context
      mix lasso.discover_limits https://provider.com/base --chain base

      # Output in YAML format for chains.yml
      mix lasso.discover_limits https://provider.com --output yaml

  ## Test Suite

  The script runs these tests:

  1. **Block Range Test** - Binary search to find max block range for eth_getLogs
  2. **Address Count Test** - Test increasing address counts to find limit
  3. **Topic Filter Test** - Test topic complexity and OR alternatives
  4. **Log Volume Test** - Test actual log count limits with real data
  5. **Batch Request Test** - Test batch request support and limits
  6. **Block Params Test** - Test special block parameters (safe, finalized, etc)
  7. **Archive Support Test** - Query very old blocks to check archive node
  8. **Rate Limit Test** - Send rapid requests to detect rate limiting
  9. **Error Code Analysis** - Analyze error codes and messages for patterns

  Results indicate:
  - Exact limits discovered through testing
  - Recommendations for adapter_config
  - Whether a custom adapter is needed
  """

  # Realistic contract addresses for testing with actual log data
  # These are high-volume contracts (like USDC) that generate many Transfer events
  @ethereum_usdc "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  @base_usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @arbitrum_usdc "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
  @optimism_usdc "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"
  @polygon_usdc "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"

  # Common event signatures
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  @impl Mix.Task
  def run(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        strict: [
          chain: :string,
          timeout: :integer,
          output: :string
        ],
        aliases: [c: :chain, t: :timeout, o: :output]
      )

    if length(args) == 0 do
      Mix.shell().error("Usage: mix lasso.discover_limits <provider_url> [options]")
      Mix.shell().info("\nRun `mix help lasso.discover_limits` for details")
      System.halt(1)
    end

    # Start only minimal dependencies (not full web server)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:finch)

    # Start Finch pool for HTTP requests
    {:ok, _} = Finch.start_link(name: LimitDiscovery.Finch)

    url = List.first(args)
    chain = Keyword.get(opts, :chain, "ethereum")
    timeout = Keyword.get(opts, :timeout, 10000)
    output_format = Keyword.get(opts, :output, "table") |> String.to_existing_atom()

    Mix.shell().info("🔍 Discovering limitations for: #{url}")
    Mix.shell().info("⛓️  Chain: #{chain}")
    Mix.shell().info("⏱️  Timeout: #{timeout}ms")
    Mix.shell().info("")

    # Run discovery tests
    results = %{
      url: url,
      chain: chain,
      timestamp: DateTime.utc_now(),
      tests: %{},
      # Track all errors encountered
      errors: []
    }

    results = run_block_range_test(results, url, timeout)
    results = run_address_count_test(results, url, timeout)
    results = run_topic_filter_test(results, url, chain, timeout)
    results = run_log_volume_test(results, url, chain, timeout)
    results = run_batch_request_test(results, url, timeout)
    results = run_block_params_test(results, url, timeout)
    results = run_archive_support_test(results, url, timeout)
    results = run_rate_limit_test(results, url, timeout)
    results = analyze_error_patterns(results)

    # Output results
    case output_format do
      :table -> output_table(results)
      :json -> output_json(results)
      :yaml -> output_yaml(results)
      _ -> Mix.shell().error("Unknown output format: #{output_format}")
    end
  end

  # Test 1: Block Range Limits
  defp run_block_range_test(results, url, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 1: Block Range Limits for eth_getLogs")
    Mix.shell().info("=" |> String.duplicate(80))

    # Get current block number
    case make_request(url, "eth_blockNumber", [], timeout) do
      {:ok, %{"result" => current_block_hex}} ->
        current_block = hex_to_int(current_block_hex)
        Mix.shell().info("Current block: #{current_block}")
        run_block_range_test_impl(results, url, current_block, timeout)

      {:server_error, status} ->
        Mix.shell().info("⚠️  Failed to get current block: HTTP #{status}")
        Mix.shell().info("")

        test_result = %{
          status: :inconclusive,
          recommendation: "Unable to query current block number due to server error"
        }

        put_in(results, [:tests, :block_range], test_result)

      {:error, reason} ->
        Mix.shell().info("⚠️  Failed to get current block: #{inspect(reason)}")
        Mix.shell().info("")

        test_result = %{
          status: :inconclusive,
          recommendation: "Unable to query current block number"
        }

        put_in(results, [:tests, :block_range], test_result)

      {:ok, %{"error" => error}} ->
        Mix.shell().info("⚠️  Error getting block number: #{error["message"]}")
        Mix.shell().info("")

        test_result = %{
          status: :inconclusive,
          recommendation: "Unable to query current block number"
        }

        put_in(results, [:tests, :block_range], test_result)
    end
  end

  defp run_block_range_test_impl(results, url, current_block, timeout) do
    # Binary search for max block range
    max_range = binary_search_block_range(url, current_block, timeout)

    test_result = %{
      status: if(max_range, do: :limited, else: :unlimited),
      max_block_range: max_range,
      recommendation:
        if max_range do
          "Set adapter_config: max_block_range: #{max_range}"
        else
          "No block range limit detected (tested up to 10000 blocks)"
        end
    }

    if max_range do
      Mix.shell().info("✅ Max block range detected: #{max_range} blocks")
    else
      Mix.shell().info("✅ No block range limit detected (tested up to 10000)")
    end

    Mix.shell().info("")

    put_in(results, [:tests, :block_range], test_result)
  end

  defp binary_search_block_range(url, current_block, timeout) do
    # Start with common limits, then binary search
    test_ranges = [100, 500, 1000, 2000, 5000, 10000]

    # Find first failure
    first_failure =
      Enum.find(test_ranges, fn range ->
        from_block = current_block - range
        to_block = current_block - 1

        params = [
          %{
            "fromBlock" => int_to_hex(from_block),
            "toBlock" => int_to_hex(to_block)
          }
        ]

        case make_request(url, "eth_getLogs", params, timeout) do
          {:ok, %{"result" => _}} ->
            Mix.shell().info("  ✓ #{range} blocks: OK")
            false

          {:ok, %{"error" => error}} ->
            if is_block_range_error?(error) do
              Mix.shell().info("  ✗ #{range} blocks: LIMIT EXCEEDED")
              true
            else
              Mix.shell().info("  ? #{range} blocks: Other error - #{error["message"]}")
              false
            end

          {:error, _} ->
            false

          e ->
            # Log the unexpected error
            Mix.shell().info("  ✗ #{range} blocks: Unexpected error - #{inspect(e)}")
            false
        end
      end)

    case first_failure do
      # No limit found
      nil ->
        nil

      limit ->
        # Binary search between previous success and this failure
        prev_idx = Enum.find_index(test_ranges, &(&1 == limit)) - 1

        if prev_idx >= 0 do
          lower = Enum.at(test_ranges, prev_idx)
          upper = limit
          refine_block_range(url, current_block, lower, upper, timeout)
        else
          limit
        end
    end
  end

  defp refine_block_range(_url, _current_block, lower, upper, _timeout)
       when upper - lower <= 10 do
    # Close enough, return lower bound
    lower
  end

  defp refine_block_range(url, current_block, lower, upper, timeout) do
    mid = div(lower + upper, 2)

    from_block = current_block - mid
    to_block = current_block - 1

    params = [
      %{
        "fromBlock" => int_to_hex(from_block),
        "toBlock" => int_to_hex(to_block)
      }
    ]

    case make_request(url, "eth_getLogs", params, timeout) do
      {:ok, %{"result" => _}} ->
        # Success, try higher
        refine_block_range(url, current_block, mid, upper, timeout)

      {:ok, %{"error" => error}} ->
        if is_block_range_error?(error) do
          # Failure, try lower
          refine_block_range(url, current_block, lower, mid, timeout)
        else
          mid
        end

      {:error, _} ->
        mid
    end
  end

  # Test 2: Address Count Limits
  defp run_address_count_test(results, url, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 2: Address Count Limits for eth_getLogs")
    Mix.shell().info("=" |> String.duplicate(80))

    # Test with increasing address counts
    test_counts = [1, 5, 10, 20, 50, 100]

    # Track detailed results
    {max_addresses, server_errors, other_errors, error_details} =
      Enum.reduce(test_counts, {nil, 0, 0, %{}}, fn count, {acc, srv_err, oth_err, err_map} ->
        addresses =
          for i <- 1..count do
            "0x" <> String.pad_leading(Integer.to_string(i, 16), 40, "0")
          end

        params = [
          %{
            "fromBlock" => "latest",
            "toBlock" => "latest",
            "address" => addresses
          }
        ]

        case make_request(url, "eth_getLogs", params, timeout) do
          {:ok, %{"result" => _}} ->
            Mix.shell().info("  ✓ #{count} addresses: OK")
            {count, srv_err, oth_err, err_map}

          {:ok, %{"error" => error}} ->
            if is_address_limit_error?(error) do
              Mix.shell().info("  ✗ #{count} addresses: LIMIT EXCEEDED")
              {:halt, {acc, srv_err, oth_err, err_map}}
            else
              msg = Map.get(error, "message", inspect(error))
              Mix.shell().info("  ✗ #{count} addresses: #{msg}")
              updated_map = Map.update(err_map, msg, 1, &(&1 + 1))
              # Keep acc, not count!
              {acc, srv_err, oth_err + 1, updated_map}
            end

          {:server_error, status} ->
            Mix.shell().info("  ⚠️  #{count} addresses: Server error (HTTP #{status})")
            msg = "HTTP #{status}"
            updated_map = Map.update(err_map, msg, 1, &(&1 + 1))
            {acc, srv_err + 1, oth_err, updated_map}

          {:error, reason} ->
            msg = inspect(reason)
            Mix.shell().info("  ✗ #{count} addresses: #{msg}")
            updated_map = Map.update(err_map, msg, 1, &(&1 + 1))
            # Keep acc, not count!
            {acc, srv_err, oth_err + 1, updated_map}
        end
      end)

    # Show error summary if there were errors
    total_errors = server_errors + other_errors

    if total_errors > 0 do
      Mix.shell().info("")
      Mix.shell().info("Error Summary:")

      Enum.each(error_details, fn {error, count} ->
        Mix.shell().info("  • \"#{error}\": #{count} occurrence(s)")
      end)
    end

    test_result =
      cond do
        # All tests failed - inconclusive
        max_addresses == nil && total_errors == length(test_counts) ->
          %{
            status: :inconclusive,
            reason: "All tests failed",
            total_errors: total_errors,
            error_breakdown: error_details,
            recommendation: "Unable to test address limits - all requests failed"
          }

        server_errors >= 3 ->
          %{
            status: :inconclusive,
            server_errors: server_errors,
            total_errors: total_errors,
            error_breakdown: error_details,
            recommendation: "Too many server errors (#{server_errors}) to determine limits"
          }

        max_addresses && max_addresses < 100 ->
          %{
            status: :limited,
            max_addresses: max_addresses,
            recommendation: "Set adapter_config: max_addresses: #{max_addresses}"
          }

        true ->
          %{
            status: :unlimited,
            max_addresses: max_addresses || 100,
            recommendation: "No address count limit detected"
          }
      end

    cond do
      max_addresses == nil && total_errors == length(test_counts) ->
        Mix.shell().info("")
        Mix.shell().info("⚠️  All tests failed - cannot determine address limits")

      server_errors >= 3 ->
        Mix.shell().info("")
        Mix.shell().info("⚠️  Too many server errors to determine limits")

      max_addresses && max_addresses < 100 ->
        Mix.shell().info("")
        Mix.shell().info("✅ Max addresses detected: #{max_addresses}")

      max_addresses ->
        Mix.shell().info("")
        Mix.shell().info("✅ No address limit detected (tested up to 100)")

      true ->
        Mix.shell().info("")
        Mix.shell().info("⚠️  Unable to determine address limits")
    end

    Mix.shell().info("")

    put_in(results, [:tests, :address_count], test_result)
  end

  # Test 3: Topic Filter Complexity
  defp run_topic_filter_test(results, url, chain, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 3: Topic Filter Complexity Limits")
    Mix.shell().info("=" |> String.duplicate(80))

    case get_busy_contract(chain) do
      nil ->
        Mix.shell().info("⚠️  No known busy contract for chain '#{chain}' - skipping test")
        Mix.shell().info("")

        test_result = %{
          status: :skipped,
          recommendation: "No suitable contract address configured for this chain"
        }

        put_in(results, [:tests, :topic_filters], test_result)

      busy_contract ->
        case make_request(url, "eth_blockNumber", [], timeout) do
          {:ok, %{"result" => current_block_hex}} ->
            run_topic_filter_test_impl(
              results,
              url,
              busy_contract,
              hex_to_int(current_block_hex),
              timeout
            )

          {:error, reason} ->
            Mix.shell().info("⚠️  Failed to get current block: #{inspect(reason)}")
            Mix.shell().info("")

            test_result = %{
              status: :failed,
              recommendation: "Unable to query current block number"
            }

            put_in(results, [:tests, :topic_filters], test_result)

          {:ok, %{"error" => error}} ->
            Mix.shell().info("⚠️  Error getting block number: #{error["message"]}")
            Mix.shell().info("")

            test_result = %{
              status: :failed,
              recommendation: "Unable to query current block number"
            }

            put_in(results, [:tests, :topic_filters], test_result)
        end
    end
  end

  defp run_topic_filter_test_impl(results, url, busy_contract, current_block, timeout) do
    # Use a reasonable recent range for testing
    from_block = current_block - 100
    to_block = current_block - 1

    # Test 1: Single topic
    Mix.shell().info("Testing single topic...")

    params_1_topic = [
      %{
        "fromBlock" => int_to_hex(from_block),
        "toBlock" => int_to_hex(to_block),
        "address" => busy_contract,
        "topics" => [@transfer_topic]
      }
    ]

    single_topic_works =
      case make_request(url, "eth_getLogs", params_1_topic, timeout) do
        {:ok, %{"result" => _}} ->
          Mix.shell().info("  ✓ Single topic: OK")
          true

        {:ok, %{"error" => error}} ->
          Mix.shell().info("  ✗ Single topic failed: #{error["message"]}")
          false

        {:error, _} ->
          false
      end

    # Test 2: Multiple topics (up to 4)
    max_topics =
      if single_topic_works do
        Enum.reduce_while(2..4, 1, fn num_topics, acc ->
          topics = List.duplicate(@transfer_topic, num_topics)

          params = [
            %{
              "fromBlock" => int_to_hex(from_block),
              "toBlock" => int_to_hex(to_block),
              "address" => busy_contract,
              "topics" => topics
            }
          ]

          case make_request(url, "eth_getLogs", params, timeout) do
            {:ok, %{"result" => _}} ->
              Mix.shell().info("  ✓ #{num_topics} topics: OK")
              {:cont, num_topics}

            {:ok, %{"error" => error}} ->
              if is_topic_complexity_error?(error) do
                Mix.shell().info("  ✗ #{num_topics} topics: LIMIT EXCEEDED")
                {:halt, acc}
              else
                Mix.shell().info("  ? #{num_topics} topics: Other error")
                {:cont, num_topics}
              end

            {:error, _} ->
              {:cont, num_topics}
          end
        end)
      else
        0
      end

    # Test 3: OR alternatives (multiple addresses in topic array)
    Mix.shell().info("Testing OR alternatives in topics...")

    max_or_alternatives =
      if single_topic_works do
        test_or_counts = [2, 5, 10, 20]

        Enum.reduce_while(test_or_counts, 1, fn count, acc ->
          # Create array of same topic repeated (simulates OR condition)
          topic_alternatives = List.duplicate(@transfer_topic, count)

          params = [
            %{
              "fromBlock" => int_to_hex(from_block),
              "toBlock" => int_to_hex(to_block),
              "address" => busy_contract,
              "topics" => [topic_alternatives]
            }
          ]

          case make_request(url, "eth_getLogs", params, timeout) do
            {:ok, %{"result" => _}} ->
              Mix.shell().info("  ✓ #{count} OR alternatives: OK")
              {:cont, count}

            {:ok, %{"error" => error}} ->
              if is_topic_complexity_error?(error) do
                Mix.shell().info("  ✗ #{count} OR alternatives: LIMIT EXCEEDED")
                {:halt, acc}
              else
                Mix.shell().info("  ? #{count} OR alternatives: Other error")
                {:cont, count}
              end

            {:error, _} ->
              {:cont, count}
          end
        end)
      else
        0
      end

    test_result = %{
      status: if(max_topics < 4 or max_or_alternatives < 20, do: :limited, else: :unlimited),
      max_topics: max_topics,
      max_or_alternatives: max_or_alternatives,
      recommendation:
        cond do
          max_topics < 4 ->
            "Topic filter limited to #{max_topics} topics - configure adapter"

          max_or_alternatives < 20 ->
            "OR alternatives limited to #{max_or_alternatives} - configure adapter"

          true ->
            "No topic filter limits detected"
        end
    }

    if max_topics < 4 do
      Mix.shell().info("✅ Max topics detected: #{max_topics}")
    end

    if max_or_alternatives < 20 do
      Mix.shell().info("✅ Max OR alternatives detected: #{max_or_alternatives}")
    end

    if max_topics >= 4 and max_or_alternatives >= 20 do
      Mix.shell().info("✅ No topic filter limits detected")
    end

    Mix.shell().info("")
    put_in(results, [:tests, :topic_filters], test_result)
  end

  # Test 4: Log Volume Limits (with real log data)
  defp run_log_volume_test(results, url, chain, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 4: Log Volume Limits (Real Data)")
    Mix.shell().info("=" |> String.duplicate(80))

    case get_busy_contract(chain) do
      nil ->
        Mix.shell().info("⚠️  No known busy contract for chain '#{chain}' - skipping test")
        Mix.shell().info("")

        test_result = %{
          status: :skipped,
          recommendation: "No suitable contract address configured for this chain"
        }

        put_in(results, [:tests, :log_volume], test_result)

      busy_contract ->
        case make_request(url, "eth_blockNumber", [], timeout) do
          {:ok, %{"result" => current_block_hex}} ->
            run_log_volume_test_impl(
              results,
              url,
              busy_contract,
              hex_to_int(current_block_hex),
              timeout
            )

          {:error, reason} ->
            Mix.shell().info("⚠️  Failed to get current block: #{inspect(reason)}")
            Mix.shell().info("")

            test_result = %{
              status: :failed,
              recommendation: "Unable to query current block number"
            }

            put_in(results, [:tests, :log_volume], test_result)

          {:ok, %{"error" => error}} ->
            Mix.shell().info("⚠️  Error getting block number: #{error["message"]}")
            Mix.shell().info("")

            test_result = %{
              status: :failed,
              recommendation: "Unable to query current block number"
            }

            put_in(results, [:tests, :log_volume], test_result)
        end
    end
  end

  defp run_log_volume_test_impl(results, url, busy_contract, current_block, timeout) do
    # Binary search to find max block range that returns actual logs
    Mix.shell().info("Searching for log volume limits using #{busy_contract}...")

    # Start with reasonable ranges
    test_ranges = [100, 500, 1000, 2000, 5000, 10000]

    max_log_range =
      Enum.reduce_while(test_ranges, nil, fn range, _acc ->
        from_block = current_block - range
        to_block = current_block - 1

        params = [
          %{
            "fromBlock" => int_to_hex(from_block),
            "toBlock" => int_to_hex(to_block),
            "address" => busy_contract,
            "topics" => [@transfer_topic]
          }
        ]

        case make_request(url, "eth_getLogs", params, timeout * 2) do
          {:ok, %{"result" => logs}} when is_list(logs) ->
            log_count = length(logs)
            Mix.shell().info("  ✓ #{range} blocks: OK (#{log_count} logs)")
            {:cont, {range, log_count}}

          {:ok, %{"error" => error}} ->
            if is_log_volume_error?(error) or is_block_range_error?(error) do
              Mix.shell().info("  ✗ #{range} blocks: VOLUME LIMIT")
              {:halt, :limited}
            else
              Mix.shell().info("  ? #{range} blocks: Other error - #{error["message"]}")
              {:cont, nil}
            end

          {:error, reason} ->
            Mix.shell().info("  ? #{range} blocks: Request failed - #{inspect(reason)}")
            {:cont, nil}
        end
      end)

    test_result =
      case max_log_range do
        {range, log_count} ->
          %{
            status: :tested,
            max_block_range_with_logs: range,
            sample_log_count: log_count,
            recommendation:
              "Tested up to #{range} blocks with #{log_count} logs - no volume limit"
          }

        :limited ->
          %{
            status: :limited,
            recommendation: "Log volume limits detected - consider smaller ranges"
          }

        nil ->
          %{
            status: :unknown,
            recommendation: "Unable to determine log volume limits"
          }
      end

    Mix.shell().info("✅ Log volume test complete")
    Mix.shell().info("")
    put_in(results, [:tests, :log_volume], test_result)
  end

  # Test 5: Batch Request Support
  defp run_batch_request_test(results, url, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 5: Batch Request Support")
    Mix.shell().info("=" |> String.duplicate(80))

    # Test batch sizes: 10, 50, 100
    test_sizes = [10, 50, 100]

    {max_batch_size, first_failure, server_errors} =
      Enum.reduce_while(test_sizes, {0, nil, 0}, fn size, {_acc, _fail, err_count} ->
        result = test_batch_size(url, size, timeout)

        case result do
          {:ok, actual_size} ->
            Mix.shell().info("  ✓ Batch size #{size}: OK (#{actual_size} responses)")
            {:cont, {size, nil, err_count}}

          {:partial, actual_size} ->
            Mix.shell().info("  ⚠️  Batch size #{size}: Partial response (#{actual_size}/#{size})")
            {:halt, {size - 10, size, err_count}}

          {:server_error, status} ->
            Mix.shell().info("  ⚠️  Batch size #{size}: Server error (HTTP #{status})")
            {:cont, {size, nil, err_count + 1}}

          {:error, reason} ->
            Mix.shell().info("  ✗ Batch size #{size}: #{reason}")
            {:halt, {size - 10, size, err_count}}
        end
      end)

    # If we have a working size and a failing size, binary search for exact limit
    final_batch_size =
      if first_failure && max_batch_size > 0 && first_failure - max_batch_size > 10 do
        Mix.shell().info("Refining batch limit between #{max_batch_size} and #{first_failure}...")
        binary_search_batch_size(url, max_batch_size, first_failure, timeout)
      else
        max_batch_size
      end

    test_result =
      cond do
        server_errors >= 2 ->
          %{
            status: :inconclusive,
            server_errors: server_errors,
            recommendation: "Too many server errors to determine batch support"
          }

        final_batch_size >= 100 ->
          %{
            status: :supported,
            max_batch_size: final_batch_size,
            recommendation: "Batch requests supported (tested up to #{final_batch_size})"
          }

        final_batch_size > 0 ->
          %{
            status: :limited,
            max_batch_size: final_batch_size,
            recommendation: "Batch requests limited to ~#{final_batch_size}"
          }

        true ->
          %{
            status: :not_supported,
            recommendation: "Batch requests not supported"
          }
      end

    cond do
      server_errors >= 2 ->
        Mix.shell().info("⚠️  Too many server errors to determine batch support")

      final_batch_size > 0 ->
        Mix.shell().info("✅ Batch requests supported (max size: ~#{final_batch_size})")

      true ->
        Mix.shell().info("⚠️  Batch requests not supported")
    end

    Mix.shell().info("")
    put_in(results, [:tests, :batch_requests], test_result)
  end

  defp test_batch_size(url, size, timeout) do
    batch_requests =
      for i <- 1..size do
        %{
          jsonrpc: "2.0",
          method: "eth_blockNumber",
          params: [],
          id: i
        }
      end

    body = Jason.encode!(batch_requests)

    request =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}],
        body
      )

    case Finch.request(request, LimitDiscovery.Finch, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, responses} when is_list(responses) ->
            if length(responses) == size do
              {:ok, size}
            else
              {:partial, length(responses)}
            end

          {:ok, %{"error" => error}} ->
            {:error, Map.get(error, "message", "Error response")}

          _ ->
            {:error, "Unexpected response format"}
        end

      {:ok, %{status: status}} when status >= 500 ->
        {:server_error, status}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp binary_search_batch_size(_url, lower, upper, _timeout) when upper - lower <= 5 do
    lower
  end

  defp binary_search_batch_size(url, lower, upper, timeout) do
    mid = div(lower + upper, 2)

    case test_batch_size(url, mid, timeout) do
      {:ok, _} ->
        Mix.shell().info("  ✓ Batch size #{mid}: OK")
        binary_search_batch_size(url, mid, upper, timeout)

      {:partial, _} ->
        Mix.shell().info("  ⚠️  Batch size #{mid}: Partial")
        binary_search_batch_size(url, lower, mid, timeout)

      {:error, _} ->
        Mix.shell().info("  ✗ Batch size #{mid}: Failed")
        binary_search_batch_size(url, lower, mid, timeout)

      {:server_error, _} ->
        Mix.shell().info("  ? Batch size #{mid}: Server error")
        lower
    end
  end

  # Test 6: Block Parameter Support
  defp run_block_params_test(results, url, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 6: Special Block Parameter Support")
    Mix.shell().info("=" |> String.duplicate(80))

    # Test special block parameters for eth_getBlockByNumber
    block_params = ["earliest", "latest", "pending", "safe", "finalized"]

    Mix.shell().info("Testing eth_getBlockByNumber...")

    {supported_getblock_params, getblock_server_errors} =
      Enum.reduce(block_params, {[], 0}, fn param, {acc, err_count} ->
        params = [param, false]

        case make_request(url, "eth_getBlockByNumber", params, timeout) do
          {:ok, %{"result" => block}} when is_map(block) ->
            Mix.shell().info("  ✓ '#{param}': Supported")
            {[param | acc], err_count}

          {:ok, %{"result" => nil}} ->
            Mix.shell().info("  ⚠️  '#{param}': Returns null (may not be supported)")
            {acc, err_count}

          {:ok, %{"error" => error}} ->
            if is_invalid_param_error?(error) do
              Mix.shell().info("  ✗ '#{param}': Not supported")
              {acc, err_count}
            else
              msg = Map.get(error, "message", inspect(error))
              Mix.shell().info("  ✗ '#{param}': #{msg}")
              {acc, err_count}
            end

          {:server_error, status} ->
            Mix.shell().info("  ⚠️  '#{param}': Server error (HTTP #{status})")
            {acc, err_count + 1}

          {:error, reason} ->
            Mix.shell().info("  ✗ '#{param}': #{inspect(reason)}")
            {acc, err_count}
        end
      end)

    # Test special block parameters for eth_getLogs
    Mix.shell().info("")
    Mix.shell().info("Testing eth_getLogs...")

    {supported_getlogs_params, getlogs_server_errors} =
      Enum.reduce(block_params, {[], 0}, fn param, {acc, err_count} ->
        params = [
          %{
            "fromBlock" => param,
            "toBlock" => param,
            "address" => "0x0000000000000000000000000000000000000000"
          }
        ]

        case make_request(url, "eth_getLogs", params, timeout) do
          {:ok, %{"result" => _logs}} ->
            Mix.shell().info("  ✓ '#{param}': Supported")
            {[param | acc], err_count}

          {:ok, %{"error" => error}} ->
            if is_invalid_param_error?(error) do
              Mix.shell().info("  ✗ '#{param}': Not supported")
              {acc, err_count}
            else
              msg = Map.get(error, "message", inspect(error))
              Mix.shell().info("  ✗ '#{param}': #{msg}")
              {acc, err_count}
            end

          {:server_error, status} ->
            Mix.shell().info("  ⚠️  '#{param}': Server error (HTTP #{status})")
            {acc, err_count + 1}

          {:error, reason} ->
            Mix.shell().info("  ✗ '#{param}': #{inspect(reason)}")
            {acc, err_count}
        end
      end)

    server_errors = getblock_server_errors + getlogs_server_errors

    test_result =
      cond do
        server_errors >= 5 ->
          %{
            status: :inconclusive,
            server_errors: server_errors,
            recommendation: "Too many server errors to determine block parameter support"
          }

        true ->
          %{
            status: :tested,
            eth_getBlockByNumber: %{
              supported: Enum.reverse(supported_getblock_params),
              total_tested: length(block_params)
            },
            eth_getLogs: %{
              supported: Enum.reverse(supported_getlogs_params),
              total_tested: length(block_params)
            },
            recommendation:
              build_block_param_recommendation(
                supported_getblock_params,
                supported_getlogs_params,
                block_params
              )
          }
      end

    Mix.shell().info("")
    Mix.shell().info("✅ Block parameter test complete")
    Mix.shell().info("")
    put_in(results, [:tests, :block_params], test_result)
  end

  defp build_block_param_recommendation(getblock_supported, getlogs_supported, all_params) do
    getblock_count = length(getblock_supported)
    getlogs_count = length(getlogs_supported)
    total = length(all_params)

    cond do
      getblock_count == total && getlogs_count == total ->
        "All block parameters supported for both methods"

      getblock_count == total ->
        "All parameters supported for eth_getBlockByNumber, limited support for eth_getLogs"

      getlogs_count == total ->
        "All parameters supported for eth_getLogs, limited support for eth_getBlockByNumber"

      getblock_count > 0 || getlogs_count > 0 ->
        "Partial block parameter support - check individual methods"

      true ->
        "No special block parameters supported"
    end
  end

  # Test 7: Archive Node Support
  defp run_archive_support_test(results, url, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 7: Archive Node Support")
    Mix.shell().info("=" |> String.duplicate(80))

    # Try to query very old block (block 100)
    # Block 100
    old_block = "0x64"

    params = [old_block, false]

    updated_results =
      case make_request(url, "eth_getBlockByNumber", params, timeout) do
        {:server_error, status} ->
          Mix.shell().info("⚠️  Server error (HTTP #{status}) - cannot determine archive support")

          test_result = %{
            status: :inconclusive,
            recommendation: "Server error prevented archive support testing"
          }

          put_in(results, [:tests, :archive_support], test_result)

        {:ok, %{"result" => nil}} ->
          Mix.shell().info("⚠️  Block 100 returned null - likely not an archive node")

          test_result = %{
            status: :non_archive,
            recommendation: "Provider does not support archive data"
          }

          put_in(results, [:tests, :archive_support], test_result)

        {:ok, %{"result" => block}} when is_map(block) ->
          Mix.shell().info("✅ Archive node - successfully retrieved block 100")

          # Try state query on old block
          balance_params = [
            "0x0000000000000000000000000000000000000000",
            old_block
          ]

          case make_request(url, "eth_getBalance", balance_params, timeout) do
            {:ok, %{"result" => _}} ->
              Mix.shell().info("✅ Archive state queries supported")

              test_result = %{
                status: :full_archive,
                recommendation: "Full archive node support"
              }

              put_in(results, [:tests, :archive_support], test_result)

            {:ok, %{"error" => _}} ->
              Mix.shell().info("⚠️  Archive blocks but not archive state")

              test_result = %{
                status: :partial_archive,
                recommendation: "Archive blocks only, no archive state"
              }

              put_in(results, [:tests, :archive_support], test_result)

            {:error, _} ->
              test_result = %{
                status: :unknown,
                recommendation: "Unable to determine archive support"
              }

              put_in(results, [:tests, :archive_support], test_result)
          end

        {:ok, %{"error" => error}} ->
          Mix.shell().info("⚠️  Error querying old block: #{error["message"]}")

          test_result = %{
            status: :non_archive,
            error: error["message"],
            recommendation: "Provider does not support archive data"
          }

          put_in(results, [:tests, :archive_support], test_result)

        {:error, reason} ->
          Mix.shell().info("⚠️  Request failed: #{inspect(reason)}")

          test_result = %{
            status: :unknown,
            recommendation: "Unable to determine archive support"
          }

          put_in(results, [:tests, :archive_support], test_result)
      end

    Mix.shell().info("")
    updated_results
  end

  # Test 8: Rate Limiting
  defp run_rate_limit_test(results, url, timeout) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 8: Rate Limit Detection")
    Mix.shell().info("=" |> String.duplicate(80))

    # Send 100 requests as fast as possible
    num_requests = 100
    Mix.shell().info("Sending #{num_requests} rapid requests...")

    start_time = System.monotonic_time(:millisecond)

    task_results =
      1..num_requests
      |> Task.async_stream(
        fn _i ->
          case make_request(url, "eth_blockNumber", [], timeout) do
            {:ok, %{"error" => error}} -> {:error, error}
            {:ok, _} -> :ok
            {:server_error, status} -> {:server_error, status}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: 50,
        timeout: timeout + 1000
      )
      |> Enum.to_list()

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    successful =
      Enum.count(task_results, fn
        {:ok, :ok} -> true
        _ -> false
      end)

    rate_limited =
      Enum.count(task_results, fn
        {:ok, {:error, error}} when is_map(error) ->
          is_rate_limit_error?(error)

        _ ->
          false
      end)

    # Categorize all failures by type
    failure_breakdown =
      Enum.reduce(task_results, %{}, fn result, acc ->
        case result do
          {:ok, :ok} ->
            acc

          {:ok, {:server_error, status}} ->
            Map.update(acc, "HTTP #{status}", 1, &(&1 + 1))

          {:ok, {:error, error}} when is_map(error) ->
            msg = Map.get(error, "message", inspect(error))
            Map.update(acc, msg, 1, &(&1 + 1))

          {:ok, {:error, reason}} ->
            Map.update(acc, inspect(reason), 1, &(&1 + 1))

          {:exit, reason} ->
            Map.update(acc, "Task timeout/exit: #{inspect(reason)}", 1, &(&1 + 1))

          other ->
            Map.update(acc, "Unknown: #{inspect(other)}", 1, &(&1 + 1))
        end
      end)

    server_errors =
      Enum.reduce(failure_breakdown, 0, fn {key, count}, acc ->
        if String.starts_with?(key, "HTTP 5"), do: acc + count, else: acc
      end)

    requests_per_second =
      if duration > 0 do
        Float.round(num_requests / (duration / 1000), 2)
      else
        0
      end

    success_rate = Float.round(successful / num_requests * 100, 1)
    failed = num_requests - successful

    Mix.shell().info("✅ Completed: #{successful}/#{num_requests} (#{success_rate}%)")

    if failed > 0 do
      Mix.shell().info("❌ Failed: #{failed}")
    end

    Mix.shell().info("📊 Rate: #{requests_per_second} req/s")
    Mix.shell().info("⏱️  Duration: #{duration}ms")

    # Show failure breakdown if there were failures
    if map_size(failure_breakdown) > 0 do
      Mix.shell().info("")
      Mix.shell().info("Failure Breakdown:")

      failure_breakdown
      # Sort by count descending
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.each(fn {error, count} ->
        pct = Float.round(count / num_requests * 100, 1)
        Mix.shell().info("  • #{error}: #{count} (#{pct}%)")
      end)
    end

    test_result =
      cond do
        rate_limited > 0 ->
          Mix.shell().info("")
          Mix.shell().info("⚠️  Rate limited: #{rate_limited} requests")

          %{
            status: :rate_limited,
            successful: successful,
            rate_limited: rate_limited,
            server_errors: server_errors,
            failure_breakdown: failure_breakdown,
            success_rate: success_rate,
            requests_per_second: requests_per_second,
            recommendation: "Provider has rate limiting - consider request throttling"
          }

        success_rate < 95.0 ->
          Mix.shell().info("")

          Mix.shell().info(
            "⚠️  Low success rate (#{success_rate}%) - potential reliability issues"
          )

          %{
            status: :potential_issues,
            successful: successful,
            server_errors: server_errors,
            failure_breakdown: failure_breakdown,
            success_rate: success_rate,
            requests_per_second: requests_per_second,
            recommendation: "Success rate below 95% - provider may have reliability issues"
          }

        true ->
          Mix.shell().info("")
          Mix.shell().info("✅ No rate limiting detected")

          %{
            status: :no_limit,
            successful: successful,
            success_rate: success_rate,
            requests_per_second: requests_per_second,
            recommendation: "No rate limiting detected in burst test"
          }
      end

    Mix.shell().info("")

    put_in(results, [:tests, :rate_limit], test_result)
  end

  # Test 9: Error Pattern Analysis
  defp analyze_error_patterns(results) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("TEST 9: Error Summary")
    Mix.shell().info("=" |> String.duplicate(80))

    # Collect error data from all tests
    all_errors = []

    # Address count errors
    all_errors =
      if addr_test = results.tests[:address_count] do
        if error_details = addr_test[:error_breakdown] do
          Enum.reduce(error_details, all_errors, fn {error, count}, acc ->
            [{:address_count, error, count} | acc]
          end)
        else
          all_errors
        end
      else
        all_errors
      end

    # Rate limit errors
    all_errors =
      if rate_test = results.tests[:rate_limit] do
        if error_details = rate_test[:failure_breakdown] do
          Enum.reduce(error_details, all_errors, fn {error, count}, acc ->
            [{:rate_limit, error, count} | acc]
          end)
        else
          all_errors
        end
      else
        all_errors
      end

    if length(all_errors) > 0 do
      Mix.shell().info("Errors encountered during testing:")
      Mix.shell().info("")

      # Group by test
      Enum.group_by(all_errors, fn {test, _error, _count} -> test end)
      |> Enum.each(fn {test_name, errors} ->
        Mix.shell().info("#{test_name}:")

        Enum.each(errors, fn {_test, error, count} ->
          Mix.shell().info("  • #{error}: #{count} occurrence(s)")
        end)

        Mix.shell().info("")
      end)
    else
      Mix.shell().info("No errors encountered during testing")
      Mix.shell().info("")
    end

    error_analysis = %{
      status: :analyzed,
      total_unique_errors: length(all_errors),
      recommendation:
        if length(all_errors) > 0 do
          "Review error details above to distinguish capability vs transient errors"
        else
          "Provider responded successfully to all tests"
        end
    }

    put_in(results, [:tests, :error_patterns], error_analysis)
  end

  # Helper: Make JSON-RPC request
  # Returns {:ok, response} | {:error, reason} | {:server_error, status}
  defp make_request(url, method, params, timeout) do
    request_body = %{
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: 1
    }

    body = Jason.encode!(request_body)

    request =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}],
        body
      )

    case Finch.request(request, LimitDiscovery.Finch, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %{status: status}} when status >= 500 ->
        # 5xx = Server error (unavailable, not a feature limitation)
        {:server_error, status}

      {:ok, %{status: status}} ->
        # 4xx = Client error (might indicate feature not supported)
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # Helper: Check if error is block range related
  defp is_block_range_error?(%{"message" => message}) when is_binary(message) do
    message = String.downcase(message)

    String.contains?(message, "block range") or
      String.contains?(message, "range limit") or
      String.contains?(message, "too many blocks") or
      String.contains?(message, "exceed") or
      (String.contains?(message, "max") and String.contains?(message, "block"))
  end

  defp is_block_range_error?(_), do: false

  # Helper: Check if error is address limit related
  defp is_address_limit_error?(%{"message" => message}) when is_binary(message) do
    message = String.downcase(message)

    String.contains?(message, "address") and
      (String.contains?(message, "limit") or
         String.contains?(message, "too many") or
         String.contains?(message, "exceed"))
  end

  defp is_address_limit_error?(_), do: false

  # Helper: Check if error is rate limit related
  defp is_rate_limit_error?(%{"message" => message}) when is_binary(message) do
    message = String.downcase(message)

    String.contains?(message, "rate limit") or
      String.contains?(message, "too many requests") or
      String.contains?(message, "throttle") or
      String.contains?(message, "429")
  end

  defp is_rate_limit_error?(%{"code" => code}) when code in [429, -32005] do
    true
  end

  defp is_rate_limit_error?(_), do: false

  # Helper: Check if error is topic complexity related
  defp is_topic_complexity_error?(%{"message" => message}) when is_binary(message) do
    message = String.downcase(message)

    String.contains?(message, "topic") and
      (String.contains?(message, "limit") or
         String.contains?(message, "too many") or
         String.contains?(message, "complex") or
         String.contains?(message, "exceed"))
  end

  defp is_topic_complexity_error?(_), do: false

  # Helper: Check if error is log volume related
  defp is_log_volume_error?(%{"message" => message}) when is_binary(message) do
    message = String.downcase(message)

    (String.contains?(message, "log") and String.contains?(message, "limit")) or
      String.contains?(message, "too many logs") or
      (String.contains?(message, "result") and String.contains?(message, "limit")) or
      (String.contains?(message, "response") and String.contains?(message, "too large"))
  end

  defp is_log_volume_error?(_), do: false

  # Helper: Check if error is invalid parameter related
  defp is_invalid_param_error?(%{"message" => message}) when is_binary(message) do
    message = String.downcase(message)

    (String.contains?(message, "invalid") and
       (String.contains?(message, "param") or
          String.contains?(message, "block"))) or
      String.contains?(message, "unsupported") or
      String.contains?(message, "unknown block")
  end

  defp is_invalid_param_error?(%{"code" => code}) when code == -32602 do
    true
  end

  defp is_invalid_param_error?(_), do: false

  # Helper: Get busy contract address for chain
  # Returns nil for unknown chains so tests can gracefully skip
  defp get_busy_contract("ethereum"), do: @ethereum_usdc
  defp get_busy_contract("base"), do: @base_usdc
  defp get_busy_contract("arbitrum"), do: @arbitrum_usdc
  defp get_busy_contract("optimism"), do: @optimism_usdc
  defp get_busy_contract("polygon"), do: @polygon_usdc

  # Testnets - use mainnet contracts as fallback (they won't have logs but structure is same)
  defp get_busy_contract("base_sepolia"), do: @base_usdc
  defp get_busy_contract("sepolia"), do: @ethereum_usdc

  # Unknown chains - return nil to skip tests that need real contract data
  defp get_busy_contract(_), do: nil

  # Helper: Convert hex to integer
  defp hex_to_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex_to_int(hex), do: String.to_integer(hex, 16)

  # Helper: Convert integer to hex
  defp int_to_hex(int), do: "0x" <> Integer.to_string(int, 16)

  # Output: Table format
  defp output_table(results) do
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("LIMITATION DISCOVERY SUMMARY")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("Provider: #{results.url}")
    Mix.shell().info("Chain: #{results.chain}")
    Mix.shell().info("Tested: #{Calendar.strftime(results.timestamp, "%Y-%m-%d %H:%M:%S")} UTC")
    Mix.shell().info("")

    # Block Range
    if block_range = results.tests[:block_range] do
      Mix.shell().info("📏 BLOCK RANGE LIMITS")
      Mix.shell().info("   Status: #{block_range.status}")

      if block_range[:max_block_range] do
        Mix.shell().info("   Max Range: #{block_range.max_block_range} blocks")
      end

      Mix.shell().info("   → #{block_range.recommendation}")
      Mix.shell().info("")
    end

    # Address Count
    if address_count = results.tests[:address_count] do
      Mix.shell().info("📍 ADDRESS COUNT LIMITS")
      Mix.shell().info("   Status: #{address_count.status}")

      if address_count.status not in [:inconclusive] && address_count[:max_addresses] do
        Mix.shell().info("   Max Addresses: #{address_count.max_addresses}")
      end

      if address_count[:error_breakdown] && map_size(address_count.error_breakdown) > 0 do
        Mix.shell().info("   Errors encountered:")

        Enum.each(address_count.error_breakdown, fn {error, count} ->
          Mix.shell().info("     • #{error}: #{count}")
        end)
      end

      Mix.shell().info("   → #{address_count.recommendation}")
      Mix.shell().info("")
    end

    # Topic Filters
    if topic_filters = results.tests[:topic_filters] do
      Mix.shell().info("🏷️  TOPIC FILTER COMPLEXITY")
      Mix.shell().info("   Status: #{topic_filters.status}")

      if topic_filters[:max_topics] do
        Mix.shell().info("   Max Topics: #{topic_filters.max_topics}")
      end

      if topic_filters[:max_or_alternatives] do
        Mix.shell().info("   Max OR Alternatives: #{topic_filters.max_or_alternatives}")
      end

      Mix.shell().info("   → #{topic_filters.recommendation}")
      Mix.shell().info("")
    end

    # Log Volume
    if log_volume = results.tests[:log_volume] do
      Mix.shell().info("📊 LOG VOLUME LIMITS")
      Mix.shell().info("   Status: #{log_volume.status}")

      if log_volume[:max_block_range_with_logs] do
        Mix.shell().info("   Tested Range: #{log_volume.max_block_range_with_logs} blocks")
        Mix.shell().info("   Sample Logs: #{log_volume.sample_log_count}")
      end

      Mix.shell().info("   → #{log_volume.recommendation}")
      Mix.shell().info("")
    end

    # Batch Requests
    if batch = results.tests[:batch_requests] do
      Mix.shell().info("📦 BATCH REQUEST SUPPORT")
      Mix.shell().info("   Status: #{batch.status}")

      if batch[:max_batch_size] do
        Mix.shell().info("   Max Batch Size: #{batch.max_batch_size}")
      end

      Mix.shell().info("   → #{batch.recommendation}")
      Mix.shell().info("")
    end

    # Block Parameters
    if block_params = results.tests[:block_params] do
      Mix.shell().info("🔢 SPECIAL BLOCK PARAMETERS")
      Mix.shell().info("   Status: #{block_params.status}")

      if block_params.status == :tested do
        if getblock = block_params[:eth_getBlockByNumber] do
          Mix.shell().info("   eth_getBlockByNumber: #{Enum.join(getblock.supported, ", ")}")
        end

        if getlogs = block_params[:eth_getLogs] do
          Mix.shell().info("   eth_getLogs: #{Enum.join(getlogs.supported, ", ")}")
        end
      end

      Mix.shell().info("   → #{block_params.recommendation}")
      Mix.shell().info("")
    end

    # Archive Support
    if archive = results.tests[:archive_support] do
      Mix.shell().info("🗄️  ARCHIVE NODE SUPPORT")
      Mix.shell().info("   Status: #{archive.status}")
      Mix.shell().info("   → #{archive.recommendation}")
      Mix.shell().info("")
    end

    # Rate Limit
    if rate_limit = results.tests[:rate_limit] do
      Mix.shell().info("⚡ RATE LIMITING")
      Mix.shell().info("   Status: #{rate_limit.status}")
      Mix.shell().info("   Success Rate: #{rate_limit.success_rate}%")
      Mix.shell().info("   Throughput: #{rate_limit.requests_per_second} req/s")

      if rate_limit[:failure_breakdown] && map_size(rate_limit.failure_breakdown) > 0 do
        Mix.shell().info("   Failures:")

        rate_limit.failure_breakdown
        |> Enum.sort_by(fn {_k, v} -> -v end)
        |> Enum.each(fn {error, count} ->
          Mix.shell().info("     • #{error}: #{count}")
        end)
      end

      Mix.shell().info("   → #{rate_limit.recommendation}")
      Mix.shell().info("")
    end

    # Final Recommendation
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("ADAPTER RECOMMENDATION")
    Mix.shell().info("=" |> String.duplicate(80))

    needs_custom_adapter = needs_custom_adapter?(results)

    if needs_custom_adapter do
      Mix.shell().info("🔧 CUSTOM ADAPTER RECOMMENDED")
      Mix.shell().info("")
      Mix.shell().info("Recommended adapter_config:")

      if block_range = results.tests[:block_range] do
        if block_range.max_block_range do
          Mix.shell().info("  max_block_range: #{block_range.max_block_range}")
        end
      end

      if address_count = results.tests[:address_count] do
        if address_count.status == :limited do
          Mix.shell().info("  max_addresses: #{address_count.max_addresses}")
        end
      end
    else
      Mix.shell().info("✅ GENERIC ADAPTER SUFFICIENT")
      Mix.shell().info("")
      Mix.shell().info("No custom adapter needed - provider follows standard JSON-RPC")
    end
  end

  # Output: JSON format
  defp output_json(results) do
    json = Jason.encode!(results, pretty: true)
    Mix.shell().info(json)
  end

  # Output: YAML format for chains.yml
  defp output_yaml(results) do
    Mix.shell().info("# Add to config/chains.yml")
    Mix.shell().info("")

    block_range = results.tests[:block_range]
    address_count = results.tests[:address_count]

    if needs_custom_adapter?(results) do
      Mix.shell().info("  adapter_config:")

      if block_range && block_range.max_block_range do
        Mix.shell().info("    max_block_range: #{block_range.max_block_range}")
      end

      if address_count && address_count.status == :limited do
        Mix.shell().info("    max_addresses: #{address_count.max_addresses}")
      end
    else
      Mix.shell().info("  # No adapter_config needed - use Generic adapter")
    end
  end

  defp needs_custom_adapter?(results) do
    block_range = results.tests[:block_range]
    address_count = results.tests[:address_count]

    (block_range && block_range.status == :limited) or
      (address_count && address_count.status == :limited)
  end
end
