defmodule LassoWeb.Dashboard do
  use LassoWeb, :live_view
  require Logger

  alias LassoWeb.NetworkTopology
  alias LassoWeb.Dashboard.{Helpers, MetricsHelpers, StatusHelpers, EndpointHelpers}
  alias LassoWeb.Dashboard.Components
  alias LassoWeb.Components.DashboardHeader
  alias LassoWeb.Components.NetworkStatusLegend
  alias LassoWeb.Components.DashboardComponents
  alias Lasso.Events.Provider

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :active_tab, "overview")

    if connected?(socket) do
      # Global subscriptions
      Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:decisions")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "clients:events")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "chain_config_changes")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "chain_config_updates")

      # Per-chain provider event subscriptions
      Lasso.Config.ConfigStore.list_chains()
      |> Enum.each(fn chain ->
        Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")
      end)

      # Enable scheduler wall time if supported (for utilization metrics)
      try do
        :erlang.system_flag(:scheduler_wall_time, true)
      rescue
        _ -> :ok
      end

      # Prime deltas for statistics-based counters
      _ = :erlang.statistics(:runtime)
      _ = :erlang.statistics(:wall_clock)
      _ = :erlang.statistics(:reductions)
      _ = :erlang.statistics(:io)

      Process.send_after(self(), :vm_metrics_tick, 1_000)
      Process.send_after(self(), :latency_leaders_refresh, 30_000)
    end

    initial_state =
      socket
      |> assign(:connections, [])
      |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
      |> assign(:selected_chain, nil)
      |> assign(:selected_provider, nil)
      |> assign(:routing_events, [])
      |> assign(:provider_events, [])
      |> assign(:client_events, [])
      |> assign(:latest_blocks, [])
      |> assign(:events, [])
      |> assign(:vm_metrics, %{})
      |> assign(:available_chains, Lasso.Config.ConfigStore.list_chains())
      |> assign(:details_collapsed, true)
      |> assign(:events_collapsed, true)
      |> assign(:latency_leaders, %{})
      |> assign(:chain_config_open, true)
      |> assign(:chain_config_collapsed, true)
      |> assign(:selected_chain_metrics, %{})
      |> assign(:selected_chain_events, [])
      |> assign(:selected_chain_unified_events, [])
      |> assign(:selected_chain_endpoints, %{})
      |> fetch_connections()

    {:ok, initial_state}
  end

  @impl true
  def handle_info({:connection_status_update, connections}, socket) do
    prev = Map.get(socket.assigns, :connections, [])
    prev_by_id = Map.new(prev, fn c -> {c.id, c} end)

    # Build diff events for status changes and reconnect attempt increments
    {socket, batch} =
      Enum.reduce(connections, {socket, []}, fn c, {sock, acc} ->
        case Map.get(prev_by_id, c.id) do
          nil ->
            {sock, acc}

          prev_c ->
            new_acc =
              []
              |> then(fn lst ->
                if Map.get(c, :status) != Map.get(prev_c, :status) do
                  [
                    Helpers.as_event(:provider,
                      chain: Map.get(c, :chain),
                      provider_id: c.id,
                      severity:
                        case c.status do
                          :connected -> :info
                          :connecting -> :warn
                          _ -> :warn
                        end,
                      message: "status #{to_string(prev_c.status)} -> #{to_string(c.status)}",
                      meta: %{name: c.name}
                    )
                    | lst
                  ]
                else
                  lst
                end
              end)
              |> then(fn lst ->
                prev_attempts = Map.get(prev_c, :reconnect_attempts, 0)
                attempts = Map.get(c, :reconnect_attempts, 0)

                if attempts > prev_attempts do
                  [
                    Helpers.as_event(:provider,
                      chain: Map.get(c, :chain),
                      provider_id: c.id,
                      severity: :warn,
                      message: "reconnect attempt #{attempts}",
                      meta: %{delta: attempts - prev_attempts}
                    )
                    | lst
                  ]
                else
                  lst
                end
              end)

            {sock, acc ++ new_acc}
        end
      end)

    socket =
      socket
      |> assign(:connections, connections)
      |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
      |> (fn s ->
            if length(batch) > 0 do
              s
              |> update(:events, fn list ->
                Enum.reverse(batch) ++ Enum.take(list, 199 - length(batch))
              end)
              |> push_event("events_batch", %{items: batch})
            else
              s
            end
          end).()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:connection_event, _event_type, _connection_id, _data}, socket) do
    if Process.get(:pending_connection_update) do
      {:noreply, socket}
    else
      Process.put(:pending_connection_update, true)
      Process.send_after(self(), :flush_connections, 500)
      {:noreply, fetch_connections(socket)}
    end
  end

  @impl true
  def handle_info({:connection_status_changed, _connection_id, _connection_data}, socket) do
    if Process.get(:pending_connection_update) do
      {:noreply, socket}
    else
      Process.put(:pending_connection_update, true)
      Process.send_after(self(), :flush_connections, 500)
      {:noreply, fetch_connections(socket)}
    end
  end

  # Routing decision feed (real or synthetic)
  @impl true
  def handle_info(
        %{
          ts: _ts,
          chain: chain,
          method: method,
          strategy: strategy,
          provider_id: pid,
          duration_ms: dur
        } = evt,
        socket
      )
      when is_map(evt) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: pid,
      duration_ms: (if is_number(dur), do: round(dur), else: 0),
      result: Map.get(evt, :result, :unknown),
      failovers: Map.get(evt, :failover_count, 0)
    }

    socket = update(socket, :routing_events, fn list ->
      require Logger
      Logger.info("Adding routing event to list: #{method} -> #{pid} (#{dur}ms, type: #{inspect(dur)}), current list size: #{length(list)}")
      [entry | Enum.take(list, 99)]
    end)

    # Unified events + client-side push
    ev =
      Helpers.as_event(:rpc,
        chain: chain,
        provider_id: pid,
        severity: if(entry.result == :error, do: :warn, else: :info),
        message: "#{method} #{entry.result} (#{dur}ms)",
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket =
      socket
      |> update(:events, fn list -> [ev | Enum.take(list, 199)] end)
      |> push_event("events_batch", %{items: [ev]})
      |> push_event("provider_request", %{provider_id: pid})

    # Update chain-specific metrics if this event is for the currently selected chain
    socket = if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end

    # Trigger connection refresh to update provider metrics in floating details window
    # This ensures real-time reactivity for both simulator and regular traffic
    socket = case Process.get(:pending_connection_update) do
      nil ->
        Process.put(:pending_connection_update, true)
        Process.send_after(self(), :flush_connections, 100)
        fetch_connections(socket)
      _ ->
        socket
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(evt, socket)
      when is_struct(evt, Provider.Healthy) or
             is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.CooldownStart) or
             is_struct(evt, Provider.CooldownEnd) or
             is_struct(evt, Provider.HealthCheckFailed) do
    {chain, pid, event, details, ts} =
      case evt do
        %Provider.Healthy{chain: chain, provider_id: pid, ts: ts} -> {chain, pid, :healthy, nil, ts}
        %Provider.Unhealthy{chain: chain, provider_id: pid, ts: ts} -> {chain, pid, :unhealthy, nil, ts}
        %Provider.CooldownStart{chain: chain, provider_id: pid, until: until, ts: ts} ->
          {chain, pid, :cooldown_start, %{until: until}, ts}
        %Provider.CooldownEnd{chain: chain, provider_id: pid, ts: ts} -> {chain, pid, :cooldown_end, nil, ts}
        %Provider.HealthCheckFailed{chain: chain, provider_id: pid, reason: reason, ts: ts} ->
          {chain, pid, :health_check_failed, %{reason: reason}, ts}
      end

    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: ts,
      chain: chain,
      provider_id: pid,
      event: event,
      details: details
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, 99)] end)

    uev =
      Helpers.as_event(:provider,
        chain: chain,
        provider_id: pid,
        severity: :info,
        message: to_string(event),
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket =
      socket
      |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
      |> push_event("events_batch", %{items: [uev]})

    {:noreply, socket}
  end

  # Client connection events
  @impl true
  def handle_info(%{ts: _t, event: ev, chain: chain, transport: transport} = msg, socket)
      when is_map(msg) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: chain,
      transport: transport,
      event: ev,
      ip: Map.get(msg, :remote_ip) || Map.get(msg, "remote_ip")
    }

    socket = update(socket, :client_events, fn list -> [entry | Enum.take(list, 99)] end)

    uev =
      Helpers.as_event(:client,
        chain: chain,
        severity: :debug,
        message: "client #{ev} via #{transport}",
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket =
      socket
      |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
      |> push_event("events_batch", %{items: [uev]})

    {:noreply, socket}
  end

  # Circuit breaker events - updated to match tuple format
  @impl true
  def handle_info({:circuit_breaker_event, event_data}, socket) do
    %{
      chain: chain,
      provider_id: provider_id,
      transport: transport,
      from: from_state,
      to: to_state,
      reason: reason
    } = event_data

    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: chain,
      provider_id: provider_id,
      event: "circuit [#{transport}]: #{from_state} -> #{to_state} (#{reason})"
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, 99)] end)

    uev =
      Helpers.as_event(:circuit,
        chain: chain,
        provider_id: provider_id,
        severity: :warn,
        message: entry.event,
        meta: Map.merge(Map.drop(entry, [:ts, :ts_ms]), %{transport: transport, from: from_state, to: to_state})
      )

    socket =
      socket
      |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
      |> push_event("events_batch", %{items: [uev]})
      |> fetch_connections()  # Refresh provider data to show updated circuit state

    {:noreply, socket}
  end

  # Compact block events
  @impl true
  def handle_info(%{chain: chain, block_number: bn} = blk, socket) when is_map(blk) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: chain,
      block_number: bn,
      provider_first: Map.get(blk, :provider_first) || Map.get(blk, "provider_first"),
      margin_ms: Map.get(blk, :margin_ms) || Map.get(blk, "margin_ms")
    }

    socket = update(socket, :latest_blocks, fn list -> [entry | Enum.take(list, 19)] end)

    uev =
      Helpers.as_event(:block,
        chain: chain,
        severity: :info,
        message:
          "block #{bn} (first: #{entry.provider_first || "n/a"}, +#{entry.margin_ms || 0}ms)",
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket =
      socket
      |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
      |> push_event("events_batch", %{items: [uev]})

    # Update chain-specific metrics if this event is for the currently selected chain
    socket = if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end

    {:noreply, socket}
  end

  # VM metrics ticker
  @impl true
  def handle_info(:vm_metrics_tick, socket) do
    metrics = MetricsHelpers.collect_vm_metrics()
    Process.send_after(self(), :vm_metrics_tick, 2_000)
    {:noreply, assign(socket, :vm_metrics, metrics)}
  end

  # Latency leaders refresh
  @impl true
  def handle_info(:latency_leaders_refresh, socket) do
    connections = Map.get(socket.assigns, :connections, [])
    latency_leaders = MetricsHelpers.get_latency_leaders_by_chain(connections)
    Process.send_after(self(), :latency_leaders_refresh, 30_000)
    {:noreply, assign(socket, :latency_leaders, latency_leaders)}
  end

  @impl true
  def handle_info(:flush_connections, socket) do
    Process.delete(:pending_connection_update)
    {:noreply, socket}
  end


  @impl true
  def handle_info({:chain_config_deleted, message}, socket) do
    socket =
      socket
      |> fetch_connections()
      |> push_event("show_notification", %{message: message, type: "warning"})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_config_test_results, results}, socket) do
    socket = push_event(socket, "show_test_results", %{results: results})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_config_notification, type, message}, socket) do
    socket = push_event(socket, "show_notification", %{message: message, type: Atom.to_string(type)})
    {:noreply, socket}
  end

  # Chain configuration change notifications (still needed for updating available chains)
  @impl true
  def handle_info({:chain_created, _chain_name, _chain_config}, socket) do
    socket = fetch_connections(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_updated, _chain_name, _chain_config}, socket) do
    socket = fetch_connections(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_deleted, _chain_name, _chain_config}, socket) do
    socket = fetch_connections(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:config_restored, _backup_path, _}, socket) do
    socket = fetch_connections(socket)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col">
      <!-- Hidden events buffer hook -->
      <div id="events-bus" class="hidden" phx-hook="EventsFeed" data-buffer-size="500"></div>
      <!-- Persistent hidden simulator control hook anchor -->
      <div
        id="simulator-control-anchor"
        class="hidden"
        phx-hook="SimulatorControl"
        data-available-chains={Jason.encode!(@available_chains)}
      >
      </div>

      <DashboardHeader.header active_tab={@active_tab} />

    <!-- Content Section -->
      <div class="grid-pattern relative flex-1 overflow-hidden">
        <%= case @active_tab do %>
          <% "overview" -> %>
            <.dashboard_tab_content
              connections={@connections}
              routing_events={@routing_events}
              provider_events={@provider_events}
              client_events={@client_events}
              latest_blocks={@latest_blocks}
              events={@events}
              selected_chain={@selected_chain}
              selected_provider={@selected_provider}
              details_collapsed={@details_collapsed}
              events_collapsed={@events_collapsed}
              available_chains={@available_chains}
              chain_config_open={@chain_config_open}
              chain_config_collapsed={@chain_config_collapsed}
              selected_chain_metrics={@selected_chain_metrics}
              selected_chain_events={@selected_chain_events}
              selected_chain_unified_events={@selected_chain_unified_events}
              selected_chain_endpoints={@selected_chain_endpoints}
              latency_leaders={@latency_leaders}
            />
          <% "benchmarks" -> %>
            <DashboardComponents.benchmarks_tab_content />
          <% "system" -> %>
            <DashboardComponents.metrics_tab_content
              connections={@connections}
              routing_events={@routing_events}
              provider_events={@provider_events}
              last_updated={@last_updated}
              vm_metrics={@vm_metrics}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # Dashboard tab content attrs
  attr :connections, :list
  attr :routing_events, :list
  attr :provider_events, :list
  attr :client_events, :list
  attr :latest_blocks, :list
  attr :events, :list
  attr :selected_chain, :string
  attr :selected_provider, :string
  attr :details_collapsed, :boolean
  attr :events_collapsed, :boolean
  attr :available_chains, :list
  attr :chain_config_open, :boolean
  attr :chain_config_collapsed, :boolean, default: true
  attr :latency_leaders, :map, default: %{}
  attr :selected_chain_metrics, :map, default: %{}
  attr :selected_chain_events, :list, default: []
  attr :selected_chain_unified_events, :list, default: []
  attr :selected_chain_endpoints, :map, default: %{}

  def dashboard_tab_content(assigns) do
    ~H"""
    <div class="relative flex h-full w-full">
      <!-- Main Network Topology Area -->
      <div
        class="flex-1 overflow-hidden"
        phx-hook="DraggableNetworkViewport"
        id="draggable-viewport"
      >
        <div class="h-full w-full" data-draggable-content>
          <div id="provider-request-animator" phx-hook="ProviderRequestAnimator" class="hidden"></div>
          <NetworkTopology.nodes_display
            id="network-topology"
            connections={@connections}
            selected_chain={@selected_chain}
            selected_provider={@selected_provider}
            latency_leaders={@latency_leaders}
            on_chain_select="select_chain"
            on_provider_select="select_provider"
          />
        </div>
      </div>

    <!-- Simulator Controls (top-left) -->
      <.live_component
        module={Components.SimulatorControls}
        id="simulator-controls"
        available_chains={@available_chains}
      />

      <NetworkStatusLegend.legend />

      <.floating_details_window
        selected_chain={@selected_chain}
        selected_provider={@selected_provider}
        details_collapsed={@details_collapsed}
        connections={@connections}
        routing_events={@routing_events}
        provider_events={@provider_events}
        latest_blocks={@latest_blocks}
        events={@events}
        chain_config_open={@chain_config_open}
        chain_config_collapsed={@chain_config_collapsed}
        selected_chain_metrics={@selected_chain_metrics}
        selected_chain_events={@selected_chain_events}
        selected_chain_unified_events={@selected_chain_unified_events}
        selected_chain_endpoints={@selected_chain_endpoints}
      />

    </div>
    """
  end



  attr :chain, :string, required: true
  attr :connections, :list, required: true
  attr :routing_events, :list, required: true
  attr :provider_events, :list, required: true
  attr :events, :list, required: true
  attr :selected_chain_metrics, :map, required: true
  attr :selected_chain_events, :list, required: true
  attr :selected_chain_unified_events, :list, required: true
  attr :selected_chain_endpoints, :map, required: true

  def chain_details_panel(assigns) do
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    assigns = assigns
    |> assign(:chain_connections, chain_connections)
    |> assign(:chain_events, assigns.selected_chain_events)
    |> assign(:chain_provider_events, Enum.filter(assigns.provider_events, &(&1.chain == assigns.chain)))
    |> assign(:chain_unified_events, assigns.selected_chain_unified_events)
    |> assign(:chain_endpoints, assigns.selected_chain_endpoints)
    |> assign(:chain_performance, assigns.selected_chain_metrics)
    |> assign(:last_decision, Helpers.get_last_decision(assigns.selected_chain_events, assigns.chain))


    ~H"""
    <div class="flex h-full flex-col" id={"chain-details-" <> @chain}>
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
            <button phx-click="select_chain" phx-value-chain="" class="rounded border border-gray-600 px-2 py-1 text-xs text-gray-400 transition-colors hover:border-gray-400 hover:text-white">
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
          <.last_decision_card last_decision={@last_decision} connections={@connections} />
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-2">
            <div class="text-[11px] text-gray-400 mb-1">Decision breakdown (5m)</div>
            <div class="space-y-1">
              <%= for {pid, pct} <- @chain_performance.decision_share do %>
                <div class="flex items-center gap-2 text-[11px] text-gray-300">
                  <div class="w-28 truncate text-emerald-300">{pid}</div>
                  <div class="flex-1 bg-gray-900/60 rounded h-2">
                    <div class="bg-emerald-500 h-2 rounded" style={"width: #{Helpers.to_float(pct) |> Float.round(1)}%"}></div>
                  </div>
                  <div class="w-12 text-right text-gray-400">{Helpers.to_float(pct) |> Float.round(1)}%</div>
                </div>
              <% end %>
              <%= if Enum.empty?(@chain_performance.decision_share) do %>
                <div class="text-xs text-gray-500">No decisions in the last 5 minutes</div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <!-- Endpoint Configuration -->
      <div id={"endpoint-config-#{@chain}"} class="border-gray-700/50 border-b p-4" phx-hook="TabSwitcher" data-chain={@chain} data-chain-id={Helpers.get_chain_id(@chain)}>
        <h4 class="mb-3 text-sm font-semibold text-gray-300">RPC Endpoints</h4>

        <div class="mb-4">
          <div class="text-xs text-gray-400 mb-2">Strategy</div>
          <div class="flex flex-wrap gap-2">
            <button data-strategy="fastest" class="px-3 py-1 rounded-full text-xs transition-all border border-sky-500 bg-sky-500/20 text-sky-300">⚡ Fastest</button>
            <button data-strategy="cheapest" class="px-3 py-1 rounded-full text-xs transition-all border border-gray-600 text-gray-300 hover:border-emerald-400 hover:text-emerald-300">💰 Cheapest</button>
            <button data-strategy="priority" class="px-3 py-1 rounded-full text-xs transition-all border border-gray-600 text-gray-300 hover:border-purple-400 hover:text-purple-300">🎯 Priority</button>
            <button data-strategy="round-robin" class="px-3 py-1 rounded-full text-xs transition-all border border-gray-600 text-gray-300 hover:border-orange-400 hover:text-orange-300">🔄 Round Robin</button>
          </div>
        </div>

        <div class="mb-2 text-xs text-gray-400">Direct (connected providers)</div>
        <div class="mb-4 flex flex-wrap gap-2">
          <%= for provider <- @chain_connections do %>
            <%= if provider.status == :connected do %>
              <button
                data-provider={provider.id}
                data-provider-type={provider.type}
                data-provider-supports-ws={provider.type in [:websocket, :both]}
                class="px-3 py-1 rounded-full text-xs transition-all border border-gray-600 text-gray-300 hover:border-indigo-400 hover:text-indigo-300 flex items-center space-x-1"
              >
                <div class="h-1.5 w-1.5 rounded-full bg-emerald-400"></div>
                <span>{provider.name}</span>
              </button>
            <% end %>
          <% end %>
          <%= if Enum.count(@chain_connections, &(&1.status == :connected)) == 0 do %>
            <span class="text-xs text-gray-500">No connected providers</span>
          <% end %>
        </div>

        <!-- Endpoint Display -->
        <div class="bg-gray-800/30 rounded-lg p-3">
          <!-- HTTP Endpoint -->
          <div class="mb-3">
            <div class="flex items-center justify-between mb-1">
              <div class="text-xs font-medium text-gray-300">HTTP</div>
              <button
                data-copy-text={EndpointHelpers.get_strategy_http_url(@chain_endpoints, "fastest")}
                class="bg-gray-700 hover:bg-gray-600 rounded px-2 py-1 text-xs text-white transition-colors"
              >
                Copy
              </button>
            </div>
            <div class="text-xs font-mono text-gray-500 bg-gray-900/50 rounded px-2 py-1 break-all" id="endpoint-url">
              {EndpointHelpers.get_strategy_http_url(@chain_endpoints, "fastest")}
            </div>
          </div>

          <!-- WebSocket Endpoint (only show if chain has providers that support WebSocket) -->
          <%= if Enum.any?(@chain_connections, fn provider ->
                provider.type in [:websocket, :both] or (!is_nil(Map.get(provider, :ws_url)) and String.length(Map.get(provider, :ws_url, "")) > 0)
              end) do %>
            <div class="mb-3">
              <div class="flex items-center justify-between mb-1">
                <div class="text-xs font-medium text-gray-300">WebSocket</div>
                <button
                  data-copy-text={EndpointHelpers.get_strategy_ws_url(@chain_endpoints, "fastest")}
                  class="bg-gray-700 hover:bg-gray-600 rounded px-2 py-1 text-xs text-white transition-colors"
                >
                  Copy
                </button>
              </div>
              <div class="text-xs font-mono text-gray-500 bg-gray-900/50 rounded px-2 py-1 break-all" id="ws-endpoint-url">
                {EndpointHelpers.get_strategy_ws_url(@chain_endpoints, "fastest")}
              </div>
            </div>
          <% else %>
            <div class="mb-3">
              <div class="text-xs font-medium text-gray-400">WebSocket</div>
              <div class="text-xs text-gray-500 bg-gray-900/50 rounded px-2 py-1">
                No WebSocket providers available for this chain
              </div>
            </div>
          <% end %>

          <div class="text-xs text-gray-400" id="mode-description">
            Using fastest provider based on latency benchmarks
          </div>
        </div>
      </div>

      <!-- Chain Events Stream -->
      <div class="flex-1 overflow-hidden p-4">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">📡 Chain Events</h4>
        <div class="flex flex-col h-full">
          <div class="flex-1 overflow-y-auto space-y-1">
            <%= for event <- Enum.take(@chain_unified_events, 50) do %>
              <div class="bg-gray-800/30 rounded-lg p-2">
                <div class="flex items-center justify-between text-xs">
                  <div class="flex items-center space-x-2">
                    <div class={[
                      "w-2 h-2 rounded-full",
                      case event[:kind] do
                        :routing -> "bg-blue-400"
                        :provider -> "bg-emerald-400"
                        :error -> "bg-red-400"
                        :benchmark -> "bg-purple-400"
                        _ -> "bg-gray-400"
                      end
                    ]}></div>
                    <span class="font-mono text-gray-300">{to_string(event[:kind])}</span>
                    <%= if event[:method] do %>
                      <span class="text-sky-400">{event[:method]}</span>
                    <% end %>
                  </div>
                  <span class="text-gray-500">{Helpers.format_timestamp(event[:ts_ms])}</span>
                </div>
                <%= if event[:message] do %>
                  <div class="text-xs text-gray-400 mt-1 font-mono">{event[:message]}</div>
                <% end %>
                <%= if get_in(event, [:meta, :latency]) do %>
                  <div class="text-xs text-yellow-400 mt-1">{get_in(event, [:meta, :latency])}ms</div>
                <% end %>
              </div>
            <% end %>
            <%= if Enum.empty?(@chain_unified_events) do %>
              <div class="text-center text-gray-500 text-xs py-4">No recent events for {String.capitalize(@chain)}</div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def provider_details_panel(assigns) do
    assigns = assigns
      |> assign(:provider_connection, Enum.find(assigns.connections, &(&1.id == assigns.provider)))
      |> assign(:provider_events, Enum.filter(assigns.routing_events, &(&1.provider_id == assigns.provider)))
      |> assign(:provider_unified_events, Enum.filter(Map.get(assigns, :events, []), fn e -> e[:provider_id] == assigns.provider end))
      |> assign(:performance_metrics, MetricsHelpers.get_provider_performance_metrics(assigns.provider, assigns.connections, assigns.routing_events))
      |> assign(:last_decision, Helpers.get_last_decision(assigns.routing_events, nil, assigns.provider))


    ~H"""
    <div class="flex h-full flex-col" data-provider-id={@provider}>
      <!-- Header -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center space-x-3">
            <div class={[
              "h-3 w-3 rounded-full",
              StatusHelpers.provider_status_indicator_class(@provider_connection || %{})
            ]}>
            </div>
            <div>
              <h3 class="text-lg font-semibold text-white">
                {if @provider_connection, do: @provider_connection.name, else: @provider}
              </h3>
              <div class="text-xs text-gray-400">
                {if @provider_connection, do: String.capitalize(@provider_connection.chain || "unknown"), else: "Provider"} • {StatusHelpers.provider_status_label(@provider_connection || %{})}
              </div>
            </div>
          </div>
          <div class="flex items-center space-x-2">
            <%= if assigns[:selected_chain] do %>
              <button
                phx-click="select_provider"
                phx-value-provider=""
                class="rounded border border-gray-600 px-2 py-1 text-sm text-gray-400 transition-colors hover:border-gray-400 hover:text-white"
              >
                Back to Chain
              </button>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Primary metrics -->
      <div class="border-gray-700/50 p-4">
        <div class="mb-2 grid grid-cols-2 md:grid-cols-4 gap-3">
          <div class="text-center bg-gray-800/40 rounded-lg p-3 overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">p50 (5m)</div>
            <div class="h-7 flex items-center justify-center">
              <div class="text-xl font-bold text-sky-400">{if @performance_metrics.p50_latency, do: "#{@performance_metrics.p50_latency}ms", else: "—"}</div>
            </div>
          </div>
          <div class="text-center bg-gray-800/40 rounded-lg p-3 overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">p95 (5m)</div>
            <div class="h-7 flex items-center justify-center">
              <div class="text-xl font-bold text-sky-400">{if @performance_metrics.p95_latency, do: "#{@performance_metrics.p95_latency}ms", else: "—"}</div>
            </div>
          </div>
          <div class="text-center bg-gray-800/40 rounded-lg p-3 overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Success (5m)</div>
            <div class="h-7 flex items-center justify-center">
              <div class={["text-xl font-bold", if((@performance_metrics.success_rate || 0.0) >= 95.0, do: "text-emerald-400", else: if((@performance_metrics.success_rate || 0.0) >= 80.0, do: "text-yellow-400", else: "text-red-400"))]}> {if @performance_metrics.success_rate, do: "#{@performance_metrics.success_rate}%", else: "—"}</div>
            </div>
          </div>
          <div class="text-center bg-gray-800/40 rounded-lg p-3 overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Calls (1h)</div>
            <div class="h-7 flex items-center justify-center">
              <div class="text-xl font-bold text-purple-400">{@performance_metrics.calls_last_hour}</div>
            </div>
          </div>
        </div>
        <%= if @provider_connection do %>
          <div class="space-y-3 pt-3  p-3">
            <!-- Enhanced Status Information -->
            <div class="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
              <div class="flex flex-col">
                <span class="text-gray-400 text-xs">Status</span>
                <span class={StatusHelpers.provider_status_class_text(@provider_connection)}>
                  {StatusHelpers.provider_status_label(@provider_connection)}
                </span>
              </div>

              <div class="flex flex-col">
                <span class="text-gray-400 text-xs">Health</span>
                <span class={StatusHelpers.provider_status_class_text(%{health_status: Map.get(@provider_connection, :health_status, :unknown)})}>
                  {Map.get(@provider_connection, :health_status, :unknown) |> to_string() |> String.upcase()}
                </span>
              </div>

              <div class="flex flex-col">
                <span class="text-gray-400 text-xs">Circuit</span>
                <span class={case Map.get(@provider_connection, :circuit_state, :closed) do
                  :open -> "text-red-400"
                  :half_open -> "text-yellow-400"
                  :closed -> "text-emerald-400"
                end}>
                  {Map.get(@provider_connection, :circuit_state, :closed) |> to_string() |> String.upcase()}
                </span>
              </div>

              <div class="flex flex-col">
                <span class="text-gray-400 text-xs">WebSocket</span>
                <% has_ws_support = Map.get(@provider_connection, :type) in [:websocket, :both] %>
                <span class={
                  cond do
                    not has_ws_support -> "text-gray-400"
                    Map.get(@provider_connection, :ws_connected, false) -> "text-emerald-400"
                    true -> "text-red-400"
                  end
                }>
                  {
                    cond do
                      not has_ws_support -> "NOT SUPPORTED"
                      Map.get(@provider_connection, :ws_connected, false) -> "CONNECTED"
                      true -> "DISCONNECTED"
                    end
                  }
                </span>
              </div>
            </div>

            <!-- Failure Information -->
            <%
              # Only show issues if there are actual current problems
              has_current_issues = (Map.get(@provider_connection, :consecutive_failures, 0) > 0) or
                                   (Map.get(@provider_connection, :reconnect_attempts, 0) > 0) or
                                   (Map.get(@provider_connection, :is_in_cooldown, false) == true) or
                                   (Map.get(@provider_connection, :circuit_state) == :open) or
                                   (Map.get(@provider_connection, :health_status) in [:unhealthy, :rate_limited])
            %>
            <%= if has_current_issues do %>
              <div class="bg-red-900/20 border border-red-600/30 rounded-lg p-3">
                <div class="flex items-center gap-2 mb-2">
                  <div class="w-2 h-2 rounded-full bg-red-400"></div>
                  <span class="text-red-300 text-sm font-medium">Issues Detected</span>
                </div>

                <div class="grid grid-cols-2 gap-3 text-xs">
                  <div>
                    <span class="text-gray-400">Consecutive failures:</span>
                    <span class="text-red-300 ml-2">{Map.get(@provider_connection, :consecutive_failures, 0)}</span>
                  </div>
                  <div>
                    <span class="text-gray-400">Reconnect attempts:</span>
                    <span class="text-yellow-300 ml-2">{@provider_connection.reconnect_attempts}</span>
                  </div>
                </div>

                <%= if @provider_connection && Map.get(@provider_connection, :last_error) do %>
                  <% last_error = Map.get(@provider_connection, :last_error) %>
                  <div class="mt-2 pt-2 border-t border-red-600/20">
                    <span class="text-gray-400 text-xs">Last error:</span>
                    <div class="text-red-300 text-xs mt-1 font-mono bg-gray-900/50 rounded px-2 py-1 break-words">
                      {inspect(last_error, pretty: true, limit: :infinity)}
                    </div>
                    <!-- Debug: Show provider ID to confirm panel is updating -->
                    <div class="text-gray-500 text-[10px] mt-1">
                      Provider: {@provider} | Updated: {DateTime.utc_now() |> DateTime.to_time() |> to_string()}
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>

            <!-- Rate Limiting Information -->
            <%= if Map.get(@provider_connection, :is_in_cooldown, false) do %>
              <div class="bg-purple-900/20 border border-purple-600/30 rounded-lg p-3">
                <div class="flex items-center gap-2 mb-2">
                  <div class="w-2 h-2 rounded-full bg-purple-400"></div>
                  <span class="text-purple-300 text-sm font-medium">Rate Limited</span>
                </div>

                <div class="text-xs">
                  <div class="grid grid-cols-2 gap-3">
                    <div>
                      <span class="text-gray-400">Cooldown count:</span>
                      <span class="text-purple-300 ml-2">{Map.get(@provider_connection, :cooldown_count, 0)}</span>
                    </div>
                    <%= if Map.get(@provider_connection, :cooldown_until) do %>
                      <% time_remaining = max(0, Map.get(@provider_connection, :cooldown_until, 0) - System.monotonic_time(:millisecond)) %>
                      <div>
                        <span class="text-gray-400">Time remaining:</span>
                        <span class="text-purple-300 ml-2">{div(time_remaining, 1000)}s</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>

            <!-- Performance Information -->
            <div class="grid grid-cols-2 gap-3 text-xs">
              <div>
                <span class="text-gray-400">Consecutive successes:</span>
                <span class="text-emerald-300 ml-2">{Map.get(@provider_connection, :consecutive_successes, 0)}</span>
              </div>
              <div>
                <span class="text-gray-400">Pick share (5m):</span>
                <span class="text-white ml-2">{(@performance_metrics.pick_share_5m || 0.0) |> Helpers.to_float() |> Float.round(1)}%</span>
              </div>
              <div>
                <span class="text-gray-400">Subscriptions:</span>
                <span class="text-white ml-2">{@provider_connection.subscriptions}</span>
              </div>
              <%= if Map.get(@provider_connection, :pending_messages, 0) > 0 do %>
                <div>
                  <span class="text-gray-400">Pending messages:</span>
                  <span class="text-yellow-300 ml-2">{Map.get(@provider_connection, :pending_messages, 0)}</span>
                </div>
              <% end %>
            </div>

            <!-- Status Explanation -->
            <div class="bg-gray-800/30 rounded-lg p-2">
              <div class="text-xs text-gray-300">
                <span class="text-gray-400">Status explanation:</span>
                <div class="mt-1">{StatusHelpers.status_explanation(@provider_connection)}</div>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Routing context -->
      <div class="border-gray-700/50 border-t p-4">
        <h4 class="mb-2 text-sm font-semibold text-gray-300">Routing decisions</h4>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
          <.last_decision_card last_decision={@last_decision} connections={@connections} />
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-2">
            <div class="text-[11px] text-gray-400 mb-1">Top methods (5m)</div>
            <div class="space-y-1 max-h-32 overflow-y-auto">
              <%= for stat <- Enum.take(@performance_metrics.rpc_stats, 5) do %>
                <div class="flex items-center justify-between text-[11px] text-gray-300">
                  <div class="text-sky-300 truncate">{stat.method}</div>
                  <div class="flex items-center gap-3">
                    <span class="text-gray-400">p50 {Helpers.to_float(stat.avg_duration_ms) |> Float.round(1)}ms</span>
                    <span class={["", if(stat.success_rate >= 0.95, do: "text-emerald-400", else: if(stat.success_rate >= 0.8, do: "text-yellow-400", else: "text-red-400"))]}> {(Helpers.to_float(stat.success_rate) * 100) |> Float.round(1)}%</span>
                    <span class="text-gray-500">{stat.total_calls} calls</span>
                  </div>
                </div>
              <% end %>
              <%= if length(@performance_metrics.rpc_stats) == 0 do %>
                <div class="text-xs text-gray-500">No recent method stats</div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <!-- Activity -->
      <div class="flex-1 overflow-hidden p-4">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">Activity</h4>
        <div class="h-full overflow-auto">
          <div
            id="provider-unified-activity"
            class="flex max-h-80 flex-col-reverse gap-1 overflow-y-auto"
            phx-hook="TerminalFeed"
          >
            <%= for e <- Enum.take(@provider_unified_events, 60) do %>
              <div class="bg-gray-800/30 rounded-lg p-2">
                <div class="text-[11px] text-gray-400">
                  <span class="text-gray-500">[{e.ts}]</span>
                  <span class="ml-1 text-emerald-300">{@provider}</span>
                  <span class="ml-1">{e.message}</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Floating details window wrapper (pinned top-right)
  attr :selected_chain, :string
  attr :selected_provider, :string
  attr :details_collapsed, :boolean
  attr :connections, :list
  attr :routing_events, :list
  attr :provider_events, :list
  attr :latest_blocks, :list
  attr :events, :list
  attr :chain_config_open, :boolean
  attr :chain_config_collapsed, :boolean
  attr :selected_chain_metrics, :map
  attr :selected_chain_events, :list
  attr :selected_chain_unified_events, :list
  attr :selected_chain_endpoints, :map

  def floating_details_window(assigns) do
    assigns =
      assigns
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
                <% @details_collapsed -> %>
                  System Overview
                <% @selected_provider -> %>
                  {
                    case Enum.find(assigns.connections, &(&1.id == @selected_provider)) do
                      %{name: name} -> name
                      _ -> @selected_provider
                    end
                  }
                <% @selected_chain -> %>
                  {@selected_chain |> String.capitalize()}
                <% true -> %>
                  System Overview
              <% end %>
            </div>
          </div>

          <div class="flex items-center gap-2">

           <%= if @selected_chain || @selected_provider do %>
            <button
              phx-click="toggle_details_panel"
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              {if @details_collapsed, do: "↙", else: "↗"}
            </button>
            <% end %>
          </div>
        </div>

        <%= if @details_collapsed do %>
          <div class="space-y-2 px-3 py-2">
              <!-- Chain/Provider specific collapsed view -->
              <div class="grid grid-cols-4 gap-3 bg-gray-800/40 rounded-md pl-3">
                <div class="py-1.5">
                  <div class="text-[10px] tracking-wide text-gray-400">Providers</div>
                  <div class="text-sm font-semibold text-white">
                    <span class="text-emerald-300">{@total_connections}</span>
                  </div>
                </div>
                <div class=" py-1.5">
                  <div class="text-[10px] uppercase tracking-wide text-gray-400">Chains</div>
                  <div class="text-sm font-semibold text-purple-300">{@total_chains}</div>
                </div>
                <div class=" py-1.5">
                  <div class="text-[10px] text-gray-400">RPC/s</div>
                  <div class="text-xs font-medium text-sky-300">
                    {MetricsHelpers.rpc_calls_per_second(@routing_events)}
                  </div>
                </div>
                <div class=" py-1.5">
                  <div class="text-[10px] text-gray-400">Failovers</div>
                  <div class="text-xs font-medium text-yellow-300">
                    {MetricsHelpers.failovers_last_minute(@routing_events)}
                  </div>
                </div>
              </div>

               <!-- Recent Activity in collapsed state -->
              <div class="px-2 pb-2">
                <div class="text-[10px] text-gray-400 mb-1.5">Recent Activity</div>
                <div class="max-h-20 space-y-1 overflow-y-auto">
                  <%= for e <- Enum.take(@routing_events, 4) do %>
                    <div class="text-[9px] text-gray-300">
                      <span class="text-purple-300">{e.chain}</span>
                      <span class="text-sky-300"> {e.method}</span>
                      → <span class="text-emerald-300">{String.slice(e.provider_id, 0, 8)}…</span>
                      <span class={["ml-1", if(e[:result] == :error, do: "text-red-400", else: "text-yellow-300")]}>
                        ({e[:duration_ms] || 0}ms)
                      </span>
                    </div>
                  <% end %>
                  <%= if length(@routing_events) == 0 do %>
                    <div class="text-[9px] text-gray-500">No recent activity</div>
                  <% end %>
                </div>
              </div>
          </div>
        <% else %>
          <!-- Body (only when expanded) -->
          <div class="max-h-[70vh] overflow-auto">
            <%= if @selected_provider do %>
              <.provider_details_panel
                id={"provider-details-#{@selected_provider}"}
                provider={@selected_provider}
                connections={@connections}
                routing_events={@routing_events}
                provider_events={@provider_events}
                events={@events}
                selected_chain={@selected_chain}
              />
            <% else %>
              <%= if @selected_chain do %>
                <.chain_details_panel
                  chain={@selected_chain}
                  connections={@connections}
                  routing_events={@routing_events}
                  provider_events={@provider_events}
                  events={@events}
                  selected_chain_metrics={@selected_chain_metrics}
                  selected_chain_events={@selected_chain_events}
                  selected_chain_unified_events={@selected_chain_unified_events}
                  selected_chain_endpoints={@selected_chain_endpoints}
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
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => ""}, socket) do
    socket =
      socket
      |> assign(:selected_chain, nil)
      |> assign(:details_collapsed, true)
      |> update_selected_chain_metrics()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => chain}, socket) do
    socket =
      socket
      |> assign(:selected_chain, chain)
      |> assign(:selected_provider, nil)
      |> assign(:details_collapsed, false)
      |> update_selected_chain_metrics()

    # Re-enable auto-centering to animate pan to the selected chain
    socket =
      if chain != "", do: push_event(socket, "center_on_chain", %{chain: chain}), else: socket


    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => ""}, socket) do
    {:noreply, socket |> assign(:selected_provider, nil) |> assign(:details_collapsed, true)}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    socket =
      socket
      |> assign(:selected_provider, provider)
      |> assign(:selected_chain, nil)
      |> assign(:details_collapsed, false)

    # Re-enable auto-centering to animate pan to the selected provider
    socket =
      socket
      |> push_event("center_on_provider", %{provider: provider})


    {:noreply, socket}
  end


  # Collapsible windows toggles
  @impl true
  def handle_event("toggle_details_panel", _params, socket) do
    {:noreply, update(socket, :details_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("toggle_events_panel", _params, socket) do
    {:noreply, update(socket, :events_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("deselect_all", _params, socket) do
    socket =
      socket
      |> assign(:selected_chain, nil)
      |> assign(:selected_provider, nil)
      |> assign(:details_collapsed, true)
      |> push_event("zoom_out", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, fetch_connections(socket)}
  end




  # Simulator Event Forwarding (only forwards when simulator is active)
  @impl true
  def handle_event("sim_stats", %{"http" => _http, "ws" => _ws} = stats, socket) do
    # Forward to SimulatorControls component
    send_update(Components.SimulatorControls, id: "simulator-controls", sim_stats: stats)
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_recent_calls", %{"calls" => calls}, socket) do
    # Forward to SimulatorControls component
    send_update(Components.SimulatorControls, id: "simulator-controls", recent_calls: calls)
    {:noreply, socket}
  end

  @impl true
  def handle_event("active_runs_update", %{"runs" => runs}, socket) do
    # Forward to SimulatorControls component
    send_update(Components.SimulatorControls, id: "simulator-controls", active_runs: runs)
    {:noreply, socket}
  end

  # Shared components

  attr :last_decision, :map, default: nil
  attr :connections, :list, default: []

  def last_decision_card(assigns) do
    # Get provider name from connections if available
    provider_name = case assigns[:connections] do
      connections when is_list(connections) ->
        case assigns[:last_decision] && Enum.find(connections, &(&1.id == assigns.last_decision.provider_id)) do
          %{name: name} -> name
          _ -> assigns[:last_decision] && assigns.last_decision.provider_id
        end
      _ -> assigns[:last_decision] && assigns.last_decision.provider_id
    end

    assigns = assign(assigns, :provider_name, provider_name)

    ~H"""
    <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-1">
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
            <span>strategy: <span class="text-purple-300">{Map.get(@last_decision, :strategy, "—")}</span></span>
          </div>
        </div>
      <% else %>
        <div class="text-xs text-gray-500">No recent decisions</div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp update_selected_chain_metrics(socket) do
    case socket.assigns[:selected_chain] do
      nil ->
        # Clear all chain-specific data when no chain is selected
        socket
        |> assign(:selected_chain_metrics, %{})
        |> assign(:selected_chain_events, [])
        |> assign(:selected_chain_unified_events, [])
        |> assign(:selected_chain_endpoints, %{})
      chain ->
        # Calculate chain-specific metrics
        chain_metrics = MetricsHelpers.get_chain_performance_metrics(socket.assigns, chain)

        # Get chain-specific endpoints
        chain_endpoints = EndpointHelpers.get_chain_endpoints(socket.assigns, chain)

        # Filter events for selected chain
        chain_events = Enum.filter(socket.assigns.routing_events, &(&1.chain == chain))
        chain_unified_events = Enum.filter(socket.assigns.events, fn e -> e[:chain] == chain end)

        # Update all chain-specific assigns at once to ensure consistency
        socket
        |> assign(:selected_chain_metrics, chain_metrics)
        |> assign(:selected_chain_events, chain_events)
        |> assign(:selected_chain_unified_events, chain_unified_events)
        |> assign(:selected_chain_endpoints, chain_endpoints)
    end
  end

  defp fetch_connections(socket) do
    alias Lasso.Config.ConfigStore
    alias Lasso.RPC.ProviderPool

    # Get all configured chains
    chains = ConfigStore.list_chains()

    # Fetch provider status from ProviderPool for each chain
    connections =
      chains
      |> Enum.flat_map(fn chain_name ->
        case ProviderPool.get_status(chain_name) do
          {:ok, pool_status} ->
            # pool_status.providers is a list of provider maps
            pool_status.providers
            |> Enum.map(fn provider_map ->
              # Determine overall circuit state (if either transport is open, show open)
              overall_circuit_state =
                cond do
                  provider_map.http_cb_state == :open or provider_map.ws_cb_state == :open -> :open
                  provider_map.http_cb_state == :half_open or provider_map.ws_cb_state == :half_open -> :half_open
                  true -> :closed
                end

              # Determine provider type based on configuration
              provider_type =
                cond do
                  provider_map.config.url && provider_map.config.ws_url -> :both
                  provider_map.config.ws_url -> :websocket
                  true -> :http
                end

              # Check if WebSocket is connected (if provider supports WS)
              ws_connected =
                case provider_type do
                  :websocket -> provider_map.ws_status == :healthy
                  :both -> provider_map.ws_status == :healthy
                  _ -> false
                end

              # Map HealthPolicy availability to dashboard health_status
              # HealthPolicy uses: :up, :down, :limited, :misconfigured
              # StatusHelpers expects: :healthy, :unhealthy, :rate_limited, :connecting, etc.
              health_status =
                case provider_map.availability do
                  :up -> :healthy
                  :down -> :unhealthy
                  :limited -> :rate_limited
                  :misconfigured -> :misconfigured
                  other -> other  # Fallback for any new states
                end

              # Map to dashboard connection format
              %{
                id: provider_map.id,
                chain: chain_name,
                name: provider_map.name,
                status: provider_map.status,  # For legacy compatibility
                health_status: health_status,
                type: provider_type,
                circuit_state: overall_circuit_state,
                http_circuit_state: provider_map.http_cb_state,
                ws_circuit_state: provider_map.ws_cb_state,
                consecutive_failures: provider_map.consecutive_failures,
                consecutive_successes: provider_map.consecutive_successes,
                last_error: provider_map.last_error,
                is_in_cooldown: provider_map.is_in_cooldown,
                cooldown_until: provider_map.cooldown_until,
                reconnect_attempts: 0,  # Not tracked currently
                ws_connected: ws_connected,
                subscriptions: 0,  # Would need to query UpstreamSubscriptionPool
                url: provider_map.config.url,
                ws_url: provider_map.config.ws_url
              }
            end)

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to get provider status for chain #{chain_name}: #{inspect(reason)}")
            []
        end
      end)

    latency_leaders = MetricsHelpers.get_latency_leaders_by_chain(connections)

    socket
    |> assign(:connections, connections)
    |> assign(:latency_leaders, latency_leaders)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end



 end
