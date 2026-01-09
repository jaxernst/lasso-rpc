defmodule LassoWeb.Dashboard.Components.MetricsTab do
  @moduledoc """
  LiveComponent for displaying provider and method performance metrics.
  Shows provider performance table and method performance breakdown charts.
  """
  use LassoWeb, :live_component

  alias LassoWeb.Dashboard.{Formatting, Status}

  @impl true
  def update(assigns, socket) do
    chain_config =
      case Lasso.Config.ConfigStore.get_chain(
             assigns.selected_profile,
             assigns.metrics_selected_chain
           ) do
        {:ok, config} -> config
        {:error, _} -> %{chain_id: "Unknown"}
      end

    socket =
      socket
      |> assign(assigns)
      |> assign(:chain_config, chain_config)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_metrics_chain", %{"chain" => chain}, socket) do
    send(self(), {:metrics_chain_selected, chain})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto">
      <div class="mx-auto max-w-7xl px-4 pb-4">
        <div class="flex items-center justify-between mb-2 py-4">
          <div class="flex gap-2 ">
            <%= for chain <- @available_chains do %>
              <button
                phx-click="select_metrics_chain"
                phx-value-chain={chain.name}
                phx-target={@myself}
                class={[
                  "px-4 py-2 rounded-lg text-sm font-medium transition-all",
                  if chain.name == @metrics_selected_chain do
                    "bg-sky-500/20 text-sky-300 border border-sky-500/50 shadow-md shadow-sky-500/10"
                  else
                    "bg-gray-800/50 text-gray-400 border border-gray-700 hover:border-sky-500/50 hover:text-sky-300 hover:bg-gray-800/80"
                  end
                ]}
              >
                <div class="flex items-center gap-2">
                  <span>{chain.display_name}</span>
                  <%= if chain.name == @metrics_selected_chain do %>
                    <span class="text-xs text-gray-500">ID: {@chain_config.chain_id}</span>
                  <% end %>
                </div>
              </button>
            <% end %>
          </div>
        </div>

        <%= if @metrics_loading do %>
          <div class="py-12">
            <div class=" text-center">
              <div class="inline-block h-8 w-8 animate-spin rounded-full border-4 border-solid border-sky-500 border-r-transparent">
              </div>
              <p class="mt-4 text-gray-400">Loading metrics...</p>
            </div>
          </div>
        <% else %>
          <div class="space-y-6">
            <.provider_performance_table
              provider_metrics={@provider_metrics}
              metrics_last_updated={@metrics_last_updated}
            />
            <.method_performance_breakdown method_metrics={@method_metrics} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Section Components
  # ============================================================================

  attr(:provider_metrics, :list, required: true)
  attr(:metrics_last_updated, :any, default: nil)

  defp provider_performance_table(assigns) do
    ~H"""
    <section>
      <div class="flex items-center justify-between mb-3 ">
        <h2 class="text-lg font-semibold flex items-center gap-2 text-white">
          <span>Provider Performance</span>
          <span class="text-xs text-gray-500 font-normal">
            ({length(@provider_metrics)} providers)
          </span>
        </h2>
        <%= if @metrics_last_updated do %>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <div class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></div>
            <span class="font-mono text-gray-400">
              {Calendar.strftime(@metrics_last_updated, "%H:%M:%S")}
            </span>
          </div>
        <% end %>
      </div>

      <%= if Enum.empty?(@provider_metrics) do %>
        <div class="rounded-xl border border-gray-700/60 border-dashed bg-gray-900/20 shadow-2xl overflow-hidden">
          <div class="flex flex-col items-center justify-center py-16 px-8">
            <div class="relative mb-4">
              <div class="bg-gray-800/40 flex h-12 w-12 items-center justify-center rounded-lg">
                <svg
                  class="h-6 w-6 text-gray-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="1.1"
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
              </div>
            </div>
            <div class="text-center">
              <p class="text-sm font-medium text-gray-400 mb-1">No metrics available</p>
              <p class="text-xs text-gray-600">
                No provider metrics recorded in the last 24 hours. Metrics will appear as requests flow through your RPC endpoints.
              </p>
            </div>
          </div>
        </div>
      <% else %>
        <div class="bg-gray-900/95 backdrop-blur-lg rounded-xl border border-gray-700/60 shadow-sm overflow-hidden">
          <div class="overflow-x-auto">
            <table class="w-full">
              <thead class="bg-gray-800/50 border-b border-gray-700/50">
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
              <tbody class="divide-y divide-gray-700/30">
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
                    <td class="px-4 py-3 font-medium text-white">{provider.name}</td>
                    <td class="px-4 py-3 text-right">
                      <%= if provider.avg_latency do %>
                        <div class="flex items-center justify-end gap-2">
                          <div class="flex-1 max-w-[100px] h-1.5 bg-gray-800 rounded-full overflow-hidden">
                            <div
                              class="h-full bg-sky-500 rounded-full transition-all"
                              style={"width: #{Formatting.calculate_bar_width(provider.avg_latency, @provider_metrics, :avg_latency)}%"}
                            >
                            </div>
                          </div>
                          <span class="text-sky-400 font-mono text-sm w-16">
                            {Formatting.safe_round(provider.avg_latency, 0)}ms
                          </span>
                        </div>
                      <% else %>
                        <span class="text-gray-600">—</span>
                      <% end %>
                    </td>
                    <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                      {if provider.p50_latency,
                        do: "#{Formatting.safe_round(provider.p50_latency, 0)}ms",
                        else: "—"}
                    </td>
                    <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                      {if provider.p95_latency,
                        do: "#{Formatting.safe_round(provider.p95_latency, 0)}ms",
                        else: "—"}
                    </td>
                    <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                      {if provider.p99_latency,
                        do: "#{Formatting.safe_round(provider.p99_latency, 0)}ms",
                        else: "—"}
                    </td>
                    <td class="px-4 py-3 text-right">
                      <%= if provider.consistency_ratio do %>
                        <span class={[
                          "font-mono text-sm",
                          Status.consistency_color(provider.consistency_ratio)
                        ]}>
                          {Formatting.safe_round(provider.consistency_ratio, 1)}x
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
                          {Formatting.safe_round(provider.success_rate * 100, 1)}%
                        </span>
                      <% else %>
                        <span class="text-gray-600">—</span>
                      <% end %>
                    </td>
                    <td class="px-4 py-3 text-right font-mono text-sm text-gray-400">
                      {Formatting.format_number(provider.total_calls)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:method_metrics, :list, required: true)

  defp method_performance_breakdown(assigns) do
    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-3 text-white">Method Performance Breakdown</h2>

      <%= if Enum.empty?(@method_metrics) do %>
        <div class="rounded-xl border border-gray-700/60 border-dashed bg-gray-900/20 shadow-2xl overflow-hidden">
          <div class="flex flex-col items-center justify-center py-16 px-8">
            <div class="relative mb-4">
              <div class="bg-gray-800/40 flex h-12 w-12 items-center justify-center rounded-lg">
                <svg
                  class="h-6 w-6 text-gray-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="1.1"
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
              </div>
            </div>
            <div class="text-center">
              <p class="text-sm font-medium text-gray-400 mb-1">No method metrics available</p>
              <p class="text-xs text-gray-600">
                No method performance data recorded in the last 24 hours. Method breakdowns will appear as RPC calls are made.
              </p>
            </div>
          </div>
        </div>
      <% else %>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <%= for method_data <- @method_metrics do %>
            <div class="bg-gray-900/95 backdrop-blur-lg rounded-xl border border-gray-700/60 shadow-2xl p-4">
              <div class="flex items-center justify-between mb-3 pb-2 border-b border-gray-700/50">
                <h3 class="font-mono text-sm text-sky-400">{method_data.method}</h3>
                <span class="text-xs text-gray-500">
                  {Formatting.format_number(method_data.total_calls)} calls
                </span>
              </div>

              <div class="space-y-2">
                <%= for {provider_stat, idx} <- Enum.with_index(method_data.providers, 1) do %>
                  <div class="flex items-center gap-2">
                    <div class="flex-none">
                      <span class={[
                        "inline-flex items-center justify-center w-4 h-4 rounded text-[9px] font-semibold",
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

                    <div class="flex-none w-28 truncate text-xs text-gray-300">
                      {provider_stat.provider_name}
                    </div>

                    <div class="flex-1 flex items-center gap-1.5">
                      <div class="flex-1 h-4 bg-gray-800/50 rounded overflow-hidden">
                        <div
                          class="h-full bg-gradient-to-r from-emerald-500 to-sky-500 flex items-center justify-end px-1.5"
                          style={"width: #{Formatting.calculate_method_bar_width(provider_stat.avg_latency, method_data.providers)}%"}
                        >
                          <span class="text-[10px] font-mono text-white font-semibold">
                            {Formatting.safe_round(provider_stat.avg_latency, 0)}ms
                          </span>
                        </div>
                      </div>
                    </div>

                    <div class="flex-none flex items-center gap-2 text-[10px]">
                      <span class={[
                        "font-mono",
                        if(provider_stat.success_rate >= 0.99,
                          do: "text-emerald-400",
                          else: "text-yellow-400"
                        )
                      ]}>
                        {Formatting.safe_round(provider_stat.success_rate * 100, 0)}%
                      </span>
                      <span class="text-gray-500">
                        {Formatting.format_number(provider_stat.total_calls)}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </section>
    """
  end
end
