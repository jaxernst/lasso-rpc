defmodule LassoWeb.Dashboard.Components.ChainDetailsPanel do
  @moduledoc """
  LiveComponent for displaying chain details in a floating window.
  """
  use LassoWeb, :live_component

  alias LassoWeb.Components.DetailPanelComponents
  alias LassoWeb.Components.RegionSelector
  alias LassoWeb.Dashboard.{EndpointHelpers, Formatting, Helpers, StatusHelpers}

  @impl true
  def update(%{_metrics_only: true} = assigns, socket) do
    live_provider_metrics = assigns[:live_provider_metrics] || %{}

    if socket.assigns[:live_provider_metrics] != live_provider_metrics do
      selected_region = socket.assigns[:chain_metrics_region] || "aggregate"
      chain = socket.assigns[:chain]
      chain_connections = socket.assigns[:chain_connections] || []
      aggregate_cached = socket.assigns[:aggregate_cached] || %{}
      cached_fallback = if selected_region == "aggregate", do: aggregate_cached, else: %{}

      filtered_metrics =
        compute_filtered_chain_metrics(
          selected_region,
          live_provider_metrics,
          chain,
          cached_fallback,
          chain_connections
        )

      {:ok,
       socket
       |> assign(:live_provider_metrics, live_provider_metrics)
       |> assign(:filtered_chain_metrics, filtered_metrics)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    chain = assigns.chain
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == chain))

    live_provider_metrics = assigns[:live_provider_metrics] || %{}
    aggregate_cached = assigns[:selected_chain_metrics] || %{}
    available_node_ids = assigns[:available_node_ids] || []
    chain_events = assigns[:selected_chain_events] || []
    cluster_block_heights = assigns[:cluster_block_heights] || %{}

    inputs_changed =
      socket.assigns[:chain] != chain or
        socket.assigns[:chain_connections] != chain_connections or
        socket.assigns[:live_provider_metrics] != live_provider_metrics or
        socket.assigns[:cluster_block_heights] != cluster_block_heights or
        socket.assigns[:chain_events] != chain_events or
        socket.assigns[:selected_chain_metrics] != aggregate_cached

    if inputs_changed do
      selected_region = socket.assigns[:chain_metrics_region] || "aggregate"
      cached_fallback = if selected_region == "aggregate", do: aggregate_cached, else: %{}

      filtered_metrics =
        compute_filtered_chain_metrics(
          selected_region,
          live_provider_metrics,
          chain,
          cached_fallback,
          chain_connections
        )

      filtered_decision = get_region_decision(chain_events, chain, selected_region)

      socket =
        socket
        |> assign(:chain, chain)
        |> assign(:connections, assigns.connections)
        |> assign(:selected_profile, assigns.selected_profile)
        |> assign(:selected_chain_metrics, assigns[:selected_chain_metrics])
        |> assign(:selected_chain_events, chain_events)
        |> assign(:selected_chain_unified_events, assigns[:selected_chain_unified_events])
        |> assign(:selected_chain_endpoints, assigns[:selected_chain_endpoints])
        |> assign(:selected_chain_provider_events, assigns[:selected_chain_provider_events])
        |> assign(:chain_connections, chain_connections)
        |> assign(:available_node_ids, available_node_ids)
        |> assign(:show_region_tabs, length(available_node_ids) > 1)
        |> assign(:live_provider_metrics, live_provider_metrics)
        |> assign(:aggregate_cached, aggregate_cached)
        |> assign(:cluster_block_heights, cluster_block_heights)
        |> assign_new(:chain_metrics_region, fn -> "aggregate" end)
        |> assign(
          :consensus_height,
          find_consensus_height(chain_connections, cluster_block_heights)
        )
        |> assign(:chain_events, chain_events)
        |> assign(:filtered_chain_metrics, filtered_metrics)
        |> assign(:filtered_last_decision, filtered_decision)

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("select_chain_region", %{"region" => region}, socket) do
    live_provider_metrics = socket.assigns[:live_provider_metrics] || %{}
    aggregate_cached = socket.assigns[:aggregate_cached] || %{}
    chain = socket.assigns.chain
    chain_events = socket.assigns[:chain_events] || []
    chain_connections = socket.assigns[:chain_connections] || []

    # Only use cached aggregate metrics when viewing aggregate
    cached_fallback = if region == "aggregate", do: aggregate_cached, else: %{}

    filtered_metrics =
      compute_filtered_chain_metrics(
        region,
        live_provider_metrics,
        chain,
        cached_fallback,
        chain_connections
      )

    socket =
      socket
      |> assign(:chain_metrics_region, region)
      |> assign(:filtered_chain_metrics, filtered_metrics)
      |> assign(:filtered_last_decision, get_region_decision(chain_events, chain, region))

    {:noreply, socket}
  end

  defp find_consensus_height(chain_connections, cluster_block_heights) do
    chain_provider_ids = MapSet.new(chain_connections, & &1.id)

    realtime_max =
      cluster_block_heights
      |> Enum.filter(fn {{pid, _node}, _} -> pid in chain_provider_ids end)
      |> Enum.map(fn {_, %{height: h}} -> h end)
      |> Enum.max(fn -> nil end)

    realtime_max ||
      Enum.find_value(chain_connections, fn conn -> Map.get(conn, :consensus_height) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col text-gray-200 overflow-hidden" id={"chain-details-#{@chain}"}>
      <.chain_header
        chain={@chain}
        selected_profile={@selected_profile}
        consensus_height={@consensus_height}
        chain_metrics={@filtered_chain_metrics}
      />

      <.endpoint_config_section
        chain={@chain}
        selected_profile={@selected_profile}
        chain_connections={@chain_connections}
        chain_endpoints={@selected_chain_endpoints}
      />

      <div :if={@show_region_tabs} class="mt-4">
        <RegionSelector.region_selector
          id="chain-region-selector"
          regions={@available_node_ids}
          selected={@chain_metrics_region}
          show_aggregate={true}
          target={@myself}
          event="select_chain_region"
        />
      </div>

      <.chain_metrics_strip chain_metrics={@filtered_chain_metrics} />

      <.routing_decisions_section
        last_decision={@filtered_last_decision}
        connections={@connections}
        chain_metrics={@filtered_chain_metrics}
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
    <DetailPanelComponents.panel_section border={false} class="px-6">
      <h4 class="text-xs font-semibold uppercase tracking-wider text-gray-500 mb-4">Performance</h4>
      <DetailPanelComponents.metrics_strip class="border-x rounded">
        <:metric label="Latency p50" value={@p50} />
        <:metric label="Latency p95" value={@p95} />
        <:metric label="Success" value={@success} value_class={@success_class} />
        <:metric label="RPS" value={@rps} value_class="text-purple-400" />
      </DetailPanelComponents.metrics_strip>
    </DetailPanelComponents.panel_section>
    """
  end

  defdelegate format_latency(ms), to: Formatting
  defdelegate format_rps(rps), to: Formatting
  defp success_color(rate), do: Formatting.success_rate_color(rate)

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
    <div class="px-6 py-8 border-gray-800">
      <div
        id={"endpoint-config-#{@chain}"}
        phx-hook="TabSwitcher"
        phx-update="ignore"
        data-chain={@chain}
        data-chain-id={Helpers.get_chain_id(@selected_profile, @chain)}
        data-profile={@selected_profile}
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
            Distributes requests evenly across all available providers
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
      |> assign(:label, EndpointHelpers.strategy_display_name(assigns.strategy))

    ~H"""
    <button
      data-strategy={@strategy}
      data-state="inactive"
      class="px-3 py-1.5 rounded-md text-xs font-medium border bg-gray-800/50"
    >
      {@label}
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
    <div class="flex-1 overflow-y-auto px-6 pb-6 space-y-6 custom-scrollbar">
      <div>
        <DetailPanelComponents.section_header title="Routing Decisions" />
        <div class="grid grid-cols-1 gap-4">
          <.last_decision_card last_decision={@last_decision} connections={@connections} />
          <.distribution_card decision_share={@decision_share} connections={@connections} />
        </div>
      </div>
    </div>
    """
  end

  attr(:decision_share, :list, required: true)
  attr(:connections, :list, required: true)

  defp distribution_card(assigns) do
    ~H"""
    <div class="bg-gray-800/20 border border-gray-800 rounded-lg p-4">
      <div class="flex justify-between items-center mb-3">
        <span class="text-[11px] text-gray-400">Distribution (Last 5m)</span>
        <div class="text-[10px] text-gray-600 uppercase tracking-wide">Req Share</div>
      </div>
      <div class="space-y-2">
        <.distribution_row
          :for={{pid, pct} <- @decision_share}
          provider_id={pid}
          provider_name={resolve_provider_name(@connections, pid)}
          percentage={pct}
        />
        <div :if={@decision_share == []} class="text-xs text-gray-600 italic pt-2 pb-3 text-center">
          No traffic recorded recently
        </div>
      </div>
    </div>
    """
  end

  attr(:provider_id, :string, required: true)
  attr(:provider_name, :string, required: true)
  attr(:percentage, :any, required: true)

  defp distribution_row(assigns) do
    pct = Helpers.to_float(assigns.percentage) |> Float.round(1)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="group">
      <div class="flex items-center justify-between text-xs mb-1">
        <span class="text-gray-300 font-medium truncate max-w-[150px] group-hover:text-white transition-colors">
          {@provider_name}
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
    resolve_provider_name(connections, decision.provider_id)
  end

  defp find_provider_name(_, decision), do: decision.provider_id

  defp resolve_provider_name(connections, provider_id) when is_list(connections) do
    case Enum.find(connections, &(&1.id == provider_id)) do
      %{name: name} -> name
      _ -> provider_id
    end
  end

  defp resolve_provider_name(_, provider_id), do: provider_id

  defp compute_filtered_chain_metrics(
         "aggregate",
         live_provider_metrics,
         chain,
         cached_metrics,
         chain_connections
       ) do
    chain_providers_with_ids =
      live_provider_metrics
      |> Enum.filter(fn {_pid, metrics} -> metrics[:chain] == chain end)

    chain_providers =
      chain_providers_with_ids
      |> Enum.map(fn {_pid, metrics} -> metrics[:aggregate] || %{} end)

    # Provider counts from actual health status (not just providers with live data)
    {connected_providers, total_providers} = count_providers_by_health(chain_connections)

    if chain_providers != [] do
      total_calls = Enum.reduce(chain_providers, 0, fn p, acc -> acc + (p[:total_calls] || 0) end)

      total_successes =
        Enum.reduce(chain_providers, 0, fn p, acc ->
          calls = p[:total_calls] || 0
          rate = p[:success_rate] || 0
          acc + calls * rate / 100
        end)

      success_rate =
        if total_calls > 0, do: Float.round(total_successes / total_calls * 100, 1), else: nil

      p50_latency = compute_weighted_latency(chain_providers, :p50_latency)
      p95_latency = compute_weighted_latency(chain_providers, :p95_latency)

      rps =
        Enum.reduce(chain_providers, 0.0, fn p, acc ->
          acc + (p[:events_per_second] || 0.0)
        end)

      decision_share = compute_decision_share(chain_providers_with_ids, :aggregate, total_calls)

      %{
        success_rate: success_rate || cached_metrics[:success_rate],
        p50_latency: p50_latency || cached_metrics[:p50_latency],
        p95_latency: p95_latency || cached_metrics[:p95_latency],
        rps: if(rps > 0, do: Float.round(rps, 1), else: cached_metrics[:rps] || 0),
        decision_share:
          if(decision_share != [],
            do: decision_share,
            else: cached_metrics[:decision_share] || []
          ),
        connected_providers: connected_providers,
        total_providers: total_providers
      }
    else
      # No live data, use cached but with accurate provider counts from connections
      Map.merge(cached_metrics, %{
        connected_providers: connected_providers,
        total_providers: total_providers
      })
    end
  end

  defp compute_filtered_chain_metrics(
         selected_region,
         live_provider_metrics,
         chain,
         cached_metrics,
         chain_connections
       ) do
    chain_providers_with_ids =
      live_provider_metrics
      |> Enum.filter(fn {_pid, metrics} -> metrics[:chain] == chain end)

    region_providers_with_ids =
      chain_providers_with_ids
      |> Enum.map(fn {provider_id, metrics} ->
        by_region = metrics[:by_region] || %{}

        case Map.get(by_region, selected_region) do
          nil -> nil
          region_data -> {provider_id, region_data}
        end
      end)
      |> Enum.reject(&is_nil/1)

    region_providers = Enum.map(region_providers_with_ids, fn {_pid, data} -> data end)

    # Provider counts always show cluster-wide health (not region-filtered)
    # The region tabs filter metrics only, not the header health display
    {connected_providers, total_providers} = count_providers_by_health(chain_connections)

    if region_providers != [] do
      total_calls =
        Enum.reduce(region_providers, 0, fn p, acc -> acc + (p[:total_calls] || 0) end)

      total_successes =
        Enum.reduce(region_providers, 0, fn p, acc ->
          calls = p[:total_calls] || 0
          rate = p[:success_rate] || 0
          acc + calls * rate / 100
        end)

      success_rate =
        if total_calls > 0, do: Float.round(total_successes / total_calls * 100, 1), else: nil

      p50_latency = compute_weighted_latency(region_providers, :p50_latency)
      p95_latency = compute_weighted_latency(region_providers, :p95_latency)

      rps =
        Enum.reduce(region_providers, 0.0, fn p, acc ->
          acc + (p[:events_per_second] || 0.0)
        end)

      decision_share = compute_decision_share(region_providers_with_ids, :region, total_calls)

      %{
        success_rate: success_rate || cached_metrics[:success_rate],
        p50_latency: p50_latency || cached_metrics[:p50_latency],
        p95_latency: p95_latency || cached_metrics[:p95_latency],
        rps: if(rps > 0, do: Float.round(rps, 1), else: cached_metrics[:rps] || 0),
        decision_share:
          if(decision_share != [],
            do: decision_share,
            else: cached_metrics[:decision_share] || []
          ),
        connected_providers: connected_providers,
        total_providers: total_providers
      }
    else
      # No live data for this region, use cached metrics with cluster-wide provider counts
      Map.merge(cached_metrics, %{
        connected_providers: connected_providers,
        total_providers: total_providers
      })
    end
  end

  defp count_providers_by_health(chain_connections) do
    total = length(chain_connections)

    connected =
      Enum.count(chain_connections, fn provider ->
        StatusHelpers.determine_provider_status(provider) in [:healthy, :recovering, :lagging]
      end)

    {connected, total}
  end

  defp compute_decision_share(providers_with_ids, mode, total_calls) when total_calls > 0 do
    providers_with_ids
    |> Enum.map(fn {provider_id, data} ->
      calls =
        case mode do
          :aggregate -> (data[:aggregate] || %{})[:total_calls] || 0
          :region -> data[:total_calls] || 0
        end

      pct = if total_calls > 0, do: Float.round(calls / total_calls * 100, 1), else: 0.0
      {provider_id, pct}
    end)
    |> Enum.filter(fn {_pid, pct} -> pct > 0 end)
    |> Enum.sort_by(fn {_pid, pct} -> pct end, :desc)
  end

  defp compute_decision_share(_, _, _), do: []

  defp compute_weighted_latency(providers, field) do
    with_data =
      providers
      |> Enum.filter(fn p -> p[field] != nil and (p[:total_calls] || 0) > 0 end)

    if with_data != [] do
      total_calls = Enum.reduce(with_data, 0, fn p, acc -> acc + (p[:total_calls] || 0) end)

      weighted_sum =
        Enum.reduce(with_data, 0, fn p, acc ->
          acc + (p[field] || 0) * (p[:total_calls] || 0)
        end)

      if total_calls > 0, do: round(weighted_sum / total_calls), else: nil
    else
      nil
    end
  end

  defp routing_decision?(e), do: e[:type] != :ws_lifecycle and is_binary(e[:method])

  defp get_region_decision(events, chain, "aggregate") do
    Enum.find(events, fn e -> e[:chain] == chain and routing_decision?(e) end)
  end

  defp get_region_decision(events, chain, region) do
    Enum.find(events, fn e ->
      e[:chain] == chain and e[:source_node_id] == region and routing_decision?(e)
    end)
  end
end
