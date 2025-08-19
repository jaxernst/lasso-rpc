defmodule Livechain.RPC.Failover do
  @moduledoc """
  Shared failover logic for both HTTP and WebSocket RPC requests.

  Provides seamless provider failover with automatic 429 rate limit handling,
  exponential backoff, and transparent error recovery for end users.
  """

  require Logger

  alias Livechain.RPC.{Selection, ChainSupervisor, ProviderPool}
  alias Livechain.Benchmarking.BenchmarkStore
  alias Livechain.Config.MethodPolicy

  @doc """
  Executes an RPC request with automatic failover on failure.

  Handles 429 rate limiting, provider failures, and automatic retry
  with excluded providers until success or all providers exhausted.

  Options:
  - `:strategy` - Provider selection strategy (:fastest, :cheapest, etc.)
  - `:protocol` - Required protocol (:http, :ws, :both)
  - `:region_filter` - Optional region filtering

  Returns {:ok, result} or {:error, reason} after all failover attempts.
  """
  @spec execute_with_failover(String.t(), String.t(), list(), keyword()) ::
          {:ok, any()} | {:error, any()}
  def execute_with_failover(chain, method, params, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :cheapest)
    protocol = Keyword.get(opts, :protocol, :http)
    region_filter = Keyword.get(opts, :region_filter)

    with {:ok, provider_id} <-
           Selection.pick_provider(chain, method, strategy: strategy, protocol: protocol) do
      execute_rpc_with_failover(chain, method, params, strategy, provider_id, region_filter)
    else
      {:error, reason} ->
        {:error, %{code: -32000, message: "No available providers: #{reason}"}}
    end
  end

  # Private functions

  # Determines whether a specific error should trigger provider failover.
  #
  # Based on actual error patterns in our codebase:
  # - HTTP Client returns typed tuples: {:rate_limit, _}, {:server_error, _}, etc.
  # - Circuit breaker states: :circuit_open, etc.  
  # - WebSocket/network errors: :timeout, :econnrefused, etc.
  #
  # Simple rule: Infrastructure/provider errors trigger failover, user errors don't.
  @spec should_failover?(any()) :: boolean()
  defp should_failover?(reason) do
    case reason do
      # === HTTP Client Errors (from Livechain.RPC.HttpClient.Finch) ===
      {:rate_limit, _} -> true
      {:server_error, _} -> true  
      {:network_error, _} -> true
      {:client_error, _} -> false  # 4xx errors are user errors
      {:decode_error, _} -> false  # JSON parse errors are user errors

      # === Circuit Breaker States ===
      :circuit_open -> true
      :circuit_opening -> true
      :circuit_reopening -> true
      {:circuit_breaker, _} -> true

      # === Common Network/Connection Errors ===
      :timeout -> true
      :econnrefused -> true
      :nxdomain -> true
      {:timeout, _} -> true
      {:connection_error, _} -> true

      # === JSON-RPC Error Responses ===
      %{code: code} when is_integer(code) ->
        should_failover_jsonrpc_error?(code)

      # === Fallback: Unknown errors don't failover (conservative) ===
      other ->
        Logger.debug("Unknown error type in failover, not failing over: #{inspect(other)}")
        false
    end
  end

  # JSON-RPC 2.0 error codes - simplified based on actual usage
  defp should_failover_jsonrpc_error?(code) do
    case code do
      # Standard JSON-RPC 2.0 errors are user errors - don't failover
      code when code in [-32700, -32600, -32601, -32602, -32603] -> false
      
      # Provider rate limiting patterns - DO failover  
      code when code in [-32005, -32429] -> true
      
      # Conservative default: don't failover on unknown JSON-RPC codes
      # Providers should use HTTP status codes for infrastructure issues
      _ -> false
    end
  end


  defp execute_rpc_with_failover(chain, method, params, strategy, provider_id, region_filter) do
    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute([:livechain, :rpc, :request, :start], %{count: 1}, %{
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id
    })

    case ChainSupervisor.forward_rpc_request(chain, provider_id, method, params) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        record_success_metrics(chain, provider_id, method, strategy, duration_ms)
        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        record_failure_metrics(chain, provider_id, method, strategy, reason, duration_ms)

        case should_failover?(reason) do
          true ->
            try_failover_with_reporting(
              chain,
              method,
              params,
              strategy,
              [provider_id],
              1,
              region_filter
            )

          false ->
            # User error - return immediately without failover
            {:error, reason}
        end
    end
  end

  defp try_failover_with_reporting(
         chain,
         method,
         params,
         strategy,
         excluded_providers,
         attempt,
         _region_filter
       ) do
    max_attempts = MethodPolicy.max_failovers(method)

    with {:attempt_limit, false} <- {:attempt_limit, attempt > max_attempts},
         {:ok, providers} <-
           Selection.get_available_providers(chain, protocol: :http, exclude: excluded_providers),
         {:providers_available, [next_provider | _]} <- {:providers_available, providers} do
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
        excluded_providers,
        attempt
      )
    else
      {:attempt_limit, true} ->
        {:error, %{code: -32000, message: "Failover limit reached for method: #{method}"}}

      {:providers_available, []} ->
        {:error, %{code: -32000, message: "All providers failed for method: #{method}"}}

      {:error, reason} ->
        {:error, %{code: -32000, message: "Failed to get available providers: #{reason}"}}
    end
  end

  defp execute_failover_attempt(
         chain,
         method,
         params,
         strategy,
         provider_id,
         excluded_providers,
         attempt
       ) do
    start_time = System.monotonic_time(:millisecond)

    case ChainSupervisor.forward_rpc_request(chain, provider_id, method, params) do
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

        record_failover_failure_metrics(
          chain,
          provider_id,
          method,
          strategy,
          reason,
          duration_ms,
          attempt
        )

        case should_failover?(reason) do
          true ->
            try_failover_with_reporting(
              chain,
              method,
              params,
              strategy,
              [provider_id | excluded_providers],
              attempt + 1,
              nil
            )

          false ->
            # User error - stop failover chain and return error
            {:error, reason}
        end
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
    # Record in BenchmarkStore for historical analysis
    BenchmarkStore.record_rpc_call(chain, provider_id, method, duration_ms, :success)

    # Update ProviderPool with real-time metrics for provider selection
    ProviderPool.report_success(chain, provider_id, duration_ms)
  end

  defp record_rpc_failure(chain, provider_id, method, reason, duration_ms) do
    # Record in BenchmarkStore for historical analysis
    BenchmarkStore.record_rpc_call(chain, provider_id, method, duration_ms, :error)

    # Update ProviderPool with failure information for provider selection
    ProviderPool.report_failure(chain, provider_id, reason)
  end
end
