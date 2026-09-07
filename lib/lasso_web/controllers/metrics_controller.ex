defmodule LassoWeb.MetricsController do
  use LassoWeb, :controller

  require Logger

  alias Lasso.Benchmarking.BenchmarkStore
  alias Lasso.Config.{ChainAlias, ConfigStore}
  alias Lasso.Config.ProfileValidator
  alias LassoWeb.Dashboard.{MetricsHelpers, ProviderConnection, ProviderStatusProjection}

  @doc """
  Returns comprehensive metrics for a specific chain.
  """
  @spec metrics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def metrics(conn, %{"chain" => chain_name}) do
    Logger.info("Metrics requested for chain: #{chain_name}")
    profile = ProfileValidator.default_profile()

    case ConfigStore.lookup_chain_id_in_profile(profile, chain_name) do
      {:ok, chain_id} ->
        json(conn, collect_chain_metrics(chain_id))

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "Chain not found",
          chain: chain_name,
          available_chains: available_chain_aliases(profile)
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
      available_chains: available_chain_aliases(ProfileValidator.default_profile())
    })
  end

  defp collect_chain_metrics(chain_id, profile \\ ProfileValidator.default_profile()) do
    {:ok, chain_config} = ConfigStore.get_chain(profile, chain_id)
    {:ok, provider_configs} = ConfigStore.get_providers(profile, chain_id)

    # Get performance data from BenchmarkStore
    chain_stats = BenchmarkStore.get_chain_wide_stats(profile, chain_id)
    realtime_stats = BenchmarkStore.get_realtime_stats(profile, chain_id)

    # Get provider leaderboard
    provider_leaderboard = BenchmarkStore.get_provider_leaderboard(profile, chain_id)

    # Calculate VM/system metrics
    vm_metrics = MetricsHelpers.collect_vm_metrics()

    total_calls = chain_stats.total_calls
    success_rate = if total_calls > 0, do: 100.0 * chain_stats.total_successes / total_calls
    {p50, p95} = MetricsHelpers.get_windowed_percentiles_from_ets(profile, chain_id)

    connections =
      ProviderConnection.fetch_connections(profile) |> Enum.filter(&(&1.chain_id == chain_id))

    chain_performance = %{
      total_calls: total_calls,
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      failovers_last_minute: nil,
      connected_providers: Enum.count(connections, &ProviderStatusProjection.available?/1),
      total_providers: length(provider_configs),
      recent_activity: nil,
      rpc_calls_per_second: nil,
      error_rate_percent: if(success_rate, do: 100.0 - success_rate)
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
              BenchmarkStore.get_real_time_stats(profile, chain_id, provider.provider_id),
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
        chain_id,
        provider_ids,
        rpc_methods,
        provider_configs
      )

    # Collect detailed performance data organized by method
    rpc_performance_by_method =
      collect_rpc_performance_by_method(
        profile,
        chain_id,
        provider_ids,
        rpc_methods,
        provider_configs
      )

    # Build comprehensive response
    %{
      chain: ChainAlias.canonical_slug(chain_id, chain_config.url_aliases),
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

  defp available_chain_aliases(profile) do
    profile
    |> ConfigStore.list_chains_for_profile()
    |> Enum.map(fn chain_id ->
      case ConfigStore.get_chain(profile, chain_id) do
        {:ok, chain_config} -> ChainAlias.canonical_slug(chain_id, chain_config.url_aliases)
        {:error, :not_found} -> ChainAlias.canonical_slug(chain_id)
      end
    end)
  end

  defp round_float(nil, _precision), do: nil

  defp round_float(value, precision) when is_float(value) or is_integer(value) do
    Float.round(value / 1, precision)
  end

  defp round_float(value, _precision), do: value
end
