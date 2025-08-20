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
      |> assign(:demo_running, false)
      |> assign(:sampler_running, false)
      |> assign(:sampler_ref, nil)
      |> assign(:vm_metrics, %{})
      |> assign(:available_chains, get_available_chains())
      |> assign(:sim_stats, %{
        http: %{success: 0, error: 0, avgLatencyMs: 0.0, inflight: 0},
        ws: %{open: 0}
      })
      |> fetch_connections()

    {:ok, initial_state}
  end

  @impl true
  def handle_info({:connection_status_update, connections}, socket) do
    socket =
      socket
      |> assign(:connections, connections)
      |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())

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
      chain: chain,
      method: method,
      provider_id: pid,
      duration_ms: dur,
      result: Map.get(evt, :result, :unknown),
      failovers: Map.get(evt, :failover_count, 0)
    }

    socket = update(socket, :routing_events, fn list -> [entry | Enum.take(list, 99)] end)
    {:noreply, socket}
  end

  # Provider pool event feed (real or synthetic)
  @impl true
  def handle_info(%{ts: _t, chain: chain, provider_id: pid, event: event} = ev, socket)
      when is_map(ev) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      chain: chain,
      provider_id: pid,
      event: event,
      details: Map.get(ev, :details)
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, 99)] end)
    {:noreply, socket}
  end

  # Client connection events
  @impl true
  def handle_info(%{ts: _t, event: ev, chain: chain, transport: transport} = msg, socket)
      when is_map(msg) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      chain: chain,
      transport: transport,
      event: ev,
      ip: Map.get(msg, :remote_ip) || Map.get(msg, "remote_ip")
    }

    socket = update(socket, :client_events, fn list -> [entry | Enum.take(list, 99)] end)
    {:noreply, socket}
  end

  # Circuit breaker events
  @impl true
  def handle_info(%{ts: _t, provider_id: pid, from: from, to: to, reason: reason} = _evt, socket) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      chain: "n/a",
      provider_id: pid,
      event: "circuit: #{from} -> #{to} (#{reason})"
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, 99)] end)
    {:noreply, socket}
  end

  # Compact block events
  @impl true
  def handle_info(%{chain: chain, block_number: bn} = blk, socket) when is_map(blk) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      chain: chain,
      block_number: bn,
      provider_first: Map.get(blk, :provider_first) || Map.get(blk, "provider_first"),
      margin_ms: Map.get(blk, :margin_ms) || Map.get(blk, "margin_ms")
    }

    socket = update(socket, :latest_blocks, fn list -> [entry | Enum.take(list, 19)] end)
    {:noreply, socket}
  end

  # VM metrics ticker
  @impl true
  def handle_info(:vm_metrics_tick, socket) do
    metrics = collect_vm_metrics()
    Process.send_after(self(), :vm_metrics_tick, 2_000)
    {:noreply, assign(socket, :vm_metrics, metrics)}
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
                  <div class="flex items-center space-x-2">
                    <h1 class="text-2xl font-bold text-white">Lasso RPC</h1>
                    <div class="flex -translate-y-1.5 items-center space-x-1">
                      <div class="h-2 w-2 flex-shrink-0 animate-pulse rounded-full bg-emerald-400">
                      </div>
                      <span class="text-xs font-medium text-emerald-600">LIVE</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Tab Switcher -->
          <div class="flex items-center space-x-4">
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
      </div>
      
    <!-- Content Section -->
      <div class="grid-pattern flex-1 overflow-hidden">
        <%= case @active_tab do %>
          <% "overview" -> %>
            <.dashboard_tab_content
              connections={@connections}
              routing_events={@routing_events}
              provider_events={@provider_events}
              selected_chain={@selected_chain}
              selected_provider={@selected_provider}
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
      <div class="flex-1 flex items-center justify-center p-8">
        <div class="w-full max-w-4xl">
          <NetworkTopology.nodes_display
            id="network-topology"
            connections={@connections}
            selected_chain={assigns[:selected_chain]}
            selected_provider={assigns[:selected_provider]}
            on_chain_select="select_chain"
            on_provider_select="select_provider"
            on_test_connection="test_connection"
          />
        </div>
      </div>
      
      <!-- Side Panel for Chain Details (when chain selected but no provider) -->
      <%= if assigns[:selected_chain] && !assigns[:selected_provider] do %>
        <div class="w-96 border-l border-gray-700/50 bg-gray-900/50 flex flex-col">
          <.chain_details_panel 
            chain={@selected_chain}
            connections={@connections}
            routing_events={@routing_events}
            provider_events={@provider_events}
          />
        </div>
      <% end %>
      
      <!-- Side Panel for Provider Details (when provider selected) -->
      <%= if assigns[:selected_provider] do %>
        <div class="w-96 border-l border-gray-700/50 bg-gray-900/50 flex flex-col">
          <.provider_details_panel 
            provider={@selected_provider}
            connections={@connections}
            routing_events={@routing_events}
            provider_events={@provider_events}
            selected_chain={@selected_chain}
          />
        </div>
      <% end %>
      
      <!-- Bottom Event Stream (when nothing selected) -->
      <%= if !assigns[:selected_chain] && !assigns[:selected_provider] do %>
        <div class="absolute bottom-0 left-0 right-0 h-48 border-t border-gray-700/50 bg-gray-900/80 backdrop-blur-sm">
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-2 h-full p-4">
            <div class="flex flex-col">
              <div class="mb-2 text-sm font-semibold text-gray-300">RPC Call Stream</div>
              <div class="flex-1 overflow-auto">
                <%= for e <- Enum.take(@routing_events, 10) do %>
                  <div class="mb-1 text-xs text-gray-400">
                    <span class="text-gray-500">[{e.ts}]</span>
                    chain=<span class="text-purple-300"><%= e.chain %></span> method=<span class="text-sky-300"><%= e.method %></span> provider=<span class="text-emerald-300"><%= e.provider_id %></span> dur=<span class="text-yellow-300"><%= e.duration_ms %>ms</span> result=<span><%= e.result %></span> failovers=<span><%= e.failovers %></span>
                  </div>
                <% end %>
              </div>
            </div>
            <div class="flex flex-col">
              <div class="mb-2 text-sm font-semibold text-gray-300">Provider pool events</div>
              <div class="flex-1 overflow-auto">
                <%= for e <- Enum.take(@provider_events, 10) do %>
                  <div class="mb-1 text-xs text-gray-400">
                    <span class="text-gray-500">[{e.ts}]</span>
                    chain=<span class="text-purple-300"><%= e.chain %></span> provider=<span class="text-emerald-300"><%= e.provider_id %></span> event=<span class="text-orange-300"><%= e.event %></span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def chain_details_panel(assigns) do
    assigns =
      assigns
      |> assign(:chain_connections, Enum.filter(assigns.connections, &(&1.chain == assigns.chain)))
      |> assign(:chain_events, Enum.filter(assigns.routing_events, &(&1.chain == assigns.chain)))
      |> assign(:chain_provider_events, Enum.filter(assigns.provider_events, &(&1.chain == assigns.chain)))
    
    ~H"""
    <div class="flex flex-col h-full">
      <!-- Header -->
      <div class="p-4 border-b border-gray-700/50">
        <div class="flex items-center justify-between">
          <h3 class="text-lg font-semibold text-white capitalize"><%= @chain %></h3>
          <button phx-click="select_chain" phx-value-chain="" class="text-gray-400 hover:text-white">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
            </svg>
          </button>
        </div>
      </div>
      
      <!-- Chain Stats -->
      <div class="p-4 border-b border-gray-700/50">
        <div class="grid grid-cols-2 gap-4">
          <div class="bg-gray-800/50 rounded-lg p-3">
            <div class="text-xs text-gray-400">Providers</div>
            <div class="text-xl font-bold text-white"><%= length(@chain_connections) %></div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3">
            <div class="text-xs text-gray-400">Connected</div>
            <div class="text-xl font-bold text-emerald-400">
              <%= Enum.count(@chain_connections, &(&1.status == :connected)) %>
            </div>
          </div>
        </div>
      </div>
      
      <!-- Providers List -->
      <div class="p-4 border-b border-gray-700/50">
        <h4 class="text-sm font-semibold text-gray-300 mb-3">Providers</h4>
        <div class="space-y-2">
          <%= for connection <- @chain_connections do %>
            <div 
              class="bg-gray-800/30 rounded-lg p-3 cursor-pointer hover:bg-gray-800/50 transition-colors"
              phx-click="select_provider" 
              phx-value-provider={connection.id}
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center space-x-3">
                  <div class={[
                    "w-3 h-3 rounded-full",
                    case connection.status do
                      :connected -> "bg-emerald-400"
                      :disconnected -> "bg-red-400"
                      _ -> "bg-yellow-400"
                    end
                  ]}></div>
                  <div>
                    <div class="text-sm font-medium text-white"><%= connection.name %></div>
                    <div class="text-xs text-gray-400"><%= connection.id %></div>
                  </div>
                </div>
                <div class="text-xs text-gray-400">
                  <%= connection.subscriptions %> subs
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      
      <!-- Recent Events -->
      <div class="flex-1 p-4 overflow-hidden">
        <h4 class="text-sm font-semibold text-gray-300 mb-3">Recent Events</h4>
        <div class="h-full overflow-auto space-y-2">
          <!-- RPC Events -->
          <%= for e <- Enum.take(@chain_events, 5) do %>
            <div class="bg-blue-900/20 rounded-lg p-2">
              <div class="text-xs text-blue-300">RPC Call</div>
              <div class="text-xs text-gray-400">
                <span class="text-sky-300"><%= e.method %></span> via 
                <span class="text-emerald-300"><%= e.provider_id %></span> 
                (<span class="text-yellow-300"><%= e.duration_ms %>ms</span>)
              </div>
            </div>
          <% end %>
          
          <!-- Provider Events -->
          <%= for e <- Enum.take(@chain_provider_events, 5) do %>
            <div class="bg-orange-900/20 rounded-lg p-2">
              <div class="text-xs text-orange-300">Provider Event</div>
              <div class="text-xs text-gray-400">
                <span class="text-emerald-300"><%= e.provider_id %></span>: 
                <span class="text-orange-300"><%= e.event %></span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def provider_details_panel(assigns) do
    assigns =
      assigns
      |> assign(:provider_connection, Enum.find(assigns.connections, &(&1.id == assigns.provider)))
      |> assign(:provider_events, Enum.filter(assigns.routing_events, &(&1.provider_id == assigns.provider)))
      |> assign(:provider_pool_events, Enum.filter(assigns.provider_events, &(&1.provider_id == assigns.provider)))
    
    ~H"""
    <div class="flex flex-col h-full">
      <!-- Header -->
      <div class="p-4 border-b border-gray-700/50">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-lg font-semibold text-white">
              <%= if @provider_connection, do: @provider_connection.name, else: @provider %>
            </h3>
            <%= if @provider_connection do %>
              <div class="text-sm text-gray-400 mt-1">
                Chain: <span class="text-purple-300 capitalize"><%= @provider_connection.chain %></span>
              </div>
            <% end %>
          </div>
          <div class="flex items-center space-x-2">
            <%= if assigns[:selected_chain] do %>
              <button 
                phx-click="select_provider" 
                phx-value-provider="" 
                class="text-gray-400 hover:text-white text-sm px-2 py-1 rounded border border-gray-600 hover:border-gray-400 transition-colors"
              >
                Back to Chain
              </button>
            <% end %>
            <button phx-click="select_provider" phx-value-provider="" class="text-gray-400 hover:text-white">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
              </svg>
            </button>
          </div>
        </div>
      </div>
      
      <!-- Provider Stats -->
      <%= if @provider_connection do %>
        <div class="p-4 border-b border-gray-700/50">
          <div class="grid grid-cols-2 gap-4">
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Status</div>
              <div class={[
                "text-sm font-bold",
                case @provider_connection.status do
                  :connected -> "text-emerald-400"
                  :disconnected -> "text-red-400"
                  _ -> "text-yellow-400"
                end
              ]}>
                <%= String.upcase(to_string(@provider_connection.status)) %>
              </div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Subscriptions</div>
              <div class="text-sm font-bold text-white"><%= @provider_connection.subscriptions %></div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Failures</div>
              <div class="text-sm font-bold text-red-400"><%= @provider_connection.reconnect_attempts %></div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3">
              <div class="text-xs text-gray-400">Last Seen</div>
              <div class="text-xs text-gray-300">
                <%= format_last_seen(@provider_connection.last_seen) %>
              </div>
            </div>
          </div>
        </div>
      <% end %>
      
      <!-- Recent Activity -->
      <div class="flex-1 p-4 overflow-hidden">
        <h4 class="text-sm font-semibold text-gray-300 mb-3">Recent Activity</h4>
        <div class="h-full overflow-auto space-y-2">
          <!-- RPC Calls -->
          <%= for e <- Enum.take(@provider_events, 10) do %>
            <div class="bg-blue-900/20 rounded-lg p-2">
              <div class="text-xs text-blue-300">RPC Call</div>
              <div class="text-xs text-gray-400">
                <span class="text-sky-300"><%= e.method %></span> on 
                <span class="text-purple-300 capitalize"><%= e.chain %></span> 
                (<span class="text-yellow-300"><%= e.duration_ms %>ms</span>)
                <span class={[
                  "ml-2",
                  case e.result do
                    :success -> "text-emerald-400"
                    :error -> "text-red-400"
                    _ -> "text-gray-400"
                  end
                ]}>
                  <%= String.upcase(to_string(e.result)) %>
                </span>
              </div>
            </div>
          <% end %>
          
          <!-- Provider Pool Events -->
          <%= for e <- Enum.take(@provider_pool_events, 10) do %>
            <div class="bg-orange-900/20 rounded-lg p-2">
              <div class="text-xs text-orange-300">Pool Event</div>
              <div class="text-xs text-gray-400">
                <span class="text-orange-300"><%= e.event %></span>
                <%= if e.details do %>
                  <span class="text-gray-500">- <%= inspect(e.details) %></span>
                <% end %>
              </div>
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
      phx-hook="SimulatorControl"
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
    {:noreply, assign(socket, :selected_chain, nil)}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => chain}, socket) do
    {:noreply, assign(socket, :selected_chain, chain)}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => ""}, socket) do
    {:noreply, assign(socket, :selected_provider, nil)}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :selected_provider, provider)}
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

  defp fetch_connections(socket) do
    connections = Livechain.RPC.ChainRegistry.list_all_connections()

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end

  defp start_demo_connections do
    # Note: Demo connections are now handled by the chain supervisors
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
end
