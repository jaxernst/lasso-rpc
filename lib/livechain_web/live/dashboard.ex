defmodule LivechainWeb.Dashboard do
  use LivechainWeb, :live_view

  alias Livechain.RPC.WSSupervisor
  alias LivechainWeb.NetworkTopology

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :active_tab, "dashboard")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "routing:decisions")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "provider_pool:events")

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
      |> assign(:demo_running, false)
      |> assign(:sampler_running, false)
      |> assign(:sampler_ref, nil)
      |> assign(:vm_metrics, %{})

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
                    <h1 class="text-2xl font-bold text-white">ChainPulse</h1>
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
                %{id: "dashboard", label: "Live Dashboard", icon: "M13 10V3L4 14h7v7l9-11h-7z"},
                %{
                  id: "live_test",
                  label: "Live Test",
                  icon: "M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3"
                },
                %{id: "metrics", label: "System Metrics", icon: "M15 4m0 13V4m-6 3l6-3"}
              ]}
              active_tab={@active_tab}
            />
          </div>
        </div>
      </div>
      
    <!-- Content Section -->
      <div class="grid-pattern flex-1 overflow-hidden">
        <%= case @active_tab do %>
          <% "dashboard" -> %>
            <.dashboard_tab_content
              connections={@connections}
              routing_events={@routing_events}
              provider_events={@provider_events}
            />
          <% "live_test" -> %>
            <.live_test_tab_content demo_running={@demo_running} sampler_running={@sampler_running} />
          <% "metrics" -> %>
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
    <div class="flex h-full w-full flex-col gap-4 p-4">
      <!-- Topology and quick stats -->
      <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3 lg:col-span-2">
          <div class="mb-2 text-sm font-semibold text-gray-300">Network topology</div>
          <NetworkTopology.nodes_display
            id="network-topology"
            connections={@connections}
            selected_chain={nil}
            selected_provider={nil}
            on_chain_select="select_chain"
            on_provider_select="select_provider"
            on_test_connection="test_connection"
          />
        </div>
        <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
          <div class="mb-2 text-sm font-semibold text-gray-300">Quick stats</div>
          <div class="space-y-1 text-sm text-gray-400">
            <div>Connections: <span class="text-emerald-300">{length(@connections)}</span></div>
            <div>
              Routing events (last 100): <span class="text-sky-300">{length(@routing_events)}</span>
            </div>
            <div>
              Provider events (last 100):
              <span class="text-yellow-300">{length(@provider_events)}</span>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Feeds -->
      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
          <div class="mb-2 text-sm font-semibold text-gray-300">Routing decisions</div>
          <div class="h-64 overflow-auto">
            <%= for e <- @routing_events do %>
              <div class="mb-1 text-xs text-gray-400">
                <span class="text-gray-500">[{e.ts}]</span>
                chain=<span class="text-purple-300"><%= e.chain %></span> method=<span class="text-sky-300"><%= e.method %></span> provider=<span class="text-emerald-300"><%= e.provider_id %></span> dur=<span class="text-yellow-300"><%= e.duration_ms %>ms</span> result=<span><%= e.result %></span> failovers=<span><%= e.failovers %></span>
              </div>
            <% end %>
          </div>
        </div>
        <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
          <div class="mb-2 text-sm font-semibold text-gray-300">Provider pool events</div>
          <div class="h-64 overflow-auto">
            <%= for e <- @provider_events do %>
              <div class="mb-1 text-xs text-gray-400">
                <span class="text-gray-500">[{e.ts}]</span>
                chain=<span class="text-purple-300"><%= e.chain %></span> provider=<span class="text-emerald-300"><%= e.provider_id %></span> event=<span class="text-orange-300"><%= e.event %></span>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def live_test_tab_content(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col gap-4 p-4">
      <div class="flex items-center justify-between">
        <div class="flex gap-2">
          <button
            phx-click="start_demo"
            disabled={@demo_running}
            class="rounded bg-emerald-600 px-3 py-1 text-white disabled:opacity-50"
          >
            Start Demo
          </button>
          <button
            phx-click="stop_demo"
            disabled={!@demo_running}
            class="rounded bg-rose-600 px-3 py-1 text-white disabled:opacity-50"
          >
            Stop Demo
          </button>
          <button phx-click="refresh_connections" class="rounded bg-slate-700 px-3 py-1 text-white">
            Refresh Connections
          </button>
        </div>
        <div class="text-sm text-gray-400">
          Demo status:
          <span class={[(@demo_running && "text-emerald-400") || "text-red-400"]}>
            {if @demo_running, do: "running", else: "stopped"}
          </span>
        </div>
      </div>

      <div class="flex items-center justify-between">
        <div class="flex gap-2">
          <button
            phx-click="start_sampler"
            disabled={@sampler_running}
            class="rounded bg-indigo-600 px-3 py-1 text-white disabled:opacity-50"
          >
            Start Routing Sampler
          </button>
          <button
            phx-click="stop_sampler"
            disabled={!@sampler_running}
            class="rounded bg-gray-700 px-3 py-1 text-white disabled:opacity-50"
          >
            Stop Routing Sampler
          </button>
          <button phx-click="emit_cooldown" class="rounded bg-amber-600 px-3 py-1 text-white">
            Emit Cooldown
          </button>
          <button phx-click="emit_healthy" class="rounded bg-teal-600 px-3 py-1 text-white">
            Emit Healthy
          </button>
        </div>
        <div class="text-sm text-gray-400">
          Sampler:
          <span class={[(@sampler_running && "text-emerald-400") || "text-red-400"]}>
            {if @sampler_running, do: "running", else: "stopped"}
          </span>
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
              {(@vm_metrics[:cpu_percent] || 0) |> :erlang.float_to_binary([{:decimals, 1}])}%
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
  def handle_event("select_chain", %{"chain" => chain}, socket) do
    {:noreply, assign(socket, :selected_chain, chain)}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :selected_provider, provider)}
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    Livechain.RPC.WSSupervisor.broadcast_connection_status_update()
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, fetch_connections(socket)}
  end

  # Demo controls
  @impl true
  def handle_event("start_demo", _params, socket) do
    if socket.assigns.demo_running do
      {:noreply, socket}
    else
      start_demo_connections()
      {:noreply, socket |> assign(:demo_running, true) |> fetch_connections()}
    end
  end

  @impl true
  def handle_event("stop_demo", _params, socket) do
    if socket.assigns.demo_running do
      stop_demo_connections()
      {:noreply, socket |> assign(:demo_running, false) |> fetch_connections()}
    else
      {:noreply, socket}
    end
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

  # Helper functions

  defp fetch_connections(socket) do
    connections = Livechain.RPC.WSSupervisor.list_connections()

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end

  defp start_demo_connections do
    eth = Livechain.RPC.MockWSEndpoint.ethereum_mainnet(subscription_topics: ["newHeads"])
    poly = Livechain.RPC.MockWSEndpoint.polygon(subscription_topics: ["newHeads"])

    _ = Livechain.RPC.WSSupervisor.start_connection(eth)
    _ = Livechain.RPC.WSSupervisor.start_connection(poly)
  end

  defp stop_demo_connections do
    for id <- ["mock_ethereum_mainnet", "mock_polygon"] do
      _ = Livechain.RPC.WSSupervisor.stop_connection(id)
    end
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
end
