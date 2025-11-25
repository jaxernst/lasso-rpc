defmodule Lasso.Discovery.Probes.Limits do
  @moduledoc """
  Probes RPC provider parameter and capability limits.

  Discovers limits like:
  - Block range limits for eth_getLogs
  - Address count limits
  - Batch request support and limits
  - Archive node support
  - Rate limiting behavior
  """

  alias Lasso.Discovery.{TestParams, ErrorClassifier}

  @available_tests [
    :block_range,
    :address_count,
    :batch_requests,
    :block_params,
    :archive_support,
    :rate_limit
  ]

  @type test_name :: :block_range | :address_count | :batch_requests | :block_params | :archive_support | :rate_limit
  @type test_status :: :limited | :unlimited | :supported | :not_supported | :inconclusive | :skipped
  @type test_result :: %{
          status: test_status(),
          value: term() | nil,
          recommendation: String.t()
        }

  @doc """
  Runs limit discovery tests against a provider URL.

  ## Options

    * `:tests` - List of tests to run (default: all tests)
    * `:chain` - Chain name for test contracts (default: "ethereum")
    * `:timeout` - Request timeout in ms (default: 10000)

  ## Returns

  Map of test names to test results.
  """
  @spec probe(String.t(), keyword()) :: %{test_name() => test_result()}
  def probe(url, opts \\ []) do
    tests = Keyword.get(opts, :tests, @available_tests)
    chain = Keyword.get(opts, :chain, "ethereum")
    timeout = Keyword.get(opts, :timeout, 10_000)

    # Get current block for tests that need it
    current_block = get_current_block(url, timeout)

    Enum.reduce(tests, %{}, fn test, acc ->
      result = run_test(test, url, chain, current_block, timeout)
      Map.put(acc, test, result)
    end)
  end

  @doc """
  Returns the list of available tests.
  """
  @spec available_tests() :: [test_name()]
  def available_tests, do: @available_tests

  # Individual test implementations

  defp run_test(:block_range, url, _chain, current_block, timeout) do
    if current_block do
      test_block_range(url, current_block, timeout)
    else
      %{status: :inconclusive, value: nil, recommendation: "Could not get current block"}
    end
  end

  defp run_test(:address_count, url, _chain, _current_block, timeout) do
    test_address_count(url, timeout)
  end

  defp run_test(:batch_requests, url, _chain, _current_block, timeout) do
    test_batch_requests(url, timeout)
  end

  defp run_test(:block_params, url, _chain, _current_block, timeout) do
    test_block_params(url, timeout)
  end

  defp run_test(:archive_support, url, _chain, _current_block, timeout) do
    test_archive_support(url, timeout)
  end

  defp run_test(:rate_limit, url, _chain, _current_block, timeout) do
    test_rate_limit(url, timeout)
  end

  # Block range limit test using binary search
  defp test_block_range(url, current_block, timeout) do
    test_ranges = [100, 500, 1000, 2000, 5000, 10000]

    # Find first failure
    first_failure =
      Enum.find(test_ranges, fn range ->
        from_block = current_block - range
        to_block = current_block - 1

        params = [
          %{
            "fromBlock" => TestParams.int_to_hex(from_block),
            "toBlock" => TestParams.int_to_hex(to_block)
          }
        ]

        case make_request(url, "eth_getLogs", params, timeout) do
          {:ok, %{"result" => _}} -> false
          {:ok, %{"error" => error}} -> ErrorClassifier.block_range_error?(error)
          _ -> false
        end
      end)

    case first_failure do
      nil ->
        %{status: :unlimited, value: nil, recommendation: "No block range limit detected (tested up to 10000)"}

      limit ->
        # Refine with binary search
        prev_idx = Enum.find_index(test_ranges, &(&1 == limit)) - 1
        lower = if prev_idx >= 0, do: Enum.at(test_ranges, prev_idx), else: 0
        refined = binary_search_block_range(url, current_block, lower, limit, timeout)
        %{status: :limited, value: refined, recommendation: "Set adapter_config: max_block_range: #{refined}"}
    end
  end

  defp binary_search_block_range(_url, _current_block, lower, upper, _timeout) when upper - lower <= 10 do
    lower
  end

  defp binary_search_block_range(url, current_block, lower, upper, timeout) do
    mid = div(lower + upper, 2)
    from_block = current_block - mid
    to_block = current_block - 1

    params = [%{"fromBlock" => TestParams.int_to_hex(from_block), "toBlock" => TestParams.int_to_hex(to_block)}]

    case make_request(url, "eth_getLogs", params, timeout) do
      {:ok, %{"result" => _}} ->
        binary_search_block_range(url, current_block, mid, upper, timeout)

      {:ok, %{"error" => error}} ->
        if ErrorClassifier.block_range_error?(error) do
          binary_search_block_range(url, current_block, lower, mid, timeout)
        else
          mid
        end

      _ ->
        mid
    end
  end

  # Address count limit test
  defp test_address_count(url, timeout) do
    test_counts = [1, 5, 10, 20, 50, 100]

    max_addresses =
      Enum.reduce_while(test_counts, nil, fn count, acc ->
        addresses =
          for i <- 1..count do
            "0x" <> String.pad_leading(Integer.to_string(i, 16), 40, "0")
          end

        params = [%{"fromBlock" => "latest", "toBlock" => "latest", "address" => addresses}]

        case make_request(url, "eth_getLogs", params, timeout) do
          {:ok, %{"result" => _}} ->
            {:cont, count}

          {:ok, %{"error" => error}} ->
            if ErrorClassifier.address_limit_error?(error) do
              {:halt, acc}
            else
              {:cont, acc}
            end

          _ ->
            {:cont, acc}
        end
      end)

    cond do
      max_addresses == nil ->
        %{status: :inconclusive, value: nil, recommendation: "Could not determine address limits"}

      max_addresses < 100 ->
        %{status: :limited, value: max_addresses, recommendation: "Set adapter_config: max_addresses: #{max_addresses}"}

      true ->
        %{status: :unlimited, value: max_addresses, recommendation: "No address limit detected (tested up to 100)"}
    end
  end

  # Batch request support test
  defp test_batch_requests(url, timeout) do
    test_sizes = [10, 50, 100]

    {max_size, _} =
      Enum.reduce_while(test_sizes, {0, nil}, fn size, {_acc, _} ->
        case test_batch_size(url, size, timeout) do
          {:ok, actual} -> {:cont, {size, actual}}
          {:partial, actual} -> {:halt, {actual, :partial}}
          {:error, _} -> {:halt, {0, :error}}
          {:server_error, _} -> {:cont, {0, nil}}
        end
      end)

    cond do
      max_size >= 100 ->
        %{status: :supported, value: max_size, recommendation: "Batch requests supported (tested up to #{max_size})"}

      max_size > 0 ->
        %{status: :limited, value: max_size, recommendation: "Batch requests limited to ~#{max_size}"}

      true ->
        %{status: :not_supported, value: nil, recommendation: "Batch requests not supported"}
    end
  end

  defp test_batch_size(url, size, timeout) do
    batch_requests =
      for i <- 1..size do
        %{jsonrpc: "2.0", method: "eth_blockNumber", params: [], id: i}
      end

    body = Jason.encode!(batch_requests)

    request =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}],
        body
      )

    case Finch.request(request, Lasso.Finch, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, responses} when is_list(responses) ->
            if length(responses) == size, do: {:ok, size}, else: {:partial, length(responses)}

          {:ok, %{"error" => _}} ->
            {:error, "Error response"}

          _ ->
            {:error, "Unexpected response"}
        end

      {:ok, %{status: status}} when status >= 500 ->
        {:server_error, status}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Block parameter support test
  defp test_block_params(url, timeout) do
    params = ["earliest", "latest", "pending", "safe", "finalized"]

    supported =
      Enum.filter(params, fn param ->
        case make_request(url, "eth_getBlockByNumber", [param, false], timeout) do
          {:ok, %{"result" => block}} when is_map(block) -> true
          _ -> false
        end
      end)

    %{
      status: :tested,
      value: supported,
      recommendation:
        if length(supported) == length(params) do
          "All block parameters supported"
        else
          "Supported: #{Enum.join(supported, ", ")}"
        end
    }
  end

  # Archive node support test
  defp test_archive_support(url, timeout) do
    # Query block 100 (very old)
    old_block = "0x64"

    case make_request(url, "eth_getBlockByNumber", [old_block, false], timeout) do
      {:ok, %{"result" => block}} when is_map(block) ->
        # Block exists, test state query
        case make_request(url, "eth_getBalance", [TestParams.zero_address(), old_block], timeout) do
          {:ok, %{"result" => _}} ->
            %{status: :supported, value: :full_archive, recommendation: "Full archive node support"}

          _ ->
            %{status: :supported, value: :partial_archive, recommendation: "Archive blocks but not archive state"}
        end

      {:ok, %{"result" => nil}} ->
        %{status: :not_supported, value: :non_archive, recommendation: "Not an archive node"}

      {:ok, %{"error" => _}} ->
        %{status: :not_supported, value: :non_archive, recommendation: "Not an archive node"}

      _ ->
        %{status: :inconclusive, value: nil, recommendation: "Could not determine archive support"}
    end
  end

  # Rate limit detection test
  defp test_rate_limit(url, timeout) do
    num_requests = 100

    start_time = System.monotonic_time(:millisecond)

    results =
      1..num_requests
      |> Task.async_stream(
        fn _i ->
          case make_request(url, "eth_blockNumber", [], timeout) do
            {:ok, %{"result" => _}} -> :ok
            {:ok, %{"error" => error}} -> {:error, error}
            {:server_error, status} -> {:server_error, status}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: 50,
        timeout: timeout + 1000
      )
      |> Enum.to_list()

    duration = System.monotonic_time(:millisecond) - start_time

    successful = Enum.count(results, fn {:ok, :ok} -> true; _ -> false end)

    rate_limited =
      Enum.count(results, fn
        {:ok, {:error, error}} when is_map(error) -> ErrorClassifier.rate_limit_error?(error)
        _ -> false
      end)

    success_rate = Float.round(successful / num_requests * 100, 1)
    requests_per_second = if duration > 0, do: Float.round(num_requests / (duration / 1000), 2), else: 0

    cond do
      rate_limited > 0 ->
        %{
          status: :limited,
          value: %{rate_limited: rate_limited, success_rate: success_rate, rps: requests_per_second},
          recommendation: "Rate limiting detected - #{rate_limited} requests throttled"
        }

      success_rate < 95.0 ->
        %{
          status: :inconclusive,
          value: %{success_rate: success_rate, rps: requests_per_second},
          recommendation: "Low success rate (#{success_rate}%) - potential reliability issues"
        }

      true ->
        %{
          status: :unlimited,
          value: %{success_rate: success_rate, rps: requests_per_second},
          recommendation: "No rate limiting detected (#{requests_per_second} req/s)"
        }
    end
  end

  # Helper: Get current block number
  defp get_current_block(url, timeout) do
    case make_request(url, "eth_blockNumber", [], timeout) do
      {:ok, %{"result" => hex}} -> TestParams.hex_to_int(hex)
      _ -> nil
    end
  end

  # Helper: Make JSON-RPC request using Lasso's Finch pool
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

    case Finch.request(request, Lasso.Finch, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %{status: status}} when status >= 500 ->
        {:server_error, status}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
