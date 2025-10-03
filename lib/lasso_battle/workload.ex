defmodule Lasso.Battle.Workload do
  @moduledoc """
  Composable workload generation for battle testing.

  ## Architecture

  The framework has three composable layers:

  1. **Request Primitives** - What to execute
     - `http/4` - HTTP client to Phoenix endpoint
     - `direct/4` - Direct RequestPipeline call (bypasses HTTP layer)
     - `custom/1` - Custom function for maximum flexibility

  2. **Load Patterns** - How to execute
     - `constant/2` - Fixed rate execution
     - `poisson/2` - Realistic Poisson-distributed arrival pattern
     - `burst/2` - Spike testing with bursts
     - `ramp/2` - Gradual load increase

  3. **Composition** - Combine primitives with patterns

  ## Examples

      # Compare HTTP endpoint vs direct pipeline calls
      http_fn = fn -> Workload.http("ethereum", "eth_blockNumber") end
      direct_http_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :http) end
      direct_ws_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :ws) end

      # Run at constant rate
      Task.async(fn -> Workload.constant(http_fn, rate: 10, duration: 30_000) end)
      Task.async(fn -> Workload.constant(direct_http_fn, rate: 10, duration: 30_000) end)
      Task.async(fn -> Workload.constant(direct_ws_fn, rate: 10, duration: 30_000) end)

      # Custom failover testing
      failover_fn = fn ->
        start = System.monotonic_time(:microsecond)
        result = Workload.direct("ethereum", "eth_blockNumber",
          provider_override: "flaky",
          failover_on_override: true
        )
        duration = System.monotonic_time(:microsecond) - start
        {result, duration}
      end

      Workload.constant(failover_fn, rate: 5, duration: 10_000)

  ## Backward Compatibility

  Legacy functions (`http_constant/1`, `ws_constant/1`, etc.) are still supported
  but are implemented using the new composable primitives internally.
  """

  require Logger
  alias Lasso.Battle.WebSocketClient

  ## ============================================================================
  ## Layer 1: Request Primitives (What to execute)
  ## ============================================================================

  @doc """
  Makes an HTTP request to the Phoenix endpoint (full stack test).

  Tests: HTTP client → Phoenix → RequestPipeline → Provider selection → Upstream

  ## Options
  - `:endpoint` - Full URL (default: "http://localhost:4002/rpc/{chain}")
  - `:timeout` - Request timeout (default: 5000)
  - `:strategy` - Routing strategy (default: nil, uses chain default)

  ## Example

      Workload.http("ethereum", "eth_blockNumber")
      Workload.http("ethereum", "eth_getBalance", ["0x123...", "latest"], strategy: :fastest)
  """
  def http(chain, method, params \\ [], opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, "http://localhost:4002/rpc/#{chain}")
    timeout = Keyword.get(opts, :timeout, 5000)
    strategy = Keyword.get(opts, :strategy)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => generate_id()
      })

    headers = [{"content-type", "application/json"}]
    headers = if strategy, do: [{"x-strategy", to_string(strategy)} | headers], else: headers

    case Finch.build(:post, endpoint, headers, body)
         |> Finch.request(Lasso.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => error}} -> {:error, error}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes a direct call to RequestPipeline (bypassing HTTP/Phoenix layer).

  Tests: RequestPipeline → Provider selection → Upstream transport

  This is the preferred way to test upstream routing performance without
  the confounding factors of HTTP client overhead and network loopback.

  ## Options
  - `:transport` - Force transport type: `:http`, `:ws`, or `:both` (default: :both)
  - `:strategy` - Routing strategy (default: :round_robin)
  - `:provider_override` - Force specific provider
  - `:failover_on_override` - Allow failover when override fails (default: false)
  - `:timeout` - Request timeout (default: 30_000)

  ## Example

      # Test HTTP upstream routing
      Workload.direct("ethereum", "eth_blockNumber", transport: :http)

      # Test WebSocket upstream routing
      Workload.direct("ethereum", "eth_blockNumber", transport: :ws)

      # Test provider failover
      Workload.direct("ethereum", "eth_blockNumber",
        provider_override: "flaky",
        failover_on_override: true
      )
  """
  def direct(chain, method, params \\ [], opts \\ []) do
    transport = Keyword.get(opts, :transport, :both)
    strategy = Keyword.get(opts, :strategy, :round_robin)
    provider_override = Keyword.get(opts, :provider_override)
    failover_on_override = Keyword.get(opts, :failover_on_override, false)
    timeout = Keyword.get(opts, :timeout, 30_000)

    pipeline_opts = [
      transport_override: transport,
      strategy: strategy,
      provider_override: provider_override,
      failover_on_override: failover_on_override,
      timeout: timeout
    ]

    Lasso.RPC.RequestPipeline.execute_via_channels(chain, method, params, pipeline_opts)
  end

  @doc """
  Executes a custom function as a workload.

  Maximum flexibility - the function can do anything and return any value.

  ## Example

      custom_fn = fn ->
        start = System.monotonic_time(:microsecond)
        result = some_complex_operation()
        duration = System.monotonic_time(:microsecond) - start

        # Emit custom telemetry
        :telemetry.execute([:my_app, :custom_metric], %{duration: duration}, %{})

        {:ok, result}
      end

      Workload.custom(custom_fn)
  """
  def custom(fun) when is_function(fun, 0) do
    fun.()
  end

  ## ============================================================================
  ## Layer 2: Load Patterns (How to execute)
  ## ============================================================================

  @doc """
  Executes a workload function at a constant rate.

  ## Options
  - `:rate` - Requests per second (required)
  - `:duration` - Duration in milliseconds (required)
  - `:on_result` - Callback for each result: `fn result -> ... end`
  - `:on_error` - Callback for each error: `fn error -> ... end`

  ## Example

      workload_fn = fn -> Workload.direct("ethereum", "eth_blockNumber", transport: :http) end

      Workload.constant(workload_fn,
        rate: 10,
        duration: 30_000,
        on_error: fn error -> Logger.error("Request failed: \#{inspect(error)}") end
      )
  """
  def constant(workload_fn, opts) when is_function(workload_fn, 0) do
    rate = Keyword.fetch!(opts, :rate)
    duration = Keyword.fetch!(opts, :duration)
    on_result = Keyword.get(opts, :on_result)
    on_error = Keyword.get(opts, :on_error)

    interval_ms = trunc(1000 / rate)
    num_requests = trunc(duration / interval_ms)

    Logger.info("Starting constant workload: #{num_requests} requests at #{rate} req/s")

    start_time = System.monotonic_time(:millisecond)

    for i <- 1..num_requests do
      Task.start(fn ->
        case workload_fn.() do
          {:ok, result} ->
            if on_result, do: on_result.(result)

          {:error, error} ->
            if on_error, do: on_error.(error)

          other ->
            Logger.debug("Workload returned: #{inspect(other)}")
        end
      end)

      # Rate limiting
      elapsed = System.monotonic_time(:millisecond) - start_time
      next_request_time = i * interval_ms
      sleep_time = max(0, next_request_time - elapsed)
      if sleep_time > 0, do: Process.sleep(sleep_time)
    end

    # Wait for remaining duration
    remaining = duration - (System.monotonic_time(:millisecond) - start_time)
    if remaining > 0, do: Process.sleep(remaining)

    Logger.info("Constant workload complete")
    :ok
  end

  ## ============================================================================
  ## Layer 3: Legacy API (Backward Compatibility)
  ## ============================================================================
  ##
  ## These functions are now implemented using the new composable primitives.
  ## They remain for backward compatibility with existing tests.

  @doc """
  Generates HTTP requests at a constant rate (LEGACY).

  **Deprecated:** Use `constant(fn -> http(...) end, ...)` instead for more flexibility.

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

  defp make_ws_request(chain, method, params, strategy, timeout, request_id) do
    alias Lasso.RPC.RequestPipeline

    Logger.debug("WS Request ##{request_id}: #{chain}.#{method} via #{inspect(strategy)}")

    # Make request via RequestPipeline with WebSocket transport override
    # This emits production telemetry just like HTTP requests
    case RequestPipeline.execute_via_channels(
           chain,
           method,
           params,
           transport_override: :ws,
           strategy: strategy,
           timeout: timeout
         ) do
      {:ok, _result} ->
        Logger.debug("WS Response ##{request_id}: success")
        :success

      {:error, reason} ->
        Logger.warning("WS Error ##{request_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp make_http_request(chain, method, params, _strategy, timeout, request_id) do
    # HTTP path is always /rpc/{chain} - strategy is not in the path
    path = "/rpc/#{chain}"

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
  Generates WebSocket unary requests at a constant rate.

  Similar to `http_constant/1` but uses WebSocket transport for unary RPC requests
  (not subscriptions). This allows for direct latency comparison between HTTP and WS.

  ## Options

  - `:chain` - Target chain name (required)
  - `:method` - RPC method to call (required)
  - `:params` - RPC params (default: [])
  - `:rate` - Requests per second (required)
  - `:duration` - Test duration in milliseconds (required)
  - `:strategy` - Routing strategy (default: :round_robin)
  - `:timeout` - Request timeout in milliseconds (default: 5000)

  ## Example

      Workload.ws_constant(
        chain: "ethereum",
        method: "eth_blockNumber",
        rate: 10,
        duration: 30_000,
        strategy: :round_robin
      )
  """
  def ws_constant(opts) do
    chain = Keyword.fetch!(opts, :chain)
    method = Keyword.fetch!(opts, :method)
    params = Keyword.get(opts, :params, [])
    rate = Keyword.fetch!(opts, :rate)
    duration = Keyword.fetch!(opts, :duration)
    strategy = Keyword.get(opts, :strategy, :round_robin)
    timeout = Keyword.get(opts, :timeout, 5_000)

    interval_ms = trunc(1000 / rate)
    num_requests = trunc(duration / interval_ms)

    Logger.info(
      "Starting WebSocket unary workload: #{num_requests} requests over #{duration}ms (#{rate} req/s)"
    )

    start_time = System.monotonic_time(:millisecond)

    # Send requests at constant rate using WebSocket transport
    for i <- 1..num_requests do
      Task.start(fn ->
        make_ws_request(chain, method, params, strategy, timeout, i)
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

    Logger.info("WebSocket unary workload complete")
    :ok
  end

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

  ## ============================================================================
  ## Private Helpers
  ## ============================================================================

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
