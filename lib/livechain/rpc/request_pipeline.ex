defmodule Livechain.RPC.RequestPipeline do
  @moduledoc """
  Orchestrates provider selection, optional override short-circuit,
  and resilient retries/failover for RPC requests across transports.

  Responsibilities:
  - Select provider using strategy and protocol constraints
  - Support provider override (attempt first; optional failover on retriable errors)
  - Execute single attempts wrapped in per-provider circuit breakers
  - Publish telemetry and update provider metrics for successes/failures
  """

  require Logger

  alias Livechain.RPC.{Selection, Transport, ProviderPool, Metrics, ProviderRegistry, Channel}
  alias Livechain.Config.ConfigStore
  alias Livechain.JSONRPC.Error, as: JError
  alias Livechain.RPC.CircuitBreaker

  @type chain :: String.t()
  @type method :: String.t()
  @type params :: list()

  @doc """
  Execute an RPC request with resilient behavior using transport-agnostic channels.

  This is a channel-based API that supports mixed HTTP and WebSocket routing.
  It automatically selects the best channels across different transports based on
  strategy, health, and capabilities.

  Options:
  - :strategy => :fastest | :cheapest | :priority | :round_robin (default: config)
  - :provider_override => provider_id (optional)
  - :transport_override => :http | :ws (optional, force specific transport)
  - :failover_on_override => boolean (default: false)
  - :timeout => ms (per-attempt timeout)
  """
  @spec execute_via_channels(chain, method, params, keyword()) :: {:ok, any()} | {:error, any()}
  def execute_via_channels(chain, method, params, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :round_robin)
    provider_override = Keyword.get(opts, :provider_override)
    transport_override = Keyword.get(opts, :transport_override)
    failover_on_override = Keyword.get(opts, :failover_on_override, false)
    timeout = Keyword.get(opts, :timeout, 30_000)

    # Build JSON-RPC request
    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => generate_request_id()
    }

    case provider_override do
      provider_id when is_binary(provider_id) ->
        execute_with_provider_override(
          chain,
          rpc_request,
          strategy,
          provider_id,
          transport_override,
          failover_on_override: failover_on_override,
          timeout: timeout
        )

      _ ->
        execute_with_channel_selection(chain, rpc_request, strategy, transport_override, timeout)
    end
  end

  @doc """
  Execute an RPC request with resilient behavior over HTTP (legacy API).

  Options:
  - :strategy => :fastest | :cheapest | :priority | :round_robin (default: config)
  - :provider_override => provider_id (optional)
  - :failover_on_override => boolean (default: false) – when overriding, fail over to others
  - :timeout => ms (per-attempt timeout)
  """
  @spec execute(chain, method, params, keyword()) :: {:ok, any()} | {:error, any()}
  def execute(chain, method, params, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :round_robin)
    provider_override = Keyword.get(opts, :provider_override)
    failover_on_override = Keyword.get(opts, :failover_on_override, false)

    case provider_override do
      provider_id when is_binary(provider_id) ->
        execute_with_override(chain, method, params, strategy, provider_id,
          failover_on_override: failover_on_override,
          timeout: Keyword.get(opts, :timeout)
        )

      _ ->
        with {:ok, provider_id} <-
               Selection.select_provider(chain, method, strategy: strategy, protocol: :http) do
          execute_with_failover(chain, method, params, strategy, provider_id,
            timeout: Keyword.get(opts, :timeout)
          )
        else
          {:error, reason} ->
            {:error, JError.new(-32000, "No available providers: #{reason}")}
        end
    end
  end

  # Private: provider override first attempt, then optional failover
  defp execute_with_override(chain, method, params, strategy, provider_id, opts) do
    failover_on_override = Keyword.get(opts, :failover_on_override, false)
    timeout = Keyword.get(opts, :timeout, 30_000)

    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute([:livechain, :rpc, :request, :start], %{count: 1}, %{
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id
    })

    case forward_request_via_transport(chain, provider_id, method, params, timeout: timeout) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        record_success_metrics(chain, provider_id, method, strategy, duration_ms)
        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        jerr = JError.from(reason, provider_id: provider_id)
        record_failure_metrics(chain, provider_id, method, strategy, jerr, duration_ms)

        should_failover =
          case jerr do
            %Livechain.JSONRPC.Error{retriable?: retriable?} -> retriable?
            _ -> false
          end

        if failover_on_override and should_failover do
          try_failover_with_reporting(
            chain,
            method,
            params,
            strategy,
            [provider_id],
            1,
            timeout
          )
        else
          {:error, jerr}
        end
    end
  end

  # Private: initial attempt + failover loop
  defp execute_with_failover(chain, method, params, strategy, provider_id, opts) do
    start_time = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :timeout, 30_000)

    :telemetry.execute([:livechain, :rpc, :request, :start], %{count: 1}, %{
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id
    })

    case forward_request_via_transport(chain, provider_id, method, params, timeout: timeout) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        record_success_metrics(chain, provider_id, method, strategy, duration_ms)
        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        jerr = JError.from(reason, provider_id: provider_id)
        record_failure_metrics(chain, provider_id, method, strategy, jerr, duration_ms)

        should_failover =
          case jerr do
            %Livechain.JSONRPC.Error{retriable?: retriable?} -> retriable?
            _ -> false
          end

        if should_failover do
          try_failover_with_reporting(
            chain,
            method,
            params,
            strategy,
            [provider_id],
            1,
            timeout
          )
        else
          {:error, jerr}
        end
    end
  end

  defp try_failover_with_reporting(
         chain,
         method,
         params,
         strategy,
         excluded,
         attempt,
         timeout
       ) do
    max_attempts = Livechain.Config.MethodPolicy.max_failovers(method)

    cond do
      attempt > max_attempts ->
        {:error, JError.new(-32000, "Failover limit reached for method: #{method}")}

      true ->
        with {:ok, next_provider} <-
               Selection.select_provider(chain, method,
                 strategy: strategy,
                 protocol: :http,
                 exclude: excluded
               ) do
          Logger.warning("Failing over to provider",
            chain: chain,
            method: method,
            provider: next_provider
          )

          execute_failover_attempt(
            chain,
            method,
            params,
            strategy,
            next_provider,
            excluded,
            attempt,
            timeout
          )
        else
          {:error, reason} ->
            {:error, JError.new(-32000, "Failed to select next provider: #{reason}")}
        end
    end
  end

  defp execute_failover_attempt(
         chain,
         method,
         params,
         strategy,
         provider_id,
         excluded,
         attempt,
         timeout
       ) do
    start_time = System.monotonic_time(:millisecond)

    case forward_request_via_transport(chain, provider_id, method, params, timeout: timeout) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        record_failover_success_metrics(
          chain,
          provider_id,
          method,
          strategy,
          duration_ms,
          attempt
        )

        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        jerr = JError.from(reason, provider_id: provider_id)

        record_failover_failure_metrics(
          chain,
          provider_id,
          method,
          strategy,
          jerr,
          duration_ms,
          attempt
        )

        should_failover =
          case jerr do
            %Livechain.JSONRPC.Error{retriable?: retriable?} -> retriable?
            _ -> false
          end

        if should_failover do
          try_failover_with_reporting(
            chain,
            method,
            params,
            strategy,
            [provider_id | excluded],
            attempt + 1,
            timeout
          )
        else
          {:error, jerr}
        end
    end
  end

  # Single attempt via CircuitBreaker + Transport
  defp forward_request_via_transport(chain, provider_id, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000) || 30_000

    case ConfigStore.get_provider(chain, provider_id) do
      {:ok, provider_config} ->
        CircuitBreaker.call(
          provider_id,
          fn ->
            Transport.forward_request(
              provider_id,
              provider_config,
              :http,
              method,
              params,
              timeout: timeout
            )
          end,
          timeout + 1_000
        )

      {:error, reason} ->
        {:error, JError.new(-32000, "Provider not found: #{reason}", provider_id: provider_id)}
    end
  end

  defp record_success_metrics(chain, provider_id, method, strategy, duration_ms) do
    record_rpc_success(chain, provider_id, method, duration_ms)

    publish_routing_decision(
      chain,
      method,
      strategy,
      provider_id,
      duration_ms,
      :success,
      0
    )

    :telemetry.execute(
      [:livechain, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        result: :success,
        failovers: 0
      }
    )
  end

  defp record_failure_metrics(chain, provider_id, method, strategy, reason, duration_ms) do
    record_rpc_failure(chain, provider_id, method, reason, duration_ms)
    publish_routing_decision(chain, method, strategy, provider_id, duration_ms, :error, 0)

    :telemetry.execute(
      [:livechain, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        result: :error,
        failovers: 0
      }
    )
  end

  defp record_failover_success_metrics(chain, provider_id, method, strategy, duration_ms, attempt) do
    record_rpc_success(chain, provider_id, method, duration_ms)

    publish_routing_decision(
      chain,
      method,
      strategy,
      provider_id,
      duration_ms,
      :success,
      attempt
    )

    :telemetry.execute(
      [:livechain, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        result: :success,
        failovers: attempt
      }
    )
  end

  defp record_failover_failure_metrics(
         chain,
         provider_id,
         method,
         strategy,
         reason,
         duration_ms,
         attempt
       ) do
    record_rpc_failure(chain, provider_id, method, reason, duration_ms)

    publish_routing_decision(
      chain,
      method,
      strategy,
      provider_id,
      duration_ms,
      :error,
      attempt
    )

    :telemetry.execute(
      [:livechain, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        result: :error,
        failovers: attempt
      }
    )
  end

  defp publish_routing_decision(
         chain,
         method,
         strategy,
         provider_id,
         duration_ms,
         result,
         failovers
       ) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "routing:decisions",
      %{
        ts: System.system_time(:millisecond),
        chain: chain,
        method: method,
        strategy: to_string(strategy),
        provider_id: provider_id,
        duration_ms: duration_ms,
        result: result,
        failover_count: failovers
      }
    )
  end

  defp record_rpc_success(chain, provider_id, method, duration_ms) do
    Metrics.record_success(chain, provider_id, method, duration_ms)
    ProviderPool.report_success(chain, provider_id)
  end

  defp record_rpc_failure(chain, provider_id, method, reason, duration_ms) do
    Metrics.record_failure(chain, provider_id, method, duration_ms)
    ProviderPool.report_failure(chain, provider_id, reason)
  end

  # New channel-based implementation functions

  defp execute_with_provider_override(
         chain,
         rpc_request,
         strategy,
         provider_id,
         transport_override,
         opts
       ) do
    failover_on_override = Keyword.get(opts, :failover_on_override, false)
    timeout = Keyword.get(opts, :timeout, 30_000)
    method = Map.get(rpc_request, "method")

    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute([:livechain, :rpc, :request, :start], %{count: 1}, %{
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id
    })

    # Get channels for the specific provider
    channels = get_provider_channels(chain, provider_id, transport_override)

    case attempt_request_on_channels(channels, rpc_request, timeout) do
      {:ok, result, channel} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        record_channel_success_metrics(chain, channel, method, strategy, duration_ms)
        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        jerr = normalize_channel_error(reason, provider_id)
        record_channel_failure_metrics(chain, provider_id, method, strategy, jerr, duration_ms)

        should_failover =
          case jerr do
            %Livechain.JSONRPC.Error{retriable?: retriable?} -> retriable?
            _ -> false
          end

        if failover_on_override and should_failover do
          try_channel_failover(
            chain,
            rpc_request,
            strategy,
            [provider_id],
            1,
            timeout
          )
        else
          {:error, jerr}
        end
    end
  end

  defp execute_with_channel_selection(chain, rpc_request, strategy, transport_override, timeout) do
    method = Map.get(rpc_request, "method")

    # Get candidate channels based on strategy and constraints
    filters = build_selection_filters(transport_override, method)

    case ProviderRegistry.get_candidate_channels(chain, filters) do
      [] ->
        {:error, JError.new(-32000, "No available channels for method: #{method}")}

      channels ->
        # Sort channels by strategy preference
        sorted_channels = sort_channels_by_strategy(channels, strategy, method, chain)

        Logger.info(
          "Found #{length(sorted_channels)} candidate channels: #{inspect(Enum.map(sorted_channels, &Channel.to_string/1))}"
        )

        start_time = System.monotonic_time(:millisecond)

        case attempt_request_on_channels(sorted_channels, rpc_request, timeout) do
          {:ok, result, channel} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            record_channel_success_metrics(chain, channel, method, strategy, duration_ms)
            {:ok, result}

          {:error, reason} ->
            _duration_ms = System.monotonic_time(:millisecond) - start_time
            jerr = normalize_channel_error(reason, "no_channels")
            {:error, jerr}
        end
    end
  end

  defp get_provider_channels(chain, provider_id, transport_override) do
    transports =
      case transport_override do
        nil -> [:http, :ws]
        transport -> [transport]
      end

    transports
    |> Enum.map(fn transport ->
      case ProviderRegistry.get_channel(chain, provider_id, transport) do
        {:ok, channel} -> channel
        {:error, _} -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp attempt_request_on_channels([], _rpc_request, _timeout) do
    {:error, :no_channels_available}
  end

  defp attempt_request_on_channels([channel | rest_channels], rpc_request, timeout) do
    case Channel.request(channel, rpc_request, timeout) do
      {:ok, result} ->
        Logger.debug("✓ Request Success via #{Channel.to_string(channel)}")
        {:ok, result, channel}

      {:error, :unsupported_method} ->
        # Fast fallthrough - try next channel immediately
        Logger.debug("Method not supported on channel, trying next",
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method")
        )

        attempt_request_on_channels(rest_channels, rpc_request, timeout)

      {:error, reason} ->
        # For other errors, we could implement retry logic here
        # For now, propagate the error
        Logger.warning("Channel request failed",
          channel: Channel.to_string(channel),
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp build_selection_filters(transport_override, method) do
    filters = %{method: method}

    case transport_override do
      nil -> Map.put(filters, :protocol, :both)
      transport -> Map.put(filters, :protocol, transport)
    end
  end

  defp sort_channels_by_strategy(channels, :priority, _method, _chain) do
    # Sort by provider priority
    Enum.sort_by(channels, fn _channel ->
      # This would need to access provider config for priority
      # For now, preserve original order
      0
    end)
  end

  defp sort_channels_by_strategy(channels, :round_robin, _method, _chain) do
    # Simple round-robin - could be improved with state tracking
    Enum.shuffle(channels)
  end

  defp sort_channels_by_strategy(channels, :fastest, _method, _chain) do
    # Sort by performance metrics - this would integrate with Metrics module
    # For now, prefer HTTP over WebSocket for unary requests
    Enum.sort_by(channels, fn channel ->
      case channel.transport do
        :http -> 0
        :ws -> 1
      end
    end)
  end

  defp sort_channels_by_strategy(channels, _strategy, _method, _chain) do
    # Default: preserve original order
    channels
  end

  defp try_channel_failover(chain, rpc_request, strategy, excluded_providers, attempt, timeout) do
    # Could be configurable
    max_attempts = 3

    if attempt > max_attempts do
      {:error, JError.new(-32000, "Failover limit reached")}
    else
      method = Map.get(rpc_request, "method")
      filters = %{method: method, exclude: excluded_providers, protocol: :both}

      case ProviderRegistry.get_candidate_channels(chain, filters) do
        [] ->
          {:error, JError.new(-32000, "No more channels available for failover")}

        channels ->
          sorted_channels = sort_channels_by_strategy(channels, strategy, method, chain)

          case attempt_request_on_channels(sorted_channels, rpc_request, timeout) do
            {:ok, result, _channel} ->
              {:ok, result}

            {:error, _reason} ->
              # Get the provider ID from the failed channel and add to exclusions
              new_excluded =
                case sorted_channels do
                  [failed_channel | _] -> [failed_channel.provider_id | excluded_providers]
                  [] -> excluded_providers
                end

              try_channel_failover(
                chain,
                rpc_request,
                strategy,
                new_excluded,
                attempt + 1,
                timeout
              )
          end
      end
    end
  end

  defp record_channel_success_metrics(chain, channel, method, strategy, duration_ms) do
    provider_id = channel.provider_id
    transport = channel.transport

    # Record with transport dimension
    Metrics.record_success(chain, provider_id, method, duration_ms, transport: transport)
    ProviderPool.report_success(chain, provider_id)

    publish_channel_routing_decision(
      chain,
      method,
      strategy,
      provider_id,
      transport,
      duration_ms,
      :success,
      0
    )

    :telemetry.execute(
      [:livechain, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: transport,
        result: :success,
        failovers: 0
      }
    )
  end

  defp record_channel_failure_metrics(chain, provider_id, method, strategy, reason, duration_ms) do
    # For now, we don't know the transport that failed, so use legacy metrics
    record_rpc_failure(chain, provider_id, method, reason, duration_ms)

    :telemetry.execute(
      [:livechain, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: :unknown,
        result: :error,
        failovers: 0
      }
    )
  end

  defp publish_channel_routing_decision(
         chain,
         method,
         strategy,
         provider_id,
         transport,
         duration_ms,
         result,
         failovers
       ) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "routing:decisions",
      %{
        ts: System.system_time(:millisecond),
        chain: chain,
        method: method,
        strategy: to_string(strategy),
        provider_id: provider_id,
        transport: transport,
        duration_ms: duration_ms,
        result: result,
        failover_count: failovers
      }
    )
  end

  defp normalize_channel_error(reason, provider_id) do
    case reason do
      %JError{} = jerr -> jerr
      other -> JError.from(other, provider_id: provider_id)
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
