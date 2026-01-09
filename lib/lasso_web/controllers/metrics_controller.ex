defmodule LassoWeb.MetricsController do
  use LassoWeb, :controller

  require Logger

  alias Lasso.Benchmarking.BenchmarkStore
  alias Lasso.Config.ConfigStore
  alias LassoWeb.Dashboard.MetricsHelpers

  @doc """
  Returns comprehensive metrics for a specific chain.
  """
  @spec metrics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def metrics(conn, %{"chain" => chain_name}) do
    Logger.info("Metrics requested for chain: #{chain_name}")
    profile = "default"

    # Check if chain is configured
    case ConfigStore.get_chain(profile, chain_name) do
      {:ok, _chain_config} ->
        # Chain exists, collect metrics
        metrics_data = collect_chain_metrics(chain_name)
        json(conn, metrics_data)

      {:error, :not_found} ->
        # Chain not found
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "Chain not found",
          chain: chain_name,
          available_chains: ConfigStore.list_chains()
        })
    end
  end

  def metrics(conn, _params) do
    # No chain specified
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Chain parameter required",
      usage: "/api/metrics/{chain_name}",
      available_chains: ConfigStore.list_chains()
    })
  end

  defp collect_chain_metrics(chain_name, profile \\ "default") do
    # Get basic chain information
    {:ok, chain_config} = ConfigStore.get_chain(profile, chain_name)
    {:ok, provider_configs} = ConfigStore.get_providers(profile, chain_name)

    # Get performance data from BenchmarkStore
    chain_stats = BenchmarkStore.get_chain_wide_stats(profile, chain_name)
    realtime_stats = BenchmarkStore.get_realtime_stats(profile, chain_name)

    # Get provider leaderboard
    provider_leaderboard = BenchmarkStore.get_provider_leaderboard(profile, chain_name)

    # Calculate VM/system metrics
    vm_metrics = MetricsHelpers.collect_vm_metrics()

    # Get routing events from telemetry (simplified implementation)
    # In a full implementation, this would aggregate telemetry events
    # For now, return empty list with placeholder for future implementation
    routing_events = []

    # Calculate chain performance metrics
    chain_performance = %{
      total_calls: Map.get(chain_stats, :total_calls, 0),
      success_rate: calculate_success_rate(realtime_stats),
      p50_latency: Map.get(realtime_stats, :p50_latency, nil),
      p95_latency: Map.get(realtime_stats, :p95_latency, nil),
      failovers_last_minute: Map.get(realtime_stats, :failovers_last_minute, 0),
      connected_providers: Map.get(realtime_stats, :connected_providers, 0),
      total_providers: Map.get(realtime_stats, :total_providers, 0),
      recent_activity: Map.get(realtime_stats, :recent_activity, 0),
      rpc_calls_per_second: MetricsHelpers.rpc_calls_per_second(routing_events),
      error_rate_percent: MetricsHelpers.error_rate_percent(routing_events)
    }

    # Get provider-specific metrics
    provider_metrics =
      Enum.map(provider_leaderboard, fn provider ->
        %{
          id: provider.provider_id,
          name: get_provider_name(provider.provider_id, provider_configs),
          score: Float.round(provider.score || 0.0, 2),
          success_rate: Float.round(provider.success_rate || 0.0, 2),
          total_calls: provider.total_calls || 0,
          avg_latency_ms: Float.round(provider.avg_latency_ms || 0.0, 2),
          calls_last_minute:
            Map.get(
              BenchmarkStore.get_real_time_stats(profile, chain_name, provider.provider_id),
              :calls_last_minute,
              0
            )
        }
      end)

    # Get detailed per-method RPC performance metrics
    rpc_methods = Map.get(realtime_stats, :rpc_methods, [])
    provider_ids = Enum.map(provider_configs, & &1.id)

    # Collect detailed performance data organized by provider
    rpc_performance_by_provider =
      collect_rpc_performance_by_provider(
        profile,
        chain_name,
        provider_ids,
        rpc_methods,
        provider_configs
      )

    # Collect detailed performance data organized by method
    rpc_performance_by_method =
      collect_rpc_performance_by_method(
        profile,
        chain_name,
        provider_ids,
        rpc_methods,
        provider_configs
      )

    # Build comprehensive response
    %{
      chain: chain_name,
      chain_id: chain_config.chain_id,
      timestamp: System.system_time(:millisecond),
      system_metrics: %{
        memory_mb: vm_metrics.mem_total_mb,
        cpu_percent: vm_metrics.cpu_percent,
        process_count: vm_metrics.process_count,
        run_queue: vm_metrics.run_queue
      },
      chain_performance: chain_performance,
      providers: provider_metrics,
      rpc_methods: rpc_methods,
      rpc_performance_by_provider: rpc_performance_by_provider,
      rpc_performance_by_method: rpc_performance_by_method,
      last_updated: Map.get(realtime_stats, :last_updated, System.system_time(:millisecond))
    }
  end

  defp calculate_success_rate(realtime_stats) do
    case Map.get(realtime_stats, :success_rate) do
      nil -> nil
      rate when is_float(rate) -> Float.round(rate, 1)
      rate when is_integer(rate) -> rate / 1.0
    end
  end

  defp get_provider_name(provider_id, provider_configs) do
    case Enum.find(provider_configs, &(&1.id == provider_id)) do
      nil -> provider_id
      provider -> Map.get(provider, :name, provider_id)
    end
  end

  defp collect_rpc_performance_by_provider(
         profile,
         chain_name,
         provider_ids,
         rpc_methods,
         provider_configs
       ) do
    Enum.map(provider_ids, fn provider_id ->
      method_metrics =
        rpc_methods
        |> Enum.map(fn method ->
          collect_method_performance(profile, chain_name, provider_id, method)
        end)
        |> Enum.reject(&is_nil/1)

      %{
        provider_id: provider_id,
        provider_name: get_provider_name(provider_id, provider_configs),
        methods: method_metrics
      }
    end)
    |> Enum.reject(fn provider -> Enum.empty?(provider.methods) end)
  end

  defp collect_rpc_performance_by_method(
         profile,
         chain_name,
         provider_ids,
         rpc_methods,
         provider_configs
       ) do
    rpc_methods
    |> Enum.map(fn method ->
      provider_metrics =
        provider_ids
        |> Enum.map(fn provider_id ->
          case collect_method_performance(profile, chain_name, provider_id, method) do
            nil ->
              nil

            metrics ->
              Map.merge(metrics, %{
                provider_id: provider_id,
                provider_name: get_provider_name(provider_id, provider_configs)
              })
          end
        end)
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(provider_metrics) do
        nil
      else
        %{
          method: method,
          providers: provider_metrics
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_method_performance(profile, chain_name, provider_id, method) do
    case BenchmarkStore.get_rpc_method_performance_with_percentiles(
           profile,
           chain_name,
           provider_id,
           method
         ) do
      nil ->
        nil

      metrics ->
        %{
          method: method,
          avg_latency_ms: round_float(metrics.avg_duration_ms, 2),
          p50_latency_ms: metrics.percentiles.p50,
          p90_latency_ms: metrics.percentiles.p90,
          p95_latency_ms: metrics.percentiles.p95,
          p99_latency_ms: metrics.percentiles.p99,
          success_rate: round_float(metrics.success_rate, 4),
          total_calls: metrics.total_calls,
          last_updated: metrics.last_updated
        }
    end
  end

  defp round_float(nil, _precision), do: nil

  defp round_float(value, precision) when is_float(value) or is_integer(value) do
    Float.round(value / 1, precision)
  end

  defp round_float(value, _precision), do: value
end
