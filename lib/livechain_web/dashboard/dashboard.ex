defmodule LivechainWeb.Dashboard do
  use LivechainWeb, :live_view
  require Logger

  alias LivechainWeb.NetworkTopology
  alias LivechainWeb.Dashboard.{Helpers, MetricsHelpers, StatusHelpers, EndpointHelpers}
  alias LivechainWeb.Dashboard.Components

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :active_tab, "overview")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "routing:decisions")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "provider_pool:events")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "clients:events")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "circuit:events")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "chain_config_changes")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "chain_config_updates")

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
      |> assign(:available_chains, Helpers.get_available_chains())
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
      |> assign(:chain_config_open, false)
      |> assign(:chain_config_collapsed, true)
      |> assign(:config_selected_chain, nil)
      |> assign(:config_form_data, %{})
      |> assign(:config_validation_errors, [])
      |> assign(:config_expanded_providers, MapSet.new())
      |> assign(:quick_add_open, false)
      |> assign(:quick_add_data, %{})
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
      Helpers.as_event(:circuit,
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

  # Handle simulator component events
  @impl true
  def handle_info({:simulator_event, "toggle_collapsed", _params}, socket) do
    {:noreply, update(socket, :sim_collapsed, &(!&1))}
  end

  @impl true
  def handle_info({:simulator_event, event, params}, socket) do
    handle_event(event, params, socket)
  end

  # Chain configuration change notifications
  @impl true
  def handle_info({:chain_created, chain_name, _chain_config}, socket) do
    if socket.assigns.chain_config_open do
      # Reload chains list to show the new chain
      case Livechain.Config.ChainConfigManager.list_chains() do
        {:ok, chains} ->
          chain_list = Enum.map(chains, fn {name, config} ->
            %{name: name, chain_id: config.chain_id, providers: config.providers}
          end)

          socket =
            socket
            |> assign(:available_chains, chain_list)
            |> push_event("show_notification", %{
              message: "Chain '#{chain_name}' was created",
              type: "info"
            })

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:chain_updated, chain_name, _chain_config}, socket) do
    if socket.assigns.chain_config_open do
      # Reload chains list and update form if this chain is selected
      case Livechain.Config.ChainConfigManager.list_chains() do
        {:ok, chains} ->
          chain_list = Enum.map(chains, fn {name, config} ->
            %{name: name, chain_id: config.chain_id, providers: config.providers}
          end)

          socket =
            socket
            |> assign(:available_chains, chain_list)
            |> push_event("show_notification", %{
              message: "Chain '#{chain_name}' was updated",
              type: "info"
            })

          # If this is the currently selected chain, reload its form data
          socket = if socket.assigns.config_selected_chain == chain_name do
            case Livechain.Config.ChainConfigManager.get_chain(chain_name) do
              {:ok, config} ->
                form_data = %{
                  name: config.name,
                  chain_id: config.chain_id,
                  block_time: config.block_time,
                  providers: Enum.map(config.providers, fn provider ->
                    %{
                      id: provider.id,
                      name: provider.name,
                      url: provider.url,
                      ws_url: provider.ws_url,
                      priority: provider.priority,
                      type: provider.type,
                      api_key_required: provider.api_key_required,
                      region: provider.region
                    }
                  end)
                }
                assign(socket, :config_form_data, form_data)

              {:error, _} ->
                socket
            end
          else
            socket
          end

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:chain_deleted, chain_name, _chain_config}, socket) do
    if socket.assigns.chain_config_open do
      # Reload chains list
      case Livechain.Config.ChainConfigManager.list_chains() do
        {:ok, chains} ->
          chain_list = Enum.map(chains, fn {name, config} ->
            %{name: name, chain_id: config.chain_id, providers: config.providers}
          end)

          socket =
            socket
            |> assign(:available_chains, chain_list)
            |> push_event("show_notification", %{
              message: "Chain '#{chain_name}' was deleted",
              type: "warning"
            })

          # If this was the currently selected chain, clear the selection
          socket = if socket.assigns.config_selected_chain == chain_name do
            socket
            |> assign(:config_selected_chain, nil)
            |> assign(:config_form_data, %{})
          else
            socket
          end

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:config_restored, _backup_path, _}, socket) do
    if socket.assigns.chain_config_open do
      # Reload everything after config restore
      case Livechain.Config.ChainConfigManager.list_chains() do
        {:ok, chains} ->
          chain_list = Enum.map(chains, fn {name, config} ->
            %{name: name, chain_id: config.chain_id, providers: config.providers}
          end)

          socket =
            socket
            |> assign(:available_chains, chain_list)
            |> assign(:config_selected_chain, nil)
            |> assign(:config_form_data, %{})
            |> push_event("show_notification", %{
              message: "Configuration restored from backup",
              type: "info"
            })

          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
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
              chain_config_open={@chain_config_open}
              chain_config_collapsed={@chain_config_collapsed}
              config_selected_chain={@config_selected_chain}
              config_form_data={@config_form_data}
              config_validation_errors={@config_validation_errors}
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
      |> assign_new(:chain_config_open, fn -> false end)
      |> assign_new(:chain_config_collapsed, fn -> true end)
      |> assign_new(:config_selected_chain, fn -> nil end)
      |> assign_new(:config_form_data, fn -> %{} end)
      |> assign_new(:config_validation_errors, fn -> [] end)
      |> assign_new(:config_expanded_providers, fn -> MapSet.new() end)
      |> assign_new(:quick_add_open, fn -> false end)
      |> assign_new(:quick_add_data, fn -> %{} end)

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
        chain_config_open={@chain_config_open}
      />

      <!-- Floating Chain Configuration Window (top-left) -->
      <.floating_chain_config_window
        chain_config_open={@chain_config_open}
        chain_config_collapsed={@chain_config_collapsed}
        config_selected_chain={@config_selected_chain}
        config_form_data={@config_form_data}
        config_validation_errors={@config_validation_errors}
        available_chains={@available_chains}
        config_expanded_providers={@config_expanded_providers}
        quick_add_open={@quick_add_open}
        quick_add_data={@quick_add_data}
      />

    </div>
    """
  end

  # Floating Chain Configuration Window (top-left)
  def floating_chain_config_window(assigns) do
    assigns =
      assigns
      |> assign_new(:chain_config_open, fn -> false end)
      |> assign_new(:chain_config_collapsed, fn -> true end)
      |> assign_new(:config_selected_chain, fn -> nil end)
      |> assign_new(:config_form_data, fn -> %{} end)
      |> assign_new(:config_validation_errors, fn -> [] end)
      |> assign_new(:available_chains, fn -> [] end)
      |> assign_new(:config_expanded_providers, fn -> MapSet.new() end)

    ~H"""
    <div class={[
      "pointer-events-none absolute top-4 left-4 z-40 transition-all duration-300",
      if(@chain_config_open,
        do: if(@chain_config_collapsed, do: "w-80 h-12", else: "w-[28rem] h-[32rem]"),
        else: "w-80 h-12 opacity-0 pointer-events-none scale-90"
      )
    ]}>
      <div class={[
        "border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg",
        "transition-all duration-300",
        unless(@chain_config_open, do: "scale-90 opacity-0")
      ]}>
        <!-- Header / Collapsed State -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-4 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class="h-2 w-2 rounded-full bg-purple-400"></div>
            <div class="truncate text-sm font-medium text-gray-200">Chain Configuration</div>
            <%= if @chain_config_collapsed do %>
              <div class="text-xs text-gray-400">
                ({length(@available_chains)} chains)
              </div>
            <% end %>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle_chain_config_collapsed"
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              {if @chain_config_collapsed, do: "↙", else: "↖"}
            </button>
            <button
              phx-click="close_chain_config"
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              ×
            </button>
          </div>
        </div>

        <%= unless @chain_config_collapsed do %>
          <!-- Expanded Three-Panel Layout -->
          <div class="flex flex-col h-[28rem]">
            <!-- Chain List Panel -->
            <div class="border-gray-700/50 border-b p-3 h-40">
              <div class="flex items-center justify-between mb-2">
                <h4 class="text-sm font-semibold text-gray-300">Configured Chains</h4>
                <button
                  phx-click="toggle_quick_add"
                  class="bg-purple-600 hover:bg-purple-500 rounded px-2 py-1 text-xs text-white transition-colors"
                >
                  + Add Provider
                </button>
              </div>
              <div class="space-y-1 max-h-24 overflow-y-auto">
                <%= for chain <- @available_chains do %>
                  <button
                    phx-click="select_config_chain"
                    phx-value-chain={chain.name}
                    class={[
                      "w-full text-left px-2 py-1.5 rounded text-xs transition-colors flex items-center justify-between",
                      if(@config_selected_chain == chain.name,
                        do: "bg-purple-600/20 border border-purple-600/40 text-purple-200",
                        else: "bg-gray-800/40 hover:bg-gray-700/60 text-gray-300"
                      )
                    ]}
                  >
                    <div>
                      <div class="font-medium">{String.capitalize(chain.name)}</div>
                      <div class="text-gray-400">Chain ID: {chain.chain_id || "—"}</div>
                    </div>
                    <div class="text-xs text-gray-400">{length(chain.providers || [])} providers</div>
                  </button>
                <% end %>
                <%= if Enum.empty?(@available_chains) do %>
                  <div class="text-xs text-gray-500 text-center py-4">
                    No chains configured
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Configuration Form Panel -->
            <div class="flex-1 p-3 overflow-y-auto">
              <%= if @quick_add_open do %>
                <.quick_add_provider_form quick_add_data={@quick_add_data} />
              <% else %>
                <%= if @config_selected_chain do %>
                  <.chain_config_form
                    selected_chain={@config_selected_chain}
                    form_data={@config_form_data}
                    validation_errors={@config_validation_errors}
                    expanded={@config_expanded_providers}
                  />
                <% else %>
                  <div class="text-center text-gray-500 text-sm py-8">
                    <svg class="h-12 w-12 mx-auto text-gray-600 mb-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.806.547M8 4h8l-1 1v5.172a2 2 0 00.586 1.414l5 5c1.26 1.26.367 3.414-1.415 3.414H4.828c-1.782 0-2.674-2.154-1.414-3.414l5-5A 2 2 0 009 10.172V5L8 4z"/>
                    </svg>
                    <p>Select a chain to configure</p>
                    <p class="text-xs text-gray-600 mt-1">or add a provider</p>
                  </div>
                <% end %>
              <% end %>
            </div>

            <!-- Action Buttons Panel -->
            <div class="border-gray-700/50 border-t p-3 flex justify-between items-center">
              <div class="flex items-center space-x-2">
                <%= if @config_selected_chain do %>
                  <button
                    phx-click="test_chain_config"
                    class="bg-blue-600 hover:bg-blue-500 rounded px-3 py-1.5 text-xs text-white transition-colors"
                  >
                    Test Connection
                  </button>
                  <button
                    phx-click="delete_chain_config"
                    class="bg-red-600 hover:bg-red-500 rounded px-3 py-1.5 text-xs text-white transition-colors"
                  >
                    Delete Chain
                  </button>
                <% end %>
              </div>
              <div class="flex items-center space-x-2">
                <button
                  type="submit"
                  form="chain-config-form"
                  class="bg-emerald-600 hover:bg-emerald-500 rounded px-3 py-1.5 text-xs text-white transition-colors font-medium"
                >
                  Save Changes
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def chain_config_form(assigns) do
    assigns =
      assigns
      |> assign_new(:selected_chain, fn -> nil end)
      |> assign_new(:form_data, fn -> %{} end)
      |> assign_new(:validation_errors, fn -> [] end)
      |> assign_new(:expanded, fn -> MapSet.new() end)

    ~H"""
    <form id="chain-config-form" phx-change="config_form_change" phx-submit="save_chain_config" class="space-y-4">
      <div class="text-sm font-medium text-gray-300">
        Configure: <span class="text-purple-300">{String.capitalize(@selected_chain)}</span>
      </div>

      <!-- Basic Chain Information -->
      <div class="grid grid-cols-2 gap-3">
        <div class="col-span-2">
          <label class="block text-[11px] font-medium text-gray-400 mb-1">Chain Name</label>
          <input
            type="text"
            name="chain[name]"
            value={Map.get(@form_data, :name, String.capitalize(@selected_chain))}
            phx-debounce="300"
            class="w-full bg-gray-800/80 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="e.g., Ethereum Mainnet"
          />
        </div>
        <div>
          <label class="block text-[11px] font-medium text-gray-400 mb-1">Chain ID</label>
          <input
            type="number"
            name="chain[chain_id]"
            value={Map.get(@form_data, :chain_id, "")}
            phx-debounce="300"
            class="w-full bg-gray-800/80 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="1"
          />
        </div>
        <div>
          <label class="block text-[11px] font-medium text-gray-400 mb-1">Block Time (ms)</label>
          <input
            type="number"
            name="chain[block_time]"
            value={Map.get(@form_data, :block_time, 12000)}
            phx-debounce="300"
            class="w-full bg-gray-800/80 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="12000"
          />
        </div>
      </div>

      <!-- Providers Section -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="block text-[11px] font-medium text-gray-400">Providers</label>
          <button
            type="button"
            phx-click="add_provider"
            class="bg-purple-600 hover:bg-purple-500 rounded px-2 py-1 text-xs text-white transition-colors"
          >
            + Add Provider
          </button>
        </div>

        <div class="space-y-2 max-h-40 overflow-y-auto pr-1">
          <%= for {provider, idx} <- Enum.with_index(Map.get(@form_data, :providers, [])) do %>
            <div class="bg-gray-800/60 border border-gray-700/70 rounded">
              <div class="flex items-center justify-between px-2 py-2">
                <button type="button" phx-click="toggle_provider_row" phx-value-index={idx} class="flex items-center gap-2 text-left flex-1">
                  <svg class={["h-3 w-3 transition-transform", if(MapSet.member?(@expanded, idx), do: "rotate-90 text-purple-300", else: "text-gray-400")]} viewBox="0 0 20 20" fill="currentColor"><path d="M6 6l6 4-6 4V6z"/></svg>
                  <span class="text-sm text-white truncate">{provider.name || "Provider #{idx + 1}"}</span>
                </button>
                <button type="button" phx-click="remove_provider" phx-value-index={idx} class="text-rose-400 hover:text-rose-300 text-xs px-2">Remove</button>
              </div>
              <%= if MapSet.member?(@expanded, idx) do %>
                <div class="border-t border-gray-700/60 p-2 space-y-2">
                  <div class="grid grid-cols-1 gap-2">
                    <input
                      type="url"
                      name={"chain[providers][#{idx}][url]"}
                      placeholder="https://rpc.example.com"
                      value={provider.url || ""}
                      phx-debounce="300"
                      class="w-full bg-gray-900/60 border border-gray-600/70 rounded px-2 py-1.5 text-xs text-white placeholder-gray-500 focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                    />
                    <input
                      type="url"
                      name={"chain[providers][#{idx}][ws_url]"}
                      placeholder="wss://ws.example.com (optional)"
                      value={provider.ws_url || ""}
                      phx-debounce="300"
                      class="w-full bg-gray-900/60 border border-gray-600/70 rounded px-2 py-1.5 text-xs text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
                    />
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if Enum.empty?(Map.get(@form_data, :providers, [])) do %>
            <div class="text-xs text-gray-500 text-center py-2">
              No providers configured
            </div>
          <% end %>
        </div>
      </div>

      <!-- Validation Errors -->
      <%= if not Enum.empty?(@validation_errors) do %>
        <div class="bg-red-900/20 border border-red-600/40 rounded p-2">
          <div class="text-xs font-medium text-red-400 mb-1">Validation Errors:</div>
          <%= for error <- @validation_errors do %>
            <div class="text-xs text-red-300">• {error}</div>
          <% end %>
        </div>
      <% end %>
    </form>
    """
  end

  def chain_details_panel(assigns) do
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    assigns =
      Map.merge(assigns, %{
        chain_connections: chain_connections,
        chain_events: Enum.filter(assigns.routing_events, &(&1.chain == assigns.chain)),
        chain_provider_events: Enum.filter(assigns.provider_events, &(&1.chain == assigns.chain)),
        chain_unified_events: Enum.filter(Map.get(assigns, :events, []), fn e -> e[:chain] == assigns.chain end),
        chain_endpoints: EndpointHelpers.get_chain_endpoints(assigns, assigns.chain),
        chain_performance: MetricsHelpers.get_chain_performance_metrics(assigns, assigns.chain),
        sample_curl: Helpers.get_sample_curl_command(),
        selected_strategy_tab: "fastest",
        selected_provider_tab: List.first(chain_connections),
        active_endpoint_tab: "strategy",
        last_decision: Helpers.get_last_decision(assigns.routing_events, assigns.chain)
      })

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

          <!-- WebSocket Endpoint -->
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
    assigns =
      Map.merge(assigns, %{
        provider_connection: Enum.find(assigns.connections, &(&1.id == assigns.provider)),
        provider_events: Enum.filter(assigns.routing_events, &(&1.provider_id == assigns.provider)),
        provider_pool_events: Enum.filter(assigns.provider_events, &(&1.provider_id == assigns.provider)),
        provider_unified_events: Enum.filter(Map.get(assigns, :events, []), fn e -> e[:provider_id] == assigns.provider end),
        performance_metrics: MetricsHelpers.get_provider_performance_metrics(assigns.provider, assigns.connections, assigns.routing_events),
        last_decision: Helpers.get_last_decision(assigns.routing_events, nil, assigns.provider)
      })

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
                {if @provider_connection, do: String.capitalize(@provider_connection.chain || "unknown"), else: "Provider"} • {StatusHelpers.provider_status_label(@provider_connection)}
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
              <span class={StatusHelpers.provider_status_class_text(@provider_connection)}>
                {StatusHelpers.provider_status_label(@provider_connection)}
              </span>
            </div>

            <div class="flex items-center space-x-3">
              <span class="text-gray-400">Pick share (5m):</span>
              <span class="text-white">{(@performance_metrics.pick_share_5m || 0.0) |> Helpers.to_float() |> Float.round(1)}%</span>
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
  def floating_details_window(assigns) do
    assigns =
      assigns
      |> assign_new(:details_collapsed, fn -> true end)
      |> assign_new(:hover_chain, fn -> nil end)
      |> assign_new(:hover_provider, fn -> nil end)
      |> assign_new(:events, fn -> [] end)
      |> assign_new(:chain_config_open, fn -> false end)
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

            <!-- Chain Configuration Button -->
            <button
              phx-click="toggle_chain_config"
              class={[
                "bg-gray-800/60 rounded px-2 py-1 text-xs transition-colors hover:bg-gray-700/60",
                if(@chain_config_open, do: "text-purple-300 bg-purple-900/30", else: "text-gray-200")
              ]}
              title="Configure Chains"
            >
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                      d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
              </svg>
            </button>

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
                  {MetricsHelpers.rpc_calls_per_second(@routing_events)}
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">Errors</div>
                <div class="text-xs font-medium text-red-300">
                  {MetricsHelpers.error_rate_percent(@routing_events)}%
                </div>
              </div>
              <div class="bg-gray-800/40 rounded-md px-2 py-1">
                <div class="text-[10px] text-gray-400">Failovers</div>
                <div class="text-xs font-medium text-yellow-300">
                  {MetricsHelpers.failovers_last_minute(@routing_events)}
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
    assigns =
      assigns
      |> assign_new(:vm_metrics, fn -> %{} end)
      |> assign_new(:last_updated, fn -> "Never" end)
      |> assign_new(:connections, fn -> [] end)
      |> assign_new(:routing_events, fn -> [] end)
      |> assign_new(:provider_events, fn -> [] end)

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

  # Chain Configuration Event Handlers
  @impl true
  def handle_event("toggle_chain_config", _params, socket) do
    Logger.info("Toggling chain config window")
    new_open = not socket.assigns.chain_config_open
    socket =
      socket
      |> assign(:chain_config_open, new_open)
      |> assign(:chain_config_collapsed, not new_open)  # Auto-expand when opening

    # Load available chains when opening
    socket = if new_open do
      case Livechain.Config.ChainConfigManager.list_chains() do
        {:ok, chains} ->
          chain_list = Enum.map(chains, fn {name, config} ->
            %{
              name: name,
              chain_id: config.chain_id,
              providers: config.providers
            }
          end)
          assign(socket, :available_chains, chain_list)

        {:error, _reason} ->
          assign(socket, :available_chains, [])
      end
    else
      socket
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_chain_config_collapsed", _params, socket) do
    {:noreply, update(socket, :chain_config_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("close_chain_config", _params, socket) do
    socket =
      socket
      |> assign(:chain_config_open, false)
      |> assign(:config_selected_chain, nil)
      |> assign(:config_form_data, %{})
      |> assign(:config_validation_errors, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_config_chain", %{"chain" => chain_name}, socket) do
    # Load the selected chain's configuration
    case Livechain.Config.ChainConfigManager.get_chain(chain_name) do
      {:ok, config} ->
        form_data = %{
          name: config.name,
          chain_id: config.chain_id,
          block_time: config.block_time,
          providers: Enum.map(config.providers, fn provider ->
            %{
              id: provider.id,
              name: provider.name,
              url: provider.url,
              ws_url: provider.ws_url,
              priority: provider.priority,
              type: provider.type,
              api_key_required: provider.api_key_required,
              region: provider.region
            }
          end)
        }

        socket =
          socket
          |> assign(:config_selected_chain, chain_name)
          |> assign(:config_form_data, form_data)
          |> assign(:config_validation_errors, [])
          |> assign(:config_expanded_providers, MapSet.new())

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("add_new_chain", _params, socket) do
    # Set up for adding a new chain
    socket =
      socket
      |> assign(:config_selected_chain, "new_chain")
      |> assign(:config_form_data, %{
        name: "",
        chain_id: nil,
        block_time: 12000,
        providers: []
      })
      |> assign(:config_validation_errors, [])
      |> assign(:config_expanded_providers, MapSet.new())

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_chain_config", _params, socket) do
    chain_name = socket.assigns.config_selected_chain
    form_data = socket.assigns.config_form_data

    # Convert form data to the format expected by ChainConfigManager
    chain_attrs = %{
      "name" => Map.get(form_data, :name, ""),
      "chain_id" => Map.get(form_data, :chain_id),
      "block_time" => Map.get(form_data, :block_time, 12000),
      "providers" => Enum.map(Map.get(form_data, :providers, []), fn provider ->
        %{
          "id" => provider.id || "",
          "name" => provider.name || "",
          "url" => provider.url || "",
          "ws_url" => provider.ws_url,
          "priority" => provider.priority || 1,
          "type" => provider.type || "public",
          "api_key_required" => provider.api_key_required || false,
          "region" => provider.region
        }
      end)
    }

    result = if chain_name == "new_chain" do
      # Create new chain
      actual_chain_name = String.downcase(Map.get(form_data, :name, "")) |> String.replace(~r/[^a-z0-9]/, "_")
      Livechain.Config.ChainConfigManager.create_chain(actual_chain_name, chain_attrs)
    else
      # Update existing chain
      Livechain.Config.ChainConfigManager.update_chain(chain_name, chain_attrs)
    end

    case result do
      {:ok, _config} ->
        # Reload chains list and show success
        case Livechain.Config.ChainConfigManager.list_chains() do
          {:ok, chains} ->
            chain_list = Enum.map(chains, fn {name, config} ->
              %{name: name, chain_id: config.chain_id, providers: config.providers}
            end)

            socket =
              socket
              |> assign(:available_chains, chain_list)
              |> assign(:config_validation_errors, [])
              |> push_event("show_success", %{message: "Chain configuration saved successfully"})

            {:noreply, socket}

          {:error, _} ->
            {:noreply, socket}
        end

      {:error, reason} ->
        error_message = case reason do
          :chain_already_exists -> "Chain already exists"
          {:invalid_chain_config, _} -> "Invalid chain configuration"
          _ -> "Failed to save chain configuration"
        end

        socket = assign(socket, :config_validation_errors, [error_message])
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("test_chain_config", _params, socket) do
    chain_name = socket.assigns.config_selected_chain

    # Test connectivity using the API endpoint
    case Livechain.Config.ChainConfigManager.get_chain(chain_name) do
      {:ok, config} ->
        # Test each provider
        test_results = Enum.map(config.providers, fn provider ->
          case Livechain.Config.ConfigValidator.test_provider_connectivity(provider) do
            :ok -> "✓ #{provider.name}: Connected"
            {:error, reason} -> "✗ #{provider.name}: #{inspect(reason)}"
          end
        end)

        socket = push_event(socket, "show_test_results", %{results: test_results})
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_chain_config", _params, socket) do
    chain_name = socket.assigns.config_selected_chain

    case Livechain.Config.ChainConfigManager.delete_chain(chain_name) do
      :ok ->
        # Reload chains list
        case Livechain.Config.ChainConfigManager.list_chains() do
          {:ok, chains} ->
            chain_list = Enum.map(chains, fn {name, config} ->
              %{name: name, chain_id: config.chain_id, providers: config.providers}
            end)

            socket =
              socket
              |> assign(:available_chains, chain_list)
              |> assign(:config_selected_chain, nil)
              |> assign(:config_form_data, %{})
              |> push_event("show_success", %{message: "Chain deleted successfully"})

            {:noreply, socket}

          {:error, _} ->
            {:noreply, socket}
        end

      {:error, reason} ->
        error_message = "Failed to delete chain: #{inspect(reason)}"
        socket = assign(socket, :config_validation_errors, [error_message])
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("add_provider", _params, socket) do
    current_providers = Map.get(socket.assigns.config_form_data, :providers, [])
    new_provider = %{
      id: "provider_#{length(current_providers) + 1}",
      name: "",
      url: "",
      ws_url: nil,
      priority: length(current_providers) + 1,
      type: "public",
      api_key_required: false,
      region: nil
    }

    updated_providers = current_providers ++ [new_provider]
    updated_form_data = Map.put(socket.assigns.config_form_data, :providers, updated_providers)

    # auto-expand the newly added row
    expanded = Map.get(socket.assigns, :config_expanded_providers, MapSet.new())
    expanded = MapSet.put(expanded, length(updated_providers) - 1)

    {:noreply, socket |> assign(:config_form_data, updated_form_data) |> assign(:config_expanded_providers, expanded)}
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

  @impl true
  def handle_event("remove_provider", %{"index" => index}, socket) do
    idx =
      case Integer.parse(index || "") do
        {val, _} -> val
        _ -> -1
      end

    current_providers = Map.get(socket.assigns.config_form_data, :providers, [])

    updated_providers =
      if idx >= 0 and idx < length(current_providers) do
        List.delete_at(current_providers, idx)
      else
        current_providers
      end

    updated_form_data = Map.put(socket.assigns.config_form_data, :providers, updated_providers)

    # Reindex expanded set to keep following rows consistent after deletion
    old_expanded = Map.get(socket.assigns, :config_expanded_providers, MapSet.new())
    new_expanded =
      old_expanded
      |> Enum.reduce(MapSet.new(), fn i, acc ->
        cond do
          i == idx -> acc
          i > idx -> MapSet.put(acc, i - 1)
          true -> MapSet.put(acc, i)
        end
      end)

    {:noreply, socket |> assign(:config_form_data, updated_form_data) |> assign(:config_expanded_providers, new_expanded)}
  end

  @impl true
  def handle_event("config_form_change", %{"chain" => chain_params}, socket) do
    current = Map.get(socket.assigns, :config_form_data, %{})

    chain_id =
      case Integer.parse(Map.get(chain_params, "chain_id", "")) do
        {v, _} -> v
        _ -> nil
      end

    block_time =
      case Integer.parse(Map.get(chain_params, "block_time", "")) do
        {v, _} -> v
        _ -> 12000
      end

    providers_params = Map.get(chain_params, "providers", %{})

    providers_list =
      providers_params
      |> Enum.sort_by(fn {k, _} ->
        case Integer.parse(k) do
          {v, _} -> v
          _ -> 0
        end
      end)
      |> Enum.with_index()
      |> Enum.map(fn {{_k, attrs}, i} ->
        existing = Enum.at(Map.get(current, :providers, []), i) || %{}
        %{
          id: Map.get(existing, :id) || Map.get(existing, "id") || "provider_#{i + 1}",
          name: Map.get(attrs, "name", existing[:name] || ""),
          url: Map.get(attrs, "url", existing[:url] || ""),
          ws_url: Map.get(attrs, "ws_url", existing[:ws_url]),
          priority: Map.get(existing, :priority) || i + 1,
          type: Map.get(existing, :type) || "public",
          api_key_required: Map.get(existing, :api_key_required) || false,
          region: Map.get(existing, :region)
        }
      end)

    form_data = %{
      name: Map.get(chain_params, "name", current[:name] || ""),
      chain_id: chain_id,
      block_time: block_time,
      providers: providers_list
    }

    {:noreply, assign(socket, :config_form_data, form_data)}
  end

  @impl true
  def handle_event("toggle_provider_row", %{"index" => index}, socket) do
    idx = case Integer.parse(index || "") do
      {v, _} -> v
      _ -> -1
    end

    expanded = Map.get(socket.assigns, :config_expanded_providers, MapSet.new())

    new_expanded =
      if idx >= 0 do
        if MapSet.member?(expanded, idx), do: MapSet.delete(expanded, idx), else: MapSet.put(expanded, idx)
      else
        expanded
      end

    {:noreply, assign(socket, :config_expanded_providers, new_expanded)}
  end

  # Helper functions

  defp fetch_connections(socket) do
    connections = Livechain.RPC.ChainRegistry.list_all_connections()
    latency_leaders = MetricsHelpers.get_latency_leaders_by_chain(connections)

    socket
    |> assign(:connections, connections)
    |> assign(:latency_leaders, latency_leaders)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end

  def quick_add_provider_form(assigns) do
    assigns =
      assigns
      |> assign_new(:quick_add_data, fn -> %{} end)

    ~H"""
    <form id="quick-add-form" phx-change="quick_add_change" phx-submit="quick_add_submit" class="space-y-3">
      <div class="text-sm font-semibold text-gray-300">Add Provider</div>
      <div class="grid grid-cols-2 gap-2">
        <div>
          <label class="block text-[11px] text-gray-400 mb-1">Chain Name</label>
          <input type="text" name="qa[name]" value={Map.get(@quick_add_data, :name, "")} placeholder="e.g., Arbitrum" phx-debounce="300" class="w-full bg-gray-800/80 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500" />
        </div>
        <div>
          <label class="block text-[11px] text-gray-400 mb-1">Chain ID</label>
          <input type="number" name="qa[chain_id]" value={Map.get(@quick_add_data, :chain_id, "")} placeholder="42161" phx-debounce="300" class="w-full bg-gray-800/80 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500" />
        </div>
        <div class="col-span-2">
          <label class="block text-[11px] text-gray-400 mb-1">HTTP URL</label>
          <input type="url" name="qa[url]" value={Map.get(@quick_add_data, :url, "")} placeholder="https://rpc.example.com" phx-debounce="300" class="w-full bg-gray-900/60 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-sky-500 focus:ring-1 focus:ring-sky-500" />
        </div>
        <div class="col-span-2">
          <label class="block text-[11px] text-gray-400 mb-1">WS URL (optional)</label>
          <input type="url" name="qa[ws_url]" value={Map.get(@quick_add_data, :ws_url, "")} placeholder="wss://ws.example.com" phx-debounce="300" class="w-full bg-gray-900/60 border border-gray-600/70 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500" />
        </div>
      </div>
      <div class="flex items-center justify-end gap-2 pt-2">
        <button type="button" phx-click="toggle_quick_add" class="bg-gray-700/80 hover:bg-gray-600 rounded px-3 py-1.5 text-xs text-gray-200">Cancel</button>
        <button type="submit" form="quick-add-form" class="bg-emerald-600 hover:bg-emerald-500 rounded px-3 py-1.5 text-xs text-white font-medium">Add Provider</button>
      </div>
    </form>
    """
  end

  @impl true
  def handle_event("toggle_quick_add", _params, socket) do
    {:noreply, socket |> update(:quick_add_open, &(!&1))}
  end

  @impl true
  def handle_event("quick_add_change", %{"qa" => qa}, socket) do
    chain_id = case Integer.parse(Map.get(qa, "chain_id", "")) do
      {v, _} -> v
      _ -> nil
    end

    data = %{
      name: Map.get(qa, "name", ""),
      chain_id: chain_id,
      url: Map.get(qa, "url", ""),
      ws_url: Map.get(qa, "ws_url", "")
    }

    {:noreply, assign(socket, :quick_add_data, data)}
  end

  @impl true
  def handle_event("quick_add_submit", %{"qa" => qa}, socket) do
    name = Map.get(qa, "name", "")
    chain_id = case Integer.parse(Map.get(qa, "chain_id", "")) do
      {v, _} -> v
      _ -> nil
    end
    url = Map.get(qa, "url", "")
    ws_url = Map.get(qa, "ws_url")

    # If a chain is selected, attach; otherwise, create or fetch by name
    target_chain = socket.assigns.config_selected_chain || String.downcase(name) |> String.replace(~r/[^a-z0-9]/, "_")

    chain_exists = case Livechain.Config.ChainConfigManager.get_chain(target_chain) do
      {:ok, _} -> true
      _ -> false
    end

    provider = %{
      "id" => "provider_#{System.unique_integer([:positive])}",
      "name" => name <> " RPC",
      "url" => url,
      "ws_url" => ws_url,
      "priority" => 1,
      "type" => "public",
      "api_key_required" => false
    }

    result = if chain_exists do
      # Append provider to existing chain
      case Livechain.Config.ChainConfigManager.get_chain(target_chain) do
        {:ok, cfg} ->
          providers = (cfg.providers || []) ++ [provider |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)]
          attrs = %{
            "name" => cfg.name || name,
            "chain_id" => cfg.chain_id || chain_id,
            "block_time" => cfg.block_time || 12000,
            "providers" => Enum.map(providers, fn p -> %{
              "id" => p[:id] || provider["id"],
              "name" => p[:name] || provider["name"],
              "url" => p[:url] || provider["url"],
              "ws_url" => p[:ws_url] || provider["ws_url"],
              "priority" => p[:priority] || 1,
              "type" => p[:type] || "public",
              "api_key_required" => p[:api_key_required] || false,
              "region" => p[:region]
            } end)
          }
          Livechain.Config.ChainConfigManager.update_chain(target_chain, attrs)

        err -> err
      end
    else
      # Create new chain with a single provider
      attrs = %{
        "name" => name,
        "chain_id" => chain_id,
        "block_time" => 12000,
        "providers" => [provider]
      }
      Livechain.Config.ChainConfigManager.create_chain(target_chain, attrs)
    end

    case result do
      {:ok, _cfg} ->
        # refresh chains and switch to the target
        {:ok, chains} = Livechain.Config.ChainConfigManager.list_chains()
        chain_list = Enum.map(chains, fn {nm, cfg} -> %{name: nm, chain_id: cfg.chain_id, providers: cfg.providers} end)

        socket = socket
        |> assign(:available_chains, chain_list)
        |> assign(:config_selected_chain, target_chain)
        |> assign(:quick_add_open, false)
        |> assign(:quick_add_data, %{})
        |> push_event("show_success", %{message: "Provider added"})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :config_validation_errors, ["Failed to add provider: #{inspect(reason)}"])}
    end
  end

 end
