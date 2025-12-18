defmodule LassoWeb.Dashboard.Components.SimulatorControls do
  use LassoWeb, :live_component
  import LassoWeb.Components.FloatingWindow
  alias LassoWeb.Dashboard.Helpers

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
      |> assign_new(:selected_strategy, fn -> "round-robin" end)
      |> assign_new(:request_rate, fn -> 5 end)
      |> assign_new(:run_duration, fn -> 30 end)
      |> assign_new(:load_types, fn -> %{http: true, ws: true} end)
      |> assign_new(:recent_calls, fn -> [] end)
      |> assign_new(:available_chains, fn -> [] end)
      |> assign_new(:active_runs, fn -> [] end)
      |> assign_new(:quick_run_config, fn -> get_default_run_config() end)
      |> assign_new(:preview_text, fn ->
        get_preview_text(%{
          strategy: "round-robin",
          chains: [],
          load_types: %{http: true, ws: true}
        })
      end)

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

    # Recalculate simulator_running based on active_runs when it changes
    socket =
      if Map.has_key?(assigns, :active_runs) do
        is_running = length(assigns.active_runs) > 0
        assign(socket, :simulator_running, is_running)
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

    socket =
      socket
      |> assign(:selected_chains, new_selected)
      |> update_preview_text()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_all_chains", _params, socket) do
    all_chains = Enum.map(socket.assigns.available_chains, & &1.name)

    socket =
      socket
      |> assign(:selected_chains, all_chains)
      |> update_preview_text()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_strategy", %{"strategy" => strategy}, socket) do
    socket =
      socket
      |> assign(:selected_strategy, strategy)
      |> update_preview_text()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_rate", %{"rate" => rate}, socket) do
    rate_int = String.to_integer(rate)

    socket =
      socket
      |> assign(:request_rate, rate_int)
      |> update_preview_text()

    {:noreply, socket}
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

    strategy = socket.assigns.selected_strategy

    opts = %{
      chains: chains,
      methods: ["eth_blockNumber", "eth_getBalance", "eth_getTransactionCount"],
      rps: socket.assigns.request_rate,
      concurrency: 4,
      durationMs: 60_000
    }

    # Only include strategy if it's a valid non-empty string
    opts = if is_binary(strategy) and String.length(strategy) > 0 do
      Map.put(opts, :strategy, strategy)
    else
      opts
    end

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
  def handle_event("sim_stats", %{"http" => http, "ws" => ws}, socket) do
    new_stats = %{http: http, ws: ws}

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
  def handle_event("toggle_load_type", %{"type" => type}, socket) do
    current_load_types = socket.assigns.load_types

    new_load_types =
      case type do
        "http" -> %{current_load_types | http: !current_load_types.http}
        "ws" -> %{current_load_types | ws: !current_load_types.ws}
        _ -> current_load_types
      end

    new_load_types =
      if !new_load_types.http && !new_load_types.ws do
        %{http: true, ws: false}
      else
        new_load_types
      end

    socket =
      socket
      |> assign(:load_types, new_load_types)
      |> update_preview_text()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_duration", %{"duration" => duration_str}, socket) do
    duration = String.to_integer(duration_str)
    config = Map.put(socket.assigns.quick_run_config, :duration, duration * 1000)
    {:noreply, assign(socket, run_duration: duration, quick_run_config: config)}
  end

  @impl true
  def render(assigns) do
    # Determine status indicator state
    status = if is_simulator_active(assigns.sim_stats, assigns.simulator_running) do
      :healthy
    else
      :info
    end

    assigns = assign(assigns, :status, status)

    ~H"""
    <div>
      <.floating_window
        id="simulator-controls"
        position={:top_left}
        collapsed={@sim_collapsed}
        on_toggle="toggle_collapsed"
        on_toggle_target={@myself}
        size={%{collapsed: "w-64 h-auto", expanded: "w-80 max-h-[80vh]"}}
      >
        <:header>
          <.status_indicator
            status={@status}
            animated={is_simulator_active(@sim_stats, @simulator_running)}
          />
          <div class="truncate text-xs font-medium text-white">
            RPC Load Simulator
          </div>
        </:header>

        <:collapsed_preview>
          <.collapsed_content
            sim_stats={@sim_stats}
            simulator_running={@simulator_running}
            preview_text={@preview_text}
            myself={@myself}
          />
        </:collapsed_preview>

        <:body>
          <.expanded_content
            sim_stats={@sim_stats}
            available_chains={@available_chains}
            selected_chains={@selected_chains}
            selected_strategy={@selected_strategy}
            request_rate={@request_rate}
            load_types={@load_types}
            simulator_running={@simulator_running}
            myself={@myself}
          />
        </:body>
      </.floating_window>
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
            {@preview_text}
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
      <!-- Header Section -->
      <div class="flex items-center justify-between">
        <h3 class="text-xs font-semibold text-white">Configure Test Run</h3>
        <%= if @simulator_running do %>
          <div class="flex items-center gap-1">
            <.status_indicator status={:healthy} animated={true} size="h-2 w-2" />
            <span class="text-[10px] text-emerald-300">Running</span>
          </div>
        <% end %>
      </div>

      <!-- Chain Selection -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="text-[10px] font-medium text-gray-400">Target Chains</label>
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
                class={[
                  "text-[9px] rounded px-2 py-1 font-medium transition-all duration-200",
                  if(chain.name in (@selected_chains || []),
                    do: "bg-sky-500/20 border border-sky-500 text-sky-300",
                    else: "border border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300"
                  )
                ]}
              >
                {chain.display_name}
              </button>
            <% end %>
          <% else %>
            <div class="text-[10px] py-1 text-gray-500">No chains available</div>
          <% end %>
        </div>
      </div>

      <!-- Routing Strategy -->
      <div class="space-y-2">
        <label class="text-[10px] font-medium text-gray-400">Routing Strategy</label>
        <div class="grid grid-cols-2 gap-1">
          <%= for {strategy, label, icon} <- [
            {"round-robin", "Round Robin", "🔄"},
            {"fastest", "Fastest", "⚡"},
            {"latency-weighted", "Latency Weighted", "⚖️"}
          ] do %>
            <button
              phx-click="select_strategy"
              phx-value-strategy={strategy}
              phx-target={@myself}
              class={[
                "text-[10px] rounded-lg p-2 text-left transition-all duration-200",
                if(@selected_strategy == strategy,
                  do: "bg-purple-500/20 border border-purple-500 text-purple-300",
                  else: "border-gray-600/40 bg-gray-800/40 border text-gray-300 hover:border-purple-400/50"
                )
              ]}
            >
              <div class="font-medium">{icon} {label}</div>
            </button>
          <% end %>
        </div>
      </div>

      <!-- Request Rate -->
      <div class="space-y-2">
        <label class="text-[10px] font-medium text-gray-400">Request Rate</label>
        <div class="flex gap-2">
          <%= for rate <- [5, 15, 30] do %>
            <button
              phx-click="set_rate"
              phx-value-rate={rate}
              phx-target={@myself}
              class={["text-[10px] rounded-lg px-3 py-2 font-medium transition-all duration-200", if(@request_rate == rate,
    do: "bg-orange-500/20 border border-orange-500 text-orange-300",
    else: "border-gray-600/40 bg-gray-800/40 border text-gray-300 hover:border-orange-400/50")]}
            >
              {rate} RPS
            </button>
          <% end %>
        </div>
      </div>


      <!-- Live Statistics -->
      <div class="bg-gray-800/40 space-y-3 rounded-lg p-3">
        <div class="text-xs font-medium text-gray-300">Live Statistics</div>

        <.metrics_grid cols={3} class="gap-2">
          <.metric_card
            label="Success"
            value={to_string(get_stat(@sim_stats, :http, "success", 0))}
            value_class="text-emerald-400 text-lg"
            class="p-2"
          />
          <.metric_card
            label="Errors"
            value={to_string(get_stat(@sim_stats, :http, "error", 0))}
            value_class="text-red-400 text-lg"
            class="p-2"
          />
          <.metric_card
            label="Avg ms"
            value={
              "#{get_stat(@sim_stats, :http, "avgLatencyMs", 0.0)
              |> Helpers.to_float()
              |> Float.round(0)}"
            }
            value_class="text-yellow-400 text-lg"
            class="p-2"
          />
        </.metrics_grid>

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
      
    <!-- Control Actions -->
      <div class="space-y-2">
        <%= if not @simulator_running do %>
          <button
            phx-click="start_simulator_run"
            phx-target={@myself}
            class="bg-emerald-600/20 border-emerald-500/40 flex w-full items-center justify-center gap-2 rounded-lg border px-4 py-3 text-sm font-medium text-emerald-300 transition-all duration-200 hover:bg-emerald-600/30"
          >
            <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
              <path d="M8 5v14l11-7z" />
            </svg>
            <span>Start Load Test</span>
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
            <span>Stop Load Test</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions
  defp is_simulator_active(sim_stats, simulator_running) do
    get_stat(sim_stats, :http, "inflight", 0) > 0 or
      get_stat(sim_stats, :ws, "open", 0) > 0 or simulator_running
  end

  defp get_stat(sim_stats, type, key, default) do
    type_string = to_string(type)
    key_string = to_string(key)

    case sim_stats do
      %{^type_string => stats} when is_map(stats) ->
        Map.get(stats, key_string, default)

      %{^type => stats} when is_map(stats) ->
        atom_key = if is_atom(key), do: key, else: String.to_atom(key)
        Map.get(stats, atom_key, default)

      _ ->
        default
    end
  end

  # Run configuration helpers
  defp get_default_run_config do
    %{
      type: "custom",
      duration: 30_000,
      strategy: "round-robin",  # Default strategy to avoid undefined routes
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

  defp build_run_config(socket) do
    load_types = socket.assigns.load_types
    # Ensure strategy is valid or omit it to use default route
    strategy = socket.assigns.selected_strategy

    config = %{
      type: "custom",
      duration: 30_000,
      chains: get_selected_chains(socket),
      http: %{
        enabled: load_types.http,
        methods: ["eth_blockNumber", "eth_getBalance"],
        rps: socket.assigns.request_rate,
        concurrency: max(8, socket.assigns.request_rate)
      },
      ws: %{
        enabled: load_types.ws,
        connections: 2,
        topics: ["newHeads"]
      }
    }

    # Only include strategy if it's a valid non-empty string
    if is_binary(strategy) and String.length(strategy) > 0 do
      Map.put(config, :strategy, strategy)
    else
      config
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

  defp get_preview_text(params) do
    strategy = Map.get(params, :strategy, "round-robin")
    chains = Map.get(params, :chains, [])
    _load_types = Map.get(params, :load_types, %{http: true, ws: true})

    strategy_label =
      case strategy do
        "round-robin" -> "Round Robin"
        "fastest" -> "Fastest"
        "latency-weighted" -> "Latency Weighted"
        _ -> "Round Robin"
      end

    chains_text =
      case length(chains) do
        0 -> "All Chains"
        1 -> "1 Chain"
        n -> "#{n} Chains"
      end

    "#{strategy_label} • #{chains_text}"
  end

  defp update_preview_text(socket) do
    preview_text =
      get_preview_text(%{
        strategy: socket.assigns.selected_strategy,
        chains: socket.assigns.selected_chains,
        load_types: socket.assigns.load_types
      })

    assign(socket, :preview_text, preview_text)
  end
end
