defmodule LivechainWeb.Dashboard do
  use LivechainWeb, :live_view
  require Logger

  alias Livechain.RPC.ChainRegistry
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
      |> assign(:demo_running, false)
      |> assign(:sampler_running, false)
      |> assign(:sampler_ref, nil)
      |> assign(:vm_metrics, %{})
      |> assign(:available_chains, get_available_chains())
      |> assign(:details_collapsed, true)
      |> assign(:events_collapsed, true)
      |> assign(:sim_stats, %{
        http: %{success: 0, error: 0, avgLatencyMs: 0.0, inflight: 0},
        ws: %{open: 0}
      })
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

  # Sampler tick
  @impl true
  def handle_info(:sample_tick, %{assigns: %{sampler_running: true}} = socket) do
    publish_sample_routing_decision()
    Process.send_after(self(), :sample_tick, 1_000)
    {:noreply, socket}
  end

  def handle_info(:sample_tick, socket), do: {:noreply, socket}

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
              %{id: "simulator", label: "Simulator", icon: "M4 6h16M4 10h16M4 14h16"},
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
            />
          <% "benchmarks" -> %>
            <.benchmarks_tab_content />
          <% "simulator" -> %>
            <.simulator_tab_content
              demo_running={@demo_running}
              sampler_running={@sampler_running}
              sim_stats={@sim_stats}
              available_chains={@available_chains}
            />
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
    ~H"""
    <div class="relative flex h-full w-full">
      <!-- Main Network Topology Area -->
      <div
        class="flex-1 overflow-hidden"
        phx-hook="DraggableNetworkViewport"
        id="draggable-viewport"
      >
        <div class="h-full w-full" data-draggable-content>
          <NetworkTopology.nodes_display
            id="network-topology"
            connections={@connections}
            selected_chain={@selected_chain}
            selected_provider={@selected_provider}
            latency_leaders={Map.get(assigns, :latency_leaders, %{})}
            on_chain_select="select_chain"
            on_provider_select="select_provider"
            on_test_connection="test_connection"
            on_chain_hover="highlight_chain"
            on_provider_hover="highlight_provider"
          />
        </div>
      </div>
      
    <!-- Simulator Controls (top-left) -->
      <.floating_simulator_controls
        sim_stats={@sim_stats}
        available_chains={@available_chains}
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
      
    <!-- Floating Events Window (bottom-left) -->
      <.floating_events_window
        events_collapsed={@events_collapsed}
        routing_events={@routing_events}
        provider_events={@provider_events}
        client_events={@client_events}
        latest_blocks={@latest_blocks}
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

    ~H"""
    <div class="flex h-full flex-col">
      <!-- Header -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="flex items-center justify-between">
          <h3 class="text-lg font-semibold capitalize text-white">{@chain}</h3>
          <button phx-click="select_chain" phx-value-chain="" class="text-gray-400 hover:text-white">
            <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              >
              </path>
            </svg>
          </button>
        </div>
      </div>
      
    <!-- Chain Stats -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="grid grid-cols-2 gap-4">
          <div class="bg-gray-800/50 rounded-lg p-3">
            <div class="text-xs text-gray-400">Providers</div>
            <div class="text-xl font-bold text-white">{length(@chain_connections)}</div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3">
            <div class="text-xs text-gray-400">Connected</div>
            <div class="text-xl font-bold text-emerald-400">
              {Enum.count(@chain_connections, &(&1.status == :connected))}
            </div>
          </div>
        </div>
      </div>
      
    <!-- Providers List -->
      <div class="border-gray-700/50 border-b p-4">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">Providers</h4>
        <div class="space-y-2">
          <%= for connection <- @chain_connections do %>
            <div
              class="bg-gray-800/30 cursor-pointer rounded-lg p-3 transition-colors hover:bg-gray-800/50"
              phx-click="select_provider"
              phx-value-provider={connection.id}
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center space-x-3">
                  <div class={["h-3 w-3 rounded-full", if(connection.status == :connected,
    do: "bg-emerald-400",
    else: if(connection.status == :disconnected,
    do: "bg-red-400",
    else: "bg-yellow-400"))]}>
                  </div>
                  <div>
                    <div class="text-sm font-medium text-white">{connection.name}</div>
                    <div class="text-xs text-gray-400">{connection.id}</div>
                  </div>
                </div>
                <div class="text-xs text-gray-400">
                  {connection.subscriptions} subs
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Recent Events (Unified) -->
      <div class="flex-1 overflow-hidden p-4">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">Recent Events</h4>
        <div class="h-full overflow-auto">
          <div class="mb-1 text-xs text-gray-500">Unified Activity</div>
          <div
            id="chain-unified-activity"
            class="flex max-h-64 flex-col-reverse gap-1 overflow-y-auto"
            phx-hook="TerminalFeed"
          >
            <%= for e <- Enum.take(@chain_unified_events, 50) do %>
              <div class="bg-gray-800/30 rounded-lg p-2">
                <div class={"text-xs " <> severity_text_class(e.severity || :info)}>Activity</div>
                <div class="text-[11px] text-gray-400">
                  <span class="text-gray-500">[{e.ts}]</span>
                  <%= if e.chain do %>
                    <span class="ml-1 text-purple-300">{e.chain}</span>
                  <% end %>
                  <%= if e.provider_id do %>
                    <span class="ml-1 text-emerald-300">{e.provider_id}</span>
                  <% end %>
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

    ~H"""
    <div class="flex h-full flex-col">
      <!-- Header -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-lg font-semibold text-white">
              {if @provider_connection, do: @provider_connection.name, else: @provider}
            </h3>
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
      
    <!-- Provider Stats -->
      <%= if @provider_connection do %>
        <div class="border-gray-700/50 border-b p-4">
          <div class="grid grid-cols-2 gap-4">
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Status</div>
              <div class={["text-sm font-bold", provider_status_class_text(@provider_connection)]}>
                {provider_status_label(@provider_connection)}
              </div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Subscriptions</div>
              <div class="text-sm font-bold text-white">{@provider_connection.subscriptions}</div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Failures</div>
              <div class="text-sm font-bold text-red-400">
                {@provider_connection.reconnect_attempts}
              </div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Last Seen</div>
              <div class="text-xs text-gray-300">
                {format_last_seen(@provider_connection.last_seen)}
              </div>
            </div>
          </div>
        </div>
      <% end %>
      
    <!-- Recent Activity (Unified) -->
      <div class="flex-1 overflow-hidden p-4">
        <h4 class="mb-3 text-sm font-semibold text-gray-300">Recent Activity</h4>
        <div class="h-full overflow-auto">
          <div class="mb-1 text-xs text-gray-500">Unified Activity</div>
          <div
            id="provider-unified-activity"
            class="flex max-h-80 flex-col-reverse gap-1 overflow-y-auto"
            phx-hook="TerminalFeed"
          >
            <%= for e <- Enum.take(@provider_unified_events, 60) do %>
              <div class="bg-gray-800/30 rounded-lg p-2">
                <div class={"text-xs " <> severity_text_class(e.severity || :info)}>Activity</div>
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
                  Provider: {@selected_provider}
                <% @selected_chain -> %>
                  Chain: {@selected_chain}
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

  # Floating events window (pinned bottom-left)
  def floating_events_window(assigns) do
    assigns =
      assign(
        assigns,
        :total_events,
        length(assigns.routing_events) + length(assigns.provider_events) +
          length(assigns.client_events) + length(assigns.latest_blocks)
      )

    ~H"""
    <div class="pointer-events-none absolute bottom-4 left-4 z-30">
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto w-96 rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300", if(@events_collapsed, do: "h-auto", else: "max-h-[70vh]")]}>
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex items-center space-x-2">
            <div class="text-xs font-medium text-gray-300">Events</div>
            <%= unless @events_collapsed do %>
              <div class="bg-purple-500/20 text-[10px] rounded px-1.5 py-0.5 font-medium text-purple-300">
                {length(@routing_events) + length(@provider_events) + length(@client_events) +
                  length(@latest_blocks)}
              </div>
            <% end %>
          </div>
          <button
            phx-click="toggle_events_panel"
            class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
          >
            {if @events_collapsed, do: "↗", else: "↙"}
          </button>
        </div>

        <%= if @events_collapsed do %>
          <div class="px-3 py-2">
            <div class="text-xs text-gray-400">
              {length(@routing_events)} RPC calls • {length(@provider_events)} provider events • {length(
                @latest_blocks
              )} blocks
            </div>
          </div>
        <% else %>
          <div class="flex flex-col overflow-hidden">
            <div class="max-h-[60vh] flex-1 space-y-3 overflow-y-auto p-2">
              <!-- RPC Call Stream Section -->
              <div>
                <div class="mb-2 flex items-center justify-between">
                  <div class="flex items-center space-x-2 text-xs font-semibold text-gray-300">
                    <span>RPC Calls</span>
                    <div class="bg-sky-500/20 text-[10px] rounded px-1.5 py-0.5 font-medium text-sky-300">
                      {length(@routing_events)}
                    </div>
                  </div>
                </div>
                <div class="flex max-h-32 flex-col-reverse gap-1 overflow-y-auto">
                  <%= for e <- Enum.take(@routing_events, 20) do %>
                    <div class="bg-gray-800/30 text-[11px] border-gray-700/20 animate-pulse rounded-md border px-2 py-1 text-gray-400">
                      <div class="flex items-center justify-between">
                        <div class="text-[10px] text-gray-500">{e.ts}</div>
                        <div class="flex items-center space-x-1">
                          <span class="text-sky-300">{e.method}</span>
                          <span class="text-gray-500">on</span>
                          <span class="capitalize text-purple-300">{e.chain}</span>
                        </div>
                      </div>
                      <div class="mt-0.5 flex items-center justify-between">
                        <span class="text-[10px] text-emerald-300">{e.provider_id}</span>
                        <span class="text-[10px] text-yellow-300">{e.duration_ms}ms</span>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
              
    <!-- Provider Events Section -->
              <%= if length(@provider_events) > 0 do %>
                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <div class="flex items-center space-x-2 text-xs font-semibold text-gray-300">
                      <span>Provider Events</span>
                      <div class="bg-orange-500/20 text-[10px] rounded px-1.5 py-0.5 font-medium text-orange-300">
                        {length(@provider_events)}
                      </div>
                    </div>
                  </div>
                  <div class="flex max-h-24 flex-col-reverse gap-1 overflow-y-auto">
                    <%= for e <- Enum.take(@provider_events, 10) do %>
                      <div class="bg-gray-800/30 text-[11px] border-gray-700/20 rounded-md border px-2 py-1 text-gray-400">
                        <div class="flex items-center justify-between">
                          <span class="text-[10px] text-gray-500">{e.ts}</span>
                          <span class="text-orange-300">{e.event}</span>
                        </div>
                        <div class="mt-0.5 flex items-center space-x-2">
                          <span class="text-[10px] text-purple-300">{e.chain}</span>
                          <span class="text-[10px] text-emerald-300">{e.provider_id}</span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
              
    <!-- Client Events Section -->
              <%= if length(@client_events) > 0 do %>
                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <div class="flex items-center space-x-2 text-xs font-semibold text-gray-300">
                      <span>Client Events</span>
                      <div class="bg-blue-500/20 text-[10px] rounded px-1.5 py-0.5 font-medium text-blue-300">
                        {length(@client_events)}
                      </div>
                    </div>
                  </div>
                  <div class="flex max-h-24 flex-col-reverse gap-1 overflow-y-auto">
                    <%= for e <- Enum.take(@client_events, 10) do %>
                      <div class="bg-gray-800/30 text-[11px] border-gray-700/20 rounded-md border px-2 py-1 text-gray-400">
                        <div class="flex items-center justify-between">
                          <span class="text-[10px] text-gray-500">{e.ts}</span>
                          <span class="text-orange-300">{e.event}</span>
                        </div>
                        <div class="mt-0.5 flex items-center space-x-2">
                          <span class="text-[10px] text-gray-300">{e.ip}</span>
                          <span class="text-[10px] text-sky-300">{e.transport}</span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
              
    <!-- Latest Blocks Section -->
              <%= if length(@latest_blocks) > 0 do %>
                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <div class="flex items-center space-x-2 text-xs font-semibold text-gray-300">
                      <span>Latest Blocks</span>
                      <div class="bg-green-500/20 text-[10px] rounded px-1.5 py-0.5 font-medium text-green-300">
                        {length(@latest_blocks)}
                      </div>
                    </div>
                  </div>
                  <div class="flex max-h-24 flex-col-reverse gap-1 overflow-y-auto">
                    <%= for e <- Enum.take(@latest_blocks, 10) do %>
                      <div class="bg-gray-800/30 text-[11px] border-gray-700/20 rounded-md border px-2 py-1 text-gray-400">
                        <div class="flex items-center justify-between">
                          <span class="text-[10px] text-gray-500">{e.ts}</span>
                          <span class="text-purple-300">{e.chain}</span>
                        </div>
                        <div class="mt-0.5 flex items-center justify-between">
                          <span class="text-[10px] text-gray-300">#{e.block_number}</span>
                          <div class="flex items-center space-x-1">
                            <span class="text-[10px] text-emerald-300">{e.provider_first}</span>
                            <span class="text-[10px] text-yellow-300">Δ{e.margin_ms}ms</span>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Default meta stats panel for details window when nothing is selected
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

  def simulator_tab_content(assigns) do
    ~H"""
    <div
      id="simulator-control"
      class="flex h-full w-full flex-col gap-4 p-4"
    >
      <!-- Available Chains Info -->
      <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
        <div class="mb-2 text-sm font-semibold text-gray-300">Available Chains</div>
        <div class="flex flex-wrap gap-2">
          <%= for chain <- @available_chains do %>
            <span class="inline-flex items-center rounded-full bg-purple-100 px-3 py-0.5 text-xs font-medium text-purple-800">
              {chain.display_name} (ID: {chain.id})
            </span>
          <% end %>
        </div>
        <%= if length(@available_chains) == 0 do %>
          <div class="text-sm text-gray-400">No chains configured</div>
        <% end %>
      </div>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
          <div class="mb-2 text-sm font-semibold text-gray-300">HTTP Load</div>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <button phx-click="sim_http_start" class="rounded bg-indigo-600 px-3 py-1 text-white">
              Start HTTP
            </button>
            <button phx-click="sim_http_stop" class="rounded bg-gray-700 px-3 py-1 text-white">
              Stop HTTP
            </button>
            <span class="text-gray-400">
              RPS: 5, Methods: eth_blockNumber/eth_getBalance <br />
              Chains: {Enum.map(@available_chains, & &1.display_name) |> Enum.join(", ")}
            </span>
          </div>
          <div class="mt-2 grid grid-cols-3 gap-2 text-xs text-gray-400">
            <div>
              Success:
              <span class="text-emerald-400">
                {@sim_stats.http["success"] || @sim_stats.http[:success]}
              </span>
            </div>
            <div>
              Errors:
              <span class="text-rose-400">{@sim_stats.http["error"] || @sim_stats.http[:error]}</span>
            </div>
            <div>
              Avg:
              <span class="text-yellow-300">
                {(@sim_stats.http["avgLatencyMs"] || @sim_stats.http[:avgLatencyMs] || 0.0)
                |> to_float()
                |> Float.round(1)} ms
              </span>
            </div>
          </div>
        </div>
        <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
          <div class="mb-2 text-sm font-semibold text-gray-300">WebSocket Load</div>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <button phx-click="sim_ws_start" class="rounded bg-purple-600 px-3 py-1 text-white">
              Start WS
            </button>
            <button phx-click="sim_ws_stop" class="rounded bg-gray-700 px-3 py-1 text-white">
              Stop WS
            </button>
            <span class="text-gray-400">
              Conns: 2, Topic: newHeads <br />
              Chains: {Enum.map(@available_chains, & &1.display_name) |> Enum.join(", ")}
            </span>
          </div>
          <div class="mt-2 text-xs text-gray-400">
            Open:
            <span class="text-emerald-400">{@sim_stats.ws["open"] || @sim_stats.ws[:open]}</span>
          </div>
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

    # Ensure at least one scoped activity item appears
    has_chain_event = Enum.any?(socket.assigns.events, fn e -> e[:chain] == chain end)

    socket =
      if not has_chain_event do
        uev =
          as_event(:system,
            chain: chain,
            severity: :debug,
            message: "Opened chain view",
            meta: %{}
          )

        socket
        |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
        |> push_event("events_batch", %{items: [uev]})
      else
        socket
      end

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
      |> assign(:details_collapsed, false)

    # Re-enable auto-centering to animate pan to the selected provider
    socket =
      socket
      |> push_event("center_on_provider", %{provider: provider})

    # Ensure at least one scoped activity item appears
    has_provider_event = Enum.any?(socket.assigns.events, fn e -> e[:provider_id] == provider end)

    socket =
      if not has_provider_event do
        uev =
          as_event(:system,
            provider_id: provider,
            severity: :debug,
            message: "Opened provider view",
            meta: %{}
          )

        socket
        |> update(:events, fn list -> [uev | Enum.take(list, 199)] end)
        |> push_event("events_batch", %{items: [uev]})
      else
        socket
      end

    {:noreply, socket}
  end

  # Hover previews
  @impl true
  def handle_event("highlight_chain", %{"highlight" => chain}, socket) do
    {:noreply, assign(socket, :hover_chain, chain)}
  end

  @impl true
  def handle_event("highlight_provider", %{"highlight" => provider}, socket) do
    {:noreply, assign(socket, :hover_provider, provider)}
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
  def handle_event("test_connection", _params, socket) do
    # Broadcast connection status update to all LiveViews
    Livechain.RPC.ChainRegistry.broadcast_connection_status_update()
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, fetch_connections(socket)}
  end

  # Sampler controls
  @impl true
  def handle_event("start_sampler", _params, %{assigns: %{sampler_running: false}} = socket) do
    Process.send_after(self(), :sample_tick, 100)
    {:noreply, assign(socket, :sampler_running, true)}
  end

  def handle_event("start_sampler", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop_sampler", _params, %{assigns: %{sampler_running: true}} = socket) do
    {:noreply, assign(socket, :sampler_running, false)}
  end

  def handle_event("stop_sampler", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("emit_cooldown", _params, socket) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "provider_pool:events",
      %{
        ts: System.system_time(:millisecond),
        chain: "demo",
        provider_id: "demo_provider",
        event: :cooldown_start,
        details: %{until: System.system_time(:millisecond) + 5_000}
      }
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("emit_healthy", _params, socket) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "provider_pool:events",
      %{
        ts: System.system_time(:millisecond),
        chain: "demo",
        provider_id: "demo_provider",
        event: :healthy,
        details: %{}
      }
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_http_start", _params, socket) do
    # Push event to JS hook with defaults; future: make dynamic via form controls
    opts = %{
      chains: Enum.map(socket.assigns.available_chains, & &1.id),
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
      chains: Enum.map(socket.assigns.available_chains, & &1.id),
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

  # Helper functions

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

  # New: floating simulator controls window
  defp floating_simulator_controls(assigns) do
    assigns =
      assigns
      |> assign_new(:sim_stats, fn ->
        %{http: %{success: 0, error: 0, avgLatencyMs: 0.0, inflight: 0}, ws: %{open: 0}}
      end)

    ~H"""
    <div class="pointer-events-none absolute top-4 left-4 z-30">
      <div class="border-gray-700/60 bg-gray-900/95 pointer-events-auto w-96 rounded-xl border shadow-2xl backdrop-blur-lg">
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex items-center space-x-2">
            <div class="text-xs font-medium text-gray-300">Simulator</div>
          </div>
          <div class="text-[10px] text-gray-500">Controls</div>
        </div>
        <div class="p-3">
          <div class="mb-3">
            <div class="mb-1 text-xs font-semibold text-gray-300">HTTP Load</div>
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <button phx-click="sim_http_start" class="rounded bg-indigo-600 px-2 py-1 text-white">
                Start
              </button>
              <button phx-click="sim_http_stop" class="rounded bg-gray-700 px-2 py-1 text-white">
                Stop
              </button>
              <div class="text-[11px] ml-auto grid grid-cols-3 gap-3 text-gray-400">
                <div>
                  OK:
                  <span class="text-emerald-400">
                    {@sim_stats.http["success"] || @sim_stats.http[:success]}
                  </span>
                </div>
                <div>
                  Err:
                  <span class="text-rose-400">
                    {@sim_stats.http["error"] || @sim_stats.http[:error]}
                  </span>
                </div>
                <div>
                  Avg:
                  <span class="text-yellow-300">
                    {(@sim_stats.http["avgLatencyMs"] || @sim_stats.http[:avgLatencyMs] || 0.0)
                    |> to_float()
                    |> Float.round(1)}ms
                  </span>
                </div>
              </div>
            </div>
          </div>
          <div>
            <div class="mb-1 text-xs font-semibold text-gray-300">WebSocket Load</div>
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <button phx-click="sim_ws_start" class="rounded bg-purple-600 px-2 py-1 text-white">
                Start
              </button>
              <button phx-click="sim_ws_stop" class="rounded bg-gray-700 px-2 py-1 text-white">
                Stop
              </button>
              <div class="text-[11px] ml-auto text-gray-400">
                Open:
                <span class="text-emerald-400">{@sim_stats.ws["open"] || @sim_stats.ws[:open]}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
