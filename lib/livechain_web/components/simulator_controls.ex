defmodule LivechainWeb.Dashboard.Components.SimulatorControls do
  use LivechainWeb, :live_component
  alias LivechainWeb.Dashboard.Helpers

  @impl true
  def update(%{sim_stats: _sim_stats} = assigns, socket) do
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

    {:ok, socket}
  end

  @impl true
  def handle_event(event, params, socket) do
    # Forward events to parent LiveView
    send(self(), {:simulator_event, event, params})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pointer-events-none absolute top-4 left-4 z-30">
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300",
                   if(@sim_collapsed, do: "w-80", else: "w-[28rem] max-h-[85vh]")]}>
        <!-- Header -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class={["h-2 w-2 rounded-full", if(is_simulator_active(@sim_stats), do: "bg-emerald-400 animate-pulse", else: "bg-gray-500")]}></div>
            <div class="truncate text-xs text-gray-300">
              <%= if is_simulator_active(@sim_stats) do %>
                Load Test Active
              <% else %>
                Load Simulator
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <%= if @sim_collapsed do %>
              <div class="text-[10px] flex items-center space-x-3 text-gray-400">
                <span class="text-emerald-300">{get_stat(@sim_stats, :http, "success", 0)} ✓</span>
                <span class="text-rose-400">{get_stat(@sim_stats, :http, "error", 0)} ✗</span>
                <span class="text-yellow-300">{get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms</span>
              </div>
            <% end %>
            <button
              phx-click="toggle_collapsed"
              phx-target={@myself}
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              {if @sim_collapsed, do: "↖", else: "↗"}
            </button>
          </div>
        </div>

        <!-- Collapsed content - basic controls only -->
        <%= if @sim_collapsed do %>
          <.collapsed_content 
            sim_stats={@sim_stats} 
            myself={@myself} />
        <% else %>
          <!-- Expanded content - full featured controls -->
          <.expanded_content 
            sim_stats={@sim_stats}
            available_chains={@available_chains}
            selected_chains={@selected_chains}
            selected_strategy={@selected_strategy}
            request_rate={@request_rate}
            recent_calls={@recent_calls}
            myself={@myself} />
        <% end %>
      </div>
    </div>
    """
  end

  defp collapsed_content(assigns) do
    ~H"""
    <div class="p-3 space-y-3">
      <!-- Quick action buttons -->
      <div class="flex items-center justify-between">
        <div class="flex space-x-2">
          <button phx-click="sim_http_start"
                  phx-target={@myself}
                  class="flex items-center space-x-1 px-3 py-1.5 rounded-lg bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-700 hover:to-purple-700 text-white text-xs font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-indigo-500/25">
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            <span>HTTP</span>
          </button>
          <button phx-click="sim_ws_start"
                  phx-target={@myself}
                  class="flex items-center space-x-1 px-3 py-1.5 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 text-white text-xs font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-purple-500/25">
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
            </svg>
            <span>WS</span>
          </button>
        </div>
        <div class="flex space-x-1">
          <button phx-click="sim_http_stop" phx-target={@myself} class="px-2 py-1 rounded bg-gray-700 hover:bg-gray-600 text-white text-xs transition-colors">Stop HTTP</button>
          <button phx-click="sim_ws_stop" phx-target={@myself} class="px-2 py-1 rounded bg-gray-700 hover:bg-gray-600 text-white text-xs transition-colors">Stop WS</button>
        </div>
      </div>

      <!-- Compact stats display -->
      <div class="grid grid-cols-2 gap-3 text-xs">
        <div class="bg-gray-800/50 rounded-lg p-2 border border-gray-700/30">
          <div class="text-gray-400 text-[10px] font-medium mb-1">HTTP STATS</div>
          <div class="flex justify-between items-center">
            <div class="flex space-x-3">
              <span class="text-emerald-400">{get_stat(@sim_stats, :http, "success", 0)}</span>
              <span class="text-rose-400">{get_stat(@sim_stats, :http, "error", 0)}</span>
            </div>
            <div class="text-yellow-300 text-[10px]">
              {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms
            </div>
          </div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-2 border border-gray-700/30">
          <div class="text-gray-400 text-[10px] font-medium mb-1">WEBSOCKET</div>
          <div class="flex justify-between items-center">
            <span class="text-emerald-400">{get_stat(@sim_stats, :ws, "open", 0)}</span>
            <div class="text-[10px] text-gray-400">open</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp expanded_content(assigns) do
    ~H"""
    <div class="max-h-[75vh] overflow-y-auto">
      <div class="p-4 space-y-4">
        <!-- Chain Selection -->
        <div class="space-y-2">
          <div class="flex items-center justify-between">
            <label class="text-xs font-semibold text-gray-300">Target Chains</label>
            <button phx-click="select_all_chains" phx-target={@myself} class="text-xs text-indigo-400 hover:text-indigo-300 transition-colors">Select All</button>
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
                       phx-target={@myself}
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
                      phx-target={@myself}
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
            <button phx-click="decrease_rate" phx-target={@myself} class="p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-300 transition-colors">
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
                     phx-target={@myself}
                     name="rate"
                     class="w-full h-2 bg-gray-700 rounded-lg appearance-none cursor-pointer slider" />
              <div class="absolute -bottom-1 left-0 right-0 flex justify-between text-[10px] text-gray-500">
                <span>1</span>
                <span>25</span>
                <span>50</span>
              </div>
            </div>
            <button phx-click="increase_rate" phx-target={@myself} class="p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-300 transition-colors">
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
                    phx-target={@myself}
                    class="flex-1 flex items-center justify-center space-x-2 py-2 px-4 rounded-lg bg-gradient-to-r from-indigo-600 to-purple-600 hover:from-indigo-700 hover:to-purple-700 text-white text-sm font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-indigo-500/25">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
              </svg>
              <span>Start HTTP Load</span>
            </button>
            <button phx-click="sim_ws_start_advanced"
                    phx-target={@myself}
                    class="flex-1 flex items-center justify-center space-x-2 py-2 px-4 rounded-lg bg-gradient-to-r from-purple-600 to-pink-600 hover:from-purple-700 hover:to-pink-700 text-white text-sm font-medium transition-all duration-200 transform hover:scale-105 shadow-lg hover:shadow-purple-500/25">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0" />
              </svg>
              <span>Start WS Load</span>
            </button>
          </div>
          <div class="flex space-x-2">
            <button phx-click="sim_stop_all"
                    phx-target={@myself}
                    class="flex-1 py-2 px-4 rounded-lg bg-gray-700 hover:bg-gray-600 text-white text-sm font-medium transition-colors">
              Stop All
            </button>
            <button phx-click="clear_sim_logs"
                    phx-target={@myself}
                    class="px-4 py-2 rounded-lg border border-gray-600 text-gray-300 hover:border-gray-500 hover:text-gray-200 text-sm transition-colors">
              Clear Logs
            </button>
          </div>
        </div>

        <!-- Live Activity Feed -->
        <.activity_feed recent_calls={@recent_calls} />

        <!-- Enhanced Stats Display -->
        <.stats_display sim_stats={@sim_stats} />
      </div>
    </div>
    """
  end

  defp activity_feed(assigns) do
    ~H"""
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
    """
  end

  defp stats_display(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <div class="bg-gradient-to-br from-indigo-900/30 to-purple-900/30 border border-indigo-500/30 rounded-lg p-3">
        <div class="flex items-center justify-between mb-2">
          <div class="text-xs font-semibold text-indigo-300">HTTP Load</div>
          <div class="text-[10px] text-gray-400">RPC Calls</div>
        </div>
        <div class="space-y-1">
          <div class="flex justify-between text-xs">
            <span class="text-gray-400">Success:</span>
            <span class="text-emerald-400 font-mono">{get_stat(@sim_stats, :http, "success", 0)}</span>
          </div>
          <div class="flex justify-between text-xs">
            <span class="text-gray-400">Errors:</span>
            <span class="text-rose-400 font-mono">{get_stat(@sim_stats, :http, "error", 0)}</span>
          </div>
          <div class="flex justify-between text-xs">
            <span class="text-gray-400">Avg Latency:</span>
            <span class="text-yellow-300 font-mono">
              {get_stat(@sim_stats, :http, "avgLatencyMs", 0.0) |> Helpers.to_float() |> Float.round(1)}ms
            </span>
          </div>
          <div class="flex justify-between text-xs">
            <span class="text-gray-400">In Flight:</span>
            <span class="text-blue-400 font-mono">{get_stat(@sim_stats, :http, "inflight", 0)}</span>
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
            <span class="text-emerald-400 font-mono">{get_stat(@sim_stats, :ws, "open", 0)}</span>
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