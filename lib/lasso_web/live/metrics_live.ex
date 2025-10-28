defmodule LassoWeb.MetricsLive do
  use LassoWeb, :live_view
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Benchmarking.BenchmarkStore

  @impl true
  def mount(%{"chain" => chain_name}, _session, socket) do
    # Check if chain exists
    case ConfigStore.get_chain(chain_name) do
      {:ok, chain_config} ->
        # Initial load
        socket = socket
          |> assign(:chain_name, chain_name)
          |> assign(:chain_id, chain_config.chain_id)
          |> assign(:loading, true)
          |> assign(:error, nil)
          |> load_metrics()

        # Auto-refresh every 30 seconds
        if connected?(socket) do
          schedule_refresh()
        end

        {:ok, socket}

      {:error, :not_found} ->
        {:ok, assign(socket, :error, "Chain '#{chain_name}' not found")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_metrics(socket)}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, 30_000)
  end

  defp load_metrics(socket) do
    chain_name = socket.assigns.chain_name

    try do
      {:ok, provider_configs} = ConfigStore.get_providers(chain_name)
      provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
      realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)

      # Get all RPC methods we have data for
      rpc_methods = Map.get(realtime_stats, :rpc_methods, [])
      provider_ids = Enum.map(provider_configs, & &1.id)

      # Collect detailed metrics by provider
      provider_metrics = collect_provider_metrics(
        chain_name,
        provider_ids,
        provider_configs,
        provider_leaderboard,
        rpc_methods
      )

      # Collect method-level metrics for comparison
      method_metrics = collect_method_metrics(
        chain_name,
        provider_ids,
        provider_configs,
        rpc_methods
      )

      socket
      |> assign(:loading, false)
      |> assign(:provider_metrics, provider_metrics)
      |> assign(:method_metrics, method_metrics)
      |> assign(:last_updated, DateTime.utc_now())
    rescue
      error ->
        Logger.error("Failed to load metrics: #{inspect(error)}")
        assign(socket, :error, "Failed to load metrics")
    end
  end

  defp collect_provider_metrics(chain_name, provider_ids, provider_configs, leaderboard, rpc_methods) do
    provider_ids
    |> Enum.map(fn provider_id ->
      config = Enum.find(provider_configs, &(&1.id == provider_id))
      leaderboard_entry = Enum.find(leaderboard, &(&1.provider_id == provider_id))

      # Get aggregate stats across all methods
      method_stats = rpc_methods
        |> Enum.map(fn method ->
          BenchmarkStore.get_rpc_method_performance_with_percentiles(chain_name, provider_id, method)
        end)
        |> Enum.reject(&is_nil/1)

      # Calculate aggregates
      total_calls = Enum.reduce(method_stats, 0, fn stat, acc -> acc + stat.total_calls end)

      avg_latency = if total_calls > 0 do
        weighted_sum = Enum.reduce(method_stats, 0, fn stat, acc ->
          acc + (stat.avg_duration_ms * stat.total_calls)
        end)
        weighted_sum / total_calls
      else
        nil
      end

      p50_latency = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.percentiles.p50)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      p95_latency = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.percentiles.p95)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      p99_latency = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.percentiles.p99)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      success_rate = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.success_rate)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      # Calculate variance/consistency (P99/P50 ratio)
      consistency_ratio = if p50_latency && p99_latency && p50_latency > 0 do
        p99_latency / p50_latency
      else
        nil
      end

      %{
        id: provider_id,
        name: if(config, do: config.name, else: provider_id),
        avg_latency: avg_latency,
        p50_latency: p50_latency,
        p95_latency: p95_latency,
        p99_latency: p99_latency,
        success_rate: success_rate,
        total_calls: total_calls,
        consistency_ratio: consistency_ratio,
        score: if(leaderboard_entry, do: leaderboard_entry.score, else: nil),
        win_rate: if(leaderboard_entry, do: leaderboard_entry.win_rate, else: nil),
        method_count: length(method_stats)
      }
    end)
    |> Enum.reject(&(&1.total_calls == 0))
    |> Enum.sort_by(& &1.avg_latency || 999_999)
  end

  defp collect_method_metrics(chain_name, provider_ids, provider_configs, rpc_methods) do
    rpc_methods
    |> Enum.map(fn method ->
      provider_stats = provider_ids
        |> Enum.map(fn provider_id ->
          config = Enum.find(provider_configs, &(&1.id == provider_id))

          case BenchmarkStore.get_rpc_method_performance_with_percentiles(chain_name, provider_id, method) do
            nil -> nil
            stats ->
              %{
                provider_id: provider_id,
                provider_name: if(config, do: config.name, else: provider_id),
                avg_latency: stats.avg_duration_ms,
                p50_latency: stats.percentiles.p50,
                p95_latency: stats.percentiles.p95,
                p99_latency: stats.percentiles.p99,
                success_rate: stats.success_rate,
                total_calls: stats.total_calls
              }
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.avg_latency)

      if Enum.empty?(provider_stats) do
        nil
      else
        %{
          method: method,
          providers: provider_stats,
          total_calls: Enum.reduce(provider_stats, 0, fn stat, acc -> acc + stat.total_calls end)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.total_calls, :desc)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-white">
      <!-- Header -->
      <div class="border-b border-gray-800 bg-gray-900/50 backdrop-blur">
        <div class="mx-auto max-w-7xl px-4 py-6">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-2xl font-bold capitalize">{@chain_name} Performance Metrics</h1>
              <p class="text-sm text-gray-400 mt-1">Chain ID: {@chain_id}</p>
            </div>
            <%= if @last_updated do %>
              <div class="text-right">
                <div class="text-xs text-gray-500">Last updated</div>
                <div class="text-sm text-gray-300 font-mono">
                  {Calendar.strftime(@last_updated, "%H:%M:%S")}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%= if @error do %>
        <!-- Error State -->
        <div class="mx-auto max-w-7xl px-4 py-12">
          <div class="rounded-lg border border-red-500/50 bg-red-500/10 p-6 text-center">
            <p class="text-red-400">{@error}</p>
          </div>
        </div>
      <% else %>
        <!-- Main Content -->
        <div class="mx-auto max-w-7xl px-4 py-8 space-y-8">

          <!-- Provider Comparison Table -->
          <section>
            <h2 class="text-lg font-semibold mb-4 flex items-center gap-2">
              <span>Provider Performance</span>
              <span class="text-xs text-gray-500 font-normal">({length(@provider_metrics)} providers)</span>
            </h2>

            <div class="overflow-x-auto rounded-lg border border-gray-800">
              <table class="w-full">
                <thead class="bg-gray-900/50 border-b border-gray-800">
                  <tr class="text-left text-xs text-gray-400 uppercase tracking-wider">
                    <th class="px-4 py-3">Rank</th>
                    <th class="px-4 py-3">Provider</th>
                    <th class="px-4 py-3 text-right">Avg Latency</th>
                    <th class="px-4 py-3 text-right">P50</th>
                    <th class="px-4 py-3 text-right">P95</th>
                    <th class="px-4 py-3 text-right">P99</th>
                    <th class="px-4 py-3 text-right">P99/P50</th>
                    <th class="px-4 py-3 text-right">Success Rate</th>
                    <th class="px-4 py-3 text-right">Total Calls</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-800/50">
                  <%= for {provider, index} <- Enum.with_index(@provider_metrics, 1) do %>
                    <tr class="hover:bg-gray-900/30 transition-colors">
                      <td class="px-4 py-3">
                        <span class={[
                          "inline-flex items-center justify-center w-6 h-6 rounded-full text-xs font-semibold",
                          case index do
                            1 -> "bg-yellow-500/20 text-yellow-400"
                            2 -> "bg-gray-400/20 text-gray-300"
                            3 -> "bg-orange-600/20 text-orange-400"
                            _ -> "bg-gray-800 text-gray-500"
                          end
                        ]}>
                          {index}
                        </span>
                      </td>
                      <td class="px-4 py-3 font-medium">{provider.name}</td>
                      <td class="px-4 py-3 text-right">
                        <%= if provider.avg_latency do %>
                          <div class="flex items-center justify-end gap-2">
                            <div class="flex-1 max-w-[100px] h-1.5 bg-gray-800 rounded-full overflow-hidden">
                              <div
                                class="h-full bg-sky-500 rounded-full transition-all"
                                style={"width: #{calculate_bar_width(provider.avg_latency, @provider_metrics, :avg_latency)}%"}
                              >
                              </div>
                            </div>
                            <span class="text-sky-400 font-mono text-sm w-16">
                              {safe_round(provider.avg_latency, 0)}ms
                            </span>
                          </div>
                        <% else %>
                          <span class="text-gray-600">—</span>
                        <% end %>
                      </td>
                      <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                        <%= if provider.p50_latency, do: "#{safe_round(provider.p50_latency, 0)}ms", else: "—" %>
                      </td>
                      <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                        <%= if provider.p95_latency, do: "#{safe_round(provider.p95_latency, 0)}ms", else: "—" %>
                      </td>
                      <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                        <%= if provider.p99_latency, do: "#{safe_round(provider.p99_latency, 0)}ms", else: "—" %>
                      </td>
                      <td class="px-4 py-3 text-right">
                        <%= if provider.consistency_ratio do %>
                          <span class={[
                            "font-mono text-sm",
                            cond do
                              provider.consistency_ratio < 2.0 -> "text-emerald-400"
                              provider.consistency_ratio < 5.0 -> "text-yellow-400"
                              true -> "text-red-400"
                            end
                          ]}>
                            {safe_round(provider.consistency_ratio, 1)}x
                          </span>
                        <% else %>
                          <span class="text-gray-600">—</span>
                        <% end %>
                      </td>
                      <td class="px-4 py-3 text-right">
                        <%= if provider.success_rate do %>
                          <span class={[
                            "font-mono text-sm",
                            cond do
                              provider.success_rate >= 0.99 -> "text-emerald-400"
                              provider.success_rate >= 0.95 -> "text-yellow-400"
                              true -> "text-red-400"
                            end
                          ]}>
                            {safe_round(provider.success_rate * 100, 1)}%
                          </span>
                        <% else %>
                          <span class="text-gray-600">—</span>
                        <% end %>
                      </td>
                      <td class="px-4 py-3 text-right font-mono text-sm text-gray-400">
                        {format_number(provider.total_calls)}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </section>

          <!-- Method Breakdown -->
          <section>
            <h2 class="text-lg font-semibold mb-4">Method Performance Breakdown</h2>

            <div class="space-y-6">
              <%= for method_data <- @method_metrics do %>
                <div class="rounded-lg border border-gray-800 bg-gray-900/30 p-6">
                  <div class="flex items-center justify-between mb-4">
                    <h3 class="font-mono text-sky-400">{method_data.method}</h3>
                    <span class="text-xs text-gray-500">
                      {format_number(method_data.total_calls)} calls
                    </span>
                  </div>

                  <div class="space-y-2">
                    <%= for {provider_stat, idx} <- Enum.with_index(method_data.providers, 1) do %>
                      <div class="flex items-center gap-4">
                        <!-- Rank Badge -->
                        <div class="flex-none">
                          <span class={[
                            "inline-flex items-center justify-center w-5 h-5 rounded text-[10px] font-semibold",
                            case idx do
                              1 -> "bg-yellow-500/20 text-yellow-400"
                              2 -> "bg-gray-400/20 text-gray-300"
                              3 -> "bg-orange-600/20 text-orange-400"
                              _ -> "bg-gray-800 text-gray-500"
                            end
                          ]}>
                            {idx}
                          </span>
                        </div>

                        <!-- Provider Name -->
                        <div class="flex-none w-40 truncate text-sm text-gray-300">
                          {provider_stat.provider_name}
                        </div>

                        <!-- Latency Bar -->
                        <div class="flex-1 flex items-center gap-2">
                          <div class="flex-1 h-6 bg-gray-800 rounded overflow-hidden">
                            <div
                              class="h-full bg-gradient-to-r from-emerald-500 to-sky-500 flex items-center justify-end px-2"
                              style={"width: #{calculate_method_bar_width(provider_stat.avg_latency, method_data.providers)}%"}
                            >
                              <span class="text-xs font-mono text-white font-semibold">
                                {safe_round(provider_stat.avg_latency, 0)}ms
                              </span>
                            </div>
                          </div>
                        </div>

                        <!-- Success Rate -->
                        <div class="flex-none w-16 text-right">
                          <span class={[
                            "text-xs font-mono",
                            if(provider_stat.success_rate >= 0.99, do: "text-emerald-400", else: "text-yellow-400")
                          ]}>
                            {safe_round(provider_stat.success_rate * 100, 1)}%
                          </span>
                        </div>

                        <!-- Call Count -->
                        <div class="flex-none w-20 text-right text-xs text-gray-500">
                          {format_number(provider_stat.total_calls)}
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </section>

        </div>
      <% end %>
    </div>
    """
  end

  # Helper to calculate bar width for comparison visualization
  defp calculate_bar_width(value, all_providers, field) do
    max_value = all_providers
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 1 end)

    if max_value > 0 do
      min(100, (value / max_value) * 100)
    else
      0
    end
  end

  defp calculate_method_bar_width(value, provider_stats) do
    max_value = provider_stats
      |> Enum.map(& &1.avg_latency)
      |> Enum.max(fn -> 1 end)

    if max_value > 0 do
      min(100, (value / max_value) * 100)
    else
      0
    end
  end

  # Simple number formatting helper
  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
  defp format_number(number), do: to_string(number)

  # Safe rounding that handles both integers and floats
  defp safe_round(value, precision) when is_integer(value), do: value
  defp safe_round(value, precision) when is_float(value), do: Float.round(value, precision)
  defp safe_round(nil, _precision), do: nil
end
