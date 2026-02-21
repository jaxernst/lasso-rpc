defmodule LassoWeb.Dashboard.Components.ProviderDetailsPanel do
  @moduledoc """
  LiveComponent for displaying detailed provider information.

  Supports aggregate and per-region views. In aggregate mode, shows cluster-wide
  aggregated metrics. In per-region mode, shows data from a specific cluster node.
  """

  use LassoWeb, :live_component

  alias LassoWeb.Components.DetailPanelComponents
  alias LassoWeb.Components.RegionSelector
  alias LassoWeb.Dashboard.{Formatting, Helpers, StatusHelpers}

  require Logger

  @impl true
  def update(assigns, socket) do
    provider_connection = Enum.find(assigns.connections, &(&1.id == assigns.provider_id))
    provider_id = assigns.provider_id

    # Get live metrics from aggregator (single source of truth)
    live_provider_metrics = assigns[:live_provider_metrics] || %{}
    live_metrics = Map.get(live_provider_metrics, provider_id)

    # Regions come from aggregator's cluster-wide tracking (single source of truth)
    available_node_ids = assigns[:available_node_ids] || []

    # Get circuit states from aggregator
    cluster_circuits = assigns[:cluster_circuit_states] || %{}

    # Get health counters (consecutive failures/successes) from aggregator
    cluster_health_counters = assigns[:cluster_health_counters] || %{}

    # Events for the provider
    events = assigns[:selected_provider_unified_events] || []

    socket =
      socket
      |> assign(assigns)
      |> assign(:provider_connection, provider_connection)
      |> assign(:available_node_ids, available_node_ids)
      |> assign(:show_region_tabs, length(available_node_ids) > 1)
      |> assign(:live_metrics, live_metrics)
      |> assign(:cluster_circuits, cluster_circuits)
      |> assign(:cluster_health_counters, cluster_health_counters)
      |> assign(:events, events)
      |> assign_new(:selected_region, fn -> "aggregate" end)
      |> compute_region_data()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_region", %{"region" => region}, socket) do
    socket =
      socket
      |> assign(:selected_region, region)
      |> compute_region_data()

    {:noreply, socket}
  end

  defp compute_region_data(socket) do
    selected_region = socket.assigns.selected_region
    provider_connection = socket.assigns.provider_connection
    live_metrics = socket.assigns[:live_metrics]
    cluster_circuits = socket.assigns[:cluster_circuits] || %{}
    cluster_health_counters = socket.assigns[:cluster_health_counters] || %{}
    cluster_block_heights = socket.assigns[:cluster_block_heights] || %{}
    events = socket.assigns[:events] || []
    provider_id = socket.assigns.provider_id

    # Get data for selected region from live metrics
    region_data = get_region_data(live_metrics, selected_region)

    # Get appropriate cached fallback based on region
    cached_fallback = get_cached_fallback(socket.assigns, selected_region)

    # Find regions with circuit issues
    regions_with_issues = find_regions_with_issues(cluster_circuits, provider_id)

    # Compute derived data (with cached fallback for metrics)
    connections = socket.assigns[:connections] || []

    sync_data =
      compute_sync_data(
        selected_region,
        region_data,
        provider_connection,
        cluster_block_heights,
        provider_id,
        connections
      )

    metrics_data = compute_metrics_data(region_data, cached_fallback)

    available_node_ids = socket.assigns[:available_node_ids] || []

    circuit_data =
      compute_circuit_data(
        selected_region,
        region_data,
        provider_connection,
        cluster_circuits,
        cluster_health_counters,
        provider_id,
        available_node_ids
      )

    filtered_events = filter_events_by_region(events, selected_region)

    socket
    |> assign(:regions_with_issues, regions_with_issues)
    |> assign(:sync_data, sync_data)
    |> assign(:metrics_data, metrics_data)
    |> assign(:circuit_data, circuit_data)
    |> assign(:filtered_events, filtered_events)
  end

  defp get_cached_fallback(assigns, "aggregate") do
    # Only use cached aggregate metrics when viewing aggregate
    assigns[:selected_provider_metrics] || %{}
  end

  defp get_cached_fallback(_assigns, _region) do
    # For per-region views, don't fall back to aggregate - show empty if no data
    %{}
  end

  defp get_region_data(nil, _selected_region), do: %{}

  defp get_region_data(live_metrics, "aggregate") do
    live_metrics[:aggregate] || %{}
  end

  defp get_region_data(live_metrics, region) do
    by_region = live_metrics[:by_region] || %{}
    Map.get(by_region, region, %{})
  end

  defp compute_sync_data(
         selected_region,
         region_data,
         provider_connection,
         cluster_block_heights,
         provider_id,
         connections
       ) do
    conn = provider_connection || %{}
    chain = Map.get(conn, :chain)
    chain_consensus = compute_chain_consensus(cluster_block_heights, chain, connections)

    {block_height, block_lag, consensus_height} =
      resolve_block_heights(
        selected_region,
        region_data,
        conn,
        cluster_block_heights,
        provider_id,
        chain_consensus
      )

    optimistic_lag =
      if selected_region == "aggregate" do
        case StatusHelpers.calculate_optimistic_lag(chain, provider_id) do
          {:ok, lag} -> lag
          {:error, _} -> nil
        end
      else
        nil
      end

    effective_lag = resolve_effective_lag(block_lag, optimistic_lag, conn)

    %{
      block_height: block_height,
      consensus_height: consensus_height,
      optimistic_lag: optimistic_lag,
      effective_lag: effective_lag,
      sync_status: sync_status_level(effective_lag),
      mode: if(selected_region == "aggregate", do: :aggregate, else: :region)
    }
  end

  defp resolve_block_heights(
         "aggregate",
         region_data,
         conn,
         cluster_block_heights,
         provider_id,
         chain_consensus
       ) do
    provider_heights =
      cluster_block_heights
      |> Enum.filter(fn {{pid, _region}, _data} -> pid == provider_id end)
      |> Enum.map(fn {{_pid, _region}, data} -> data end)

    consensus =
      chain_consensus || region_data[:consensus_height] || Map.get(conn, :consensus_height)

    if provider_heights != [] do
      max_height =
        provider_heights
        |> Enum.map(& &1[:height])
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> nil end)

      min_lag =
        provider_heights
        |> Enum.map(& &1[:lag])
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> 0 end)

      {max_height, min_lag, consensus}
    else
      {region_data[:block_height] || Map.get(conn, :block_height), region_data[:block_lag] || 0,
       consensus}
    end
  end

  defp resolve_block_heights(
         selected_region,
         region_data,
         conn,
         cluster_block_heights,
         provider_id,
         chain_consensus
       ) do
    region_height_data = Map.get(cluster_block_heights, {provider_id, selected_region}, %{})

    {
      region_height_data[:height] || region_data[:block_height] || Map.get(conn, :block_height),
      region_height_data[:lag] || region_data[:block_lag] || 0,
      chain_consensus || region_data[:consensus_height] || Map.get(conn, :consensus_height)
    }
  end

  defp resolve_effective_lag(block_lag, optimistic_lag, conn) do
    cond do
      is_integer(block_lag) and block_lag > 0 -> block_lag
      optimistic_lag != nil -> abs(min(0, optimistic_lag))
      true -> Map.get(conn, :blocks_behind, 0) || 0
    end
  end

  defp compute_chain_consensus(cluster_block_heights, chain, connections)
       when is_binary(chain) do
    chain_provider_ids =
      connections
      |> Enum.filter(&(&1.chain == chain))
      |> MapSet.new(& &1.id)

    cluster_block_heights
    |> Enum.filter(fn {{pid, _node}, _} -> pid in chain_provider_ids end)
    |> Enum.map(fn {_, %{height: h}} -> h end)
    |> Enum.max(fn -> nil end)
  end

  defp compute_chain_consensus(_, _, _), do: nil

  defp compute_metrics_data(region_data, cached_metrics) do
    # Prefer live data for real-time metrics, fall back to cached
    # Note: region_data comes from aggregator (real-time events)
    # cached_metrics comes from BenchmarkStore (historical data)
    live_calls = region_data[:total_calls] || 0
    cached_calls = cached_metrics[:calls_last_minute] || 0

    # Use live success_rate only if we have enough events to be meaningful
    success_rate =
      cond do
        live_calls >= 5 -> region_data[:success_rate]
        cached_calls > 0 -> cached_metrics[:success_rate]
        live_calls > 0 -> region_data[:success_rate]
        true -> nil
      end

    # Latencies: prefer live if we have events, otherwise cached
    p50 = if live_calls > 0, do: region_data[:p50_latency], else: cached_metrics[:p50_latency]
    p95 = if live_calls > 0, do: region_data[:p95_latency], else: cached_metrics[:p95_latency]

    # RPC stats: prefer live region-specific data if available
    live_rpc_stats = region_data[:rpc_stats] || []
    cached_rpc_stats = cached_metrics[:rpc_stats] || []
    rpc_stats = if live_rpc_stats != [], do: live_rpc_stats, else: cached_rpc_stats

    %{
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      pick_share_5m: region_data[:traffic_pct] || cached_metrics[:pick_share_5m],
      calls_last_minute: max(live_calls, cached_calls),
      rpc_stats: rpc_stats
    }
  end

  defp compute_circuit_data(
         "aggregate",
         _region_data,
         provider_connection,
         cluster_circuits,
         _cluster_health_counters,
         provider_id,
         available_node_ids
       ) do
    conn = provider_connection || %{}
    has_http = Map.get(conn, :url) != nil
    has_ws = Map.get(conn, :ws_url) != nil

    # Use available_node_ids as the total node count (not just providers with circuit data)
    total_regions = length(available_node_ids)

    # Collect all circuit states for this provider across all regions
    provider_circuits =
      cluster_circuits
      |> Enum.filter(fn {{pid, _region}, _circuit} -> pid == provider_id end)
      |> Enum.map(fn {{_pid, region}, circuit} -> {region, circuit} end)

    if total_regions <= 1 do
      %{
        mode: :single,
        http_state: Map.get(conn, :http_circuit_state, :closed),
        ws_state: Map.get(conn, :ws_circuit_state, :closed),
        ws_connected: Map.get(conn, :ws_connected, false),
        consecutive_failures: Map.get(conn, :consecutive_failures, 0),
        consecutive_successes: Map.get(conn, :consecutive_successes, 0),
        has_http: has_http,
        has_ws: has_ws
      }
    else
      http_counts =
        count_circuit_states_with_default(provider_circuits, :http, available_node_ids)

      ws_counts = count_circuit_states_with_default(provider_circuits, :ws, available_node_ids)

      %{
        mode: :aggregate,
        region_count: total_regions,
        http_counts: http_counts,
        ws_counts: ws_counts,
        has_http: has_http,
        has_ws: has_ws,
        http_worst: worst_circuit_state(http_counts),
        ws_worst: worst_circuit_state(ws_counts)
      }
    end
  end

  defp compute_circuit_data(
         selected_region,
         _region_data,
         provider_connection,
         cluster_circuits,
         cluster_health_counters,
         provider_id,
         _available_node_ids
       ) do
    conn = provider_connection || %{}
    live_circuit = Map.get(cluster_circuits, {provider_id, selected_region}, %{})
    health_counters = Map.get(cluster_health_counters, {provider_id, selected_region}, %{})

    # For per-region view, only use cluster data for that region
    # Default to :closed (healthy) when no data exists - don't fall back to local node state
    %{
      mode: :single,
      http_state: live_circuit[:http] || :closed,
      ws_state: live_circuit[:ws] || :closed,
      ws_connected: live_circuit[:ws_connected] || false,
      consecutive_failures: health_counters[:consecutive_failures] || 0,
      consecutive_successes: health_counters[:consecutive_successes] || 0,
      has_http: Map.get(conn, :url) != nil,
      has_ws: Map.get(conn, :ws_url) != nil
    }
  end

  defp count_circuit_states_with_default(provider_circuits, transport, available_node_ids) do
    # Build a map of region -> circuit state
    circuit_by_region =
      provider_circuits
      |> Enum.map(fn {region, circuit} -> {region, circuit[transport] || :closed} end)
      |> Enum.into(%{})

    # Count states, defaulting missing regions to :closed
    available_node_ids
    |> Enum.map(fn region -> Map.get(circuit_by_region, region, :closed) end)
    |> Enum.frequencies()
  end

  defp worst_circuit_state(counts) do
    cond do
      Map.get(counts, :open, 0) > 0 -> :open
      Map.get(counts, :half_open, 0) > 0 -> :half_open
      true -> :closed
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="flex h-full flex-col overflow-y-auto text-gray-200 overflow-hidden"
      data-provider-id={@provider_id}
    >
      <.provider_header
        provider_connection={@provider_connection}
        provider_id={@provider_id}
        selected_profile={@selected_profile}
      />

      <div :if={@provider_connection}>
        <div :if={@show_region_tabs} class="mt-4">
          <RegionSelector.region_selector
            id="provider-region-selector"
            regions={@available_node_ids}
            selected={@selected_region}
            show_aggregate={true}
            target={@myself}
            event="select_region"
            regions_with_issues={@regions_with_issues}
          />
        </div>

        <div class="px-2">
          <.sync_status_section sync_data={@sync_data} />
          <.performance_metrics_strip metrics_data={@metrics_data} />
          <.circuit_breaker_section circuit_data={@circuit_data} />

          <hr class="border-gray-800 mt-2 -mx-2" />

          <.issues_section
            provider_connection={@provider_connection}
            provider_unified_events={@filtered_events}
          />

          <hr class="border-gray-800 mt-2 -mx-2" />

          <.method_performance_section metrics_data={@metrics_data} />
        </div>
      </div>

      <div :if={!@provider_connection} class="flex-1 flex items-center justify-center">
        <div class="text-gray-500">Provider data not available</div>
      </div>
    </div>
    """
  end

  # --- Header ---

  attr(:provider_connection, :map, default: nil)
  attr(:provider_id, :string, required: true)
  attr(:selected_profile, :string, required: true)

  defp provider_header(assigns) do
    conn = assigns.provider_connection || %{}

    assigns =
      assigns
      |> assign(:name, Map.get(conn, :name, assigns.provider_id))
      |> assign(:transport_label, transport_label(conn))
      |> assign(:chain_id, get_chain_id_display(assigns.selected_profile, conn))

    ~H"""
    <div class="flex gap-2 items-center border-gray-800 p-6 pb-3 relative overflow-hidden">
      <div class="w-full">
        <div class="flex items-center w-full justify-between mb-1.5 relative z-10">
          <h3 class="text-3xl font-bold text-white tracking-tight">{@name}</h3>

          <div class={[
            "flex items-center gap-1.5 px-2.5 py-1 rounded-full border text-xs font-medium",
            StatusHelpers.provider_status_badge_class(@provider_connection || %{})
          ]}>
            <div class={[
              "h-1.5 w-1.5 rounded-full animate-pulse",
              StatusHelpers.provider_status_indicator_class(@provider_connection || %{})
            ]}>
            </div>
            <span>{StatusHelpers.provider_status_label(@provider_connection || %{})}</span>
          </div>
        </div>

        <div class="flex items-center gap-2 text-sm mb-2 relative z-10">
          <span class="text-gray-400">{@chain_id}</span>
          <span :if={@provider_connection} class="text-gray-300">·</span>
          <span :if={@provider_connection} class="text-gray-400">{@transport_label}</span>
        </div>
      </div>
    </div>
    """
  end

  defp transport_label(%{url: url, ws_url: ws_url}) when not is_nil(url) and not is_nil(ws_url),
    do: "HTTP + WS"

  defp transport_label(%{ws_url: ws_url}) when not is_nil(ws_url), do: "WS only"
  defp transport_label(_), do: "HTTP only"

  defp get_chain_id_display(profile, %{chain: chain}) when not is_nil(chain),
    do: "Chain ID: #{Helpers.get_chain_id(profile, chain)}"

  defp get_chain_id_display(_, _), do: "Provider"

  # --- Sync Status ---

  attr(:sync_data, :map, required: true)

  defp sync_status_section(assigns) do
    ~H"""
    <DetailPanelComponents.panel_section border={false} class="pb-2">
      <DetailPanelComponents.section_header title="Sync Status" />
      <div :if={@sync_data.block_height && @sync_data.consensus_height}>
        <div class="flex items-center justify-between text-sm mb-2">
          <span class="text-gray-400">
            Block Height:
            <span class="text-white font-mono">
              {Formatting.format_number(@sync_data.block_height)}
            </span>
          </span>
          <span class="text-gray-400">
            Consensus:
            <span class="text-white font-mono">
              {Formatting.format_number(@sync_data.consensus_height)}
            </span>
          </span>
          <span class={["font-mono font-bold", sync_color(@sync_data.sync_status)]}>
            {sync_label(@sync_data.optimistic_lag, @sync_data.effective_lag)}
          </span>
        </div>
        <DetailPanelComponents.progress_bar
          value={sync_progress(@sync_data.block_height, @sync_data.consensus_height)}
          status={@sync_data.sync_status}
          class="mb-2"
        />
        <div class="text-xs text-gray-500 text-right">{sync_description(@sync_data.sync_status)}</div>
      </div>
      <div
        :if={!@sync_data.block_height || !@sync_data.consensus_height}
        class="text-sm text-gray-600 pt-2 pb-6"
      >
        Block height data unavailable
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  # --- Performance Metrics ---

  attr(:metrics_data, :map, required: true)

  defp performance_metrics_strip(assigns) do
    metrics = assigns.metrics_data
    success_rate = Map.get(metrics, :success_rate)
    calls = Map.get(metrics, :calls_last_minute, 0)

    # Show success rate if we have data, even if 0%
    success_display =
      cond do
        is_number(success_rate) and success_rate > 0 -> "#{success_rate}%"
        calls > 0 -> "0%"
        true -> "—"
      end

    assigns =
      assigns
      |> assign(:p50, format_latency(Map.get(metrics, :p50_latency)))
      |> assign(:p95, format_latency(Map.get(metrics, :p95_latency)))
      |> assign(:success_rate_display, success_display)
      |> assign(:success_class, success_rate_color(success_rate || 0))
      |> assign(:traffic, format_traffic(Map.get(metrics, :pick_share_5m)))

    ~H"""
    <DetailPanelComponents.panel_section border={false} class="pt-1 pb-2">
      <div class="flex items-center gap-2 mb-4">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-gray-500">Performance</h4>
        <span class="text-[9px] px-1.5 py-0.5 rounded bg-gray-800 text-gray-500 font-medium">
          Profile
        </span>
      </div>
      <DetailPanelComponents.metrics_strip class="border-x rounded">
        <:metric label="Latency p50" value={@p50} />
        <:metric label="Latency p95" value={@p95} />
        <:metric label="Success" value={@success_rate_display} value_class={@success_class} />
        <:metric label="Traffic" value={@traffic} />
      </DetailPanelComponents.metrics_strip>
    </DetailPanelComponents.panel_section>
    """
  end

  # --- Circuit Breaker ---

  attr(:circuit_data, :map, required: true)

  defp circuit_breaker_section(assigns) do
    ~H"""
    <DetailPanelComponents.panel_section
      :if={@circuit_data.has_http || @circuit_data.has_ws}
      border={false}
    >
      <DetailPanelComponents.section_header title="Circuit Breaker" class="pb-[18px]" />
      <.unified_circuit_view circuit_data={@circuit_data} />
    </DetailPanelComponents.panel_section>
    """
  end

  attr(:circuit_data, :map, required: true)

  defp unified_circuit_view(assigns) do
    # Unified view uses classic visualization for all modes
    # In aggregate mode, adds subtle counts under each state dot
    circuit = assigns.circuit_data
    is_aggregate = circuit.mode == :aggregate

    # Get state and counts for HTTP
    {http_state, http_counts} =
      if is_aggregate do
        {circuit.http_worst, circuit.http_counts}
      else
        {circuit.http_state, nil}
      end

    # Get state and counts for WS
    {ws_state, ws_counts} =
      if is_aggregate do
        {circuit.ws_worst, circuit.ws_counts}
      else
        {circuit.ws_state, nil}
      end

    failures = Map.get(circuit, :consecutive_failures, 0)
    successes = Map.get(circuit, :consecutive_successes, 0)
    region_count = Map.get(circuit, :region_count, 1)

    assigns =
      assigns
      |> assign(:http_state, http_state)
      |> assign(:ws_state, ws_state)
      |> assign(:http_counts, http_counts)
      |> assign(:ws_counts, ws_counts)
      |> assign(:is_aggregate, is_aggregate)
      |> assign(:region_count, region_count)
      |> assign(:failures, failures)
      |> assign(:failures_class, if(failures > 0, do: "text-red-400", else: "text-gray-300"))
      |> assign(:successes, successes)

    ~H"""
    <div class="space-y-2">
      <div :if={@circuit_data.has_http}>
        <.circuit_breaker_row_with_counts
          label="HTTP"
          state={@http_state}
          counts={@http_counts}
          total={@region_count}
        />
      </div>

      <div :if={@circuit_data.has_ws}>
        <.circuit_breaker_row_with_counts
          label="WS"
          state={@ws_state}
          counts={@ws_counts}
          total={@region_count}
          connected={Map.get(@circuit_data, :ws_connected, false)}
          class="mt-3"
        />
      </div>

      <div :if={!@is_aggregate} class="flex justify-between text-xs text-gray-500 pt-2">
        <span>
          Failures: <span class={@failures_class}>{@failures}/5</span> threshold
        </span>
        <span>
          Successes: <span class="text-emerald-400">{@successes}</span> consecutive
        </span>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:state, :atom, required: true)
  attr(:counts, :map, default: nil)
  attr(:total, :integer, default: 1)
  attr(:connected, :boolean, default: nil)
  attr(:class, :string, default: "")

  defp circuit_breaker_row_with_counts(assigns) do
    {status_text, status_class} = circuit_status_display(assigns.state, assigns.connected)
    counts = assigns.counts
    total = assigns.total
    is_aggregate = counts != nil and total > 1

    # In aggregate mode, light up dots for any state with count > 0
    # In single mode, only light up the current state
    {closed_active, half_open_active, open_active} =
      if is_aggregate do
        {
          Map.get(counts, :closed, 0) > 0,
          Map.get(counts, :half_open, 0) > 0,
          Map.get(counts, :open, 0) > 0
        }
      else
        {
          assigns.state == :closed,
          assigns.state == :half_open,
          assigns.state == :open
        }
      end

    assigns =
      assigns
      |> assign(:status_text, status_text)
      |> assign(:status_class, status_class)
      |> assign(:is_aggregate, is_aggregate)
      |> assign(:closed_active, closed_active)
      |> assign(:half_open_active, half_open_active)
      |> assign(:open_active, open_active)

    ~H"""
    <div class={@class}>
      <div class="flex items-center gap-3">
        <span class="w-10 text-xs text-gray-400">{@label}</span>
        <div class="flex-1 flex items-center gap-1">
          <.circuit_dot active={@closed_active} color="emerald" />
          <div class="flex-1 h-0.5 bg-gray-700"></div>
          <.circuit_dot active={@half_open_active} color="yellow" />
          <div class="flex-1 h-0.5 bg-gray-700"></div>
          <.circuit_dot active={@open_active} color="red" />
        </div>
        <span :if={!@is_aggregate} class={["w-20 text-xs text-right", @status_class]}>
          {@status_text}
        </span>
      </div>
      <.circuit_breaker_labels_with_counts
        :if={@is_aggregate}
        counts={@counts}
        total={@total}
        is_aggregate={@is_aggregate}
      />
    </div>
    """
  end

  attr(:active, :boolean, required: true)
  attr(:color, :string, required: true)

  defp circuit_dot(assigns) do
    active_class =
      case assigns.color do
        "emerald" -> "bg-emerald-500 border-emerald-400"
        "yellow" -> "bg-yellow-500 border-yellow-400"
        "red" -> "bg-red-500 border-red-400"
      end

    assigns = assign(assigns, :active_class, active_class)

    ~H"""
    <div class={[
      "w-3 h-3 rounded-full border-2",
      if(@active, do: @active_class, else: "border-gray-600")
    ]}>
    </div>
    """
  end

  attr(:counts, :map, default: nil)
  attr(:total, :integer, default: 1)
  attr(:is_aggregate, :boolean, default: false)

  defp circuit_breaker_labels_with_counts(assigns) do
    counts = assigns.counts || %{}
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <div class="flex items-center gap-3 pb-1">
      <span class="w-10"></span>
      <div class="flex-1 flex items-center gap-1 pl-1.5">
        <span class="text-[11px] text-gray-600 text-center">
          closed · {Map.get(@counts, :closed, 0)}/{@total}
        </span>
        <div class="flex-1"></div>
        <span class="text-[11px] text-gray-600 text-center">
          half-open · {Map.get(@counts, :half_open, 0)}/{@total}
        </span>
        <div class="flex-1"></div>
        <span class="text-[11px] text-gray-600 text-center">
          open · {Map.get(@counts, :open, 0)}/{@total}
        </span>
      </div>
      <span :if={!@is_aggregate} class="w-20"></span>
    </div>
    """
  end

  defp circuit_status_display(state, connected) do
    case {state, connected} do
      {:open, _} -> {"Open", "text-red-400"}
      {:half_open, _} -> {"Half-open", "text-yellow-400"}
      {_, true} -> {"Connected", "text-emerald-400"}
      {_, false} -> {"Disconnected", "text-gray-400"}
      {:closed, _} -> {"Connected", "text-emerald-400"}
      _ -> {"Unknown", "text-gray-400"}
    end
  end

  # --- Issues ---

  attr(:provider_connection, :map, required: true)
  attr(:provider_unified_events, :list, required: true)

  defp issues_section(assigns) do
    active_alerts = build_active_alerts(assigns.provider_connection)

    event_feed =
      assigns.provider_unified_events
      |> Enum.filter(&relevant_event?/1)
      |> Enum.take(15)

    has_content = length(active_alerts) > 0 or length(event_feed) > 0

    assigns =
      assigns
      |> assign(:active_alerts, active_alerts)
      |> assign(:event_feed, event_feed)
      |> assign(:has_content, has_content)

    ~H"""
    <DetailPanelComponents.panel_section border={false}>
      <DetailPanelComponents.section_header title="Issues" />

      <div :if={length(@active_alerts) > 0} class="space-y-2 mb-3">
        <DetailPanelComponents.alert_item
          :for={{severity, message, detail} <- @active_alerts}
          severity={severity}
          message={message}
          detail={detail}
        />
      </div>

      <div :if={length(@event_feed) > 0}>
        <div class="max-h-64 overflow-y-auto space-y-1.5 pr-1">
          <.event_feed_item :for={event <- @event_feed} event={event} />
        </div>
        <div class="mt-2 pt-1 text-center">
          <span class="text-[10px] text-gray-500">{length(@event_feed)} events</span>
        </div>
      </div>

      <div :if={!@has_content} class="text-xs text-gray-500 text-center pt-2 pb-6">
        No issues detected
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  # --- Method Performance ---

  attr(:metrics_data, :map, required: true)

  defp method_performance_section(assigns) do
    rpc_stats = Map.get(assigns.metrics_data, :rpc_stats, [])
    max_calls = rpc_stats |> Enum.map(& &1.total_calls) |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(:rpc_stats, Enum.take(rpc_stats, 6))
      |> assign(:max_calls, max_calls)

    ~H"""
    <DetailPanelComponents.panel_section border={false}>
      <DetailPanelComponents.section_header title="Method Performance" />
      <div :if={length(@rpc_stats) > 0} class="space-y-2">
        <.method_stat_row :for={stat <- @rpc_stats} stat={stat} max_calls={@max_calls} />
        <div class="text-[10px] text-gray-600 text-right mt-2">(calls)</div>
      </div>
      <div :if={@rpc_stats == []} class="text-xs text-gray-500 text-center py-2 pb-6">
        No recent method data
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  attr(:stat, :map, required: true)
  attr(:max_calls, :integer, required: true)

  defp method_stat_row(assigns) do
    stat = assigns.stat
    bar_width = if assigns.max_calls > 0, do: stat.total_calls / assigns.max_calls * 100, else: 0

    assigns =
      assigns
      |> assign(:bar_width, bar_width)
      |> assign(:latency, "#{Helpers.to_float(stat.avg_duration_ms) |> Float.round(0)}ms")
      |> assign(:success_pct, "#{(Helpers.to_float(stat.success_rate) * 100) |> Float.round(1)}%")
      |> assign(:success_class, success_rate_color(stat.success_rate * 100))

    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <span class="w-28 text-gray-300 truncate font-mono" title={@stat.method}>{@stat.method}</span>
      <span class="w-16 text-gray-400">p50: {@latency}</span>
      <span class={["w-12", @success_class]}>{@success_pct}</span>
      <div class="flex-1 bg-gray-800 rounded h-2">
        <div class="bg-gray-600 h-2 rounded" style={"width: #{@bar_width}%"}></div>
      </div>
      <span class="w-14 text-right text-gray-500">{@stat.total_calls}</span>
    </div>
    """
  end

  # --- Event Feed Item ---

  defp relevant_event?(event) do
    event[:kind] in [:circuit, :provider, :error] or event[:severity] in [:warn, :error]
  end

  attr(:event, :map, required: true)

  defp event_feed_item(assigns) do
    event = assigns.event
    display_message = format_event_message(event[:message] || "Unknown event")
    is_expandable = String.length(display_message) > 80 or has_event_details?(event)

    assigns =
      assigns
      |> assign(:severity_color, severity_dot_color(event[:severity]))
      |> assign(:time_ago, format_time_ago(event[:ts_ms]))
      |> assign(:display_message, display_message)
      |> assign(:is_expandable, is_expandable)
      |> assign(:preview_message, truncate_message(display_message, 80))
      |> assign(
        :event_id,
        "event-#{:erlang.phash2({event[:kind], event[:message], event[:ts_ms]})}"
      )

    ~H"""
    <details
      :if={@is_expandable}
      id={@event_id}
      phx-hook="ExpandableDetails"
      class="group bg-gray-800/30 rounded-lg hover:bg-gray-800/50 transition-colors"
    >
      <summary class="p-2 cursor-pointer list-none">
        <.event_row
          severity_color={@severity_color}
          message={@preview_message}
          time_ago={@time_ago}
          expandable={true}
        />
      </summary>
      <.event_details event={@event} display_message={@display_message} />
    </details>

    <div
      :if={!@is_expandable}
      class="bg-gray-800/30 rounded-lg p-2 hover:bg-gray-800/50 transition-colors"
    >
      <.event_row
        severity_color={@severity_color}
        message={@display_message}
        time_ago={@time_ago}
        expandable={false}
      />
    </div>
    """
  end

  attr(:severity_color, :string, required: true)
  attr(:message, :string, required: true)
  attr(:time_ago, :string, required: true)
  attr(:expandable, :boolean, required: true)

  defp event_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-2">
      <div class="flex items-start gap-2 min-w-0 flex-1">
        <div class={["w-1.5 h-1.5 rounded-full mt-1.5 shrink-0", @severity_color]}></div>
        <span class="text-xs text-gray-300 break-words">{@message}</span>
      </div>
      <div class="flex items-center gap-1 shrink-0">
        <svg
          :if={@expandable}
          class="w-3 h-3 text-gray-500 transition-transform group-open:rotate-180"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
        <span class="text-[10px] text-gray-500">{@time_ago}</span>
      </div>
    </div>
    """
  end

  attr(:event, :map, required: true)
  attr(:display_message, :string, required: true)

  defp event_details(assigns) do
    error_code = get_in(assigns.event, [:meta, :error_code])
    error_message = get_in(assigns.event, [:meta, :error_message])
    error_category = get_in(assigns.event, [:meta, :error_category])
    transport = get_in(assigns.event, [:meta, :transport])

    assigns =
      assigns
      |> assign(:error_code, error_code)
      |> assign(:error_message, error_message)
      |> assign(:error_category, error_category)
      |> assign(:transport, transport)
      |> assign(:has_error_info, error_code || error_message)
      |> assign(:is_truncated, String.length(assigns.display_message) > 80)

    ~H"""
    <div class="px-2 pb-2 pt-1 ml-3.5 space-y-2">
      <div :if={@is_truncated} class="text-xs text-gray-300 break-words whitespace-pre-wrap">
        {@display_message}
      </div>

      <div :if={@has_error_info} class="space-y-1.5">
        <div :if={@error_message} class="text-[11px] text-red-400 break-words">{@error_message}</div>
        <div class="flex flex-wrap gap-1.5">
          <span
            :if={@error_code}
            class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 text-[10px] font-mono"
          >
            ERR {@error_code}
          </span>
          <span
            :if={@error_category}
            class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400 text-[10px]"
          >
            {@error_category}
          </span>
        </div>
      </div>

      <div class="flex flex-wrap gap-1">
        <span
          :if={@event[:kind]}
          class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400"
        >
          {@event[:kind] |> to_string() |> String.capitalize()}
        </span>
        <span :if={@transport} class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400">
          {@transport}
        </span>
      </div>
    </div>
    """
  end

  # --- Helper Functions ---

  defp sync_status_level(blocks_behind) when blocks_behind <= 2, do: :healthy
  defp sync_status_level(blocks_behind) when blocks_behind <= 10, do: :degraded
  defp sync_status_level(_), do: :down

  defp sync_color(:healthy), do: "text-emerald-400"
  defp sync_color(:degraded), do: "text-yellow-400"
  defp sync_color(:down), do: "text-red-400"

  defp sync_label(optimistic_lag, _effective_lag) when is_integer(optimistic_lag) do
    cond do
      optimistic_lag >= -2 -> "Synced"
      optimistic_lag < 0 -> "#{optimistic_lag}"
      true -> "+#{optimistic_lag}"
    end
  end

  defp sync_label(nil, effective_lag) when effective_lag <= 2, do: "Synced"
  defp sync_label(nil, effective_lag) when effective_lag > 2, do: "-#{effective_lag}"
  defp sync_label(nil, _), do: "—"

  defp sync_description(:healthy), do: "(within range)"
  defp sync_description(:degraded), do: "(slightly behind)"
  defp sync_description(:down), do: "(significantly behind)"

  defp sync_progress(_, 0), do: 100

  defp sync_progress(block_height, consensus_height),
    do: min(100, block_height / consensus_height * 100)

  defdelegate format_latency(ms), to: Formatting
  defdelegate format_time_ago(ts_ms), to: Formatting
  defdelegate success_rate_color(rate), to: Formatting

  defp format_traffic(nil), do: "—"
  defp format_traffic(value), do: "#{value |> Helpers.to_float() |> Float.round(1)}%"

  defp severity_dot_color(:error), do: "bg-red-500"
  defp severity_dot_color(:warn), do: "bg-yellow-500"
  defp severity_dot_color(_), do: "bg-blue-500"

  defp truncate_message(message, max_length) when byte_size(message) > max_length do
    String.slice(message, 0, max_length - 3) <> "..."
  end

  defp truncate_message(message, _), do: message

  defp build_active_alerts(conn) do
    []
    |> add_circuit_alerts(conn)
    |> add_rate_limit_alerts(conn)
    |> add_failure_alerts(conn)
    |> add_ws_disconnect_alert(conn)
  end

  defp add_circuit_alerts(alerts, conn) do
    http_cb = Map.get(conn, :http_circuit_state)
    ws_cb = Map.get(conn, :ws_circuit_state)

    alerts
    |> maybe_add(
      http_cb == :open,
      {:error, "HTTP circuit OPEN", format_cb_error(conn[:http_cb_error])}
    )
    |> maybe_add(ws_cb == :open, {:error, "WS circuit OPEN", format_cb_error(conn[:ws_cb_error])})
    |> maybe_add(http_cb == :half_open, {:warn, "HTTP circuit recovering", nil})
    |> maybe_add(ws_cb == :half_open, {:warn, "WS circuit recovering", nil})
  end

  defp add_rate_limit_alerts(alerts, conn) do
    http_limited = Map.get(conn, :http_rate_limited, false)
    ws_limited = Map.get(conn, :ws_rate_limited, false)
    remaining = Map.get(conn, :rate_limit_remaining, %{})

    case {http_limited, ws_limited} do
      {true, true} ->
        http_sec = div(Map.get(remaining, :http, 0), 1000)
        ws_sec = div(Map.get(remaining, :ws, 0), 1000)
        [{:warn, "Rate limited (HTTP: #{http_sec}s, WS: #{ws_sec}s)", nil} | alerts]

      {true, false} ->
        [{:warn, "HTTP rate limited (#{div(Map.get(remaining, :http, 0), 1000)}s)", nil} | alerts]

      {false, true} ->
        [{:warn, "WS rate limited (#{div(Map.get(remaining, :ws, 0), 1000)}s)", nil} | alerts]

      _ ->
        alerts
    end
  end

  defp add_failure_alerts(alerts, conn) do
    case Map.get(conn, :consecutive_failures, 0) do
      0 -> alerts
      n when n >= 3 -> [{:error, "#{n} consecutive failures", nil} | alerts]
      n -> [{:warn, "#{n} consecutive failures", nil} | alerts]
    end
  end

  defp add_ws_disconnect_alert(alerts, conn) do
    has_ws = Map.get(conn, :ws_url) != nil
    ws_connected = Map.get(conn, :ws_connected, false)
    ws_circuit_ok = Map.get(conn, :ws_circuit_state) != :open

    if has_ws and not ws_connected and ws_circuit_ok do
      [{:warn, "WebSocket disconnected", nil} | alerts]
    else
      alerts
    end
  end

  defp maybe_add(alerts, true, alert), do: [alert | alerts]
  defp maybe_add(alerts, false, _), do: alerts

  defp format_cb_error(nil), do: nil

  defp format_cb_error(error) when is_map(error) do
    %{
      code: error[:code] || error[:error_code],
      category: error[:category] || error[:error_category],
      message: error[:message] || error[:error_message]
    }
  end

  defp format_event_message(message) when is_binary(message) do
    if String.starts_with?(message, "%Lasso.JSONRPC.Error{") do
      parse_jsonrpc_error(message)
    else
      message
    end
  end

  defp format_event_message(other), do: inspect(other)

  defp parse_jsonrpc_error(message) do
    code = extract_field(message, "code:")
    msg = extract_field(message, "message:")
    category = extract_field(message, "category:")

    [msg, code, category]
    |> Enum.reject(&(&1 == nil or &1 == "nil"))
    |> Enum.map(fn
      ^msg -> clean_string_value(msg)
      ^code -> "ERR #{code}"
      ^category -> "(#{category})"
    end)
    |> case do
      [] -> message
      parts -> Enum.join(parts, " ")
    end
  end

  defp extract_field(str, field) do
    case Regex.run(~r/#{Regex.escape(field)}\s*([^,}]+)/, str) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp clean_string_value(str) do
    str
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace(~r/\\\"/, "\"")
  end

  defp has_event_details?(event) do
    meta = event[:meta] || %{}
    meta[:error_code] || meta[:error_message] || meta[:error_category]
  end

  defp find_regions_with_issues(cluster_circuits, provider_id) do
    cluster_circuits
    |> Enum.filter(fn {{pid, _region}, circuit} ->
      pid == provider_id and (circuit[:http] == :open or circuit[:ws] == :open)
    end)
    |> Enum.map(fn {{_pid, region}, _} -> region end)
    |> Enum.uniq()
  end

  defp filter_events_by_region(events, "aggregate"), do: events

  defp filter_events_by_region(events, region) do
    Enum.filter(events, fn event ->
      event[:source_node_id] == region or event[:source_node_id] == nil
    end)
  end
end
