defmodule LassoWeb.Dashboard.Components.ChainDetailsPanel do
  @moduledoc """
  LiveComponent for displaying chain details in a floating window.
  """
  use LassoWeb, :live_component

  alias LassoWeb.Components.DetailPanelComponents
  alias LassoWeb.Dashboard.{EndpointHelpers, Formatting, Helpers}

  @impl true
  def update(assigns, socket) do
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    socket =
      socket
      |> assign(assigns)
      |> assign(:chain_connections, chain_connections)
      |> assign(:consensus_height, find_consensus_height(chain_connections))
      |> assign(
        :last_decision,
        Helpers.get_last_decision(assigns[:selected_chain_events] || [], assigns.chain)
      )

    {:ok, socket}
  end

  defp find_consensus_height(connections) do
    Enum.find_value(connections, fn conn -> Map.get(conn, :consensus_height) end)
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

      <.endpoint_config_section
        chain={@chain}
        selected_profile={@selected_profile}
        chain_connections={@chain_connections}
        chain_endpoints={@selected_chain_endpoints}
      />

      <.chain_metrics_strip chain_metrics={@selected_chain_metrics} />

      <.routing_decisions_section
        last_decision={@last_decision}
        connections={@connections}
        chain_metrics={@selected_chain_metrics}
      />
    </div>
    """
  end

  attr(:chain, :string, required: true)
  attr(:selected_profile, :string, required: true)
  attr(:consensus_height, :integer, default: nil)
  attr(:chain_metrics, :map, required: true)

  defp chain_header(assigns) do
    connected = Map.get(assigns.chain_metrics, :connected_providers, 0)
    total = Map.get(assigns.chain_metrics, :total_providers, 0)
    status = provider_status(connected, total)

    assigns =
      assigns
      |> assign(:connected, connected)
      |> assign(:total, total)
      |> assign(:status, status)
      |> assign(:provider_count_class, provider_count_color(connected, total))

    ~H"""
    <div class="px-6 pt-6 border-gray-800 relative overflow-hidden">
      <div class="flex items-center justify-between mb-1.5 relative z-10">
        <h3 class="text-3xl font-bold text-white tracking-tight capitalize">
          {Helpers.get_chain_display_name(@selected_profile, @chain)}
        </h3>
        <DetailPanelComponents.status_badge status={@status} />
      </div>

      <div class="flex items-center gap-3 text-sm relative z-10">
        <span class="text-gray-500">
          Chain ID
          <span class="font-mono text-gray-300">
            {Helpers.get_chain_id(@selected_profile, @chain)}
          </span>
        </span>
        <span class="text-gray-400">·</span>
        <span class="text-gray-500">
          Block
          <span :if={@consensus_height} class="font-mono text-emerald-400">
            {Formatting.format_number(@consensus_height)}
          </span>
          <span :if={!@consensus_height} class="text-gray-600">—</span>
        </span>
        <span class="text-gray-400">·</span>
        <span class="text-gray-500">
          <span class={["font-mono", @provider_count_class]}>{@connected}/{@total}</span> providers
        </span>
      </div>
    </div>
    """
  end

  defp provider_status(connected, total) when connected == total and connected > 0, do: :healthy
  defp provider_status(0, _), do: :down
  defp provider_status(_, _), do: :degraded

  defp provider_count_color(c, t) when c == t and c > 0, do: "text-gray-300"
  defp provider_count_color(0, _), do: "text-red-400"
  defp provider_count_color(_, _), do: "text-yellow-400"

  attr(:chain_metrics, :map, required: true)

  defp chain_metrics_strip(assigns) do
    metrics = assigns.chain_metrics
    success_rate = Map.get(metrics, :success_rate, 0.0)

    assigns =
      assigns
      |> assign(:p50, format_latency(Map.get(metrics, :p50_latency)))
      |> assign(:p95, format_latency(Map.get(metrics, :p95_latency)))
      |> assign(:success, if(success_rate > 0, do: "#{success_rate}%", else: "—"))
      |> assign(:success_class, success_color(success_rate))
      |> assign(:rps, format_rps(Map.get(metrics, :rps, 0.0)))

    ~H"""
    <DetailPanelComponents.metrics_strip>
      <:metric label="Latency p50" value={@p50} />
      <:metric label="Latency p95" value={@p95} />
      <:metric label="Success" value={@success} value_class={@success_class} />
      <:metric label="RPS" value={@rps} value_class="text-purple-400" />
    </DetailPanelComponents.metrics_strip>
    """
  end

  defp format_latency(nil), do: "—"
  defp format_latency(ms), do: "#{ms}ms"

  defp format_rps(rps) when rps > 0, do: "#{rps}"
  defp format_rps(_), do: "0"

  defp success_color(rate) when rate >= 95.0, do: "text-emerald-400"
  defp success_color(rate) when rate >= 80.0, do: "text-yellow-400"
  defp success_color(_), do: "text-red-400"

  @strategy_labels %{
    "fastest" => "Fastest",
    "round-robin" => "Round Robin",
    "latency-weighted" => "Latency Weighted"
  }

  @strategy_icons %{
    "fastest" => "⚡",
    "round-robin" => "🔄",
    "latency-weighted" => "⚖️"
  }

  attr(:chain, :string, required: true)
  attr(:selected_profile, :string, required: true)
  attr(:chain_connections, :list, required: true)
  attr(:chain_endpoints, :map, required: true)

  defp endpoint_config_section(assigns) do
    has_ws = Enum.any?(assigns.chain_connections, &EndpointHelpers.provider_supports_websocket/1)
    http_url = EndpointHelpers.get_strategy_http_url(assigns.chain_endpoints, "fastest")

    ws_url =
      if has_ws,
        do: EndpointHelpers.get_strategy_ws_url(assigns.chain_endpoints, "fastest"),
        else: nil

    assigns =
      assigns
      |> assign(:has_ws, has_ws)
      |> assign(:http_url, http_url)
      |> assign(:ws_url, ws_url)

    ~H"""
    <div class="px-6 py-8 border-b border-gray-800">
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
              <.strategy_button
                :for={strategy <- EndpointHelpers.available_strategies()}
                strategy={strategy}
              />
            </div>
          </div>

          <div class="bg-black/20 border border-gray-700/50 rounded-xl overflow-hidden">
            <.endpoint_row
              id="http-row"
              label="HTTP"
              url_id="endpoint-url"
              url={@http_url}
              border={true}
            />
            <.endpoint_row
              id="ws-row"
              label="WS"
              url_id="ws-endpoint-url"
              url={@ws_url}
              disabled={!@has_ws}
              border={false}
            />
          </div>

          <div class="text-[11px] text-gray-500 pl-1" id="mode-description">
            Routes to fastest provider based on real-time latency benchmarks
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:strategy, :string, required: true)

  defp strategy_button(assigns) do
    assigns =
      assigns
      |> assign(:icon, Map.get(@strategy_icons, assigns.strategy, ""))
      |> assign(:label, Map.get(@strategy_labels, assigns.strategy, assigns.strategy))

    ~H"""
    <button
      data-strategy={@strategy}
      class="px-3 py-1.5 rounded-md text-xs font-medium transition-all border border-gray-700 bg-gray-800/50 text-gray-400 hover:border-gray-600 hover:text-gray-300"
    >
      {@icon} {@label}
    </button>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:url_id, :string, required: true)
  attr(:url, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:border, :boolean, default: false)

  defp endpoint_row(assigns) do
    ~H"""
    <div class={["flex items-stretch", @border && "border-b border-gray-800/50"]} id={@id}>
      <div class="bg-gray-800/30 w-14 shrink-0 px-3 py-2 flex items-center justify-center border-r border-gray-800/50">
        <span class="text-[10px] font-bold text-gray-500 uppercase">{@label}</span>
      </div>
      <div
        class="flex-grow px-3 py-2 font-mono text-xs text-gray-300 flex items-center overflow-hidden whitespace-nowrap"
        id={@url_id}
      >
        <span :if={@url}>{@url}</span>
        <span :if={!@url} class="text-gray-600 italic">WebSocket not available</span>
      </div>
      <button
        disabled={@disabled}
        data-copy-text={@url || ""}
        class="px-4 py-2 hover:bg-indigo-500/20 hover:text-indigo-300 text-gray-500 border-l border-gray-800/50 transition-colors flex items-center justify-center group disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:text-gray-500"
        title={"Copy #{@label} URL"}
      >
        <DetailPanelComponents.copy_icon />
      </button>
    </div>
    """
  end

  attr(:last_decision, :map, default: nil)
  attr(:connections, :list, required: true)
  attr(:chain_metrics, :map, required: true)

  defp routing_decisions_section(assigns) do
    decision_share = Map.get(assigns.chain_metrics, :decision_share, [])
    assigns = assign(assigns, :decision_share, decision_share)

    ~H"""
    <div class="flex-1 overflow-y-auto p-6 space-y-6 custom-scrollbar">
      <div>
        <DetailPanelComponents.section_header title="Routing Decisions" />
        <div class="grid grid-cols-1 gap-4">
          <.last_decision_card last_decision={@last_decision} connections={@connections} />
          <.distribution_card decision_share={@decision_share} />
        </div>
      </div>
    </div>
    """
  end

  attr(:decision_share, :list, required: true)

  defp distribution_card(assigns) do
    ~H"""
    <div class="bg-gray-800/20 border border-gray-800 rounded-lg p-4">
      <div class="flex justify-between items-center mb-3">
        <div class="text-[11px] text-gray-400">Distribution (Last 5m)</div>
        <div class="text-[10px] text-gray-600 uppercase tracking-wide">Req Share</div>
      </div>
      <div class="space-y-2">
        <.distribution_row :for={{pid, pct} <- @decision_share} provider_id={pid} percentage={pct} />
        <div :if={@decision_share == []} class="text-xs text-gray-600 italic pt-2 pb-3 text-center">
          No traffic recorded recently
        </div>
      </div>
    </div>
    """
  end

  attr(:provider_id, :string, required: true)
  attr(:percentage, :any, required: true)

  defp distribution_row(assigns) do
    pct = Helpers.to_float(assigns.percentage) |> Float.round(1)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="group">
      <div class="flex items-center justify-between text-xs mb-1">
        <span class="text-gray-300 font-medium truncate max-w-[150px] group-hover:text-white transition-colors">
          {@provider_id}
        </span>
        <span class="text-gray-500 font-mono group-hover:text-gray-400">{@pct}%</span>
      </div>
      <div class="w-full bg-gray-900 rounded-full h-1.5 overflow-hidden">
        <div
          class="bg-emerald-500/80 h-full rounded-full transition-all duration-500"
          style={"width: #{@pct}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  attr(:last_decision, :map, default: nil)
  attr(:connections, :list, default: [])

  defp last_decision_card(assigns) do
    provider_name = find_provider_name(assigns.connections, assigns.last_decision)
    assigns = assign(assigns, :provider_name, provider_name)

    ~H"""
    <div class="bg-gray-800/20 border border-gray-800 rounded-lg p-4 md:col-span-1">
      <div class="text-[11px] text-gray-400 mb-1">Last decision</div>
      <div :if={@last_decision} class="text-xs text-gray-300 space-y-1">
        <div class="flex items-center justify-between gap-2">
          <div class="truncate">
            <span class="text-sky-300">{@last_decision.method}</span>
            <span class="text-gray-500">→</span>
            <span class="text-emerald-300 truncate" title={@last_decision.provider_id}>
              {@provider_name}
            </span>
          </div>
          <div class="shrink-0 text-yellow-300 font-mono">{@last_decision.duration_ms}ms</div>
        </div>
        <div class="text-[11px] text-gray-400">
          strategy: <span class="text-purple-300">{Map.get(@last_decision, :strategy, "—")}</span>
        </div>
      </div>
      <div :if={!@last_decision} class="text-xs text-gray-600 italic py-2 text-center">
        No recent decisions
      </div>
    </div>
    """
  end

  defp find_provider_name(_connections, nil), do: nil

  defp find_provider_name(connections, decision) when is_list(connections) do
    case Enum.find(connections, &(&1.id == decision.provider_id)) do
      %{name: name} -> name
      _ -> decision.provider_id
    end
  end

  defp find_provider_name(_, decision), do: decision.provider_id
end
