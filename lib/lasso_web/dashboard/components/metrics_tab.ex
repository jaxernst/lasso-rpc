defmodule LassoWeb.Dashboard.Components.MetricsTab do
  @moduledoc """
  LiveComponent for displaying provider and method performance metrics.
  """
  use LassoWeb, :live_component

  alias LassoWeb.Components.DetailPanelComponents
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

    # Prefer cluster node IDs from topology (authoritative), fall back to extracting from metrics
    cluster_node_ids = assigns[:cluster_node_ids] || []
    metrics_node_ids = extract_available_node_ids(assigns.provider_metrics)

    # Merge both sources: cluster node IDs are authoritative, but include any additional from metrics
    available_node_ids =
      (cluster_node_ids ++ metrics_node_ids)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [nil, "unknown"]))
      |> Enum.sort()

    # Only show node tabs when there are multiple nodes (single node = no point in tabs)
    show_node_tabs = length(available_node_ids) > 1

    # Preserve selected_node_id if already set and still valid, otherwise default to "all"
    current_node_id = socket.assigns[:selected_node_id] || "all"

    selected_node_id =
      if current_node_id == "all" or current_node_id in available_node_ids do
        current_node_id
      else
        "all"
      end

    socket =
      socket
      |> assign(assigns)
      |> assign(:chain_config, chain_config)
      |> assign(:available_node_ids, available_node_ids)
      |> assign(:selected_node_id, selected_node_id)
      |> assign(:show_node_tabs, show_node_tabs)

    {:ok, socket}
  end

  defp extract_available_node_ids(provider_metrics) when is_list(provider_metrics) do
    provider_metrics
    |> Enum.flat_map(fn provider ->
      case Map.get(provider, :latency_by_node) do
        nodes when is_map(nodes) ->
          Map.keys(nodes)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, "unknown"]))
    |> Enum.sort()
  end

  defp extract_available_node_ids(_), do: []

  @impl true
  def handle_event("select_metrics_chain", %{"chain" => chain}, socket) do
    send(self(), {:metrics_chain_selected, chain})
    {:noreply, assign(socket, :selected_node_id, "all")}
  end

  @impl true
  def handle_event("select_node_id", %{"node-id" => node_id}, socket) do
    {:noreply, assign(socket, :selected_node_id, node_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto">
      <div class="mx-auto max-w-7xl px-4 py-6">
        <div class={["flex gap-2", if(@show_node_tabs, do: "mb-4", else: "mb-6")]}>
          <.chain_selector_button
            :for={chain <- @available_chains}
            chain={chain}
            selected={chain.name == @metrics_selected_chain}
            chain_config={@chain_config}
            myself={@myself}
          />
        </div>

        <.node_view_tabs
          :if={@show_node_tabs}
          available_node_ids={@available_node_ids}
          selected_node_id={@selected_node_id}
          myself={@myself}
        />

        <.loading_state :if={@metrics_loading} />

        <div :if={!@metrics_loading} class="space-y-6">
          <.provider_performance_table
            provider_metrics={@provider_metrics}
            metrics_last_updated={@metrics_last_updated}
            available_node_ids={@available_node_ids}
            selected_node_id={@selected_node_id}
            show_node_filter={false}
            myself={@myself}
          />
          <.method_performance_breakdown
            method_metrics={@method_metrics}
            selected_node_id={@selected_node_id}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:available_node_ids, :list, required: true)
  attr(:selected_node_id, :string, required: true)
  attr(:myself, :any, required: true)

  defp node_view_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-1 mb-8 text-sm">
      <span class="text-xs text-gray-500 uppercase tracking-wide mr-2">Viewing</span>
      <button
        phx-click="select_node_id"
        phx-value-region="all"
        phx-target={@myself}
        class={[
          "px-3 py-1 border rounded-full transition-all",
          if(@selected_node_id == "all",
            do: "border-gray-700 border bg-gray-800/50 text-white",
            else: "border-gray-700/0 text-gray-400 hover:text-gray-300"
          )
        ]}
      >
        all nodes
        <span :if={length(@available_node_ids) > 0} class="text-gray-500">
          ({length(@available_node_ids)})
        </span>
      </button>

      <button
        :for={nid <- @available_node_ids}
        phx-click="select_node_id"
        phx-value-node-id={nid}
        phx-target={@myself}
        class={[
          "px-3 py-1 border rounded-full transition-all",
          if(@selected_node_id == nid,
            do: "border-gray-700 border bg-gray-800/50 text-white",
            else: "border-gray-700/0 text-gray-400 hover:text-gray-300"
          )
        ]}
      >
        {nid}
      </button>
    </div>
    """
  end

  attr(:chain, :map, required: true)
  attr(:selected, :boolean, required: true)
  attr(:chain_config, :map, required: true)
  attr(:myself, :any, required: true)

  defp chain_selector_button(assigns) do
    ~H"""
    <button
      phx-click="select_metrics_chain"
      phx-value-chain={@chain.name}
      phx-target={@myself}
      class={[
        "px-4 py-2 rounded-lg text-sm font-medium transition-all",
        if(@selected,
          do: "bg-sky-500/20 text-sky-300 border border-sky-500/50 shadow-md shadow-sky-500/10",
          else:
            "bg-gray-800/50 text-gray-400 border border-gray-700 hover:border-sky-500/50 hover:text-sky-300 hover:bg-gray-800/80"
        )
      ]}
    >
      <div class="flex items-center gap-2">
        <span>{@chain.display_name}</span>
        <span :if={@selected} class="text-xs text-gray-500">ID: {@chain_config.chain_id}</span>
      </div>
    </button>
    """
  end

  defp loading_state(assigns) do
    ~H"""
    <div class="py-12 text-center">
      <div class="inline-block h-8 w-8 animate-spin rounded-full border-4 border-solid border-sky-500 border-r-transparent">
      </div>
      <p class="mt-4 text-gray-400">Loading metrics...</p>
    </div>
    """
  end

  attr(:provider_metrics, :list, required: true)
  attr(:metrics_last_updated, :any, default: nil)
  attr(:available_node_ids, :list, default: [])
  attr(:selected_node_id, :string, default: "all")
  attr(:show_node_filter, :boolean, default: true)
  attr(:myself, :any, required: true)

  defp provider_performance_table(assigns) do
    filtered_metrics = filter_metrics_by_node_id(assigns.provider_metrics, assigns.selected_node_id)
    assigns = assign(assigns, :filtered_metrics, filtered_metrics)

    ~H"""
    <section>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-lg font-semibold flex items-center gap-2 text-white">
          <span>Provider Performance</span>
          <span class="text-xs text-gray-500 font-normal">
            ({length(@filtered_metrics)} providers)
          </span>
        </h2>
        <div :if={@metrics_last_updated} class="flex items-center gap-2 text-xs text-gray-500">
          <div class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></div>
          <span class="font-mono text-gray-400">
            {Calendar.strftime(@metrics_last_updated, "%H:%M:%S")}
          </span>
        </div>
      </div>

      <.node_filter_pills
        :if={@show_node_filter and @available_node_ids != []}
        available_node_ids={@available_node_ids}
        selected_node_id={@selected_node_id}
        myself={@myself}
      />

      <DetailPanelComponents.empty_state :if={@filtered_metrics == []}>
        <p class="text-sm font-medium text-gray-400 mb-1">No metrics available</p>
        <p class="text-xs text-gray-600">
          <%= if @selected_node_id != "all" do %>
            No provider metrics for node <span class="font-mono">{@selected_node_id}</span>. Try selecting "all nodes" or a different node.
          <% else %>
            No provider metrics recorded in the last 24 hours. Metrics will appear as requests flow through your RPC endpoints.
          <% end %>
        </p>
      </DetailPanelComponents.empty_state>

      <div
        :if={@filtered_metrics != []}
        class="bg-gray-900/95 backdrop-blur-lg rounded-xl border border-gray-700/60 shadow-sm overflow-hidden"
      >
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
              <.provider_row
                :for={{provider, index} <- Enum.with_index(@filtered_metrics, 1)}
                provider={provider}
                rank={index}
                provider_metrics={@filtered_metrics}
              />
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr(:available_node_ids, :list, required: true)
  attr(:selected_node_id, :string, required: true)
  attr(:myself, :any, required: true)

  defp node_filter_pills(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 mb-4">
      <button
        phx-click="select_node_id"
        phx-value-node-id="all"
        phx-target={@myself}
        class={[
          "px-3 py-1.5 rounded-full text-sm font-medium transition-all",
          if(@selected_node_id == "all",
            do: "bg-sky-500/20 text-sky-300 border border-sky-500/50",
            else: "bg-gray-800/50 text-gray-400 border border-gray-700 hover:border-sky-500/30"
          )
        ]}
      >
        All Nodes
      </button>
      <button
        :for={nid <- @available_node_ids}
        phx-click="select_node_id"
        phx-value-node-id={nid}
        phx-target={@myself}
        class={[
          "px-3 py-1.5 rounded-full text-sm font-medium transition-all",
          if(@selected_node_id == nid,
            do: "bg-sky-500/20 text-sky-300 border border-sky-500/50",
            else: "bg-gray-800/50 text-gray-400 border border-gray-700 hover:border-sky-500/30"
          )
        ]}
      >
        {nid}
      </button>
    </div>
    """
  end

  defp filter_metrics_by_node_id(provider_metrics, "all"), do: provider_metrics

  defp filter_metrics_by_node_id(provider_metrics, node_id) do
    provider_metrics
    |> Enum.map(fn provider ->
      case Map.get(provider, :latency_by_node) do
        nodes when is_map(nodes) and map_size(nodes) > 0 ->
          node_data = Map.get(nodes, node_id)

          if node_data && node_data[:avg] do
            provider
            |> Map.put(:avg_latency, node_data[:avg])
            |> Map.put(:p50_latency, node_data[:p50])
            |> Map.put(:p95_latency, node_data[:p95])
            |> Map.put(:p99_latency, node_data[:p99])
            |> Map.put(:success_rate, node_data[:success_rate])
            |> Map.put(:total_calls, node_data[:total_calls])
            |> Map.put(:node_filtered, true)
            |> update_consistency_ratio()
          else
            nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.avg_latency || 999_999))
  end

  defp update_consistency_ratio(provider) do
    p50 = Map.get(provider, :p50_latency)
    p99 = Map.get(provider, :p99_latency)

    consistency_ratio =
      if p50 && p99 && p50 > 0 do
        p99 / p50
      else
        nil
      end

    Map.put(provider, :consistency_ratio, consistency_ratio)
  end

  attr(:provider, :map, required: true)
  attr(:rank, :integer, required: true)
  attr(:provider_metrics, :list, required: true)

  defp provider_row(assigns) do
    ~H"""
    <tr class="hover:bg-gray-900/30 transition-colors">
      <td class="px-4 py-3">
        <DetailPanelComponents.rank_badge rank={@rank} />
      </td>
      <td class="px-4 py-3 font-medium text-white">{@provider.name}</td>
      <td class="px-4 py-3 text-right">
        <.latency_bar
          :if={@provider.avg_latency}
          latency={@provider.avg_latency}
          provider_metrics={@provider_metrics}
        />
        <span :if={!@provider.avg_latency} class="text-gray-600">—</span>
      </td>
      <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
        {format_latency(@provider.p50_latency)}
      </td>
      <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
        {format_latency(@provider.p95_latency)}
      </td>
      <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
        {format_latency(@provider.p99_latency)}
      </td>
      <td class="px-4 py-3 text-right">
        <span
          :if={@provider.consistency_ratio}
          class={["font-mono text-sm", Status.consistency_color(@provider.consistency_ratio)]}
        >
          {Formatting.safe_round(@provider.consistency_ratio, 1)}x
        </span>
        <span :if={!@provider.consistency_ratio} class="text-gray-600">—</span>
      </td>
      <td class="px-4 py-3 text-right">
        <span
          :if={@provider.success_rate}
          class={["font-mono text-sm", success_color(@provider.success_rate)]}
        >
          {Formatting.safe_round(@provider.success_rate * 100, 1)}%
        </span>
        <span :if={!@provider.success_rate} class="text-gray-600">—</span>
      </td>
      <td class="px-4 py-3 text-right font-mono text-sm text-gray-400">
        {Formatting.format_number(@provider.total_calls)}
      </td>
    </tr>
    """
  end

  attr(:latency, :float, required: true)
  attr(:provider_metrics, :list, required: true)

  defp latency_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-end gap-2">
      <div class="flex-1 max-w-[100px] h-1.5 bg-gray-800 rounded-full overflow-hidden">
        <div
          class="h-full bg-sky-500 rounded-full transition-all"
          style={"width: #{Formatting.calculate_bar_width(@latency, @provider_metrics, :avg_latency)}%"}
        >
        </div>
      </div>
      <span class="text-sky-400 font-mono text-sm w-16">{Formatting.safe_round(@latency, 0)}ms</span>
    </div>
    """
  end

  defp format_latency(nil), do: "—"
  defp format_latency(ms), do: "#{Formatting.safe_round(ms, 0)}ms"

  defp success_color(rate) when rate >= 0.99, do: "text-emerald-400"
  defp success_color(rate) when rate >= 0.95, do: "text-yellow-400"
  defp success_color(_), do: "text-red-400"

  attr(:method_metrics, :list, required: true)
  attr(:selected_node_id, :string, default: "all")

  defp method_performance_breakdown(assigns) do
    filtered_metrics =
      filter_method_metrics_by_node_id(assigns.method_metrics, assigns.selected_node_id)

    assigns = assign(assigns, :filtered_metrics, filtered_metrics)

    ~H"""
    <section>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-lg font-semibold text-white">Method Performance Breakdown</h2>
      </div>

      <DetailPanelComponents.empty_state :if={@filtered_metrics == []}>
        <p class="text-sm font-medium text-gray-400 mb-1">No method metrics available</p>
        <p class="text-xs text-gray-600">
          <%= if @selected_node_id != "all" do %>
            No method metrics for this node. Try selecting "all nodes" to see aggregate data.
          <% else %>
            No method performance data recorded in the last 24 hours. Method breakdowns will appear as RPC calls are made.
          <% end %>
        </p>
      </DetailPanelComponents.empty_state>

      <div :if={@filtered_metrics != []} class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <.method_card :for={method_data <- @filtered_metrics} method_data={method_data} />
      </div>
    </section>
    """
  end

  defp filter_method_metrics_by_node_id(method_metrics, "all"), do: method_metrics

  defp filter_method_metrics_by_node_id(method_metrics, node_id) do
    method_metrics
    |> Enum.map(fn method_data ->
      filtered_providers =
        method_data.providers
        |> Enum.map(fn provider ->
          case Map.get(provider, :stats_by_node) do
            stats when is_list(stats) and stats != [] ->
              node_stats = Enum.find(stats, fn s -> s.node_id == node_id end)

              if node_stats && node_stats.avg_duration_ms do
                provider
                |> Map.put(:avg_latency, node_stats.avg_duration_ms)
                |> Map.put(:success_rate, node_stats.success_rate)
                |> Map.put(:total_calls, node_stats.total_calls)
                |> Map.put(:p50_latency, get_in(node_stats, [:percentiles, :p50]))
                |> Map.put(:p95_latency, get_in(node_stats, [:percentiles, :p95]))
                |> Map.put(:p99_latency, get_in(node_stats, [:percentiles, :p99]))
              else
                nil
              end

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&(&1.avg_latency || 999_999))

      if filtered_providers == [] do
        nil
      else
        total_calls =
          Enum.reduce(filtered_providers, 0, fn p, acc -> acc + (p.total_calls || 0) end)

        %{method_data | providers: filtered_providers, total_calls: total_calls}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  attr(:method_data, :map, required: true)

  defp method_card(assigns) do
    ~H"""
    <div class="bg-gray-900/95 backdrop-blur-lg rounded-xl border border-gray-700/60 shadow-2xl p-4">
      <div class="flex items-center justify-between mb-3 pb-2 border-b border-gray-700/50">
        <h3 class="font-mono text-sm text-sky-400">{@method_data.method}</h3>
        <span class="text-xs text-gray-500">
          {Formatting.format_number(@method_data.total_calls)} calls
        </span>
      </div>
      <div class="space-y-2">
        <.method_provider_row
          :for={{provider_stat, idx} <- Enum.with_index(@method_data.providers, 1)}
          provider_stat={provider_stat}
          rank={idx}
          providers={@method_data.providers}
        />
      </div>
    </div>
    """
  end

  attr(:provider_stat, :map, required: true)
  attr(:rank, :integer, required: true)
  attr(:providers, :list, required: true)

  defp method_provider_row(assigns) do
    bar_width =
      Formatting.calculate_method_bar_width(assigns.provider_stat.avg_latency, assigns.providers)

    assigns = assign(assigns, :bar_width, bar_width)

    ~H"""
    <div class="flex items-center gap-2">
      <div class="flex-none">
        <DetailPanelComponents.rank_badge rank={@rank} size={:small} />
      </div>
      <div class="flex-none w-28 truncate text-xs text-gray-300">{@provider_stat.provider_name}</div>
      <div class="flex-1 flex items-center gap-1.5">
        <div class="flex-1 h-4 bg-gray-800/50 rounded overflow-hidden">
          <div
            class="h-full bg-gradient-to-r from-emerald-500 to-sky-500 flex items-center justify-end px-1.5"
            style={"width: #{@bar_width}%"}
          >
            <span class="text-[10px] font-mono text-white font-semibold">
              {Formatting.safe_round(@provider_stat.avg_latency, 0)}ms
            </span>
          </div>
        </div>
      </div>
      <div class="flex-none flex items-center gap-2 text-[10px]">
        <span class={[
          "font-mono",
          if(@provider_stat.success_rate >= 0.99, do: "text-emerald-400", else: "text-yellow-400")
        ]}>
          {Formatting.safe_round(@provider_stat.success_rate * 100, 0)}%
        </span>
        <span class="text-gray-500">{Formatting.format_number(@provider_stat.total_calls)}</span>
      </div>
    </div>
    """
  end
end
