defmodule LivechainWeb.Dashboard do
  use LivechainWeb, :live_view
  require Logger

  alias LivechainWeb.NetworkTopology

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :active_tab, "overview")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "routing:decisions")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "provider_pool:events")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "clients:events")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "circuit:events")

      # Subscribe to compact block events per configured chain
      case Livechain.Config.ChainConfig.load_config() do
        {:ok, cfg} ->
          Enum.each(Map.keys(cfg.chains), fn chain ->
            Phoenix.PubSub.subscribe(Livechain.PubSub, "blocks:new:#{chain}")
          end)

        _ ->
          :ok
      end

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
      |> assign(:hover_chain, nil)
      |> assign(:hover_provider, nil)
      |> assign(:routing_events, [])
      |> assign(:provider_events, [])
      |> assign(:client_events, [])
      |> assign(:latest_blocks, [])
      |> assign(:events, [])
      |> assign(:vm_metrics, %{})
      |> assign(:available_chains, get_available_chains())
      |> assign(:details_collapsed, true)
      |> assign(:events_collapsed, true)
      |> assign(:sim_stats, %{
        http: %{success: 0, error: 0, avgLatencyMs: 0.0, inflight: 0},
        ws: %{open: 0}
      })
      |> assign(:sim_collapsed, true)
      |> assign(:selected_chains, [])
      |> assign(:selected_strategy, "fastest")
      |> assign(:request_rate, 5)
      |> assign(:recent_calls, [])
      |> assign(:latency_leaders, %{})
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
                    as_event(:provider,
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
                    as_event(:provider,
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
          strategy: _strategy,
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
      provider_id: pid,
      duration_ms: dur,
      result: Map.get(evt, :result, :unknown),
      failovers: Map.get(evt, :failover_count, 0)
    }

    socket = update(socket, :routing_events, fn list -> [entry | Enum.take(list, 99)] end)

    # Unified events + client-side push
    ev =
      as_event(:rpc,
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

    {:noreply, socket}
  end

  # Provider pool event feed (real or synthetic)
  @impl true
  def handle_info(%{ts: _t, chain: chain, provider_id: pid, event: event} = ev, socket)
      when is_map(ev) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: chain,
      provider_id: pid,
      event: event,
      details: Map.get(ev, :details)
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, 99)] end)

    uev =
      as_event(:provider,
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
      as_event(:client,
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

  # Circuit breaker events
  @impl true
  def handle_info(%{ts: _t, provider_id: pid, from: from, to: to, reason: reason} = _evt, socket) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: "n/a",
      provider_id: pid,
      event: "circuit: #{from} -> #{to} (#{reason})"
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, 99)] end)

    uev =
      as_event(:circuit,
        provider_id: pid,
        severity: :warn,
        message: entry.event,
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket =
      socket
      |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
      |> push_event("events_batch", %{items: [uev]})

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
      as_event(:block,
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

    {:noreply, socket}
  end

  # VM metrics ticker
  @impl true
  def handle_info(:vm_metrics_tick, socket) do
    metrics = collect_vm_metrics()
    Process.send_after(self(), :vm_metrics_tick, 2_000)
    {:noreply, assign(socket, :vm_metrics, metrics)}
  end

  # Latency leaders refresh
  @impl true
  def handle_info(:latency_leaders_refresh, socket) do
    connections = Map.get(socket.assigns, :connections, [])
    latency_leaders = get_latency_leaders_by_chain(connections)
    Process.send_after(self(), :latency_leaders_refresh, 30_000)
    {:noreply, assign(socket, :latency_leaders, latency_leaders)}
  end

  @impl true
  def handle_info(:flush_connections, socket) do
    Process.delete(:pending_connection_update)
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

      <!-- Header -->
      <div class="border-gray-700/50 relative flex-shrink-0 border-b">
        <div class="relative flex items-center justify-between p-6">
          <!-- Title Section -->
          <div class="flex items-center space-x-4">
            <div class="relative">
              <div class="absolute inset-0 rounded-2xl bg-gradient-to-r from-purple-600 to-purple-400 opacity-10 blur-xl">
              </div>
              <div class="relative rounded-2xl ">
                <div class="flex items-center space-x-3">
                  <div class="relative">
                    <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-purple-400 to-purple-600 shadow-lg">
                      <svg
                        class="h-5 w-5 text-white"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M13 10V3L4 14h7v7l9-11h-7z"
                        />
                      </svg>
                    </div>
                    <div class="absolute inset-0 animate-ping rounded-lg bg-gradient-to-br from-purple-400 to-purple-600 opacity-20">
                    </div>
                  </div>
                  <div>
                    <div class="text-lg font-bold text-white">Lasso RPC</div>
                    <div class="text-xs text-gray-400">
                      <span class="text-emerald-400">LIVE</span> • Orchestration Dashboard
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

    <!-- Navigation Tabs -->
          <.tab_switcher
            id="main-tabs"
            tabs={[
              %{id: "overview", label: "Dashboard", icon: "M13 10V3L4 14h7v7l9-11h-7z"},
              %{id: "benchmarks", label: "Benchmarks", icon: "M3 3h18M9 7l6-3M9 17l6-3"},
              %{id: "system", label: "System", icon: "M15 4m0 13V4m-6 3l6-3"}
            ]}
            active_tab={@active_tab}
          />
        </div>
      </div>

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
              hover_chain={@hover_chain}
              hover_provider={@hover_provider}
              details_collapsed={@details_collapsed}
              events_collapsed={@events_collapsed}
              sim_stats={@sim_stats}
              available_chains={@available_chains}
              sim_collapsed={@sim_collapsed}
              selected_chains={@selected_chains}
              selected_strategy={@selected_strategy}
              request_rate={@request_rate}
              recent_calls={@recent_calls}
            />
          <% "benchmarks" -> %>
            <.benchmarks_tab_content />
          <% "system" -> %>
            <.metrics_tab_content
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

  def dashboard_tab_content(assigns) do
    assigns =
      assigns
      |> assign_new(:latency_leaders, fn -> %{} end)

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
      <.floating_simulator_controls
        sim_stats={@sim_stats}
        available_chains={@available_chains}
        sim_collapsed={@sim_collapsed}
        selected_chains={@selected_chains}
        selected_strategy={@selected_strategy}
        request_rate={@request_rate}
        recent_calls={@recent_calls}
      />

    <!-- Network Status Legend (positioned relative to full dashboard) -->
      <div class="bg-gray-900/95 absolute right-4 bottom-4 z-30 min-w-max rounded-lg border border-gray-600 p-4 shadow-xl backdrop-blur-sm">
        <h4 class="mb-3 text-xs font-semibold text-white">Network Status</h4>
        <div class="space-y-2.5">
          <!-- Provider Status -->
          <div class="flex items-center space-x-2 text-xs text-gray-300">
            <div class="h-3 w-3 flex-shrink-0 rounded-full bg-emerald-400"></div>
            <span>Connected</span>
          </div>
          <div class="flex items-center space-x-2 text-xs text-gray-300">
            <div class="h-3 w-3 flex-shrink-0 rounded-full bg-yellow-400"></div>
            <span>Connecting/Reconnecting</span>
          </div>
          <div class="flex items-center space-x-2 text-xs text-gray-300">
            <div class="h-3 w-3 flex-shrink-0 rounded-full bg-red-400"></div>
            <span>Disconnected</span>
          </div>
          <!-- Racing Flag Indicator -->
          <div class="flex items-center space-x-2 text-xs text-gray-300">
            <div class="relative flex flex-shrink-0 items-center">
              <div class="h-3 w-3 rounded-full bg-purple-600"></div>
              <svg
                class="absolute h-2.5 w-2.5 text-yellow-300"
                fill="currentColor"
                viewBox="0 0 24 24"
                style="top: 0.25px; left: 0.25px;"
              >
                <path d="M3 3v18l7-3 7 3V3H3z" />
              </svg>
            </div>
            <span>Fastest average latency</span>
          </div>
          <!-- Reconnect Attempts Badge -->
          <div class="mt-3 flex items-center space-x-2 border-t border-gray-700 pt-2.5 text-xs text-gray-300">
            <div class="relative flex flex-shrink-0 items-center">
              <div class="h-3 w-3 rounded-full bg-gray-600"></div>
              <div class="absolute -top-1 -right-1 flex h-4 w-4 items-center justify-center rounded-full bg-yellow-500">
                <span class="text-[10px] font-bold leading-none text-white">3</span>
              </div>
            </div>
            <span>Reconnect attempts</span>
          </div>
        </div>
      </div>

    <!-- Floating Details Window (top-right) -->
      <.floating_details_window
        selected_chain={@selected_chain}
        selected_provider={@selected_provider}
        hover_chain={@hover_chain}
        hover_provider={@hover_provider}
        details_collapsed={@details_collapsed}
        connections={@connections}
        routing_events={@routing_events}
        provider_events={@provider_events}
        latest_blocks={@latest_blocks}
        events={@events}
      />

    </div>
    """
  end

  def chain_details_panel(assigns) do
    assigns =
      assigns
      |> assign(
        :chain_connections,
        Enum.filter(assigns.connections, &(&1.chain == assigns.chain))
      )
      |> assign(:chain_events, Enum.filter(assigns.routing_events, &(&1.chain == assigns.chain)))
      |> assign(
        :chain_provider_events,
        Enum.filter(assigns.provider_events, &(&1.chain == assigns.chain))
      )
      |> assign(
        :chain_unified_events,
        Enum.filter(Map.get(assigns, :events, []), fn e -> e[:chain] == assigns.chain end)
      )
      |> assign_chain_endpoints(assigns.chain)
      |> assign_chain_performance_metrics(assigns.chain)
      |> assign(:sample_curl, get_sample_curl_command())
      |> assign(:selected_strategy_tab, "fastest")
      |> assign(:selected_provider_tab, List.first(Enum.filter(assigns.connections, &(&1.chain == assigns.chain))))
      |> assign(:active_endpoint_tab, "strategy")
      |> assign(:last_decision, get_last_decision(assigns.routing_events, assigns.chain))

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
                <span>{get_chain_id(@chain)}</span>
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
                  <span>failovers: {Map.get(@last_decision, :failovers, 0)}</span>
                </div>
              </div>
            <% else %>
              <div class="text-xs text-gray-500">No recent decisions</div>
            <% end %>
          </div>
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-2">
            <div class="text-[11px] text-gray-400 mb-1">Decision breakdown (5m)</div>
            <div class="space-y-1">
              <%= for {pid, pct} <- @chain_performance.decision_share do %>
                <div class="flex items-center gap-2 text-[11px] text-gray-300">
                  <div class="w-28 truncate text-emerald-300">{pid}</div>
                  <div class="flex-1 bg-gray-900/60 rounded h-2">
                    <div class="bg-emerald-500 h-2 rounded" style={"width: #{to_float(pct) |> Float.round(1)}%"}></div>
                  </div>
                  <div class="w-12 text-right text-gray-400">{to_float(pct) |> Float.round(1)}%</div>
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
      <div id="endpoint-config" class="border-gray-700/50 border-b p-4" phx-hook="TabSwitcher">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">RPC Endpoints</h4>

        <div class="mb-4">
          <div class="text-xs text-gray-400 mb-2">Strategy</div>
          <div class="flex flex-wrap gap-2">
            <button data-strategy="fastest" class="px-3 py-1 rounded-full text-xs transition-all border border-sky-500 bg-sky-500/20 text-sky-300">⚡ Fastest</button>
            <button data-strategy="leaderboard" class="px-3 py-1 rounded-full text-xs transition-all border border-gray-600 text-gray-300 hover:border-emerald-400 hover:text-emerald-300">🏆 Leaderboard</button>
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
                data-copy-text={get_strategy_http_url(@chain_endpoints, "fastest")}
                class="bg-gray-700 hover:bg-gray-600 rounded px-2 py-1 text-xs text-white transition-colors"
              >
                Copy
              </button>
            </div>
            <div class="text-xs font-mono text-gray-500 bg-gray-900/50 rounded px-2 py-1 break-all" id="endpoint-url">
              {get_strategy_http_url(@chain_endpoints, "fastest")}
            </div>
          </div>

          <!-- WebSocket Endpoint -->
          <div class="mb-3">
            <div class="flex items-center justify-between mb-1">
              <div class="text-xs font-medium text-gray-300">WebSocket</div>
              <button
                data-copy-text={get_strategy_ws_url(@chain_endpoints, "fastest")}
                class="bg-gray-700 hover:bg-gray-600 rounded px-2 py-1 text-xs text-white transition-colors"
              >
                Copy
              </button>
            </div>
            <div class="text-xs font-mono text-gray-500 bg-gray-900/50 rounded px-2 py-1 break-all" id="ws-endpoint-url">
              {get_strategy_ws_url(@chain_endpoints, "fastest")}
            </div>
          </div>

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
                    <span class="font-mono text-gray-300">{to_string(event[:kind]) || "event"}</span>
                    <%= if event[:method] do %>
                      <span class="text-sky-400">{event[:method]}</span>
                    <% end %>
                  </div>
                  <span class="text-gray-500">{format_timestamp(event[:ts_ms])}</span>
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
    assigns =
      assigns
      |> assign(
        :provider_connection,
        Enum.find(assigns.connections, &(&1.id == assigns.provider))
      )
      |> assign(
        :provider_events,
        Enum.filter(assigns.routing_events, &(&1.provider_id == assigns.provider))
      )
      |> assign(
        :provider_pool_events,
        Enum.filter(assigns.provider_events, &(&1.provider_id == assigns.provider))
      )
      |> assign(
        :provider_unified_events,
        Enum.filter(Map.get(assigns, :events, []), fn e -> e[:provider_id] == assigns.provider end)
      )
      |> assign_provider_performance_metrics(assigns.provider)
      |> assign(:last_decision, get_last_decision(assigns.routing_events, nil, assigns.provider))

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
                {if @provider_connection, do: String.capitalize(@provider_connection.chain || "unknown"), else: "Provider"} • {provider_status_label(@provider_connection)}
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
          <div class="flex flex-wrap items-center justify-between gap-3 text-sm pt-2 border-t border-gray-700/30">
            <div class="flex items-center space-x-3">
              <span class="text-gray-400">Status:</span>
              <span class={provider_status_class_text(@provider_connection)}>
                {provider_status_label(@provider_connection)}
              </span>
            </div>

            <div class="flex items-center space-x-3">
              <span class="text-gray-400">Pick share (5m):</span>
              <span class="text-white">{(@performance_metrics.pick_share_5m || 0.0) |> to_float() |> Float.round(1)}%</span>
            </div>

            <div class="flex items-center space-x-3">
              <span class="text-gray-400">Subs:</span>
              <span class="text-white">{@provider_connection.subscriptions}</span>
            </div>

            <%= if @provider_connection.reconnect_attempts > 0 do %>
              <div class="flex items-center space-x-3">
                <span class="text-gray-400">Issues:</span>
                <span class={["font-medium", if(@provider_connection.reconnect_attempts >= 10, do: "text-red-400", else: if(@provider_connection.reconnect_attempts >= 5, do: "text-yellow-400", else: "text-gray-300"))]}>
                  <%= if @provider_connection.reconnect_attempts >= 5 do %>
                    High
                  <% else %>
                    {@provider_connection.reconnect_attempts}
                  <% end %>
                </span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Routing context -->
      <div class="border-gray-700/50 border-t p-4">
        <h4 class="mb-2 text-sm font-semibold text-gray-300">Routing decisions</h4>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
          <div class="bg-gray-800/40 rounded-lg p-3">
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
                  <span>failovers: {Map.get(@last_decision, :failovers, 0)}</span>
                </div>
              </div>
            <% else %>
              <div class="text-xs text-gray-500">No recent decisions</div>
            <% end %>
          </div>
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-2">
            <div class="text-[11px] text-gray-400 mb-1">Top methods (5m)</div>
            <div class="space-y-1 max-h-32 overflow-y-auto">
              <%= for stat <- Enum.take(@performance_metrics.rpc_stats, 5) do %>
                <div class="flex items-center justify-between text-[11px] text-gray-300">
                  <div class="text-sky-300 truncate">{stat.method}</div>
                  <div class="flex items-center gap-3">
                    <span class="text-gray-400">p50 {to_float(stat.avg_duration_ms) |> Float.round(1)}ms</span>
                    <span class={["", if(stat.success_rate >= 0.95, do: "text-emerald-400", else: if(stat.success_rate >= 0.8, do: "text-yellow-400", else: "text-red-400"))]}> {(to_float(stat.success_rate) * 100) |> Float.round(1)}%</span>
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
  def floating_details_window(assigns) do
    assigns =
      assigns
      |> assign_new(:details_collapsed, fn -> true end)
      |> assign_new(:hover_chain, fn -> nil end)
      |> assign_new(:hover_provider, fn -> nil end)
      |> assign_new(:events, fn -> [] end)
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
            <button
              phx-click="toggle_details_panel"
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
                  {rpc_calls_per_second(@routing_events)}
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">Errors</div>
                <div class="text-xs font-medium text-red-300">
                  {error_rate_percent(@routing_events)}%
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">Failovers</div>
                <div class="text-xs font-medium text-yellow-300">
                  {failovers_last_minute(@routing_events)}
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
              />
            <% else %>
              <%= if @selected_chain do %>
                <.chain_details_panel
                  chain={@selected_chain}
                  connections={@connections}
                  routing_events={@routing_events}
                  provider_events={@provider_events}
                  events={@events}
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

  def benchmarks_tab_content(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col gap-4 p-4">
      <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-6">
        <div class="text-sm font-semibold text-gray-300">Benchmarks</div>
        <div class="mt-2 text-xs text-gray-400">
          Coming soon: provider leaderboard, method x provider latency heatmap, and strategy comparisons.
        </div>
      </div>
    </div>
    """
  end

  def metrics_tab_content(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col gap-4 p-4">
      <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
        <div class="mb-2 text-sm font-semibold text-gray-300">System metrics</div>
        <div class="grid grid-cols-1 gap-2 text-sm text-gray-300 md:grid-cols-3">
          <div class="bg-gray-800/60 rounded p-3">
            Connections: <span class="text-emerald-300">{length(@connections)}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Routing events buffered: <span class="text-sky-300">{length(@routing_events)}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Provider events buffered: <span class="text-yellow-300">{length(@provider_events)}</span>
          </div>
        </div>
        <div class="mt-4 grid grid-cols-1 gap-2 text-sm text-gray-300 md:grid-cols-3">
          <div class="bg-gray-800/60 rounded p-3">
            CPU:
            <span class="text-emerald-300">
              {(@vm_metrics[:cpu_percent] || 0.0) |> :erlang.float_to_binary([{:decimals, 1}])}%
            </span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Run queue: <span class="text-emerald-300">{@vm_metrics[:run_queue] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Reductions/s: <span class="text-emerald-300">{@vm_metrics[:reductions_s] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Proc count: <span class="text-emerald-300">{@vm_metrics[:process_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Port count: <span class="text-emerald-300">{@vm_metrics[:port_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Atom count: <span class="text-emerald-300">{@vm_metrics[:atom_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            ETS tables: <span class="text-emerald-300">{@vm_metrics[:ets_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem total: <span class="text-emerald-300">{@vm_metrics[:mem_total_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem processes:
            <span class="text-emerald-300">{@vm_metrics[:mem_processes_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem binary: <span class="text-emerald-300">{@vm_metrics[:mem_binary_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem code: <span class="text-emerald-300">{@vm_metrics[:mem_code_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem ETS: <span class="text-emerald-300">{@vm_metrics[:mem_ets_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            IO in: <span class="text-emerald-300">{@vm_metrics[:io_in_bytes] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            IO out: <span class="text-emerald-300">{@vm_metrics[:io_out_bytes] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Sched util avg:
            <span class="text-emerald-300">
              {(@vm_metrics[:sched_util_avg] &&
                  :erlang.float_to_binary(@vm_metrics[:sched_util_avg], [{:decimals, 1}])) || "n/a"}%
            </span>
          </div>
        </div>
        <div class="mt-2 text-xs text-gray-500">Last updated: {@last_updated}</div>
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
    {:noreply, socket |> assign(:selected_chain, nil) |> assign(:details_collapsed, true)}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => chain}, socket) do
    socket =
      socket
      |> assign(:selected_chain, chain)
      |> assign(:selected_provider, nil)
      |> assign(:details_collapsed, false)

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

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, fetch_connections(socket)}
  end

  @impl true
  def handle_event("sim_http_start", _params, socket) do
    # Push event to JS hook with defaults; future: make dynamic via form controls
    opts = %{
      chains: Enum.map(socket.assigns.available_chains, & &1.name),
      methods: ["eth_blockNumber", "eth_getBalance"],
      rps: 5,
      concurrency: 4,
      durationMs: 30_000
    }

    socket = push_event(socket, "sim_start_http", opts)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_http_stop", _params, socket) do
    socket = push_event(socket, "sim_stop_http", %{})
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_ws_start", _params, socket) do
    opts = %{
      chains: Enum.map(socket.assigns.available_chains, & &1.name),
      connections: 2,
      topics: ["newHeads"],
      durationMs: 30_000
    }

    socket = push_event(socket, "sim_start_ws", opts)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_ws_stop", _params, socket) do
    socket = push_event(socket, "sim_stop_ws", %{})
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_stats", %{"http" => http, "ws" => ws}, socket) do
    {:noreply, assign(socket, :sim_stats, %{http: http, ws: ws})}
  end

  # New enhanced simulator controls
  @impl true
  def handle_event("toggle_sim_panel", _params, socket) do
    {:noreply, update(socket, :sim_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("toggle_chain_selection", %{"chain" => chain}, socket) do
    selected = socket.assigns.selected_chains
    new_selected = if chain in selected do
      Enum.reject(selected, &(&1 == chain))
    else
      [chain | selected]
    end
    {:noreply, assign(socket, :selected_chains, new_selected)}
  end

  @impl true
  def handle_event("select_all_chains", _params, socket) do
    all_chains = Enum.map(socket.assigns.available_chains, & &1.name)
    {:noreply, assign(socket, :selected_chains, all_chains)}
  end

  @impl true
  def handle_event("select_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, assign(socket, :selected_strategy, strategy)}
  end

  @impl true
  def handle_event("update_rate", %{"rate" => rate}, socket) do
    rate_int = String.to_integer(rate)
    {:noreply, assign(socket, :request_rate, rate_int)}
  end

  @impl true
  def handle_event("increase_rate", _params, socket) do
    current_rate = socket.assigns.request_rate
    new_rate = min(current_rate + 1, 50)
    {:noreply, assign(socket, :request_rate, new_rate)}
  end

  @impl true
  def handle_event("decrease_rate", _params, socket) do
    current_rate = socket.assigns.request_rate
    new_rate = max(current_rate - 1, 1)
    {:noreply, assign(socket, :request_rate, new_rate)}
  end

  @impl true
  def handle_event("sim_http_start_advanced", _params, socket) do
    selected_chains = socket.assigns.selected_chains
    chains = if length(selected_chains) > 0 do
      selected_chains
    else
      Enum.map(socket.assigns.available_chains, & &1.name)
    end

    opts = %{
      chains: chains,
      methods: ["eth_blockNumber", "eth_getBalance", "eth_getTransactionCount"],
      rps: socket.assigns.request_rate,
      concurrency: 4,
      strategy: socket.assigns.selected_strategy,
      durationMs: 60_000
    }

    socket = push_event(socket, "sim_start_http_advanced", opts)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_ws_start_advanced", _params, socket) do
    selected_chains = socket.assigns.selected_chains
    chains = if length(selected_chains) > 0 do
      selected_chains
    else
      Enum.map(socket.assigns.available_chains, & &1.name)
    end

    opts = %{
      chains: chains,
      connections: 3,
      topics: ["newHeads", "logs"],
      durationMs: 60_000
    }

    socket = push_event(socket, "sim_start_ws_advanced", opts)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_stop_all", _params, socket) do
    socket = socket
    |> push_event("sim_stop_http", %{})
    |> push_event("sim_stop_ws", %{})
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_sim_logs", _params, socket) do
    socket = assign(socket, :recent_calls, [])
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_recent_calls", %{"calls" => calls}, socket) do
    {:noreply, assign(socket, :recent_calls, calls)}
  end

  @impl true
  def handle_event("sim_start_load_test", _params, socket) do
    # Start both HTTP and WebSocket load tests with sensible defaults
    selected_chains = socket.assigns.selected_chains
    chains = if length(selected_chains) > 0 do
      selected_chains
    else
      Enum.map(socket.assigns.available_chains, & &1.name)
    end

    # Start HTTP load test
    http_opts = %{
      chains: chains,
      methods: ["eth_blockNumber", "eth_getBalance"],
      rps: socket.assigns.request_rate,
      concurrency: 4,
      strategy: socket.assigns.selected_strategy,
      durationMs: 60_000
    }

    # Start WebSocket connections
    ws_opts = %{
      chains: chains,
      connections: 2,
      topics: ["newHeads"],
      durationMs: 60_000
    }

    socket = socket
    |> push_event("sim_start_http_advanced", http_opts)
    |> push_event("sim_start_ws_advanced", ws_opts)

    {:noreply, socket}
  end


  # Helper functions

  defp assign_chain_endpoints(assigns, chain_name) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = get_chain_id(chain_name)

    # Get available providers for this chain
    providers = Enum.filter(assigns.connections, &(&1.chain == chain_name))

    endpoints = %{
      # Strategy endpoints
      http_strategies: [
        %{name: "Fastest (Latency-Optimized)", url: "#{base_url}/rpc/fastest/#{chain_id}", description: "Routes to fastest provider based on real-time latency"},
        %{name: "Leaderboard (Performance-Based)", url: "#{base_url}/rpc/leaderboard/#{chain_id}", description: "Routes using racing-based performance scores"},
        %{name: "Priority (Configured Order)", url: "#{base_url}/rpc/priority/#{chain_id}", description: "Routes by configured provider priority"},
        %{name: "Round Robin", url: "#{base_url}/rpc/round-robin/#{chain_id}", description: "Distributes load evenly across providers"},
        %{name: "Debug Mode", url: "#{base_url}/rpc/debug/#{chain_id}", description: "Enhanced logging and debugging info"}
      ],

      # WebSocket endpoints
      ws_strategies: [
        %{name: "Default Strategy", url: "#{String.replace(base_url, ~r/^http/, "ws")}/ws/rpc/#{chain_id}", description: "WebSocket with intelligent provider selection"},
        %{name: "Direct Connection", url: "#{String.replace(base_url, ~r/^http/, "ws")}/ws/rpc/#{chain_id}?strategy=direct", description: "Direct WebSocket without failover"}
      ],

      # Provider-specific endpoints
      provider_overrides: Enum.map(providers, fn provider ->
        %{
          name: provider.name,
          provider_id: provider.id,
          url: "#{base_url}/rpc/provider/#{provider.id}/#{chain_id}",
          status: provider.status,
          description: "Direct route to #{provider.name}"
        }
      end),

      # Development endpoints
      dev_endpoints: [
        %{name: "No Failover", url: "#{base_url}/rpc/no-failover/#{chain_id}", description: "Disable failover for testing"},
        %{name: "Aggressive Failover", url: "#{base_url}/rpc/aggressive/#{chain_id}", description: "Faster failover for development"},
        %{name: "Benchmark Mode", url: "#{base_url}/rpc/benchmark/#{chain_id}", description: "Force active benchmarking"}
      ]
    }

    assign(assigns, :chain_endpoints, endpoints)
  end

  defp assign_chain_performance_metrics(assigns, chain_name) do
    alias Livechain.Benchmarking.BenchmarkStore

    # Get chain-wide statistics
    chain_stats = BenchmarkStore.get_chain_wide_stats(chain_name)
    realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)

    # Calculate aggregate performance metrics over 5 minutes
    now_ms = System.system_time(:millisecond)
    window_ms = 300_000

    recent_events = Enum.filter(assigns.routing_events, fn e ->
      e[:chain] == chain_name and (e[:ts_ms] || 0) >= now_ms - window_ms
    end)

    latencies =
      recent_events
      |> Enum.map(&(&1[:duration_ms] || 0))
      |> Enum.filter(&(&1 > 0))

    {p50, p95} = percentile_pair(latencies)

    success_rate = if length(recent_events) > 0 do
      successes = Enum.count(recent_events, fn e -> e[:result] == :success end)
      Float.round(successes * 100.0 / length(recent_events), 1)
    else
      nil
    end

    failovers_5m = Enum.count(recent_events, fn e -> (e[:failovers] || 0) > 0 end)

    decision_share =
      recent_events
      |> Enum.group_by(& &1.provider_id)
      |> Enum.map(fn {pid, evs} -> {pid, 100.0 * length(evs) / max(length(recent_events), 1)} end)
      |> Enum.sort_by(fn {_pid, pct} -> -pct end)

    connected_providers = Enum.count(assigns.connections, &(&1.chain == chain_name && &1.status == :connected))
    total_providers = Enum.count(assigns.connections, &(&1.chain == chain_name))

    assign(assigns, :chain_performance, %{
      total_calls: Map.get(chain_stats, :total_calls, 0),
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      failovers_5m: failovers_5m,
      connected_providers: connected_providers,
      total_providers: total_providers,
      recent_activity: length(recent_events),
      providers_list: Map.get(realtime_stats, :providers, []),
      rpc_methods: Map.get(realtime_stats, :rpc_methods, []),
      last_updated: Map.get(realtime_stats, :last_updated, 0),
      decision_share: decision_share
    })
  end

  defp get_sample_curl_command do
    ~s({"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1})
  end

  defp get_strategy_description(strategy) do
    case strategy do
      "fastest" -> "Routes to the provider with lowest average latency based on real-time benchmarks"
      "leaderboard" -> "Uses racing-based performance scores to select the best provider"
      "priority" -> "Routes by configured provider priority order"
      "round-robin" -> "Distributes load evenly across all available providers"
      _ -> "Smart routing based on performance metrics"
    end
  end

  defp get_strategy_http_url(endpoints, strategy) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = get_current_chain_id(endpoints)
    "#{base_url}/rpc/#{String.replace(strategy, "_", "-")}/#{chain_id}"
  end

  defp get_strategy_ws_url(endpoints, _strategy) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = get_current_chain_id(endpoints)
    ws_url = String.replace(base_url, ~r/^http/, "ws")
    "#{ws_url}/ws/rpc/#{chain_id}"
  end

  defp get_provider_http_url(endpoints, provider) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = get_current_chain_id(endpoints)
    "#{base_url}/rpc/#{chain_id}/#{provider.id}"
  end

  defp get_provider_ws_url(endpoints, provider) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = get_current_chain_id(endpoints)
    ws_url = String.replace(base_url, ~r/^http/, "ws")
    "#{ws_url}/ws/rpc/#{chain_id}?provider=#{provider.id}"
  end

  defp get_provider_name(provider) do
    provider.name || provider.id
  end

  defp provider_supports_websocket(_provider) do
    # For now, assume all providers support WebSocket
    # In the future, this could check provider capabilities
    true
  end

  defp get_current_chain_id(endpoints) do
    # Extract chain_id from the first endpoint URL
    case List.first(endpoints.http_strategies) do
      %{url: url} ->
        url
        |> String.split("/")
        |> List.last()
      _ -> "1"
    end
  end

  defp get_chain_id(chain_name) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        case Map.get(config.chains, String.to_atom(chain_name)) do
          %{chain_id: chain_id} -> to_string(chain_id)
          _ -> chain_name
        end
      _ -> chain_name
    end
  end

  defp assign_provider_performance_metrics(assigns, provider_id) do
    alias Livechain.Benchmarking.BenchmarkStore

    # Get the chain for this provider
    chain = case Enum.find(assigns.connections, &(&1.id == provider_id)) do
      %{chain: chain_name} -> chain_name
      _ -> nil
    end

    if chain do
      provider_score = BenchmarkStore.get_provider_score(chain, provider_id)
      real_time_stats = BenchmarkStore.get_real_time_stats(chain, provider_id)
      anomalies = BenchmarkStore.detect_performance_anomalies(chain, provider_id)

      now_ms = System.system_time(:millisecond)
      five_min_ms = 300_000
      hour_ms = 3_600_000

      events_5m = Enum.filter(assigns.routing_events, fn e ->
        e[:provider_id] == provider_id and (e[:ts_ms] || 0) >= now_ms - five_min_ms
      end)

      latencies_5m =
        events_5m
        |> Enum.map(&(&1[:duration_ms] || 0))
        |> Enum.filter(&(&1 > 0))

      {p50, p95} = percentile_pair(latencies_5m)

      success_rate = if length(events_5m) > 0 do
        successes = Enum.count(events_5m, fn e -> e[:result] == :success end)
        Float.round(successes * 100.0 / length(events_5m), 1)
      else
        nil
      end

      calls_last_minute = Map.get(real_time_stats, :calls_last_minute, 0)

      calls_last_hour =
        assigns.routing_events
        |> Enum.count(fn e -> e[:provider_id] == provider_id and (e[:ts_ms] || 0) >= now_ms - hour_ms end)

      # Provider pick share among chain decisions in 5m
      chain_events_5m = Enum.filter(assigns.routing_events, fn e ->
        e[:chain] == chain and (e[:ts_ms] || 0) >= now_ms - five_min_ms
      end)

      pick_share_5m = if length(chain_events_5m) > 0 do
        100.0 * Enum.count(chain_events_5m, fn e -> e[:provider_id] == provider_id end) / length(chain_events_5m)
      else
        0.0
      end

      assign(assigns, :performance_metrics, %{
        provider_score: Float.round(provider_score || 0.0, 2),
        p50_latency: p50,
        p95_latency: p95,
        success_rate: success_rate,
        calls_last_minute: calls_last_minute,
        calls_last_5m: length(events_5m),
        calls_last_hour: calls_last_hour,
        racing_stats: Map.get(real_time_stats, :racing_stats, []),
        rpc_stats: Map.get(real_time_stats, :rpc_stats, []),
        anomalies: anomalies || [],
        recent_activity_count: length(events_5m),
        pick_share_5m: pick_share_5m
      })
    else
      assign(assigns, :performance_metrics, %{
        provider_score: 0.0,
        p50_latency: nil,
        p95_latency: nil,
        success_rate: nil,
        calls_last_minute: 0,
        calls_last_5m: 0,
        calls_last_hour: 0,
        racing_stats: [],
        rpc_stats: [],
        anomalies: [],
        recent_activity_count: 0,
        pick_share_5m: 0.0
      })
    end
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value
  defp to_float(_), do: 0.0

  defp get_latency_leaders_by_chain(connections) do
    alias Livechain.Benchmarking.BenchmarkStore

    # Group connections by chain
    chains_with_providers =
      connections
      |> Enum.group_by(fn conn -> Map.get(conn, :chain) end)
      |> Enum.reject(fn {chain, _providers} -> is_nil(chain) end)

    # For each chain, find the provider with lowest average latency
    Enum.reduce(chains_with_providers, %{}, fn {chain_name, chain_connections}, acc ->
      # Get latency data for each provider
      provider_latencies =
        Enum.map(chain_connections, fn conn ->
          provider_id = conn.id

          # Get RPC performance for common methods
          common_methods = ["eth_blockNumber", "eth_getBalance", "eth_chainId", "eth_getLogs"]

          total_latency =
            Enum.reduce(common_methods, {0.0, 0}, fn method, {sum_latency, count} ->
              case BenchmarkStore.get_rpc_performance(chain_name, provider_id, method) do
                %{avg_latency: avg_lat, total_calls: total} when total >= 10 and avg_lat > 0 ->
                  {sum_latency + avg_lat, count + 1}

                _ ->
                  {sum_latency, count}
              end
            end)

          case total_latency do
            {sum, count} when count > 0 -> {provider_id, sum / count}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      # Find provider with lowest average latency
      case Enum.min_by(
             provider_latencies,
             fn {_provider_id, avg_latency} -> avg_latency end,
             fn -> nil end
           ) do
        {fastest_provider_id, _latency} -> Map.put(acc, chain_name, fastest_provider_id)
        nil -> acc
      end
    end)
  end

  defp fetch_connections(socket) do
    connections = Livechain.RPC.ChainRegistry.list_all_connections()
    latency_leaders = get_latency_leaders_by_chain(connections)

    socket
    |> assign(:connections, connections)
    |> assign(:latency_leaders, latency_leaders)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end

  defp start_demo_connections do
    # Note: Demo connections are now managed by the chain supervisors
    # This function is kept for compatibility but doesn't start connections
    Logger.info("Demo connections are now managed by chain supervisors")
    :ok
  end

  defp stop_demo_connections do
    # Note: Demo connections are now managed by chain supervisors
    # This function is kept for compatibility but doesn't stop connections
    Logger.info("Demo connections are now managed by chain supervisors")
    :ok
  end

  defp publish_sample_routing_decision do
    sample = %{
      ts: System.system_time(:millisecond),
      chain: Enum.random(["ethereum", "polygon", "demo"]),
      method: Enum.random(["eth_blockNumber", "eth_getBalance", "eth_chainId"]),
      strategy: "priority",
      provider_id: Enum.random(["mock_ethereum_mainnet", "mock_polygon", "demo_provider"]),
      duration_ms: Enum.random(20..300),
      result: Enum.random([:success, :error]),
      failover_count: Enum.random(0..1)
    }

    Phoenix.PubSub.broadcast(Livechain.PubSub, "routing:decisions", sample)
  end

  defp collect_vm_metrics do
    mem = :erlang.memory()

    # CPU percent (runtime/wallclock deltas)
    {_rt_total, rt_delta} = :erlang.statistics(:runtime)
    {_wc_total, wc_delta} = :erlang.statistics(:wall_clock)

    cpu_percent =
      if wc_delta > 0 do
        min(100.0, 100.0 * rt_delta / wc_delta)
      else
        0.0
      end

    # Reductions delta per tick (approx/s)
    {_red_total, red_delta} = :erlang.statistics(:reductions)

    # IO bytes
    io = :erlang.statistics(:io)

    {in_bytes, out_bytes} =
      case io do
        {{in_total, _}, {out_total, _}} -> {in_total, out_total}
        {{in_total, _in2}} -> {in_total, 0}
        _ -> {0, 0}
      end

    # Scheduler utilization avg (if enabled)
    sched =
      try do
        :erlang.statistics(:scheduler_wall_time)
      catch
        :error, _ -> :not_available
      end

    sched_util_avg =
      case sched do
        list when is_list(list) and length(list) > 0 ->
          vals =
            Enum.map(list, fn
              {_id, active, total} when total > 0 -> 100.0 * active / total
              {_id, _active, _total} -> 0.0
            end)

          Enum.sum(vals) / max(1, length(vals))

        _ ->
          nil
      end

    %{
      mem_total_mb: to_mb(mem[:total]),
      mem_processes_mb: to_mb(mem[:processes_used] || mem[:processes] || 0),
      mem_binary_mb: to_mb(mem[:binary] || 0),
      mem_code_mb: to_mb(mem[:code] || 0),
      mem_ets_mb: to_mb(mem[:ets] || 0),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      ets_count: :erlang.system_info(:ets_count),
      run_queue: :erlang.statistics(:run_queue),
      cpu_percent: cpu_percent,
      reductions_s: red_delta,
      io_in_bytes: in_bytes,
      io_out_bytes: out_bytes,
      sched_util_avg: sched_util_avg
    }
  end

  defp to_mb(bytes) when is_integer(bytes), do: Float.round(bytes / 1_048_576, 1)
  defp to_mb(_), do: 0.0

  defp format_last_seen(nil), do: "Never"

  defp format_last_seen(timestamp) when is_integer(timestamp) and timestamp > 0 do
    case DateTime.from_unix(timestamp, :millisecond) do
      {:ok, datetime} -> datetime |> DateTime.to_time() |> to_string()
      {:error, _} -> "Invalid"
    end
  end

  defp format_last_seen(_), do: "Unknown"

  # New helpers for richer UI metrics and labeling
  defp rpc_calls_per_second(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000
    count = Enum.count(routing_events, fn e -> (e[:ts_ms] || 0) >= one_minute_ago end)
    Float.round(count / 60, 1)
  end

  defp error_rate_percent(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000
    recent = Enum.filter(routing_events, fn e -> (e[:ts_ms] || 0) >= one_minute_ago end)
    total = max(length(recent), 1)
    errors = Enum.count(recent, fn e -> e[:result] == :error end)
    Float.round(errors * 100.0 / total)
  end

  defp failovers_last_minute(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000

    Enum.reduce(routing_events, 0, fn e, acc ->
      if (e[:ts_ms] || 0) >= one_minute_ago and (e[:failovers] || 0) > 0, do: acc + 1, else: acc
    end)
  end

  defp provider_status_label(%{status: :connected}), do: "CONNECTED"
  defp provider_status_label(%{status: :disconnected}), do: "DISCONNECTED"
  defp provider_status_label(%{status: :rate_limited}), do: "RATE LIMITED"

  defp provider_status_label(%{status: :connecting} = pc) do
    attempts = Map.get(pc, :reconnect_attempts, 0)
    last_seen = Map.get(pc, :last_seen)

    cond do
      attempts >= 5 and (is_nil(last_seen) or last_seen == 0) -> "UNREACHABLE"
      attempts >= 5 -> "UNSTABLE"
      true -> "CONNECTING"
    end
  end

  defp provider_status_label(_), do: "UNKNOWN"

  defp provider_status_class_text(%{status: :connected}), do: "text-emerald-400"
  defp provider_status_class_text(%{status: :disconnected}), do: "text-red-400"
  defp provider_status_class_text(%{status: :rate_limited}), do: "text-purple-300"

  defp provider_status_class_text(%{status: :connecting} = pc) do
    attempts = Map.get(pc, :reconnect_attempts, 0)
    last_seen = Map.get(pc, :last_seen)

    cond do
      attempts >= 5 and (is_nil(last_seen) or last_seen == 0) -> "text-red-400"
      attempts >= 5 -> "text-yellow-400"
      true -> "text-yellow-400"
    end
  end

  defp provider_status_class_text(_), do: "text-gray-400"

  defp get_available_chains do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        config.chains
        |> Enum.map(fn {chain_name, chain_config} ->
          %{
            id: to_string(chain_config.chain_id),
            name: chain_name,
            display_name: chain_config.name,
            block_time: chain_config.block_time
          }
        end)

      {:error, _} ->
        # Fallback to hardcoded values if config loading fails
        [
          %{id: "1", name: "ethereum", display_name: "Ethereum Mainnet", block_time: 12000}
        ]
    end
  end

  # Unified event builder
  defp as_event(kind, opts) when is_list(opts) do
    now_ms = System.system_time(:millisecond)

    %{
      id: System.unique_integer([:positive]),
      kind: kind,
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: now_ms,
      chain: Keyword.get(opts, :chain),
      provider_id: Keyword.get(opts, :provider_id),
      severity: Keyword.get(opts, :severity, :info),
      message: Keyword.get(opts, :message),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  defp severity_text_class(:debug), do: "text-gray-400"
  defp severity_text_class(:info), do: "text-sky-300"
  defp severity_text_class(:warn), do: "text-yellow-300"
  defp severity_text_class(:error), do: "text-red-400"
  defp severity_text_class(_), do: "text-gray-400"

  # Enhanced floating simulator controls window with collapsible design
  defp floating_simulator_controls(assigns) do
    assigns =
      assigns
      |> assign_new(:sim_stats, fn ->
        %{http: %{success: 0, error: 0, avgLatencyMs: 0.0, inflight: 0}, ws: %{open: 0}}
      end)

    ~H"""
    <div class="pointer-events-none absolute top-4 left-4 z-30">
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300",
                   if(@sim_collapsed, do: "w-80", else: "w-[28rem] max-h-[85vh]")]}>
        <!-- Header -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class={["h-2 w-2 rounded-full", if((@sim_stats.http["success"] || @sim_stats.http[:success] || 0) > 0 or (@sim_stats.http["inflight"] || @sim_stats.http[:inflight] || 0) > 0 or (@sim_stats.ws["open"] || @sim_stats.ws[:open] || 0) > 0, do: "bg-emerald-400 animate-pulse", else: "bg-gray-500")]}></div>
            <div class="truncate text-xs text-gray-300">
              <%= if (@sim_stats.http["success"] || @sim_stats.http[:success] || 0) > 0 or (@sim_stats.http["inflight"] || @sim_stats.http[:inflight] || 0) > 0 or (@sim_stats.ws["open"] || @sim_stats.ws[:open] || 0) > 0 do %>
                Load Test Active
              <% else %>
                Load Simulator
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%= if @sim_collapsed do %>
              <div class="text-[10px] flex items-center space-x-3 text-gray-400">
                <span class="text-emerald-300">{@sim_stats.http["success"] || @sim_stats.http[:success] || 0} ✓</span>
                <span class="text-rose-400">{@sim_stats.http["error"] || @sim_stats.http[:error] || 0} ✗</span>
                <span class="text-yellow-300">{(@sim_stats.http["avgLatencyMs"] || @sim_stats.http[:avgLatencyMs] || 0.0) |> to_float() |> Float.round(1)}ms</span>
              </div>
            <% end %>
            <button
              phx-click="toggle_sim_panel"
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              {if @sim_collapsed, do: "↖", else: "↗"}
            </button>
          </div>
        </div>

        <!-- Collapsed content - basic controls only -->
        <%= if @sim_collapsed do %>
          <div class="p-3 space-y-3">
            <!-- Quick action buttons -->
            <div class="flex items-center justify-between">
              <div class="flex space-x-2">
                <button phx-click="sim_http_start"
                        class="flex items-center space-x-1 px-3 py-1.5 rounded-lg bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-700 hover:to-purple-700 text-white text-xs font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-indigo-500/25">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                  </svg>
                  <span>HTTP</span>
                </button>
                <button phx-click="sim_ws_start"
                        class="flex items-center space-x-1 px-3 py-1.5 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 text-white text-xs font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-purple-500/25">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
                  </svg>
                  <span>WS</span>
                </button>
              </div>
              <div class="flex space-x-1">
                <button phx-click="sim_http_stop" class="px-2 py-1 rounded bg-gray-700 hover:bg-gray-600 text-white text-xs transition-colors">Stop HTTP</button>
                <button phx-click="sim_ws_stop" class="px-2 py-1 rounded bg-gray-700 hover:bg-gray-600 text-white text-xs transition-colors">Stop WS</button>
              </div>
            </div>

            <!-- Compact stats display -->
            <div class="grid grid-cols-2 gap-3 text-xs">
              <div class="bg-gray-800/50 rounded-lg p-2 border border-gray-700/30">
                <div class="text-gray-400 text-[10px] font-medium mb-1">HTTP STATS</div>
                <div class="flex justify-between items-center">
                  <div class="flex space-x-3">
                    <span class="text-emerald-400">{@sim_stats.http["success"] || @sim_stats.http[:success] || 0}</span>
                    <span class="text-rose-400">{@sim_stats.http["error"] || @sim_stats.http[:error] || 0}</span>
                  </div>
                  <div class="text-yellow-300 text-[10px]">
                    {(@sim_stats.http["avgLatencyMs"] || @sim_stats.http[:avgLatencyMs] || 0.0) |> to_float() |> Float.round(1)}ms
                  </div>
                </div>
              </div>
              <div class="bg-gray-800/50 rounded-lg p-2 border border-gray-700/30">
                <div class="text-gray-400 text-[10px] font-medium mb-1">WEBSOCKET</div>
                <div class="flex justify-between items-center">
                  <span class="text-emerald-400">{@sim_stats.ws["open"] || @sim_stats.ws[:open] || 0}</span>
                  <div class="text-[10px] text-gray-400">open</div>
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <!-- Expanded content - full featured controls -->
          <div class="max-h-[75vh] overflow-y-auto">
            <div class="p-4 space-y-4">
            <!-- Chain Selection -->
            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <label class="text-xs font-semibold text-gray-300">Target Chains</label>
                <button phx-click="select_all_chains" class="text-xs text-indigo-400 hover:text-indigo-300 transition-colors">Select All</button>
              </div>
              <div class="grid grid-cols-2 gap-2 max-h-24 overflow-y-auto">
                <%= for chain <- @available_chains do %>
                  <label class="flex items-center space-x-2 cursor-pointer group">
                    <input type="checkbox"
                           name="selected_chains[]"
                           value={chain.name}
                           checked={chain.name in (@selected_chains || [])}
                           phx-click="toggle_chain_selection"
                           phx-value-chain={chain.name}
                           class="rounded border-gray-600 bg-gray-700 text-indigo-600 focus:ring-indigo-500 focus:ring-2 w-3 h-3" />
                    <span class="text-xs text-gray-300 group-hover:text-gray-200 transition-colors truncate">{chain.display_name}</span>
                  </label>
                <% end %>
              </div>
            </div>

            <!-- Strategy Selection -->
            <div class="space-y-2">
              <label class="text-xs font-semibold text-gray-300">Routing Strategy</label>
              <div class="grid grid-cols-2 gap-2">
                <%= for {strategy, label, color} <- [["fastest", "Fastest", "sky"], ["leaderboard", "Best Score", "emerald"], ["priority", "Priority", "purple"], ["round-robin", "Round Robin", "orange"], ["cheapest", "Cheapest", "green"]] do %>
                  <button phx-click="select_strategy"
                          phx-value-strategy={strategy}
                          class={"px-3 py-2 rounded-lg text-xs font-medium transition-all duration-200 border #{if @selected_strategy == strategy, do: "border-#{color}-500 bg-#{color}-500/20 text-#{color}-300", else: "border-gray-600 bg-gray-700/50 text-gray-300 hover:border-#{color}-400 hover:text-#{color}-300"}"}
                  >
                    {label}
                  </button>
                <% end %>
              </div>
            </div>

            <!-- Request Rate Control -->
            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <label class="text-xs font-semibold text-gray-300">Request Rate</label>
                <span class="text-xs text-indigo-400 font-mono">{@request_rate} RPS</span>
              </div>
              <div class="flex items-center space-x-3">
                <button phx-click="decrease_rate" class="p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-300 transition-colors">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 12H4" />
                  </svg>
                </button>
                <div class="flex-1 relative">
                  <input type="range"
                         min="1"
                         max="50"
                         value={@request_rate}
                         phx-change="update_rate"
                         name="rate"
                         class="w-full h-2 bg-gray-700 rounded-lg appearance-none cursor-pointer slider" />
                  <div class="absolute -bottom-1 left-0 right-0 flex justify-between text-[10px] text-gray-500">
                    <span>1</span>
                    <span>25</span>
                    <span>50</span>
                  </div>
                </div>
                <button phx-click="increase_rate" class="p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-300 transition-colors">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
                  </svg>
                </button>
              </div>
            </div>

            <!-- Action Controls -->
            <div class="space-y-3">
              <div class="flex space-x-2">
                <button phx-click="sim_http_start_advanced"
                        class="flex-1 flex items-center justify-center space-x-2 py-2 px-4 rounded-lg bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-700 hover:to-purple-700 text-white text-sm font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-indigo-500/25">
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                  </svg>
                  <span>Start HTTP Load</span>
                </button>
                <button phx-click="sim_ws_start_advanced"
                        class="flex-1 flex items-center justify-center space-x-2 py-2 px-4 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 text-white text-sm font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-purple-500/25">
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
                  </svg>
                  <span>Start WS Load</span>
                </button>
              </div>
              <div class="flex space-x-2">
                <button phx-click="sim_stop_all"
                        class="flex-1 py-2 px-4 rounded-lg bg-gray-700 hover:bg-gray-600 text-white text-sm font-medium transition-colors">
                  Stop All
                </button>
                <button phx-click="clear_sim_logs"
                        class="px-4 py-2 rounded-lg border border-gray-600 text-gray-300 hover:border-gray-500 hover:text-gray-200 text-sm transition-colors">
                  Clear Logs
                </button>
              </div>
            </div>

            <!-- Live Activity Feed -->
            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <label class="text-xs font-semibold text-gray-300">Live Activity</label>
                <div class="flex items-center space-x-1">
                  <div class="w-2 h-2 rounded-full bg-green-500 animate-pulse"></div>
                  <span class="text-[10px] text-gray-400">Real-time</span>
                </div>
              </div>
              <div class="bg-gray-900/50 border border-gray-700/50 rounded-lg p-3 h-32 overflow-y-auto">
                <div class="space-y-1 text-xs font-mono">
                  <%= if length(@recent_calls || []) > 0 do %>
                    <%= for call <- Enum.take(@recent_calls || [], 8) do %>
                      <div class="flex items-center justify-between text-[10px] py-0.5">
                        <div class="flex items-center space-x-2">
                          <span class={"w-1.5 h-1.5 rounded-full #{if call[:type] == :http, do: "bg-indigo-400", else: "bg-purple-400"}"}></span>
                          <span class="text-gray-400">{call[:method] || "subscribe"}</span>
                          <span class="text-gray-500">→</span>
                          <span class="text-gray-300">{call[:chain]}</span>
                        </div>
                        <div class="flex items-center space-x-2">
                          <span class={"#{if call[:status] == :success, do: "text-emerald-400", else: "text-rose-400"}"}>
                            {if call[:status] == :success, do: "✓", else: "✗"}
                          </span>
                          <%= if call[:latency] do %>
                            <span class="text-yellow-300">{call[:latency]}ms</span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  <% else %>
                    <div class="text-center text-gray-500 mt-8">
                      <svg class="w-6 h-6 mx-auto mb-2 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
                      </svg>
                      <div class="text-xs">No activity yet</div>
                      <div class="text-[10px] text-gray-600">Start a simulation to see live calls</div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <!-- Enhanced Stats Display -->
            <div class="grid grid-cols-2 gap-3">
              <div class="bg-gradient-to-br from-indigo-900/30 to-purple-900/30 border border-indigo-500/30 rounded-lg p-3">
                <div class="flex items-center justify-between mb-2">
                  <div class="text-xs font-semibold text-indigo-300">HTTP Load</div>
                  <div class="text-[10px] text-gray-400">RPC Calls</div>
                </div>
                <div class="space-y-1">
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">Success:</span>
                    <span class="text-emerald-400 font-mono">{@sim_stats.http["success"] || @sim_stats.http[:success] || 0}</span>
                  </div>
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">Errors:</span>
                    <span class="text-rose-400 font-mono">{@sim_stats.http["error"] || @sim_stats.http[:error] || 0}</span>
                  </div>
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">Avg Latency:</span>
                    <span class="text-yellow-300 font-mono">
                      {(@sim_stats.http["avgLatencyMs"] || @sim_stats.http[:avgLatencyMs] || 0.0) |> to_float() |> Float.round(1)}ms
                    </span>
                  </div>
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">In Flight:</span>
                    <span class="text-blue-400 font-mono">{@sim_stats.http["inflight"] || @sim_stats.http[:inflight] || 0}</span>
                  </div>
                </div>
              </div>
              <div class="bg-gradient-to-br from-purple-900/30 to-pink-900/30 border border-purple-500/30 rounded-lg p-3">
                <div class="flex items-center justify-between mb-2">
                  <div class="text-xs font-semibold text-purple-300">WebSocket</div>
                  <div class="text-[10px] text-gray-400">Subscriptions</div>
                </div>
                <div class="space-y-1">
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">Open:</span>
                    <span class="text-emerald-400 font-mono">{@sim_stats.ws["open"] || @sim_stats.ws[:open] || 0}</span>
                  </div>
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">Topics:</span>
                    <span class="text-purple-400 font-mono">newHeads</span>
                  </div>
                  <div class="flex justify-between text-xs">
                    <span class="text-gray-400">Messages:</span>
                    <span class="text-blue-400 font-mono">Live</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper function for formatting timestamps
  defp format_timestamp(nil), do: "now"
  defp format_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:millisecond)
    diff = now - timestamp

    cond do
      diff < 1000 -> "now"
      diff < 60_000 -> "#{div(diff, 1000)}s ago"
      diff < 3_600_000 -> "#{div(diff, 60_000)}m ago"
      true -> "#{div(diff, 3_600_000)}h ago"
    end
  end
  defp format_timestamp(_), do: "unknown"

  defp percentile_pair(values) when is_list(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if n == 0 do
      {nil, nil}
    else
      p50 = percentile(sorted, 0.5)
      p95 = percentile(sorted, 0.95)
      {Float.round(p50, 1), Float.round(p95, 1)}
    end
  end

  defp percentile([], _p), do: 0.0
  defp percentile(sorted_values, p) do
    n = length(sorted_values)
    r = p * (n - 1)
    lower = :math.floor(r) |> trunc()
    upper = :math.ceil(r) |> trunc()

    if lower == upper do
      Enum.at(sorted_values, lower) * 1.0
    else
      lower_val = Enum.at(sorted_values, lower) * 1.0
      upper_val = Enum.at(sorted_values, upper) * 1.0
      frac = r - lower
      lower_val + frac * (upper_val - lower_val)
    end
  end

  defp get_last_decision(routing_events, chain_name, provider_id \\ nil) do
    Enum.find(routing_events, fn e ->
      cond do
        provider_id -> e[:provider_id] == provider_id
        chain_name -> e[:chain] == chain_name
        true -> false
      end
    end)
  end
end
