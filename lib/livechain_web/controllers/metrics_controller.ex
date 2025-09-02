defmodule LivechainWeb.MetricsController do
  use LivechainWeb, :controller

  alias LivechainWeb.Dashboard.MetricsHelpers
  alias Livechain.RPC.ChainRegistry
  alias Livechain.Config.ConfigStore
  alias Livechain.Benchmarking.BenchmarkStore

  @doc """
  Returns comprehensive metrics for a specific chain.
  """
  def metrics(conn, %{"chain" => chain_name}) do
    Logger.info("Metrics requested for chain: #{chain_name}")

    # Check if chain is configured
    case ConfigStore.get_chain(chain_name) do
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
          available_chains: ConfigStore.get_all_chain_names()
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
      available_chains: ConfigStore.get_all_chain_names()
    })
  end

  defp collect_chain_metrics(chain_name) do
    # Get basic chain information
    chain_config = ConfigStore.get_chain(chain_name)
    provider_configs = ConfigStore.get_providers(chain_name)

    # Get performance data from BenchmarkStore
    chain_stats = BenchmarkStore.get_chain_wide_stats(chain_name)
    realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)

    # Get provider leaderboard
    provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)

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
          win_rate: Float.round(provider.win_rate || 0.0, 2),
          total_races: provider.total_races || 0,
          avg_margin_ms: provider.avg_margin_ms || 0,
          calls_last_minute:
            Map.get(
              BenchmarkStore.get_real_time_stats(chain_name, provider.provider_id),
              :calls_last_minute,
              0
            )
        }
      end)

    # Build comprehensive response
    %{
      chain: chain_name,
      chain_id: chain_config[:chain_id],
      timestamp: System.system_time(:millisecond),
      system_metrics: %{
        memory_mb: vm_metrics.mem_total_mb,
        cpu_percent: vm_metrics.cpu_percent,
        process_count: vm_metrics.process_count,
        run_queue: vm_metrics.run_queue
      },
      chain_performance: chain_performance,
      providers: provider_metrics,
      rpc_methods: Map.get(realtime_stats, :rpc_methods, []),
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
end
