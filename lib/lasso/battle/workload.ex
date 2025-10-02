defmodule Lasso.Battle.Workload do
  @moduledoc """
  Workload generation for battle testing.

  Generates realistic load patterns:
  - HTTP requests at constant or variable rates
  - WebSocket subscriptions
  - Mixed method distributions
  """

  require Logger
  alias Lasso.Battle.WebSocketClient

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

  # Private helpers

  defp make_http_request(chain, method, params, strategy, timeout, request_id) do
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

    # Make request via HTTP client - production telemetry emitted by RequestPipeline
    # Use port 4002 in test environment, 4000 otherwise
    port = if Mix.env() == :test, do: 4002, else: 4000
    url = "http://localhost:#{port}#{path}"

    Logger.debug("HTTP Request ##{request_id}: POST #{url}")

    case Finch.build(:post, url, [{"content-type", "application/json"}], body)
         |> Finch.request(Lasso.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        Logger.debug("HTTP Response ##{request_id}: 200 - #{String.slice(response_body, 0, 100)}")

        case Jason.decode(response_body) do
          {:ok, %{"result" => _}} -> :success
          {:ok, %{"error" => error}} -> {:error, error}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("HTTP Response ##{request_id}: #{status} - #{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("HTTP Error ##{request_id}: #{inspect(reason)}")
        {:error, reason}
    end
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

  defp default_params_for_method("eth_getBalance"),
    do: ["0x0000000000000000000000000000000000000000", "latest"]

  defp default_params_for_method("eth_getBlockByNumber"), do: ["latest", false]

  defp default_params_for_method("eth_call") do
    [%{"to" => "0x0000000000000000000000000000000000000000", "data" => "0x"}, "latest"]
  end

  defp default_params_for_method(_), do: []

  @doc """
  Creates WebSocket subscriptions and collects events.

  ## Options

  - `:chain` - Target chain name (required)
  - `:subscription` - Subscription type: "newHeads" or {"logs", filter} (required)
  - `:count` - Number of concurrent subscriptions (default: 1)
  - `:duration` - Test duration in milliseconds (required)
  - `:host` - WebSocket host (default: "localhost")
  - `:port` - WebSocket port (default: 4000)

  ## Returns

  Map with subscription statistics:
    - `:subscriptions` - Number of subscriptions created
    - `:events_received` - Total events received across all subscriptions
    - `:duplicates` - Number of duplicate events detected
    - `:gaps` - Number of gaps detected (missing events)
    - `:clients` - List of client PIDs for inspection

  ## Example

      Workload.ws_subscribe(
        chain: "ethereum",
        subscription: "newHeads",
        count: 10,
        duration: 300_000
      )
  """
  def ws_subscribe(opts) do
    chain = Keyword.fetch!(opts, :chain)
    subscription = Keyword.fetch!(opts, :subscription)
    count = Keyword.get(opts, :count, 1)
    duration = Keyword.fetch!(opts, :duration)
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 4002)

    Logger.info("Starting WebSocket workload: #{count} subscription(s) for #{duration}ms")

    url = "ws://#{host}:#{port}/ws/rpc/#{chain}"

    # Start WebSocket clients (handle connection errors gracefully)
    clients =
      for i <- 1..count do
        case WebSocketClient.start_link(url, subscription, "sub_#{i}") do
          {:ok, pid} ->
            {:ok, pid}

          {:error, reason} ->
            Logger.warning("Failed to start WebSocket client #{i}: #{inspect(reason)}")
            {:error, reason}
        end
      end

    # Filter out failed connections
    successful_clients =
      Enum.flat_map(clients, fn
        {:ok, pid} -> [pid]
        {:error, _} -> []
      end)

    failure_count = count - length(successful_clients)

    if failure_count > 0 do
      Logger.warning("#{failure_count}/#{count} WebSocket clients failed to connect")
    end

    # Wait for duration
    Process.sleep(duration)

    # Collect statistics from all successful clients
    stats =
      Enum.map(successful_clients, fn pid ->
        WebSocketClient.get_stats(pid)
      end)

    # Aggregate stats
    total_events = Enum.reduce(stats, 0, fn s, acc -> acc + s.events_received end)
    total_duplicates = Enum.reduce(stats, 0, fn s, acc -> acc + s.duplicates end)
    total_gaps = Enum.reduce(stats, 0, fn s, acc -> acc + s.gaps end)

    # Stop clients
    Enum.each(successful_clients, fn pid -> WebSocketClient.stop(pid) end)

    Logger.info(
      "WebSocket workload complete: #{total_events} events, #{total_duplicates} duplicates, #{total_gaps} gaps (#{length(successful_clients)}/#{count} clients connected)"
    )

    %{
      subscriptions: count,
      successful_connections: length(successful_clients),
      failed_connections: failure_count,
      events_received: total_events,
      duplicates: total_duplicates,
      gaps: total_gaps,
      clients: successful_clients,
      per_client_stats: stats
    }
  end
end
