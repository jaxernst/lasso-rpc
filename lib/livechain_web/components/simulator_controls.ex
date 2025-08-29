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
      |> assign_new(:simulator_running, fn -> false end)
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

    socket = socket
    |> assign(:simulator_running, true)
    |> push_event("sim_start_http_advanced", opts)
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

    socket = socket
    |> assign(:simulator_running, true)
    |> push_event("sim_start_ws_advanced", opts)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_stop_all", _params, socket) do
    socket = socket
    |> assign(:simulator_running, false)
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
    |> assign(:simulator_running, true)
    |> push_event("sim_start_http_advanced", http_opts)
    |> push_event("sim_start_ws_advanced", ws_opts)

    {:noreply, socket}
  end

  # Handle stats updates from JavaScript
  @impl true
  def handle_event("sim_stats", %{"http" => http, "ws" => ws}, socket) do
    new_stats = %{http: http, ws: ws}
    
    # Auto-detect if simulator has stopped (no inflight requests and no connections)
    simulator_actually_running = get_stat(new_stats, :http, "inflight", 0) > 0 or 
                                get_stat(new_stats, :ws, "open", 0) > 0
    
    socket = socket
    |> assign(:sim_stats, new_stats)
    |> assign(:simulator_running, simulator_actually_running)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_recent_calls", %{"calls" => calls}, socket) do
    {:noreply, assign(socket, :recent_calls, calls)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pointer-events-none absolute top-4 left-4 z-30">
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300",
                   if(@sim_collapsed, do: "w-64", else: "w-80 max-h-[70vh]")]}>
        <!-- Header -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class={["h-2 w-2 rounded-full", if(is_simulator_active(@sim_stats, @simulator_running), do: "bg-emerald-400 animate-pulse", else: "bg-gray-500")]}></div>
            <div class="truncate text-xs font-medium text-white">
              Network Simulator
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%= if @sim_collapsed do %>
              <div class="flex items-center gap-1">
                <%= if is_simulator_active(@sim_stats, @simulator_running) do %>
                  <button phx-click="sim_stop_all" phx-target={@myself} 
                          class="bg-red-600/20 hover:bg-red-600/30 border border-red-500/40 text-red-300 rounded px-2 py-1 text-xs transition-all duration-200">
                    <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>
                    </svg>
                  </button>
                <% else %>
                  <button phx-click="sim_start_load_test" phx-target={@myself} 
                          class="bg-emerald-600/20 hover:bg-emerald-600/30 border border-emerald-500/40 text-emerald-300 rounded px-2 py-1 text-xs transition-all duration-200">
                    <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M8 5v14l11-7z"/>
                    </svg>
                  </button>
                <% end %>
              </div>
            <% end %>
            <button
              phx-click="toggle_collapsed"
              phx-target={@myself}
              class="bg-gray-800/60 hover:bg-gray-700/60 rounded px-2 py-1 text-xs text-gray-200 transition-all duration-200"
            >
              {if @sim_collapsed, do: "↖", else: "↗"}
            </button>
          </div>
        </div>

        <!-- Collapsed content - minimal stats -->
        <%= if @sim_collapsed do %>
          <.collapsed_content 
            sim_stats={@sim_stats} 
            myself={@myself} />
        <% else %>
          <!-- Expanded content - full control panel -->
          <div class="max-h-[60vh] overflow-y-auto">
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
    <div class="px-3 py-2 space-y-1.5">
      <!-- Ultra Compact Stats -->
      <div class="flex justify-between items-center text-[10px]">
        <span class="text-gray-400">Success/Errors</span>
        <span class="font-mono">
          <span class="text-emerald-400">{get_stat(@sim_stats, :http, "success", 0)}</span>
          <span class="text-gray-500">/</span>
          <span class="text-red-400">{get_stat(@sim_stats, :http, "error", 0)}</span>
        </span>
      </div>
      
      <div class="flex justify-between items-center text-[10px]">
        <span class="text-gray-400">Latency</span>
        <span class="text-yellow-400 font-mono">
          {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms
        </span>
      </div>
    </div>
    """
  end

  defp expanded_content(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <!-- Chain Selection -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="text-xs font-medium text-white">Target Chains</label>
          <button phx-click="select_all_chains" phx-target={@myself} 
                  class="text-[10px] text-sky-400 hover:text-sky-300 transition-colors px-2 py-0.5 rounded border border-sky-500/30 hover:border-sky-400/50">All</button>
        </div>
        <div class="flex flex-wrap gap-1">
          <%= if length(@available_chains) > 0 do %>
            <%= for chain <- @available_chains do %>
              <button phx-click="toggle_chain_selection"
                      phx-value-chain={chain.name}
                      phx-target={@myself}
                      class={["px-2 py-1 rounded-full text-[10px] font-medium transition-all duration-200",
                             if(chain.name in (@selected_chains || []), 
                                do: "border border-sky-500 bg-sky-500/20 text-sky-300", 
                                else: "border border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300")]}>
                {chain.display_name}
              </button>
            <% end %>
          <% else %>
            <div class="text-center py-2 text-[10px] text-gray-400">No chains available</div>
          <% end %>
        </div>
      </div>

      <!-- Strategy Selection -->
      <div class="space-y-2">
        <label class="text-xs font-medium text-white">Routing Strategy</label>
        <div class="flex flex-wrap gap-1">
          <%= for {strategy, label, emoji} <- [["fastest", "Fastest", "⚡"], ["leaderboard", "Leaderboard", "🏆"], ["priority", "Priority", "⭐"], ["round-robin", "Round Robin", "🔄"]] do %>
            <button phx-click="select_strategy"
                    phx-value-strategy={strategy}
                    phx-target={@myself}
                    class={["px-2 py-1 rounded-full text-[10px] font-medium transition-all duration-200 flex items-center gap-1",
                           if(@selected_strategy == strategy, 
                              do: "border border-purple-500 bg-purple-500/20 text-purple-300", 
                              else: "border border-gray-600 text-gray-300 hover:border-purple-400 hover:text-purple-300")]}>
              <span>{emoji}</span>
              <span>{label}</span>
            </button>
          <% end %>
        </div>
      </div>

      <!-- Request Rate Control -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="text-xs font-medium text-white">Request Rate</label>
          <div class="bg-orange-500/20 border border-orange-500/30 rounded px-2 py-0.5">
            <span class="text-xs text-orange-300 font-mono font-bold">{@request_rate}</span>
            <span class="text-[10px] text-orange-400 ml-1">RPS</span>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button phx-click="decrease_rate" phx-target={@myself} class="p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-300 transition-all duration-200">
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 12H4" />
            </svg>
          </button>
          <input type="range"
                 min="1"
                 max="50"
                 value={@request_rate}
                 phx-change="update_rate"
                 phx-target={@myself}
                 name="rate"
                 class="flex-1 h-1 bg-gray-700 rounded appearance-none cursor-pointer accent-orange-500" />
          <button phx-click="increase_rate" phx-target={@myself} class="p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-300 transition-all duration-200">
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
          </button>
        </div>
      </div>

      <!-- Action Controls -->
      <div class="space-y-2">
        <div class="grid grid-cols-2 gap-2">
          <button phx-click="sim_http_start_advanced"
                  phx-target={@myself}
                  class="flex items-center justify-center gap-1 py-2 px-2 rounded-lg bg-sky-600/20 hover:bg-sky-600/30 border border-sky-500/40 text-sky-300 text-xs font-medium transition-all duration-200">
            <span>HTTP</span>
          </button>
          <button phx-click="sim_ws_start_advanced"
                  phx-target={@myself}
                  class="flex items-center justify-center gap-1 py-2 px-2 rounded-lg bg-purple-600/20 hover:bg-purple-600/30 border border-purple-500/40 text-purple-300 text-xs font-medium transition-all duration-200">
            <span>WS</span>
          </button>
        </div>
        
        <button phx-click="sim_start_load_test"
                phx-target={@myself}
                class="w-full flex items-center justify-center gap-1 py-2 px-3 rounded-lg bg-emerald-600/20 hover:bg-emerald-600/30 border border-emerald-500/40 text-emerald-300 text-xs font-medium transition-all duration-200">
          <span>Full Load Test</span>
        </button>
        
        <div class="grid grid-cols-2 gap-2">
          <button phx-click="sim_stop_all"
                  phx-target={@myself}
                  class="py-1.5 px-2 rounded-lg bg-red-600/20 hover:bg-red-600/30 border border-red-500/40 text-red-300 text-xs font-medium transition-all duration-200">
            Stop All
          </button>
          <button phx-click="clear_sim_logs"
                  phx-target={@myself}
                  class="py-1.5 px-2 rounded-lg border border-gray-600/40 bg-gray-800/60 text-gray-300 hover:border-gray-500/60 hover:text-white hover:bg-gray-700/60 text-xs transition-all duration-200">
            Clear
          </button>
        </div>
      </div>

      <!-- Compact Stats -->
      <div class="bg-gray-800/40 rounded-lg p-2 space-y-1">
        <div class="text-[10px] text-gray-400 font-medium">Live Stats</div>
        <div class="grid grid-cols-2 gap-2 text-[10px]">
          <div class="flex justify-between">
            <span class="text-gray-400">HTTP:</span>
            <span class="text-emerald-400 font-mono">{get_stat(@sim_stats, :http, "success", 0)}/{get_stat(@sim_stats, :http, "error", 0)}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-gray-400">WS:</span>
            <span class="text-purple-400 font-mono">{get_stat(@sim_stats, :ws, "open", 0)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end


  # Helper functions
  defp is_simulator_active(sim_stats, simulator_running) do
    # Check if simulator is actively running based on inflight requests or open connections
    (get_stat(sim_stats, :http, "inflight", 0) > 0 or 
     get_stat(sim_stats, :ws, "open", 0) > 0) or simulator_running
  end

  defp get_stat(sim_stats, type, key, default) do
    # JavaScript sends string keys for both outer and inner maps
    type_string = to_string(type)
    key_string = to_string(key)
    
    case sim_stats do
      %{^type_string => stats} when is_map(stats) ->
        Map.get(stats, key_string, default)
      %{^type => stats} when is_map(stats) ->
        # Fallback for atom keys
        atom_key = if is_atom(key), do: key, else: String.to_atom(key)
        Map.get(stats, atom_key, default)
      _ -> 
        default
    end
  end
end