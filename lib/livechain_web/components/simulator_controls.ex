defmodule LivechainWeb.Dashboard.Components.SimulatorControls do
  use LivechainWeb, :live_component
  alias LivechainWeb.Dashboard.Helpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:sim_stats, fn ->
        %{http: %{success: 0, error: 0, avgLatencyMs: 0.0, inflight: 0}, ws: %{open: 0}}
      end)
      |> assign_new(:sim_collapsed, fn -> true end)
      |> assign_new(:selected_chains, fn -> [] end)
      |> assign_new(:selected_strategy, fn -> "fastest" end)
      |> assign_new(:request_rate, fn -> 5 end)
      |> assign_new(:recent_calls, fn -> [] end)
      |> assign_new(:available_chains, fn -> [] end)

    # Handle specific updates from Dashboard forwarding
    socket = 
      if Map.has_key?(assigns, :sim_stats) do
        assign(socket, :sim_stats, assigns.sim_stats)
      else
        socket
      end

    socket = 
      if Map.has_key?(assigns, :recent_calls) do
        assign(socket, :recent_calls, assigns.recent_calls)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_collapsed", _params, socket) do
    {:noreply, update(socket, :sim_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("sim_http_start", _params, socket) do
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
  def handle_event("sim_start_load_test", _params, socket) do
    selected_chains = socket.assigns.selected_chains
    chains = if length(selected_chains) > 0 do
      selected_chains
    else
      Enum.map(socket.assigns.available_chains, & &1.name)
    end

    http_opts = %{
      chains: chains,
      methods: ["eth_blockNumber", "eth_getBalance"],
      rps: socket.assigns.request_rate,
      concurrency: 4,
      strategy: socket.assigns.selected_strategy,
      durationMs: 60_000
    }

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

  # Handle stats updates from JavaScript
  @impl true
  def handle_event("sim_stats", %{"http" => http, "ws" => ws}, socket) do
    {:noreply, assign(socket, :sim_stats, %{http: http, ws: ws})}
  end

  @impl true
  def handle_event("update_recent_calls", %{"calls" => calls}, socket) do
    {:noreply, assign(socket, :recent_calls, calls)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pointer-events-none absolute top-4 left-4 z-30">
      <div class={["border-slate-700/40 bg-slate-900/90 pointer-events-auto rounded-2xl border shadow-2xl backdrop-blur-xl transition-all duration-300 backdrop-saturate-150",
                   if(@sim_collapsed, do: "w-80", else: "w-96 max-h-[90vh]")]}>
        <!-- Header -->
        <div class="border-slate-700/30 flex items-center justify-between border-b px-4 py-3">
          <div class="flex min-w-0 items-center gap-3">
            <div class={["h-2.5 w-2.5 rounded-full", if(is_simulator_active(@sim_stats), do: "bg-emerald-400 animate-pulse shadow-lg shadow-emerald-400/50", else: "bg-slate-500")]}></div>
            <div class="truncate text-sm font-medium text-white">
              <%= if is_simulator_active(@sim_stats) do %>
                Load Test Running
              <% else %>
                Network Simulator
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <%= if @sim_collapsed do %>
              <div class="text-xs flex items-center space-x-4 text-slate-400">
                <div class="flex items-center gap-1">
                  <div class="h-1.5 w-1.5 rounded-full bg-emerald-400"></div>
                  <span class="text-emerald-300 font-mono">{get_stat(@sim_stats, :http, "success", 0)}</span>
                </div>
                <div class="flex items-center gap-1">
                  <div class="h-1.5 w-1.5 rounded-full bg-rose-400"></div>
                  <span class="text-rose-300 font-mono">{get_stat(@sim_stats, :http, "error", 0)}</span>
                </div>
                <span class="text-amber-300 font-mono">{get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms</span>
              </div>
            <% end %>
            <button
              phx-click="toggle_collapsed"
              phx-target={@myself}
              class="bg-slate-800/60 hover:bg-slate-700/80 rounded-lg px-2.5 py-1.5 text-xs text-slate-200 transition-all duration-200 border border-slate-600/40"
            >
              <svg class={["w-3 h-3 transition-transform duration-200", if(@sim_collapsed, do: "rotate-45", else: "-rotate-45")]} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 8V4m0 0h4M4 4l5 5m11-1V4m0 0h-4m4 0l-5 5M4 16v4m0 0h4m-4 0l5-5m11 5l-5-5m5 5v-4m0 4h-4" />
              </svg>
            </button>
          </div>
        </div>

        <!-- Collapsed content - quick actions only -->
        <%= if @sim_collapsed do %>
          <.collapsed_content 
            sim_stats={@sim_stats} 
            myself={@myself} />
        <% else %>
          <!-- Expanded content - full control panel -->
          <div class="max-h-[80vh] overflow-y-auto">
            <.expanded_content 
              sim_stats={@sim_stats}
              available_chains={@available_chains}
              selected_chains={@selected_chains}
              selected_strategy={@selected_strategy}
              request_rate={@request_rate}
              recent_calls={@recent_calls}
              myself={@myself} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp collapsed_content(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <!-- Quick Launch Buttons -->
      <div class="grid grid-cols-2 gap-2">
        <button phx-click="sim_http_start"
                phx-target={@myself}
                class="group flex items-center justify-center gap-2 px-3 py-2.5 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-700 hover:to-indigo-700 text-white text-sm font-medium transition-all duration-200 shadow-lg hover:shadow-blue-500/25 border border-blue-500/20">
          <svg class="w-4 h-4 group-hover:scale-110 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
          </svg>
          <span>HTTP</span>
        </button>
        <button phx-click="sim_ws_start"
                phx-target={@myself}
                class="group flex items-center justify-center gap-2 px-3 py-2.5 rounded-xl bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 text-white text-sm font-medium transition-all duration-200 shadow-lg hover:shadow-purple-500/25 border border-purple-500/20">
          <svg class="w-4 h-4 group-hover:scale-110 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 717.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
          </svg>
          <span>WS</span>
        </button>
      </div>
      
      <!-- Stop Controls -->
      <div class="flex gap-2">
        <button phx-click="sim_http_stop" 
                phx-target={@myself} 
                class="flex-1 px-3 py-1.5 rounded-lg bg-slate-800/80 hover:bg-slate-700/80 text-slate-300 text-xs transition-all duration-200 border border-slate-600/40">
          Stop HTTP
        </button>
        <button phx-click="sim_ws_stop" 
                phx-target={@myself} 
                class="flex-1 px-3 py-1.5 rounded-lg bg-slate-800/80 hover:bg-slate-700/80 text-slate-300 text-xs transition-all duration-200 border border-slate-600/40">
          Stop WS
        </button>
      </div>

      <!-- Live Stats Cards -->
      <div class="grid grid-cols-2 gap-3">
        <div class="bg-gradient-to-br from-blue-900/20 to-indigo-900/20 border border-blue-500/20 rounded-xl p-3">
          <div class="text-blue-300 text-xs font-medium mb-2 flex items-center gap-1">
            <div class="h-1.5 w-1.5 rounded-full bg-blue-400"></div>
            HTTP Load
          </div>
          <div class="space-y-1.5">
            <div class="flex justify-between text-xs">
              <span class="text-slate-400">Success:</span>
              <span class="text-emerald-400 font-mono">{get_stat(@sim_stats, :http, "success", 0)}</span>
            </div>
            <div class="flex justify-between text-xs">
              <span class="text-slate-400">Errors:</span>
              <span class="text-rose-400 font-mono">{get_stat(@sim_stats, :http, "error", 0)}</span>
            </div>
            <div class="flex justify-between text-xs">
              <span class="text-slate-400">Latency:</span>
              <span class="text-amber-400 font-mono">
                {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms
              </span>
            </div>
          </div>
        </div>
        
        <div class="bg-gradient-to-br from-purple-900/20 to-pink-900/20 border border-purple-500/20 rounded-xl p-3">
          <div class="text-purple-300 text-xs font-medium mb-2 flex items-center gap-1">
            <div class="h-1.5 w-1.5 rounded-full bg-purple-400"></div>
            WebSocket
          </div>
          <div class="space-y-1.5">
            <div class="flex justify-between text-xs">
              <span class="text-slate-400">Open:</span>
              <span class="text-emerald-400 font-mono">{get_stat(@sim_stats, :ws, "open", 0)}</span>
            </div>
            <div class="flex justify-between text-xs">
              <span class="text-slate-400">Topics:</span>
              <span class="text-purple-400 font-mono">Live</span>
            </div>
            <div class="flex justify-between text-xs">
              <span class="text-slate-400">Status:</span>
              <span class={"font-mono text-xs #{if get_stat(@sim_stats, :ws, "open", 0) > 0, do: "text-emerald-400", else: "text-slate-500"}"}>
                {if get_stat(@sim_stats, :ws, "open", 0) > 0, do: "Active", else: "Idle"}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp expanded_content(assigns) do
    ~H"""
    <div class="p-5 space-y-6">
      <!-- Chain Selection -->
      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <label class="text-sm font-semibold text-white flex items-center gap-2">
            <svg class="w-4 h-4 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
            </svg>
            Target Chains
          </label>
          <button phx-click="select_all_chains" phx-target={@myself} class="text-xs text-blue-400 hover:text-blue-300 transition-colors px-2 py-1 rounded-md border border-blue-500/30 hover:border-blue-400/50">Select All</button>
        </div>
        <div class="bg-slate-800/30 border border-slate-700/40 rounded-xl p-3">
          <div class="grid grid-cols-1 gap-2 max-h-32 overflow-y-auto">
            <%= if length(@available_chains) > 0 do %>
              <%= for chain <- @available_chains do %>
                <label class="flex items-center gap-3 cursor-pointer group hover:bg-slate-700/30 rounded-lg p-2 transition-all duration-200">
                  <input type="checkbox"
                         name="selected_chains[]"
                         value={chain.name}
                         checked={chain.name in (@selected_chains || [])}
                         phx-click="toggle_chain_selection"
                         phx-value-chain={chain.name}
                         phx-target={@myself}
                         class="rounded border-slate-500 bg-slate-700 text-blue-600 focus:ring-blue-500 focus:ring-2 w-4 h-4" />
                  <span class="text-sm text-slate-300 group-hover:text-white transition-colors font-medium">{chain.display_name}</span>
                  <span class="text-xs text-slate-500 ml-auto">{chain.name}</span>
                </label>
              <% end %>
            <% else %>
              <div class="text-center py-4">
                <div class="text-slate-400 text-sm">No chains available</div>
                <div class="text-slate-500 text-xs">Configure chains in settings</div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Strategy Selection -->
      <div class="space-y-3">
        <label class="text-sm font-semibold text-white flex items-center gap-2">
          <svg class="w-4 h-4 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
          </svg>
          Routing Strategy
        </label>
        <div class="bg-slate-800/30 border border-slate-700/40 rounded-xl p-3">
          <div class="grid grid-cols-2 gap-2">
            <%= for {strategy, label, emoji} <- [["fastest", "Fastest", "⚡"], ["leaderboard", "Leaderboard", "🏆"], ["priority", "Priority", "⭐"], ["round-robin", "Round Robin", "🔄"]] do %>
              <button phx-click="select_strategy"
                      phx-value-strategy={strategy}
                      phx-target={@myself}
                      class={["px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 border flex items-center gap-2",
                             if(@selected_strategy == strategy, 
                                do: "border-blue-500 bg-blue-500/20 text-blue-300 shadow-lg shadow-blue-500/20", 
                                else: "border-slate-600 bg-slate-700/50 text-slate-300 hover:border-blue-400 hover:text-blue-300 hover:bg-slate-600/50")]}>
                <span class="text-base">{emoji}</span>
                <span>{label}</span>
              </button>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Request Rate Control -->
      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <label class="text-sm font-semibold text-white flex items-center gap-2">
            <svg class="w-4 h-4 text-orange-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            Request Rate
          </label>
          <div class="bg-orange-500/20 border border-orange-500/30 rounded-lg px-3 py-1">
            <span class="text-sm text-orange-300 font-mono font-bold">{@request_rate}</span>
            <span class="text-xs text-orange-400 ml-1">RPS</span>
          </div>
        </div>
        <div class="bg-slate-800/30 border border-slate-700/40 rounded-xl p-4">
          <div class="flex items-center gap-4">
            <button phx-click="decrease_rate" phx-target={@myself} class="p-2 rounded-lg bg-slate-700 hover:bg-slate-600 text-slate-300 transition-all duration-200 border border-slate-600">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 12H4" />
              </svg>
            </button>
            <div class="flex-1 relative">
              <input type="range"
                     min="1"
                     max="50"
                     value={@request_rate}
                     phx-change="update_rate"
                     phx-target={@myself}
                     name="rate"
                     class="w-full h-2 bg-slate-700 rounded-lg appearance-none cursor-pointer accent-orange-500" />
              <div class="absolute -bottom-4 left-0 right-0 flex justify-between text-xs text-slate-500">
                <span>1</span>
                <span>25</span>
                <span>50</span>
              </div>
            </div>
            <button phx-click="increase_rate" phx-target={@myself} class="p-2 rounded-lg bg-slate-700 hover:bg-slate-600 text-slate-300 transition-all duration-200 border border-slate-600">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
              </svg>
            </button>
          </div>
        </div>
      </div>

      <!-- Action Controls -->
      <div class="space-y-4">
        <div class="grid grid-cols-2 gap-3">
          <button phx-click="sim_http_start_advanced"
                  phx-target={@myself}
                  class="group flex items-center justify-center gap-2 py-3 px-4 rounded-xl bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-700 hover:to-indigo-700 text-white font-medium transition-all duration-200 shadow-lg hover:shadow-blue-500/30 border border-blue-500/30">
            <svg class="w-5 h-5 group-hover:scale-110 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            <span>HTTP Load</span>
          </button>
          <button phx-click="sim_ws_start_advanced"
                  phx-target={@myself}
                  class="group flex items-center justify-center gap-2 py-3 px-4 rounded-xl bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 text-white font-medium transition-all duration-200 shadow-lg hover:shadow-purple-500/30 border border-purple-500/30">
            <svg class="w-5 h-5 group-hover:scale-110 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 717.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
            </svg>
            <span>WS Load</span>
          </button>
        </div>
        
        <button phx-click="sim_start_load_test"
                phx-target={@myself}
                class="w-full group flex items-center justify-center gap-3 py-3 px-4 rounded-xl bg-gradient-to-r from-emerald-600 to-green-600 hover:from-emerald-700 hover:to-green-700 text-white font-semibold transition-all duration-200 shadow-lg hover:shadow-emerald-500/30 border border-emerald-500/30">
          <svg class="w-5 h-5 group-hover:scale-110 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
          </svg>
          <span>Full Load Test</span>
        </button>
        
        <div class="grid grid-cols-2 gap-3">
          <button phx-click="sim_stop_all"
                  phx-target={@myself}
                  class="py-2.5 px-4 rounded-xl bg-red-600/20 hover:bg-red-600/30 border border-red-500/40 text-red-300 font-medium transition-all duration-200">
            Stop All
          </button>
          <button phx-click="clear_sim_logs"
                  phx-target={@myself}
                  class="py-2.5 px-4 rounded-xl border border-slate-600/40 bg-slate-800/60 text-slate-300 hover:border-slate-500/60 hover:text-white hover:bg-slate-700/60 transition-all duration-200">
            Clear Logs
          </button>
        </div>
      </div>

      <!-- Live Activity Feed -->
      <.activity_feed recent_calls={@recent_calls} />

      <!-- Enhanced Stats Display -->
      <.stats_display sim_stats={@sim_stats} />
    </div>
    """
  end

  defp activity_feed(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <label class="text-sm font-semibold text-white flex items-center gap-2">
          <svg class="w-4 h-4 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
          </svg>
          Live Activity
        </label>
        <div class="flex items-center gap-2 bg-green-500/10 border border-green-500/30 rounded-lg px-2 py-1">
          <div class="w-2 h-2 rounded-full bg-green-400 animate-pulse shadow-lg shadow-green-400/50"></div>
          <span class="text-xs text-green-300 font-medium">Real-time</span>
        </div>
      </div>
      <div class="bg-slate-900/50 border border-slate-700/50 rounded-xl p-4 h-40 overflow-y-auto">
        <div class="space-y-2 text-sm font-mono">
          <%= if length(@recent_calls || []) > 0 do %>
            <%= for call <- Enum.take(@recent_calls || [], 10) do %>
              <div class="flex items-center justify-between py-1.5 px-2 rounded-lg bg-slate-800/40 border border-slate-700/30">
                <div class="flex items-center gap-3">
                  <span class={"w-2 h-2 rounded-full #{if call[:type] == :http, do: "bg-blue-400 shadow-lg shadow-blue-400/50", else: "bg-purple-400 shadow-lg shadow-purple-400/50"}"}></span>
                  <div class="flex items-center gap-2 text-xs">
                    <span class="text-slate-400">{call[:method] || "subscribe"}</span>
                    <svg class="w-3 h-3 text-slate-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7l5 5m0 0l-5 5m5-5H6" />
                    </svg>
                    <span class="text-slate-300 font-medium">{call[:chain]}</span>
                  </div>
                </div>
                <div class="flex items-center gap-3">
                  <div class={"w-5 h-5 rounded-full flex items-center justify-center #{if call[:status] == :success, do: "bg-emerald-500/20 text-emerald-400", else: "bg-rose-500/20 text-rose-400"}"}>
                    <span class="text-xs font-bold">
                      {if call[:status] == :success, do: "✓", else: "✗"}
                    </span>
                  </div>
                  <%= if call[:latency] do %>
                    <span class="text-amber-400 text-xs font-mono bg-amber-500/10 px-2 py-0.5 rounded">
                      {call[:latency]}ms
                    </span>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% else %>
            <div class="text-center text-slate-400 py-8">
              <div class="w-12 h-12 mx-auto mb-3 rounded-full bg-slate-800/50 border border-slate-700/50 flex items-center justify-center">
                <svg class="w-6 h-6 opacity-60" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                </svg>
              </div>
              <div class="text-sm font-medium text-slate-300">No activity yet</div>
              <div class="text-xs text-slate-500 mt-1">Start a load test to see live requests</div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp stats_display(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-4">
      <div class="bg-gradient-to-br from-blue-900/20 to-indigo-900/20 border border-blue-500/30 rounded-xl p-4">
        <div class="flex items-center justify-between mb-3">
          <div class="text-sm font-semibold text-blue-300 flex items-center gap-2">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            HTTP Load
          </div>
          <div class="text-xs text-slate-500 bg-slate-800/40 px-2 py-1 rounded-md">RPC</div>
        </div>
        <div class="space-y-2">
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Success:</span>
            <span class="text-emerald-400 font-mono font-bold text-sm bg-emerald-500/10 px-2 py-1 rounded">
              {get_stat(@sim_stats, :http, "success", 0)}
            </span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Errors:</span>
            <span class="text-rose-400 font-mono font-bold text-sm bg-rose-500/10 px-2 py-1 rounded">
              {get_stat(@sim_stats, :http, "error", 0)}
            </span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Latency:</span>
            <span class="text-amber-400 font-mono font-bold text-sm bg-amber-500/10 px-2 py-1 rounded">
              {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms
            </span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">In Flight:</span>
            <span class="text-blue-400 font-mono font-bold text-sm bg-blue-500/10 px-2 py-1 rounded">
              {get_stat(@sim_stats, :http, "inflight", 0)}
            </span>
          </div>
        </div>
      </div>
      
      <div class="bg-gradient-to-br from-purple-900/20 to-pink-900/20 border border-purple-500/30 rounded-xl p-4">
        <div class="flex items-center justify-between mb-3">
          <div class="text-sm font-semibold text-purple-300 flex items-center gap-2">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 717.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
            </svg>
            WebSocket
          </div>
          <div class="text-xs text-slate-500 bg-slate-800/40 px-2 py-1 rounded-md">Sub</div>
        </div>
        <div class="space-y-2">
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Open:</span>
            <span class="text-emerald-400 font-mono font-bold text-sm bg-emerald-500/10 px-2 py-1 rounded">
              {get_stat(@sim_stats, :ws, "open", 0)}
            </span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Topics:</span>
            <span class="text-purple-400 font-mono text-sm bg-purple-500/10 px-2 py-1 rounded">newHeads</span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Status:</span>
            <span class={"font-mono text-sm px-2 py-1 rounded #{if get_stat(@sim_stats, :ws, "open", 0) > 0, do: "text-emerald-400 bg-emerald-500/10", else: "text-slate-500 bg-slate-500/10"}"}>
              {if get_stat(@sim_stats, :ws, "open", 0) > 0, do: "Active", else: "Idle"}
            </span>
          </div>
          <div class="flex justify-between items-center">
            <span class="text-slate-400 text-sm">Messages:</span>
            <span class="text-blue-400 font-mono text-sm bg-blue-500/10 px-2 py-1 rounded">Live</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp is_simulator_active(sim_stats) do
    get_stat(sim_stats, :http, "success", 0) > 0 or 
    get_stat(sim_stats, :http, "inflight", 0) > 0 or 
    get_stat(sim_stats, :ws, "open", 0) > 0
  end

  defp get_stat(sim_stats, type, key, default) do
    case sim_stats do
      %{^type => stats} when is_map(stats) ->
        Map.get(stats, key, nil) || Map.get(stats, String.to_atom(key), default)
      _ -> default
    end
  end
end