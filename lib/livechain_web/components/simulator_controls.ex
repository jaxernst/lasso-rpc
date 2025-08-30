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
      |> assign_new(:run_duration, fn -> 30 end)
      |> assign_new(:run_type, fn -> "load_test" end)
      |> assign_new(:recent_calls, fn -> [] end)
      |> assign_new(:available_chains, fn -> [] end)
      |> assign_new(:active_runs, fn -> [] end)
      |> assign_new(:quick_run_config, fn -> get_default_run_config() end)

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

    socket =
      if Map.has_key?(assigns, :simulator_running) do
        assign(socket, :simulator_running, assigns.simulator_running)
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

    new_selected =
      if chain in selected do
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

    chains =
      if length(selected_chains) > 0 do
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

    socket =
      socket
      |> assign(:simulator_running, true)
      |> push_event("sim_start_http_advanced", opts)

    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_ws_start_advanced", _params, socket) do
    selected_chains = socket.assigns.selected_chains

    chains =
      if length(selected_chains) > 0 do
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

    socket =
      socket
      |> assign(:simulator_running, true)
      |> push_event("sim_start_ws_advanced", opts)

    {:noreply, socket}
  end

  @impl true
  def handle_event("sim_stop_all", _params, socket) do
    socket =
      socket
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

    chains =
      if length(selected_chains) > 0 do
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

    socket =
      socket
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
    simulator_actually_running =
      get_stat(new_stats, :http, "inflight", 0) > 0 or
        get_stat(new_stats, :ws, "open", 0) > 0

    socket =
      socket
      |> assign(:sim_stats, new_stats)
      |> assign(:simulator_running, simulator_actually_running)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_recent_calls", %{"calls" => calls}, socket) do
    {:noreply, assign(socket, :recent_calls, calls)}
  end

  @impl true
  def handle_event("active_runs_update", %{"runs" => runs}, socket) do
    # Update simulator_running based on whether there are any active runs
    is_running = length(runs) > 0
    
    socket = 
      socket
      |> assign(:active_runs, runs)
      |> assign(:simulator_running, is_running)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_simulator_run", _params, socket) do
    config = build_run_config(socket)

    socket =
      socket
      |> assign(:simulator_running, true)
      |> push_event("start_simulator_run", config)

    {:noreply, socket}
  end

  @impl true
  def handle_event("quick_start", _params, socket) do
    config = socket.assigns.quick_run_config

    socket =
      socket
      |> assign(:simulator_running, true)
      |> push_event("start_simulator_run", config)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_run_type", %{"type" => type}, socket) do
    new_config =
      case type do
        "load_test" -> get_load_test_config(socket)
        "http_only" -> get_http_only_config(socket)
        "ws_only" -> get_ws_only_config(socket)
        "stress_test" -> get_stress_test_config(socket)
        _ -> get_default_run_config()
      end

    {:noreply, assign(socket, run_type: type, quick_run_config: new_config)}
  end

  @impl true
  def handle_event("update_duration", %{"duration" => duration_str}, socket) do
    duration = String.to_integer(duration_str)
    config = Map.put(socket.assigns.quick_run_config, :duration, duration * 1000)
    {:noreply, assign(socket, run_duration: duration, quick_run_config: config)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pointer-events-none absolute top-4 left-4 z-30">
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300", if(@sim_collapsed, do: "w-64", else: "max-h-[70vh] w-80")]}>
        <!-- Header -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class={["h-2 w-2 rounded-full", if(is_simulator_active(@sim_stats, @simulator_running),
    do: "animate-pulse bg-emerald-400",
    else: "bg-gray-500")]}>
            </div>
            <div class="truncate text-xs font-medium text-white">
              Network Simulator
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle_collapsed"
              phx-target={@myself}
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-all duration-200 hover:bg-gray-700/60"
            >
              {if @sim_collapsed, do: "↖", else: "↗"}
            </button>
          </div>
        </div>
        
    <!-- Collapsed content - minimal stats -->
        <%= if @sim_collapsed do %>
          <.collapsed_content
            sim_stats={@sim_stats}
            simulator_running={@simulator_running}
            quick_run_config={@quick_run_config}
            myself={@myself}
          />
        <% else %>
          <!-- Expanded content - full control panel -->
          <div class="max-h-[60vh] overflow-y-auto">
            <.expanded_content
              sim_stats={@sim_stats}
              available_chains={@available_chains}
              selected_chains={@selected_chains}
              selected_strategy={@selected_strategy}
              request_rate={@request_rate}
              run_duration={@run_duration}
              run_type={@run_type}
              quick_run_config={@quick_run_config}
              active_runs={@active_runs}
              recent_calls={@recent_calls}
              simulator_running={@simulator_running}
              myself={@myself}
            />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp collapsed_content(assigns) do
    ~H"""
    <div class="space-y-2 px-3 py-2">
      <!-- Quick Run Controls -->
      <%= if not @simulator_running do %>
        <div class="flex items-center justify-between">
          <div class="text-[10px] text-gray-400">
            {format_run_config(@quick_run_config)}
          </div>
          <button
            phx-click="quick_start"
            phx-target={@myself}
            class="bg-emerald-600/20 border-emerald-500/40 text-[10px] rounded border px-2 py-0.5 font-medium text-emerald-300 transition-all duration-200 hover:bg-emerald-600/30"
          >
            Start
          </button>
        </div>
      <% else %>
        <!-- Live Stats Display -->
        <div class="space-y-1">
          <div class="text-[10px] flex items-center justify-between">
            <span class="text-gray-400">Requests</span>
            <span class="font-mono">
              <span class="text-emerald-400">{get_stat(@sim_stats, :http, "success", 0)}</span>
              <span class="text-gray-500">/</span>
              <span class="text-red-400">{get_stat(@sim_stats, :http, "error", 0)}</span>
            </span>
          </div>

          <div class="text-[10px] flex items-center justify-between">
            <span class="text-gray-400">Avg Latency</span>
            <span class="font-mono text-yellow-400">
              {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0)
              |> Helpers.to_float()
              |> Float.round(1)}ms
            </span>
          </div>

          <div class="text-[10px] flex items-center justify-between">
            <span class="text-gray-400">Active</span>
            <span class="font-mono">
              <span class="text-sky-400">{get_stat(@sim_stats, :http, "inflight", 0)} HTTP</span>
              <span class="mx-1 text-gray-500">•</span>
              <span class="text-purple-400">{get_stat(@sim_stats, :ws, "open", 0)} WS</span>
            </span>
          </div>
          
          <div class="flex justify-end pt-1">
            <button
              phx-click="sim_stop_all"
              phx-target={@myself}
              class="bg-red-600/20 border-red-500/40 text-[10px] rounded border px-2 py-0.5 font-medium text-red-300 transition-all duration-200 hover:bg-red-600/30"
            >
              Stop
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp expanded_content(assigns) do
    ~H"""
    <div class="space-y-4 p-4">
      <!-- Run Configuration Section -->
      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <h3 class="text-xs font-semibold text-white">Simulation Configuration</h3>
          <%= if @simulator_running do %>
            <div class="flex items-center gap-1">
              <div class="h-2 w-2 animate-pulse rounded-full bg-emerald-400"></div>
              <span class="text-[10px] text-emerald-300">Running</span>
            </div>
          <% end %>
        </div>
        
    <!-- Quick Run Type Selector -->
        <div class="space-y-2">
          <label class="text-[10px] font-medium text-gray-400">Run Type</label>
          <div class="grid grid-cols-2 gap-1">
            <%= for {type, label, desc} <- [
              {"load_test", "Load Test", "HTTP + WS mixed"},
              {"http_only", "HTTP Only", "REST API load"},
              {"ws_only", "WebSocket", "Real-time subs"},
              {"stress_test", "Stress Test", "High throughput"}
            ] do %>
              <button
                phx-click="update_run_type"
                phx-value-type={type}
                phx-target={@myself}
                class={["text-[10px] rounded-lg p-2 text-left transition-all duration-200", if(@run_type == type,
    do: "bg-emerald-500/20 border border-emerald-500 text-emerald-300",
    else: "border-gray-600/40 bg-gray-800/40 border text-gray-300 hover:border-emerald-400/50")]}
              >
                <div class="font-medium">{label}</div>
                <div class="mt-0.5 text-gray-400">{desc}</div>
              </button>
            <% end %>
          </div>
        </div>
        
    <!-- Duration Control -->
        <div class="space-y-2">
          <div class="flex items-center justify-between">
            <label class="text-[10px] font-medium text-gray-400">Duration</label>
            <div class="bg-blue-500/20 border-blue-500/30 rounded border px-2 py-0.5">
              <span class="text-[10px] font-mono text-blue-300">{@run_duration}s</span>
            </div>
          </div>
          <input
            type="range"
            min="5"
            max="300"
            step="5"
            value={@run_duration}
            phx-change="update_duration"
            phx-target={@myself}
            name="duration"
            class="h-1 w-full cursor-pointer appearance-none rounded bg-gray-700 accent-blue-500"
          />
          <div class="text-[9px] flex justify-between text-gray-500">
            <span>5s</span>
            <span>5min</span>
          </div>
        </div>
      </div>
      
    <!-- Advanced Configuration -->
      <div class="border-gray-700/40 space-y-3 border-t pt-4">
        <h4 class="text-[10px] font-medium text-gray-400">Advanced Settings</h4>
        
    <!-- Chain Selection -->
        <div class="space-y-2">
          <div class="flex items-center justify-between">
            <label class="text-[10px] text-gray-400">Target Chains</label>
            <button
              phx-click="select_all_chains"
              phx-target={@myself}
              class="text-[9px] border-sky-500/30 rounded border px-1.5 py-0.5 text-sky-400 transition-colors hover:border-sky-400/50 hover:text-sky-300"
            >
              All
            </button>
          </div>
          <div class="flex flex-wrap gap-1">
            <%= if length(@available_chains) > 0 do %>
              <%= for chain <- @available_chains do %>
                <button
                  phx-click="toggle_chain_selection"
                  phx-value-chain={chain.name}
                  phx-target={@myself}
                  class={["text-[9px] rounded px-2 py-1 font-medium transition-all duration-200", if(chain.name in (@selected_chains || []),
    do: "bg-sky-500/20 border border-sky-500 text-sky-300",
    else: "border border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300")]}
                >
                  {chain.display_name}
                </button>
              <% end %>
            <% else %>
              <div class="text-[10px] py-1 text-gray-500">No chains available</div>
            <% end %>
          </div>
        </div>
        
    <!-- Strategy and Rate -->
        <div class="grid grid-cols-2 gap-3">
          <div class="space-y-1">
            <label class="text-[10px] text-gray-400">Strategy</label>
            <select
              phx-change="select_strategy"
              phx-target={@myself}
              name="strategy"
              class="text-[10px] w-full rounded border border-gray-600 bg-gray-800 px-2 py-1 text-gray-300 focus:border-purple-500 focus:outline-none"
            >
              <%= for {strategy, label} <- [{"fastest", "⚡ Fastest"}, {"leaderboard", "🏆 Leaderboard"}, {"priority", "⭐ Priority"}, {"round-robin", "🔄 Round Robin"}] do %>
                <option value={strategy} selected={@selected_strategy == strategy}>{label}</option>
              <% end %>
            </select>
          </div>

          <div class="space-y-1">
            <label class="text-[10px] text-gray-400">Rate (RPS)</label>
            <div class="flex items-center gap-1">
              <button
                phx-click="decrease_rate"
                phx-target={@myself}
                class="rounded bg-gray-700 p-1 text-xs text-gray-300 hover:bg-gray-600"
              >
                -
              </button>
              <input
                type="number"
                min="1"
                max="100"
                value={@request_rate}
                phx-change="update_rate"
                phx-target={@myself}
                name="rate"
                class="text-[10px] flex-1 rounded border border-gray-600 bg-gray-800 px-1 py-1 text-center text-gray-300 focus:border-orange-500 focus:outline-none"
              />
              <button
                phx-click="increase_rate"
                phx-target={@myself}
                class="rounded bg-gray-700 p-1 text-xs text-gray-300 hover:bg-gray-600"
              >
                +
              </button>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Control Actions -->
      <div class="border-gray-700/40 space-y-2 border-t pt-4">
        <%= if not @simulator_running do %>
          <button
            phx-click="start_simulator_run"
            phx-target={@myself}
            class="bg-emerald-600/20 border-emerald-500/40 flex w-full items-center justify-center gap-2 rounded-lg border px-4 py-3 text-sm font-medium text-emerald-300 transition-all duration-200 hover:bg-emerald-600/30"
          >
            <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
              <path d="M8 5v14l11-7z" />
            </svg>
            <span>Start Simulation</span>
          </button>
        <% else %>
          <button
            phx-click="sim_stop_all"
            phx-target={@myself}
            class="bg-red-600/20 border-red-500/40 flex w-full items-center justify-center gap-2 rounded-lg border px-4 py-3 text-sm font-medium text-red-300 transition-all duration-200 hover:bg-red-600/30"
          >
            <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
              <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
            </svg>
            <span>Stop All Runs</span>
          </button>
        <% end %>

        <div class="grid grid-cols-2 gap-2">
          <button
            phx-click="clear_sim_logs"
            phx-target={@myself}
            class="border-gray-600/40 bg-gray-800/60 rounded-lg border px-3 py-2 text-xs text-gray-300 transition-all duration-200 hover:border-gray-500/60 hover:bg-gray-700/60 hover:text-white"
          >
            Clear Logs
          </button>
          <button
            phx-click="toggle_collapsed"
            phx-target={@myself}
            class="border-gray-600/40 bg-gray-800/60 rounded-lg border px-3 py-2 text-xs text-gray-300 transition-all duration-200 hover:border-gray-500/60 hover:bg-gray-700/60 hover:text-white"
          >
            Minimize
          </button>
        </div>
      </div>
      
    <!-- Enhanced Live Stats -->
      <div class="bg-gray-800/40 space-y-2 rounded-lg p-3">
        <div class="flex items-center justify-between">
          <div class="text-xs font-medium text-gray-300">Live Statistics</div>
          <%= if @simulator_running do %>
            <div class="text-[9px] text-gray-400">Updating...</div>
          <% end %>
        </div>

        <div class="grid grid-cols-3 gap-2">
          <div class="text-center">
            <div class="font-mono text-lg text-emerald-400">
              {get_stat(@sim_stats, :http, "success", 0)}
            </div>
            <div class="text-[9px] text-gray-400">Success</div>
          </div>
          <div class="text-center">
            <div class="font-mono text-lg text-red-400">
              {get_stat(@sim_stats, :http, "error", 0)}
            </div>
            <div class="text-[9px] text-gray-400">Errors</div>
          </div>
          <div class="text-center">
            <div class="font-mono text-lg text-yellow-400">
              {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0)
              |> Helpers.to_float()
              |> Float.round(0)}
            </div>
            <div class="text-[9px] text-gray-400">Avg ms</div>
          </div>
        </div>

        <div class="text-[10px] border-gray-700/40 flex justify-between border-t pt-2">
          <div>
            <span class="text-gray-400">HTTP:</span>
            <span class="font-mono ml-1 text-sky-400">
              {get_stat(@sim_stats, :http, "inflight", 0)} active
            </span>
          </div>
          <div>
            <span class="text-gray-400">WS:</span>
            <span class="font-mono ml-1 text-purple-400">
              {get_stat(@sim_stats, :ws, "open", 0)} open
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp is_simulator_active(sim_stats, simulator_running) do
    # Check if simulator is actively running based on inflight requests or open connections
    get_stat(sim_stats, :http, "inflight", 0) > 0 or
      get_stat(sim_stats, :ws, "open", 0) > 0 or simulator_running
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

  # Run configuration helpers
  defp get_default_run_config do
    %{
      type: "load_test",
      duration: 30000,
      http: %{
        enabled: true,
        methods: ["eth_blockNumber", "eth_getBalance"],
        rps: 5,
        concurrency: 4
      },
      ws: %{
        enabled: true,
        connections: 2,
        topics: ["newHeads"]
      }
    }
  end

  defp get_load_test_config(socket) do
    %{
      type: "load_test",
      duration: socket.assigns.run_duration * 1000,
      chains: get_selected_chains(socket),
      strategy: socket.assigns.selected_strategy,
      http: %{
        enabled: true,
        methods: ["eth_blockNumber", "eth_getBalance", "eth_getTransactionCount"],
        rps: socket.assigns.request_rate,
        concurrency: 4
      },
      ws: %{
        enabled: true,
        connections: 2,
        topics: ["newHeads"]
      }
    }
  end

  defp get_http_only_config(socket) do
    %{
      type: "http_only",
      duration: socket.assigns.run_duration * 1000,
      chains: get_selected_chains(socket),
      strategy: socket.assigns.selected_strategy,
      http: %{
        enabled: true,
        methods: ["eth_blockNumber", "eth_getBalance", "eth_getTransactionCount"],
        rps: socket.assigns.request_rate,
        concurrency: 6
      },
      ws: %{enabled: false}
    }
  end

  defp get_ws_only_config(socket) do
    %{
      type: "ws_only",
      duration: socket.assigns.run_duration * 1000,
      chains: get_selected_chains(socket),
      http: %{enabled: false},
      ws: %{
        enabled: true,
        connections: 4,
        topics: ["newHeads", "logs"]
      }
    }
  end

  defp get_stress_test_config(socket) do
    %{
      type: "stress_test",
      duration: socket.assigns.run_duration * 1000,
      chains: get_selected_chains(socket),
      strategy: socket.assigns.selected_strategy,
      http: %{
        enabled: true,
        methods: ["eth_blockNumber", "eth_getBalance", "eth_getTransactionCount"],
        rps: socket.assigns.request_rate * 2,
        concurrency: 8
      },
      ws: %{
        enabled: true,
        connections: 6,
        topics: ["newHeads", "logs", "pendingTransactions"]
      }
    }
  end

  defp build_run_config(socket) do
    case socket.assigns.run_type do
      "load_test" -> get_load_test_config(socket)
      "http_only" -> get_http_only_config(socket)
      "ws_only" -> get_ws_only_config(socket)
      "stress_test" -> get_stress_test_config(socket)
      _ -> get_load_test_config(socket)
    end
  end

  defp get_selected_chains(socket) do
    selected = socket.assigns.selected_chains || []

    if length(selected) > 0 do
      selected
    else
      Enum.map(socket.assigns.available_chains, & &1.name)
    end
  end

  defp format_run_config(config) do
    duration_s = div(Map.get(config, :duration, 30000), 1000)
    http_enabled = get_in(config, [:http, :enabled]) || false
    ws_enabled = get_in(config, [:ws, :enabled]) || false

    type_label =
      case {http_enabled, ws_enabled} do
        {true, true} -> "Load Test"
        {true, false} -> "HTTP Only"
        {false, true} -> "WebSocket"
        _ -> "Custom"
      end

    "#{type_label} • #{duration_s}s"
  end
end
