defmodule LassoWeb.Dashboard.Components.ChainDetailsPanel do
  @moduledoc """
  LiveComponent for displaying chain details in a floating window.
  Shows chain status, endpoint configuration, performance metrics, and routing decisions.
  """
  use LassoWeb, :live_component

  alias LassoWeb.Components.DetailPanelComponents
  alias LassoWeb.Dashboard.{EndpointHelpers, Formatting, Helpers}

  @impl true
  def update(assigns, socket) do
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    consensus_height =
      chain_connections
      |> Enum.find_value(fn conn -> Map.get(conn, :consensus_height) end)

    last_decision =
      Helpers.get_last_decision(
        Map.get(assigns, :selected_chain_events, []),
        assigns.chain
      )

    socket =
      socket
      |> assign(assigns)
      |> assign(:chain_connections, chain_connections)
      |> assign(:consensus_height, consensus_height)
      |> assign(:last_decision, last_decision)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col text-gray-200 overflow-hidden" id={"chain-details-#{@chain}"}>
      <.chain_header
        chain={@chain}
        selected_profile={@selected_profile}
        consensus_height={@consensus_height}
        chain_metrics={@selected_chain_metrics}
      />

      <.chain_metrics_strip chain_metrics={@selected_chain_metrics} />

      <.endpoint_config_section
        chain={@chain}
        selected_profile={@selected_profile}
        chain_connections={@chain_connections}
        chain_endpoints={@selected_chain_endpoints}
      />

      <.routing_decisions_section
        last_decision={@last_decision}
        connections={@connections}
        chain_metrics={@selected_chain_metrics}
      />
    </div>
    """
  end

  # ============================================================================
  # Private Section Components
  # ============================================================================

  attr :chain, :string, required: true
  attr :selected_profile, :string, required: true
  attr :consensus_height, :integer, default: nil
  attr :chain_metrics, :map, required: true

  defp chain_header(assigns) do
    connected = Map.get(assigns.chain_metrics, :connected_providers, 0)
    total = Map.get(assigns.chain_metrics, :total_providers, 0)
    is_healthy = connected == total and connected > 0
    is_down = connected == 0

    status =
      cond do
        is_healthy -> :healthy
        is_down -> :down
        true -> :degraded
      end

    assigns =
      assigns
      |> assign(:connected, connected)
      |> assign(:total, total)
      |> assign(:status, status)

    ~H"""
    <div class="p-6 pb-5 border-b border-gray-800 relative overflow-hidden">
      <div class="flex items-center justify-between mb-1.5 relative z-10">
        <h3 class="text-3xl font-bold text-white tracking-tight capitalize">
          {Helpers.get_chain_display_name(@selected_profile, @chain)}
        </h3>
        <DetailPanelComponents.status_badge status={@status} />
      </div>

      <div class="flex items-center gap-3 text-sm mb-6 relative z-10">
        <span class="text-gray-500">
          Chain ID
          <span class="font-mono text-gray-300">
            {Helpers.get_chain_id(@selected_profile, @chain)}
          </span>
        </span>
        <span class="text-gray-400">·</span>
        <span class="text-gray-500">
          Block
          <%= if @consensus_height do %>
            <span class="font-mono text-emerald-400">
              {Formatting.format_number(@consensus_height)}
            </span>
          <% else %>
            <span class="text-gray-600">—</span>
          <% end %>
        </span>
        <span class="text-gray-400">·</span>
        <span class={["text-gray-500", if(@connected < @total, do: "", else: "")]}>
          <span class={[
            "font-mono",
            if(@connected == @total && @connected > 0,
              do: "text-gray-300",
              else: if(@connected == 0, do: "text-red-400", else: "text-yellow-400")
            )
          ]}>
            {@connected}/{@total}
          </span>
          providers
        </span>
      </div>
    </div>
    """
  end

  attr :chain_metrics, :map, required: true

  defp chain_metrics_strip(assigns) do
    ~H"""
    <DetailPanelComponents.metrics_strip>
      <:metric
        label="Latency p50"
        value={
          if Map.get(@chain_metrics, :p50_latency),
            do: "#{Map.get(@chain_metrics, :p50_latency)}ms",
            else: "—"
        }
      />
      <:metric
        label="Latency p95"
        value={
          if Map.get(@chain_metrics, :p95_latency),
            do: "#{Map.get(@chain_metrics, :p95_latency)}ms",
            else: "—"
        }
      />
      <:metric
        label="Success"
        value={
          if (success_rate = Map.get(@chain_metrics, :success_rate, 0.0)) > 0,
            do: "#{success_rate}%",
            else: "—"
        }
        value_class={
          success_rate = Map.get(@chain_metrics, :success_rate, 0.0)

          cond do
            success_rate >= 95.0 -> "text-emerald-400"
            success_rate >= 80.0 -> "text-yellow-400"
            true -> "text-red-400"
          end
        }
      />
      <:metric
        label="RPS"
        value={
          rps = Map.get(@chain_metrics, :rps, 0.0)
          if rps > 0, do: "#{rps}", else: "0"
        }
        value_class="text-purple-400"
      />
    </DetailPanelComponents.metrics_strip>
    """
  end

  attr :chain, :string, required: true
  attr :selected_profile, :string, required: true
  attr :chain_connections, :list, required: true
  attr :chain_endpoints, :map, required: true

  defp endpoint_config_section(assigns) do
    ~H"""
    <div class="p-6 border-b border-gray-800">
      <div
        id={"endpoint-config-#{@chain}"}
        phx-hook="TabSwitcher"
        phx-update="ignore"
        data-chain={@chain}
        data-chain-id={Helpers.get_chain_id(@selected_profile, @chain)}
        class="relative z-10"
      >
        <div class="space-y-4">
          <div>
            <label class="text-xs font-semibold uppercase tracking-wider text-gray-500 block mb-3">
              Routing Strategy
            </label>
            <div class="flex flex-wrap gap-2">
              <%= for strategy <- EndpointHelpers.available_strategies() do %>
                <button
                  data-strategy={strategy}
                  class="px-3 py-1.5 rounded-md text-xs font-medium transition-all border border-gray-700 bg-gray-800/50 text-gray-400 hover:border-gray-600 hover:text-gray-300"
                >
                  <%= case strategy do %>
                    <% "fastest" -> %>
                      ⚡ Fastest
                    <% "round-robin" -> %>
                      🔄 Round Robin
                    <% "latency-weighted" -> %>
                      ⚖️ Latency Weighted
                    <% other -> %>
                      {other}
                  <% end %>
                </button>
              <% end %>
            </div>
          </div>

          <div class="bg-black/20 border border-gray-700/50 rounded-xl overflow-hidden">
            <div class="flex items-stretch border-b border-gray-800/50" id="http-row">
              <div class="bg-gray-800/30 w-14 shrink-0 px-3 py-2 flex items-center justify-center border-r border-gray-800/50">
                <span class="text-[10px] font-bold text-gray-500 uppercase">HTTP</span>
              </div>
              <div
                class="flex-grow px-3 py-2 font-mono text-xs text-gray-300 flex items-center overflow-hidden whitespace-nowrap"
                id="endpoint-url"
              >
                {EndpointHelpers.get_strategy_http_url(@chain_endpoints, "fastest")}
              </div>
              <button
                data-copy-text={EndpointHelpers.get_strategy_http_url(@chain_endpoints, "fastest")}
                class="px-4 py-2 hover:bg-indigo-500/20 hover:text-indigo-300 text-gray-500 border-l border-gray-800/50 transition-colors flex items-center justify-center group"
                title="Copy HTTP URL"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4 group-hover:scale-110 transition-transform"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15.666 3.888A2.25 2.25 0 0013.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 01-.75.75H9a.75.75 0 01-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 01-2.25 2.25H6.75A2.25 2.25 0 014.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 011.927-.184"
                  />
                </svg>
              </button>
            </div>

            <div class="flex items-stretch" id="ws-row">
              <div class="bg-gray-800/30 w-14 shrink-0 px-3 py-2 flex items-center justify-center border-r border-gray-800/50">
                <span class="text-[10px] font-bold text-gray-500 uppercase">WS</span>
              </div>
              <div
                class="flex-grow px-3 py-2 font-mono text-xs text-gray-300 flex items-center overflow-hidden whitespace-nowrap"
                id="ws-endpoint-url"
              >
                <%= if Enum.any?(@chain_connections, &EndpointHelpers.provider_supports_websocket/1) do %>
                  {EndpointHelpers.get_strategy_ws_url(@chain_endpoints, "fastest")}
                <% else %>
                  <span class="text-gray-600 italic">WebSocket not available</span>
                <% end %>
              </div>
              <button
                disabled={
                  !Enum.any?(@chain_connections, &EndpointHelpers.provider_supports_websocket/1)
                }
                data-copy-text={
                  if Enum.any?(@chain_connections, &EndpointHelpers.provider_supports_websocket/1) do
                    EndpointHelpers.get_strategy_ws_url(@chain_endpoints, "fastest")
                  else
                    ""
                  end
                }
                class="px-4 py-2 hover:bg-indigo-500/20 hover:text-indigo-300 text-gray-500 border-l border-gray-800/50 transition-colors flex items-center justify-center group disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:text-gray-500"
                title="Copy WebSocket URL"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="w-4 h-4 group-hover:scale-110 transition-transform"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15.666 3.888A2.25 2.25 0 0013.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 01-.75.75H9a.75.75 0 01-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 01-2.25 2.25H6.75A2.25 2.25 0 014.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 011.927-.184"
                  />
                </svg>
              </button>
            </div>
          </div>

          <div class="text-[11px] text-gray-500 pl-1" id="mode-description">
            Routes to fastest provider based on real-time latency benchmarks
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :last_decision, :map, default: nil
  attr :connections, :list, required: true
  attr :chain_metrics, :map, required: true

  defp routing_decisions_section(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 space-y-6 custom-scrollbar">
      <div>
        <DetailPanelComponents.section_header title="Routing Decisions" />
        <div class="grid grid-cols-1 gap-4">
          <.last_decision_card last_decision={@last_decision} connections={@connections} />

          <div class="bg-gray-800/20 border border-gray-800 rounded-lg p-4">
            <div class="flex justify-between items-center mb-3">
              <div class="text-[11px] text-gray-400">Distribution (Last 5m)</div>
              <div class="text-[10px] text-gray-600 uppercase tracking-wide">Req Share</div>
            </div>
            <% decision_share = Map.get(@chain_metrics, :decision_share, []) %>
            <div class="space-y-2">
              <%= for {pid, pct} <- decision_share do %>
                <div class="group">
                  <div class="flex items-center justify-between text-xs mb-1">
                    <span class="text-gray-300 font-medium truncate max-w-[150px] group-hover:text-white transition-colors">
                      {pid}
                    </span>
                    <span class="text-gray-500 font-mono group-hover:text-gray-400">
                      {Helpers.to_float(pct) |> Float.round(1)}%
                    </span>
                  </div>
                  <div class="w-full bg-gray-900 rounded-full h-1.5 overflow-hidden">
                    <div
                      class="bg-emerald-500/80 h-full rounded-full transition-all duration-500"
                      style={"width: #{Helpers.to_float(pct) |> Float.round(1)}%"}
                    >
                    </div>
                  </div>
                </div>
              <% end %>
              <%= if Enum.empty?(decision_share) do %>
                <div class="text-xs text-gray-600 italic pt-2 pb-3 text-center">
                  No traffic recorded recently
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :last_decision, :map, default: nil
  attr :connections, :list, default: []

  defp last_decision_card(assigns) do
    provider_name =
      case assigns[:connections] do
        connections when is_list(connections) ->
          connection =
            assigns[:last_decision] &&
              Enum.find(connections, &(&1.id == assigns.last_decision.provider_id))

          case connection do
            %{name: name} -> name
            _ -> assigns[:last_decision] && assigns.last_decision.provider_id
          end

        _ ->
          assigns[:last_decision] && assigns.last_decision.provider_id
      end

    assigns = assign(assigns, :provider_name, provider_name)

    ~H"""
    <div class="bg-gray-800/20 border border-gray-800 rounded-lg p-4 md:col-span-1">
      <div class="text-[11px] text-gray-400 mb-1">Last decision</div>
      <%= if @last_decision do %>
        <div class="text-xs text-gray-300 space-y-1">
          <div class="flex items-center justify-between gap-2">
            <div class="truncate">
              <span class="text-sky-300">{@last_decision.method}</span>
              <span class="text-gray-500">→</span>
              <span class="text-emerald-300 truncate" title={@last_decision.provider_id}>
                {@provider_name || @last_decision.provider_id}
              </span>
            </div>
            <div class="shrink-0 text-yellow-300 font-mono">{@last_decision.duration_ms}ms</div>
          </div>
          <div class="text-[11px] text-gray-400 flex items-center gap-2">
            <span>
              strategy: <span class="text-purple-300">{Map.get(@last_decision, :strategy, "—")}</span>
            </span>
          </div>
        </div>
      <% else %>
        <div class="text-xs text-gray-600 italic py-2 text-center">No recent decisions</div>
      <% end %>
    </div>
    """
  end
end
