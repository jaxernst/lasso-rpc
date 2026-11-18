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

  alias Lasso.Discovery.{ErrorClassifier, MethodEvidence, Response, TestParams}
  alias Lasso.JSONRPC.Quantity
  alias Lasso.RPC.Transport.HTTP.Client.Finch, as: BoundedHTTP

  @min_archive_depth 128_000
  @block_range_tiers [10, 1_000, 10_000]
  @widest_block_range_tier List.last(@block_range_tiers)

  @available_tests [
    :block_range,
    :address_count,
    :batch_requests,
    :block_params,
    :archive_support,
    :rate_limit
  ]

  @type test_name ::
          :block_range
          | :address_count
          | :batch_requests
          | :block_params
          | :archive_support
          | :rate_limit
  @type test_status ::
          :limited | :unlimited | :supported | :not_supported | :inconclusive | :skipped
  @type test_result :: %{
          status: test_status(),
          value: term() | nil,
          recommendation: String.t()
        }

  @doc """
  Runs limit discovery tests against a provider URL.

  ## Options

    * `:tests` - List of tests to run (default: all tests)
    * `:chain` - Legacy label accepted for compatibility; archive depth uses the live head
    * `:timeout` - Request timeout in ms (default: 10000)

  ## Returns

  Map of test names to test results.
  """
  @spec probe(String.t(), keyword()) :: %{test_name() => test_result()}
  def probe(url, opts \\ []) do
    context = %{
      on_throttle: Keyword.get(opts, :on_throttle),
      capabilities: Keyword.get(opts, :provider_capabilities, %{})
    }

    default_tests =
      if Keyword.get(opts, :user_initiated, false),
        do: @available_tests -- [:rate_limit],
        else: @available_tests

    tests = Keyword.get(opts, :tests, default_tests)
    chain = Keyword.get(opts, :chain, "ethereum")
    timeout = Keyword.get(opts, :timeout, 10_000)

    # Get current block for tests that need it
    current_block = get_current_block(url, timeout)

    Enum.reduce(tests, %{}, fn test, acc ->
      result = run_test(test, url, chain, current_block, timeout, context)
      Map.put(acc, test, result)
    end)
  end

  @doc """
  Returns the list of available tests.
  """
  @spec available_tests() :: [test_name()]
  def available_tests, do: @available_tests

  # Individual test implementations

  defp run_test(:block_range, url, _chain, current_block, timeout, context) do
    if current_block do
      test_block_range(url, current_block, timeout, context)
    else
      %{status: :inconclusive, value: nil, recommendation: "Could not get current block"}
    end
  end

  defp run_test(:address_count, url, _chain, _current_block, timeout, _context) do
    test_address_count(url, timeout)
  end

  defp run_test(:batch_requests, url, _chain, _current_block, timeout, _context) do
    test_batch_requests(url, timeout)
  end

  defp run_test(:block_params, url, _chain, _current_block, timeout, _context) do
    test_block_params(url, timeout)
  end

  defp run_test(:archive_support, url, _chain, current_block, timeout, context) do
    test_archive_support(url, current_block, timeout, context)
  end

  defp run_test(:rate_limit, url, _chain, _current_block, timeout, _context) do
    test_rate_limit(url, timeout)
  end

  # A range limit is reported only after a narrower tier succeeds and a wider
  # tier receives a recognized range rejection. Empty or failed probes prove
  # neither an unlimited range nor a specific ceiling.
  defp test_block_range(url, current_block, timeout, context) do
    @block_range_tiers
    |> Enum.filter(&(&1 <= current_block - 1))
    |> Enum.reduce_while({:none, nil}, fn tier, {_outcome, last_success} ->
      case probe_block_range_tier(url, current_block, tier, timeout, context.on_throttle) do
        :ok ->
          {:cont, {:ok, tier}}

        {:rejected, error} ->
          {:halt, {range_failure(error, context.capabilities), last_success}}

        :transient ->
          {:halt, {:inconclusive, last_success}}
      end
    end)
    |> block_range_result()
  end

  defp probe_block_range_tier(url, current_block, tier, timeout, on_throttle) do
    to_block = max(current_block - 1, 0)
    from_block = max(to_block - tier, 0)

    params = [
      %{
        "fromBlock" => TestParams.int_to_hex(from_block),
        "toBlock" => TestParams.int_to_hex(to_block),
        "address" => "0x0000000000000000000000000000000000000001"
      }
    ]

    case make_request(url, "eth_getLogs", params, timeout) do
      {:ok, %{"result" => value}} ->
        if MethodEvidence.classify("eth_getLogs", value) == :supported,
          do: :ok,
          else: :transient

      {:ok, %{"error" => error}} ->
        {:rejected, error}

      {:rate_limited, _} ->
        maybe_signal_throttle(on_throttle)
        :transient

      _ ->
        :transient
    end
  end

  defp range_failure(error, capabilities) do
    case ErrorClassifier.classify(error, capabilities) do
      {:block_range, _} -> :too_wide
      _ -> :inconclusive
    end
  end

  defp block_range_result({:ok, tier}) when tier >= @widest_block_range_tier do
    %{
      status: :unlimited,
      value: nil,
      recommendation: "No block range limit detected (verified to #{tier})"
    }
  end

  defp block_range_result({:too_wide, last_success}) when is_integer(last_success) do
    %{
      status: :limited,
      value: last_success,
      recommendation: "Set capabilities.limits.max_block_range: #{last_success}"
    }
  end

  defp block_range_result(_) do
    %{
      status: :inconclusive,
      value: nil,
      recommendation: "Could not determine block range limit"
    }
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
        %{
          status: :limited,
          value: max_addresses,
          recommendation: "Set capabilities.limits.max_addresses: #{max_addresses}"
        }

      true ->
        %{
          status: :unlimited,
          value: max_addresses,
          recommendation: "No address limit detected (tested up to 100)"
        }
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
        %{
          status: :supported,
          value: max_size,
          recommendation: "Batch requests supported (tested up to #{max_size})"
        }

      max_size > 0 ->
        %{
          status: :limited,
          value: max_size,
          recommendation: "Batch requests limited to ~#{max_size}"
        }

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

    BoundedHTTP.bounded_request(request, [receive_timeout: timeout], fn
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, responses} when is_list(responses) ->
            if valid_batch_response?(responses, size),
              do: {:ok, size},
              else: {:error, :invalid_batch_response}

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
    end)
  end

  defp valid_batch_response?(responses, size) when length(responses) == size do
    ids =
      Enum.map(responses, fn
        %{"id" => id} -> id
        _ -> nil
      end)

    Enum.sort(ids) == Enum.to_list(1..size) and
      Enum.all?(responses, fn response ->
        match?({:ok, _}, Response.validate(response, Map.get(response, "id")))
      end)
  end

  defp valid_batch_response?(_responses, _size), do: false

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

  defp test_archive_support(_url, nil, _timeout, _context) do
    %{
      status: :inconclusive,
      value: nil,
      recommendation: "Could not read chain height, so archive depth is unknown"
    }
  end

  defp test_archive_support(_url, current_block, _timeout, _context)
       when current_block <= @min_archive_depth do
    %{
      status: :inconclusive,
      value: nil,
      recommendation: "Chain is too young to establish archive retention depth"
    }
  end

  defp test_archive_support(url, current_block, timeout, context) do
    midpoint = div(current_block, 2)
    floor_block = max(current_block - @min_archive_depth, 1)
    deep_block = midpoint |> min(floor_block) |> max(1)

    case probe_state_retention(url, deep_block, timeout, context.capabilities) do
      :unknown ->
        %{
          status: :inconclusive,
          value: nil,
          recommendation: "Provider did not answer a current-state read; archive depth unknown"
        }

      state ->
        classify_archive(
          state,
          probe_log_retention(url, deep_block, timeout, context.capabilities),
          deep_block
        )
    end
  end

  defp probe_state_retention(url, deep_block, timeout, capabilities) do
    if state_readable?(url, "latest", timeout) do
      deep = TestParams.int_to_hex(deep_block)

      case make_request(url, "eth_getBalance", [TestParams.zero_address(), deep], timeout) do
        {:ok, %{"result" => value}} ->
          if MethodEvidence.quantity?(value), do: :retained, else: :unknown

        {:ok, %{"error" => error}} ->
          depth_failure(error, capabilities)

        _ ->
          :unknown
      end
    else
      :unknown
    end
  end

  defp state_readable?(url, block, timeout) do
    case make_request(url, "eth_getBalance", [TestParams.zero_address(), block], timeout) do
      {:ok, %{"result" => value}} -> MethodEvidence.quantity?(value)
      _ -> false
    end
  end

  defp probe_log_retention(url, deep_block, timeout, capabilities) do
    params = [
      %{
        "fromBlock" => TestParams.int_to_hex(deep_block),
        "toBlock" => TestParams.int_to_hex(deep_block + 10),
        "topics" => [TestParams.transfer_topic()]
      }
    ]

    case make_request(url, "eth_getLogs", params, timeout) do
      {:ok, %{"result" => [_ | _] = logs}} ->
        if MethodEvidence.classify("eth_getLogs", logs) == :supported,
          do: :retained,
          else: :unknown

      {:ok, %{"error" => error}} ->
        depth_failure(error, capabilities)

      _ ->
        :unknown
    end
  end

  defp depth_failure(error, capabilities) do
    case ErrorClassifier.classify(error, capabilities) do
      {:state_unavailable, _} -> :pruned
      _ -> :unknown
    end
  end

  defp classify_archive(:retained, :retained, depth) do
    %{
      status: :supported,
      value: :full_archive,
      observed_state_block: depth,
      observed_log_block: depth,
      recommendation: "Serves archive state and logs at block #{depth}"
    }
  end

  defp classify_archive(:retained, _logs, depth) do
    %{
      status: :supported,
      value: :archive_state_only,
      observed_state_block: depth,
      recommendation: "Serves archive state at block #{depth}; log retention unconfirmed"
    }
  end

  defp classify_archive(:pruned, :retained, depth) do
    %{
      status: :supported,
      value: :archive_logs_only,
      observed_log_block: depth,
      unavailable_state_block: depth,
      recommendation: "Serves logs at block #{depth}; state at that block is unavailable"
    }
  end

  defp classify_archive(:pruned, _logs, depth) do
    %{
      status: :not_supported,
      value: :non_archive,
      unavailable_state_block: depth,
      recommendation: "State at block #{depth} has been pruned"
    }
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
            {:rate_limited, _} -> :rate_limited
            {:server_error, status} -> {:server_error, status}
            {:error, reason} -> {:error, reason}
          end
        end,
        max_concurrency: 50,
        timeout: timeout + 1000
      )
      |> Enum.to_list()

    duration = System.monotonic_time(:millisecond) - start_time

    successful =
      Enum.count(results, fn
        {:ok, :ok} -> true
        _ -> false
      end)

    rate_limited =
      Enum.count(results, fn
        {:ok, :rate_limited} -> true
        {:ok, {:error, error}} when is_map(error) -> ErrorClassifier.rate_limit_error?(error)
        _ -> false
      end)

    success_rate = Float.round(successful / num_requests * 100, 1)

    requests_per_second =
      if duration > 0, do: Float.round(num_requests / (duration / 1000), 2), else: 0

    cond do
      rate_limited > 0 ->
        %{
          status: :limited,
          value: %{
            rate_limited: rate_limited,
            success_rate: success_rate,
            rps: requests_per_second
          },
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
      {:ok, %{"result" => hex}} ->
        case Quantity.decode(hex) do
          {:ok, height} -> height
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Reject malformed envelopes and mismatched IDs before recording probe evidence.
  defp make_request(url, method, params, timeout) do
    case Response.request_decoded(%{url: url}, method, params, timeout: timeout) do
      {:error, {:rate_limit, payload}} ->
        {:rate_limited, payload}

      {:error, {:server_error, payload}} ->
        {:server_error, Map.get(payload, :status, :unavailable)}

      other ->
        other
    end
  rescue
    e -> {:error, e}
  end

  defp maybe_signal_throttle(on_throttle) when is_function(on_throttle, 1) do
    on_throttle.(%{retry_after_ms: nil, phase: :limits})
  end

  defp maybe_signal_throttle(_), do: :ok
end
