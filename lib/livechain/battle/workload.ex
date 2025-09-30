defmodule Livechain.Battle.Workload do
  @moduledoc """
  Workload generation for battle testing.

  Generates realistic load patterns:
  - HTTP requests at constant or variable rates
  - WebSocket subscriptions
  - Mixed method distributions
  """

  require Logger

  @doc """
  Generates HTTP requests at a constant rate.

  ## Options

  - `:chain` - Target chain name (required)
  - `:method` - RPC method to call (required)
  - `:params` - RPC params (default: [])
  - `:rate` - Requests per second (required)
  - `:duration` - Test duration in milliseconds (required)
  - `:strategy` - Routing strategy (default: nil, uses chain default)
  - `:timeout` - Request timeout in milliseconds (default: 5000)

  ## Example

      Workload.http_constant(
        chain: "testchain",
        method: "eth_blockNumber",
        rate: 10,
        duration: 30_000
      )
  """
  def http_constant(opts) do
    chain = Keyword.fetch!(opts, :chain)
    method = Keyword.fetch!(opts, :method)
    params = Keyword.get(opts, :params, [])
    rate = Keyword.fetch!(opts, :rate)
    duration = Keyword.fetch!(opts, :duration)
    strategy = Keyword.get(opts, :strategy)
    timeout = Keyword.get(opts, :timeout, 5_000)

    interval_ms = trunc(1000 / rate)
    num_requests = trunc(duration / interval_ms)

    Logger.info(
      "Starting HTTP workload: #{num_requests} requests over #{duration}ms (#{rate} req/s)"
    )

    start_time = System.monotonic_time(:millisecond)

    # Send requests at constant rate
    for i <- 1..num_requests do
      Task.start(fn ->
        make_http_request(chain, method, params, strategy, timeout, i)
      end)

      # Calculate when next request should be sent
      elapsed = System.monotonic_time(:millisecond) - start_time
      next_request_time = i * interval_ms

      sleep_time = max(0, next_request_time - elapsed)
      if sleep_time > 0, do: Process.sleep(sleep_time)
    end

    # Wait for remaining requests to complete
    remaining = duration - (System.monotonic_time(:millisecond) - start_time)
    if remaining > 0, do: Process.sleep(remaining)

    Logger.info("HTTP workload complete")
    :ok
  end

  @doc """
  Generates HTTP requests with Poisson arrival pattern (more realistic).

  ## Options

  Same as `http_constant/1`, except:
  - `:rate` - Can be `{:poisson, lambda: N}` for Poisson distribution

  ## Example

      Workload.http_poisson(
        chain: "testchain",
        method: "eth_blockNumber",
        rate: {:poisson, lambda: 100},
        duration: 60_000
      )
  """
  def http_poisson(opts) do
    # For Phase 1, just use constant rate
    # Phase 2 will implement proper Poisson distribution
    http_constant(opts)
  end

  @doc """
  Generates HTTP requests with a mix of methods.

  ## Options

  - `:chain` - Target chain name (required)
  - `:methods` - List of {method, weight} tuples (required)
  - `:rate` - Requests per second (required)
  - `:duration` - Test duration in milliseconds (required)
  - `:strategy` - Routing strategy (default: nil)

  ## Example

      Workload.http_mixed(
        chain: "testchain",
        methods: [
          {"eth_blockNumber", 0.4},
          {"eth_getBalance", 0.3},
          {"eth_gasPrice", 0.3}
        ],
        rate: 50,
        duration: 60_000
      )
  """
  def http_mixed(opts) do
    chain = Keyword.fetch!(opts, :chain)
    methods = Keyword.fetch!(opts, :methods)
    rate = Keyword.fetch!(opts, :rate)
    duration = Keyword.fetch!(opts, :duration)
    strategy = Keyword.get(opts, :strategy)
    timeout = Keyword.get(opts, :timeout, 5_000)

    interval_ms = trunc(1000 / rate)
    num_requests = trunc(duration / interval_ms)

    # Build cumulative distribution for weighted sampling
    cumulative = build_cumulative_distribution(methods)

    Logger.info("Starting mixed HTTP workload: #{num_requests} requests over #{duration}ms")

    start_time = System.monotonic_time(:millisecond)

    for i <- 1..num_requests do
      method = sample_method(cumulative)
      params = default_params_for_method(method)

      Task.start(fn ->
        make_http_request(chain, method, params, strategy, timeout, i)
      end)

      elapsed = System.monotonic_time(:millisecond) - start_time
      next_request_time = i * interval_ms
      sleep_time = max(0, next_request_time - elapsed)
      if sleep_time > 0, do: Process.sleep(sleep_time)
    end

    remaining = duration - (System.monotonic_time(:millisecond) - start_time)
    if remaining > 0, do: Process.sleep(remaining)

    Logger.info("Mixed HTTP workload complete")
    :ok
  end

  @doc """
  Creates WebSocket subscriptions for testing.

  ## Options

  - `:chain` - Target chain name (required)
  - `:subscription` - Subscription type (e.g., "newHeads") (required)
  - `:count` - Number of concurrent subscriptions (default: 1)
  - `:duration` - How long to keep subscriptions open in ms (required)

  ## Example

      Workload.ws_subscribe(
        chain: "testchain",
        subscription: "newHeads",
        count: 5,
        duration: 60_000
      )
  """
  def ws_subscribe(opts) do
    # Phase 1: Placeholder
    # Phase 2: Implement WebSocket client that subscribes and tracks events
    Logger.info("WebSocket workload (placeholder for Phase 2)")
    duration = Keyword.fetch!(opts, :duration)
    Process.sleep(duration)
    :ok
  end

  # Private helpers

  defp make_http_request(chain, method, params, strategy, timeout, request_id) do
    start_time = System.monotonic_time(:millisecond)

    # Build path based on strategy
    path =
      case strategy do
        nil -> "/rpc/#{chain}"
        strategy -> "/rpc/#{strategy}/#{chain}"
      end

    # Build JSON-RPC request
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => request_id
      })

    # Make request via HTTP client
    result =
      case Finch.build(:post, "http://localhost:4000#{path}", [{"content-type", "application/json"}], body)
           |> Finch.request(Livechain.Finch, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: 200, body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, %{"result" => _}} -> :success
            {:ok, %{"error" => error}} -> {:error, error}
            {:error, _} -> {:error, :invalid_json}
          end

        {:ok, %Finch.Response{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end

    end_time = System.monotonic_time(:millisecond)
    latency = end_time - start_time

    # Emit telemetry event for collection
    :telemetry.execute(
      [:livechain, :battle, :request],
      %{latency: latency},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        result: result,
        request_id: request_id
      }
    )

    result
  end

  defp build_cumulative_distribution(methods) do
    # Normalize weights
    total_weight = Enum.reduce(methods, 0.0, fn {_, weight}, acc -> acc + weight end)

    methods
    |> Enum.reduce({[], 0.0}, fn {method, weight}, {acc, cumulative} ->
      new_cumulative = cumulative + weight / total_weight
      {[{method, new_cumulative} | acc], new_cumulative}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp sample_method(cumulative) do
    r = :rand.uniform()

    Enum.find(cumulative, fn {_method, cum_weight} ->
      r <= cum_weight
    end)
    |> elem(0)
  end

  defp default_params_for_method("eth_getBalance"), do: ["0x0000000000000000000000000000000000000000", "latest"]
  defp default_params_for_method("eth_getBlockByNumber"), do: ["latest", false]
  defp default_params_for_method("eth_call") do
    [%{"to" => "0x0000000000000000000000000000000000000000", "data" => "0x"}, "latest"]
  end
  defp default_params_for_method(_), do: []
end