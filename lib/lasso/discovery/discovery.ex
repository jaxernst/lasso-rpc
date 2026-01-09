defmodule Lasso.Discovery do
  @moduledoc """
  Unified RPC provider discovery and capability probing.

  Orchestrates multiple probe modules to comprehensively analyze
  an RPC provider's capabilities, limits, and features.

  ## Usage

      # Full probe (all probes)
      Lasso.Discovery.probe("https://eth.example.com")

      # Selective probing
      Lasso.Discovery.probe("https://eth.example.com",
        probes: [:methods, :limits],
        method_level: :standard,
        chain: "ethereum"
      )

      # WebSocket-only probe
      Lasso.Discovery.probe("wss://eth.example.com/ws",
        probes: [:websocket],
        subscription_wait: 30_000
      )

  ## Probe Modules

    * `:methods` - HTTP method support detection
    * `:limits` - Provider limits (block range, batch size, etc.)
    * `:websocket` - WebSocket connection and subscription support
  """

  alias Lasso.Discovery.Probes.{Limits, MethodSupport, WebSocket}

  @available_probes [:methods, :limits, :websocket]

  @type probe_results :: %{
          url: String.t(),
          probes_run: [atom()],
          timestamp: DateTime.t(),
          methods: map() | nil,
          limits: map() | nil,
          websocket: map() | nil
        }

  @doc """
  Probes an RPC provider URL for capabilities.

  ## Options

    * `:probes` - List of probes to run (default: all)
    * `:timeout` - Request timeout in ms (default: 10000)
    * `:chain` - Chain name for test contracts (default: "ethereum")
    * `:method_level` - Method probe level: :critical, :standard, :full (default: :standard)
    * `:concurrent` - Max concurrent requests (default: 5)
    * `:subscription_wait` - Time to wait for WS subscription events (default: 15000)

  ## Returns

  Map with results from each probe module.
  """
  @spec probe(String.t(), keyword()) :: probe_results()
  def probe(url, opts \\ []) do
    probes = Keyword.get(opts, :probes, @available_probes)
    timestamp = DateTime.utc_now()

    results =
      probes
      |> Enum.filter(&(&1 in @available_probes))
      |> Enum.reduce(%{}, fn probe, acc ->
        result = run_probe(probe, url, opts)
        Map.put(acc, probe, result)
      end)

    Map.merge(results, %{
      url: url,
      probes_run: probes,
      timestamp: timestamp
    })
  end

  @doc """
  Probes only HTTP method support.

  Shorthand for `probe(url, probes: [:methods], ...)`.
  """
  @spec probe_methods(String.t(), keyword()) :: [map()]
  def probe_methods(url, opts \\ []) do
    level = Keyword.get(opts, :level, :standard)
    timeout = Keyword.get(opts, :timeout, 3000)
    concurrent = Keyword.get(opts, :concurrent, 5)

    MethodSupport.probe(url,
      level: level,
      timeout: timeout,
      concurrent: concurrent
    )
  end

  @doc """
  Probes only provider limits.

  Shorthand for `probe(url, probes: [:limits], ...)`.
  """
  @spec probe_limits(String.t(), keyword()) :: map()
  def probe_limits(url, opts \\ []) do
    chain = Keyword.get(opts, :chain, "ethereum")
    timeout = Keyword.get(opts, :timeout, 10_000)
    tests = Keyword.get(opts, :tests, Limits.available_tests())

    Limits.probe(url,
      chain: chain,
      timeout: timeout,
      tests: tests
    )
  end

  @doc """
  Probes only WebSocket capabilities.

  Shorthand for `probe(url, probes: [:websocket], ...)`.
  """
  @spec probe_websocket(String.t(), keyword()) :: map()
  def probe_websocket(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    subscription_wait = Keyword.get(opts, :subscription_wait, 15_000)

    WebSocket.probe(url,
      timeout: timeout,
      subscription_wait: subscription_wait
    )
  end

  @doc """
  Returns the list of available probe types.
  """
  @spec available_probes() :: [atom()]
  def available_probes, do: @available_probes

  @doc """
  Generates adapter configuration recommendations based on probe results.

  Returns a map suitable for use in provider adapter configuration.
  """
  @spec generate_adapter_config(probe_results()) :: map()
  def generate_adapter_config(results) do
    config = %{}

    config =
      if results[:limits] do
        limits = results.limits

        config
        |> maybe_add_limit(limits, :block_range, :max_block_range)
        |> maybe_add_limit(limits, :address_count, :max_addresses)
        |> maybe_add_limit(limits, :batch_requests, :max_batch_size)
        |> maybe_add_archive_config(limits)
      else
        config
      end

    config =
      if results[:methods] do
        blocked = MethodSupport.find_blocked_categories(results.methods)
        unsupported = MethodSupport.find_unsupported_methods(results.methods, blocked)

        config
        |> Map.put(:blocked_categories, blocked)
        |> Map.put(:unsupported_methods, unsupported)
      else
        config
      end

    config =
      if results[:websocket] do
        ws = results.websocket

        config
        |> Map.put(:websocket_supported, ws.connected)
        |> maybe_add_subscription_config(ws)
      else
        config
      end

    config
  end

  # Individual probe runners

  defp run_probe(:methods, url, opts) do
    # Methods probe requires HTTP URL
    http_url = ensure_http_url(url)
    level = Keyword.get(opts, :method_level, :standard)
    timeout = Keyword.get(opts, :timeout, 3000)
    concurrent = Keyword.get(opts, :concurrent, 5)

    MethodSupport.probe(http_url, level: level, timeout: timeout, concurrent: concurrent)
  end

  defp run_probe(:limits, url, opts) do
    # Limits probe requires HTTP URL
    http_url = ensure_http_url(url)
    chain = Keyword.get(opts, :chain, "ethereum")
    timeout = Keyword.get(opts, :timeout, 10_000)

    Limits.probe(http_url, chain: chain, timeout: timeout)
  end

  defp run_probe(:websocket, url, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    subscription_wait = Keyword.get(opts, :subscription_wait, 15_000)

    WebSocket.probe(url, timeout: timeout, subscription_wait: subscription_wait)
  end

  # URL conversion helpers

  defp ensure_http_url("wss://" <> rest), do: "https://" <> rest
  defp ensure_http_url("ws://" <> rest), do: "http://" <> rest
  defp ensure_http_url(url), do: url

  # Helpers for adapter config generation

  defp maybe_add_limit(config, limits, test_key, config_key) do
    case Map.get(limits, test_key) do
      %{status: :limited, value: value} when is_integer(value) ->
        Map.put(config, config_key, value)

      _ ->
        config
    end
  end

  defp maybe_add_archive_config(config, limits) do
    case Map.get(limits, :archive_support) do
      %{status: :supported, value: :full_archive} ->
        Map.put(config, :archive_node, true)

      %{status: :supported, value: :partial_archive} ->
        Map.put(config, :archive_node, :partial)

      _ ->
        config
    end
  end

  defp maybe_add_subscription_config(config, ws) do
    if ws.connected and ws.subscriptions do
      supported =
        ws.subscriptions
        |> Enum.filter(fn {_type, result} -> result.status == :supported end)
        |> Enum.map(fn {type, _} -> type end)

      Map.put(config, :supported_subscriptions, supported)
    else
      config
    end
  end
end
