defmodule LivechainWeb.Components.FloatingDetailsWindow do
  use LivechainWeb, :live_component

  alias LivechainWeb.Dashboard.{Helpers, MetricsHelpers, StatusHelpers, EndpointHelpers}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:details_collapsed, fn -> true end)
      |> assign_new(:hover_chain, fn -> nil end)
      |> assign_new(:hover_provider, fn -> nil end)
      |> assign_new(:events, fn -> [] end)
      |> assign_new(:chain_config_open, fn -> false end)
      |> assign(:total_connections, length(assigns.connections))
      |> assign(:connected_providers, Enum.count(assigns.connections, &(&1.status == :connected)))
      |> assign(
        :total_chains,
        assigns.connections |> Enum.map(& &1.chain) |> Enum.uniq() |> length()
      )

    ~H"""
    <div class="pointer-events-none absolute top-4 right-4 z-30">
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300", if(@details_collapsed, do: "w-96", else: "w-[36rem] max-h-[80vh]")]}>
        <!-- Header / Collapsed preview bar -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class={["h-2 w-2 rounded-full", if(@connected_providers == @total_connections,
    do: "bg-emerald-400",
    else: "bg-yellow-400")]}>
            </div>
            <div class="truncate text-xs text-gray-300">
              <%= cond do %>
                <% @selected_provider -> %>
                  {
                    case Enum.find(assigns.connections, &(&1.id == @selected_provider)) do
                      %{name: name} -> name
                      _ -> @selected_provider
                    end
                  }
                <% @selected_chain -> %>
                  {@selected_chain |> String.capitalize()}
                <% @hover_provider -> %>
                  Preview: {@hover_provider}
                <% @hover_chain -> %>
                  Preview: {@hover_chain}
                <% true -> %>
                  System Overview
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%= if @details_collapsed do %>
              <div class="text-[10px] flex items-center space-x-2 text-gray-400">
                <span class="text-emerald-300">{@connected_providers}/{@total_connections}</span>
                <span>•</span>
                <span class="text-purple-300">{@total_chains} chains</span>
              </div>
            <% end %>

            <!-- Chain Configuration Button -->
            <button
              phx-click="toggle_chain_config"
              phx-target={@myself}
              class={[
                "bg-gray-800/60 rounded px-2 py-1 text-xs transition-colors hover:bg-gray-700/60",
                if(@chain_config_open, do: "text-purple-300 bg-purple-900/30", else: "text-gray-200")
              ]}
              title="Configure Chains"
            >
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
              </svg>
            </button>

            <button
              phx-click="toggle_details_panel"
              phx-target={@myself}
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              {if @details_collapsed, do: "↖", else: "↗"}
            </button>
          </div>
        </div>

        <%= if @details_collapsed do %>
          <div class="space-y-2 px-3 py-2">
            <div class="grid grid-cols-2 gap-3">
              <div class="bg-gray-800/40 rounded-md px-2 py-1.5">
                <div class="text-[10px] uppercase tracking-wide text-gray-400">Providers</div>
                <div class="text-sm font-semibold text-white">
                  <span class="text-emerald-300">{@connected_providers}</span>
                  <span class="text-gray-500">/{@total_connections}</span>
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1.5">
                <div class="text-[10px] uppercase tracking-wide text-gray-400">Chains</div>
                <div class="text-sm font-semibold text-purple-300">{@total_chains}</div>
              </div>
            </div>
            <div class="grid grid-cols-3 gap-2">
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">RPC/s</div>
                <div class="text-xs font-medium text-sky-300">
                  {MetricsHelpers.rpc_calls_per_second(@routing_events)}
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">Errors</div>
                <div class="text-xs font-medium text-red-300">
                  {MetricsHelpers.error_rate_percent(@routing_events)}%
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">Failovers</div>
                <div class="text-xs font-medium text-yellow-300">
                  {MetricsHelpers.failovers_last_minute(@routing_events)}
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <!-- Body (only when expanded) -->
          <div class="max-h-[70vh] overflow-auto">
            <%= if @selected_provider do %>
              <.provider_details_panel
                provider={@selected_provider}
                connections={@connections}
                routing_events={@routing_events}
                provider_events={@provider_events}
                events={@events}
                selected_chain={@selected_chain}
                myself={@myself}
              />
            <% else %>
              <%= if @selected_chain do %>
                <.chain_details_panel
                  chain={@selected_chain}
                  connections={@connections}
                  routing_events={@routing_events}
                  provider_events={@provider_events}
                  events={@events}
                  myself={@myself}
                />
              <% else %>
                <.meta_stats_panel
                  connections={@connections}
                  routing_events={@routing_events}
                  provider_events={@provider_events}
                />
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_details_panel", _params, socket) do
    send(self(), {:toggle_details_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_chain_config", _params, socket) do
    send(self(), {:toggle_chain_config})
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_chain", params, socket) do
    send(self(), {:handle_event, "select_chain", params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", params, socket) do
    send(self(), {:handle_event, "select_provider", params})
    {:noreply, socket}
  end

  defp meta_stats_panel(assigns) do
    assigns =
      assigns
      |> assign_new(:connections, fn -> [] end)
      |> assign_new(:routing_events, fn -> [] end)
      |> assign_new(:provider_events, fn -> [] end)

    total = length(assigns.connections)
    connected = Enum.count(assigns.connections, &(&1.status == :connected))
    chains = assigns.connections |> Enum.map(& &1.chain) |> Enum.uniq() |> length()

    assigns =
      assign(assigns, :__meta_totals, %{total: total, connected: connected, chains: chains})

    ~H"""
    <div class="space-y-4 p-4">
      <div class="grid grid-cols-3 gap-3">
        <div class="bg-gray-800/50 rounded-lg p-3">
          <div class="text-[11px] text-gray-400">Chains</div>
          <div class="text-lg font-bold text-white">{@__meta_totals.chains}</div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3">
          <div class="text-[11px] text-gray-400">Providers</div>
          <div class="text-lg font-bold text-white">{@__meta_totals.total}</div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3">
          <div class="text-[11px] text-gray-400">Connected</div>
          <div class="text-lg font-bold text-emerald-400">{@__meta_totals.connected}</div>
        </div>
      </div>
      <div class="text-xs text-gray-400">
        <div class="mb-1 font-semibold text-gray-300">Recent activity</div>
        <div class="max-h-40 space-y-1 overflow-auto">
          <%= for e <- Enum.take(@routing_events, 5) do %>
            <div>
              <span class="text-gray-500">[{e.ts}]</span>
              <span class="text-purple-300">{e.chain}</span>
              <span class="text-sky-300">{e.method}</span>
              via <span class="text-emerald-300">{e.provider_id}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp chain_details_panel(assigns) do
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    assigns =
      Map.merge(assigns, %{
        chain_connections: chain_connections,
        chain_events: Enum.filter(assigns.routing_events, &(&1.chain == assigns.chain)),
        chain_provider_events: Enum.filter(assigns.provider_events, &(&1.chain == assigns.chain)),
        chain_unified_events: Enum.filter(Map.get(assigns, :events, []), fn e -> e[:chain] == assigns.chain end),
        chain_endpoints: EndpointHelpers.get_chain_endpoints(assigns, assigns.chain),
        chain_performance: MetricsHelpers.get_chain_performance_metrics(assigns, assigns.chain),
        sample_curl: Helpers.get_sample_curl_command(),
        selected_strategy_tab: "fastest",
        selected_provider_tab: List.first(chain_connections),
        active_endpoint_tab: "strategy",
        last_decision: Helpers.get_last_decision(assigns.routing_events, assigns.chain)
      })

    ~H"""
    <div class="flex h-full flex-col">
      <!-- Header -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center space-x-3">
            <div class={[
              "h-3 w-3 rounded-full",
              if(@chain_performance.connected_providers == @chain_performance.total_providers && @chain_performance.connected_providers > 0,
                do: "bg-emerald-400",
                else: if(@chain_performance.connected_providers == 0, do: "bg-red-400", else: "bg-yellow-400")
              )
            ]}>
            </div>
            <div>
              <h3 class="text-lg font-semibold capitalize text-white">{@chain}</h3>
              <div class="text-xs text-gray-400 flex items-center gap-2">
                <span>{Helpers.get_chain_id(@chain)}</span>
                <span>•</span>
                <span><span class="text-emerald-400">{@chain_performance.connected_providers}</span>/<span class="text-gray-500">{@chain_performance.total_providers}</span> providers</span>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="select_chain" phx-value-chain="" phx-target={@myself} class="rounded border border-gray-600 px-2 py-1 text-xs text-gray-400 transition-colors hover:border-gray-400 hover:text-white">
              Close
            </button>
          </div>
        </div>
      </div>

      <!-- KPIs -->
      <div class="border-gray-700/50 p-4">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Latency p50 (5m)</div>
            <div class="h-6 flex items-center justify-center">
              <div class="text-lg font-bold text-sky-400">{if @chain_performance.p50_latency, do: "#{@chain_performance.p50_latency}ms", else: "—"}</div>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Latency p95 (5m)</div>
            <div class="h-6 flex items-center justify-center">
              <div class="text-lg font-bold text-sky-400">{if @chain_performance.p95_latency, do: "#{@chain_performance.p95_latency}ms", else: "—"}</div>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Success (5m)</div>
            <div class="h-6 flex items-center justify-center">
              <div class={["text-lg font-bold", if((@chain_performance.success_rate || 0.0) >= 95.0, do: "text-emerald-400", else: if((@chain_performance.success_rate || 0.0) >= 80.0, do: "text-yellow-400", else: "text-red-400"))]}> {if @chain_performance.success_rate, do: "#{@chain_performance.success_rate}%", else: "—"}</div>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Connected</div>
            <div class="h-6 flex items-center justify-center">
              <div class="text-lg font-bold text-white"><span class="text-emerald-400">{@chain_performance.connected_providers}</span><span class="text-gray-500">/{@chain_performance.total_providers}</span></div>
            </div>
          </div>
        </div>
      </div>

      <!-- Routing decision context -->
      <div class="border-gray-700/50 border-t p-4">
        <h4 class="mb-2 text-sm font-semibold text-gray-300">Routing decisions</h4>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-1">
            <div class="text-[11px] text-gray-400 mb-1">Last decision</div>
            <%= if @last_decision do %>
              <div class="text-xs text-gray-300 space-y-1">
                <div class="flex items-center justify-between gap-2">
                  <div class="truncate"><span class="text-sky-300">{@last_decision.method}</span> <span class="text-gray-500">→</span> <span class="text-emerald-300 truncate">{@last_decision.provider_id}</span></div>
                  <div class="shrink-0 text-yellow-300 font-mono">{@last_decision.duration_ms}ms</div>
                </div>
                <div class="text-[11px] text-gray-400 flex items-center gap-2">
                  <span>strategy: {Map.get(@last_decision, :strategy, "—")}</span>
                  <span>•</span>
                  <span>{relative_time(@last_decision.timestamp)}</span>
                </div>
              </div>
            <% else %>
              <div class="text-xs text-gray-500">No recent decisions</div>
            <% end %>
          </div>
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-2">
            <div class="text-[11px] text-gray-400 mb-1">Recent activity (5m)</div>
            <div class="grid grid-cols-3 gap-3 text-center">
              <div>
                <div class="text-sm font-semibold text-sky-300">{length(@chain_events)}</div>
                <div class="text-[10px] text-gray-400">Requests</div>
              </div>
              <div>
                <div class="text-sm font-semibold text-emerald-300">{Enum.count(@chain_events, &(&1.status == "success"))}</div>
                <div class="text-[10px] text-gray-400">Success</div>
              </div>
              <div>
                <div class="text-sm font-semibold text-red-300">{Enum.count(@chain_events, &(&1.status == "error"))}</div>
                <div class="text-[10px] text-gray-400">Errors</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Provider performance table -->
      <div class="border-gray-700/50 border-t p-4">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">Provider performance</h4>
        <div class="space-y-2">
          <%= for conn <- @chain_connections do %>
            <div class="bg-gray-800/30 flex items-center justify-between rounded-lg p-3">
              <div class="flex items-center space-x-3">
                <div class={[
                  "h-2 w-2 rounded-full",
                  case conn.status do
                    :connected -> "bg-emerald-400"
                    :disconnected -> "bg-red-400"
                    _ -> "bg-yellow-400"
                  end
                ]}>
                </div>
                <div>
                  <div class="text-sm font-medium text-white">{conn.name}</div>
                  <div class="text-[11px] text-gray-400">{get_in(conn, [:config, :url]) || conn.id}</div>
                </div>
              </div>
              <div class="flex items-center space-x-4 text-xs">
                <div class="text-center">
                  <div class="text-sky-300 font-semibold">
                    {case MetricsHelpers.get_provider_performance_metrics(conn.id, @connections, @routing_events) do
                      %{p50_latency: nil} -> "—"
                      %{p50_latency: latency} -> "#{latency}ms"
                      _ -> "—"
                    end}
                  </div>
                  <div class="text-[10px] text-gray-400">Latency</div>
                </div>
                <div class="text-center">
                  <div class="text-emerald-300 font-semibold">
                    {case MetricsHelpers.get_provider_performance_metrics(conn.id, @connections, @routing_events) do
                      %{success_rate: nil} -> "—"
                      %{success_rate: rate} -> "#{rate}%"
                      _ -> "—"
                    end}
                  </div>
                  <div class="text-[10px] text-gray-400">Success</div>
                </div>
                <div class="text-center">
                  <div class="text-purple-300 font-semibold">
                    {case MetricsHelpers.get_provider_performance_metrics(conn.id, @connections, @routing_events) do
                      %{calls_last_5m: count} -> count
                      _ -> 0
                    end}
                  </div>
                  <div class="text-[10px] text-gray-400">Requests</div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp provider_details_panel(assigns) do
    assigns =
      Map.merge(assigns, %{
        provider_connection: Enum.find(assigns.connections, &(&1.id == assigns.provider)),
        provider_events: Enum.filter(assigns.routing_events, &(&1.provider_id == assigns.provider)),
        provider_pool_events: Enum.filter(assigns.provider_events, &(&1.provider_id == assigns.provider)),
        provider_unified_events: Enum.filter(Map.get(assigns, :events, []), fn e -> e[:provider_id] == assigns.provider end),
        performance_metrics: MetricsHelpers.get_provider_performance_metrics(assigns.provider, assigns.connections, assigns.routing_events),
        last_decision: Helpers.get_last_decision(assigns.routing_events, nil, assigns.provider)
      })

    ~H"""
    <div class="flex h-full flex-col">
      <!-- Header -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center space-x-3">
            <div class={[
              "h-3 w-3 rounded-full",
              if(@provider_connection && @provider_connection.status == :connected,
                do: "bg-emerald-400",
                else: if(@provider_connection && @provider_connection.status == :disconnected,
                  do: "bg-red-400",
                  else: "bg-yellow-400"
                )
              )
            ]}>
            </div>
            <div>
              <h3 class="text-lg font-semibold text-white">
                {if @provider_connection, do: @provider_connection.name, else: @provider}
              </h3>
              <div class="text-xs text-gray-400">
                {if @provider_connection, do: String.capitalize(@provider_connection.chain || "unknown"), else: "Provider"} • {StatusHelpers.provider_status_label(@provider_connection)}
              </div>
            </div>
          </div>
          <div class="flex items-center space-x-2">
            <%= if assigns[:selected_chain] do %>
              <button
                phx-click="select_provider"
                phx-value-provider=""
                phx-target={@myself}
                class="rounded border border-gray-600 px-2 py-1 text-sm text-gray-400 transition-colors hover:border-gray-400 hover:text-white"
              >
                Back to Chain
              </button>
            <% end %>
            <button
              phx-click="select_provider"
              phx-value-provider=""
              phx-target={@myself}
              class="rounded border border-gray-600 px-2 py-1 text-xs text-gray-400 transition-colors hover:border-gray-400 hover:text-white"
            >
              Close
            </button>
          </div>
        </div>
      </div>

      <!-- Provider KPIs -->
      <div class="border-gray-700/50 p-4">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div class="bg-gray-800/50 rounded-lg p-3 text-center">
            <div class="text-[11px] text-gray-400">Avg Latency (5m)</div>
            <div class="text-lg font-bold text-sky-400">
              {if @performance_metrics.avg_latency, do: "#{@performance_metrics.avg_latency}ms", else: "—"}
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center">
            <div class="text-[11px] text-gray-400">Success Rate (5m)</div>
            <div class={["text-lg font-bold", if((@performance_metrics.success_rate || 0.0) >= 95.0, do: "text-emerald-400", else: if((@performance_metrics.success_rate || 0.0) >= 80.0, do: "text-yellow-400", else: "text-red-400"))]}>
              {if @performance_metrics.success_rate, do: "#{@performance_metrics.success_rate}%", else: "—"}
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center">
            <div class="text-[11px] text-gray-400">Request Count (5m)</div>
            <div class="text-lg font-bold text-white">{@performance_metrics.request_count || 0}</div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center">
            <div class="text-[11px] text-gray-400">Status</div>
            <div class={[
              "text-sm font-bold",
              if(@provider_connection && @provider_connection.status == :connected,
                do: "text-emerald-400",
                else: "text-red-400"
              )
            ]}>
              {StatusHelpers.provider_status_label(@provider_connection)}
            </div>
          </div>
        </div>
      </div>

      <!-- Recent activity -->
      <div class="border-gray-700/50 border-t p-4">
        <h4 class="mb-2 text-sm font-semibold text-gray-300">Recent requests</h4>
        <div class="max-h-60 space-y-1 overflow-auto">
          <%= if length(@provider_events) > 0 do %>
            <%= for event <- Enum.take(@provider_events, 10) do %>
              <div class="bg-gray-800/30 flex items-center justify-between rounded px-3 py-2">
                <div class="flex items-center space-x-2">
                  <div class={[
                    "h-1.5 w-1.5 rounded-full",
                    case event.status do
                      "success" -> "bg-emerald-400"
                      "error" -> "bg-red-400"
                      _ -> "bg-yellow-400"
                    end
                  ]}>
                  </div>
                  <span class="text-xs text-sky-300">{event.method || "—"}</span>
                  <span class="text-xs text-gray-400">({event.chain})</span>
                </div>
                <div class="flex items-center space-x-2">
                  <span class="text-[11px] font-mono text-yellow-300">
                    {if event.duration_ms, do: "#{event.duration_ms}ms", else: "—"}
                  </span>
                  <span class="text-[11px] text-gray-500">
                    {relative_time(event.timestamp)}
                  </span>
                </div>
              </div>
            <% end %>
          <% else %>
            <div class="text-center text-xs text-gray-500">No recent activity</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp relative_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> relative_time(dt)
      _ -> timestamp
    end
  end

  defp relative_time(%DateTime{} = timestamp) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, timestamp, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp relative_time(_), do: "—"
end
