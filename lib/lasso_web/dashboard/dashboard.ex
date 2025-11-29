defmodule LassoWeb.Dashboard do
  use LassoWeb, :live_view
  require Logger

  alias LassoWeb.NetworkTopology
  alias LassoWeb.Dashboard.{Helpers, MetricsHelpers, StatusHelpers, EndpointHelpers, Constants, Status, EventBuffer, Formatting}
  alias LassoWeb.Dashboard.Components
  alias LassoWeb.Components.DashboardHeader
  alias LassoWeb.Components.NetworkStatusLegend
  alias LassoWeb.Components.DashboardComponents
  alias Lasso.Events.Provider

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :active_tab, Map.get(params, "tab", "overview"))

    if connected?(socket) do
      # Global subscriptions
      Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:decisions")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "clients:events")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "chain_config_changes")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "chain_config_updates")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "dashboard:event_buffer")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "sync:updates")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "block_cache:updates")

      # Per-chain provider event subscriptions
      Lasso.Config.ConfigStore.list_chains()
      |> Enum.each(fn chain ->
        Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")
      end)

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

      Process.send_after(self(), :vm_metrics_tick, Constants.vm_metrics_interval())
      Process.send_after(self(), :latency_leaders_refresh, Constants.latency_refresh_interval())
      Process.send_after(self(), :metrics_refresh, Constants.vm_metrics_interval())
    end

    # Transform chain names into map structures for the UI
    available_chains =
      Lasso.Config.ConfigStore.list_chains()
      |> Enum.map(fn chain_name ->
        %{
          name: chain_name,
          display_name: Helpers.get_chain_display_name(chain_name)
        }
      end)

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
      |> assign(:events, [])
      |> assign(:vm_metrics, %{})
      |> assign(:available_chains, available_chains)
      |> assign(:details_collapsed, true)
      |> assign(:events_collapsed, true)
      |> assign(:latency_leaders, %{})
      |> assign(:chain_config_open, true)
      |> assign(:chain_config_collapsed, true)
      |> assign(:selected_chain_metrics, %{})
      |> assign(:selected_chain_events, [])
      |> assign(:selected_chain_unified_events, [])
      |> assign(:selected_chain_endpoints, %{})
      |> assign(:selected_chain_provider_events, [])
      |> assign(:selected_provider_events, [])
      |> assign(:selected_provider_unified_events, [])
      |> assign(:selected_provider_metrics, %{})
      |> assign(:metrics_selected_chain, "ethereum")
      |> assign(:provider_metrics, [])
      |> assign(:method_metrics, [])
      |> assign(:metrics_loading, true)
      |> assign(:metrics_last_updated, nil)
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

    # Buffer all events from the batch
    socket = Enum.reduce(batch, socket, fn event, sock ->
      buffer_event(sock, event)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:connection_event, _event_type, _connection_id, _data}, socket) do
    socket = schedule_connection_refresh(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:connection_status_changed, _connection_id, _connection_data}, socket) do
    socket = schedule_connection_refresh(socket)
    {:noreply, socket}
  end

  # Routing decision feed (real or synthetic)
  @impl true
  def handle_info(
        %{
          ts: _ts,
          chain: chain,
          method: method,
          strategy: strategy,
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
      strategy: strategy,
      provider_id: pid,
      duration_ms: (if is_number(dur), do: round(dur), else: 0),
      result: Map.get(evt, :result, :unknown),
      failovers: Map.get(evt, :failover_count, 0)
    }

    socket = update(socket, :routing_events, fn list ->
      [entry | Enum.take(list, Constants.routing_events_limit() - 1)]
    end)

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
      |> buffer_event(ev)
      |> push_event("provider_request", %{provider_id: pid})

    # Update chain-specific metrics if this event is for the currently selected chain
    socket = if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end

    # Update provider-specific metrics if this event is for the currently selected provider
    socket = if socket.assigns[:selected_provider] == pid do
      update_selected_provider_data(socket)
    else
      socket
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(evt, socket)
      when is_struct(evt, Provider.Healthy) or
             is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.HealthCheckFailed) or
             is_struct(evt, Provider.WSConnected) or
             is_struct(evt, Provider.WSClosed) do
    {chain, pid, event, details, ts} =
      case evt do
        %Provider.Healthy{chain: chain, provider_id: pid, ts: ts} -> {chain, pid, :healthy, nil, ts}
        %Provider.Unhealthy{chain: chain, provider_id: pid, ts: ts} -> {chain, pid, :unhealthy, nil, ts}
        %Provider.HealthCheckFailed{chain: chain, provider_id: pid, reason: reason, ts: ts} ->
          {chain, pid, :health_check_failed, %{reason: reason}, ts}
        %Provider.WSConnected{chain: chain, provider_id: pid, ts: ts} -> {chain, pid, :ws_connected, nil, ts}
        %Provider.WSClosed{chain: chain, provider_id: pid, code: code, reason: reason, ts: ts} ->
          {chain, pid, :ws_closed, %{code: code, reason: reason}, ts}
      end

    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: ts,
      chain: chain,
      provider_id: pid,
      event: event,
      details: details
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, Constants.provider_events_limit() - 1)] end)

    uev =
      Helpers.as_event(:provider,
        chain: chain,
        provider_id: pid,
        severity: :info,
        message: to_string(event),
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket = buffer_event(socket, uev)

    # Update provider panel if this event is for the currently selected provider
    socket = if socket.assigns[:selected_provider] == pid do
      socket
      |> fetch_connections()
      |> update_selected_provider_data()
    else
      socket
    end

    # Update chain panel if this event is for the currently selected chain
    socket = if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end

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

    socket = update(socket, :client_events, fn list -> [entry | Enum.take(list, Constants.client_events_limit() - 1)] end)

    uev =
      Helpers.as_event(:client,
        chain: chain,
        severity: :debug,
        message: "client #{ev} via #{transport}",
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket = buffer_event(socket, uev)

    {:noreply, socket}
  end

  # Circuit breaker events - updated to match tuple format
  @impl true
  def handle_info({:circuit_breaker_event, event_data}, socket) do
    %{
      chain: chain,
      provider_id: provider_id,
      transport: transport,
      from: from_state,
      to: to_state,
      reason: reason
    } = event_data

    # Extract error details if present (new format includes error info)
    error_info = Map.get(event_data, :error)

    # Build message with error details when available
    base_message = "circuit [#{transport}]: #{from_state} -> #{to_state}"

    message =
      case {reason, error_info} do
        {:failure_threshold_exceeded, %{error_code: code, error_category: cat}} ->
          "#{base_message} — #{format_error_code(code)} (#{cat})"

        {:reopen_due_to_failure, %{error_code: code, error_category: cat}} ->
          "#{base_message} — #{format_error_code(code)} (#{cat})"

        {reason, _} ->
          "#{base_message} (#{format_reason(reason)})"
      end

    # Determine severity based on state transition
    severity =
      case to_state do
        :open -> :error
        :half_open -> :warn
        :closed -> :info
      end

    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: System.system_time(:millisecond),
      chain: chain,
      provider_id: provider_id,
      event: message
    }

    socket = update(socket, :provider_events, fn list -> [entry | Enum.take(list, Constants.provider_events_limit() - 1)] end)

    # Include error details in meta for expanded view
    meta_base = %{transport: transport, from: from_state, to: to_state, reason: reason}

    meta =
      if error_info do
        Map.merge(meta_base, %{
          error_code: error_info[:error_code],
          error_category: error_info[:error_category],
          error_message: error_info[:error_message]
        })
      else
        meta_base
      end

    uev =
      Helpers.as_event(:circuit,
        chain: chain,
        provider_id: provider_id,
        severity: severity,
        message: message,
        meta: meta
      )

    socket =
      socket
      |> buffer_event(uev)
      |> fetch_connections()  # Refresh provider data to show updated circuit state

    # Update provider panel if this event is for the currently selected provider
    socket = if socket.assigns[:selected_provider] == provider_id do
      update_selected_provider_data(socket)
    else
      socket
    end

    # Update chain panel if this event is for the currently selected chain
    socket = if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end

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

    socket = update(socket, :latest_blocks, fn list -> [entry | Enum.take(list, Constants.recent_blocks_limit() - 1)] end)

    uev =
      Helpers.as_event(:block,
        chain: chain,
        severity: :info,
        message:
          "block #{bn} (first: #{entry.provider_first || "n/a"}, +#{entry.margin_ms || 0}ms)",
        meta: Map.drop(entry, [:ts, :ts_ms])
      )

    socket = buffer_event(socket, uev)

    # Update chain-specific metrics if this event is for the currently selected chain
    socket = if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end

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

  # Provider metrics refresh
  @impl true
  def handle_info(:metrics_refresh, socket) do
    socket = load_provider_metrics(socket)
    Process.send_after(self(), :metrics_refresh, 30_000)
    {:noreply, socket}
  end

  # Provider panel periodic refresh (when provider is selected)
  @impl true
  def handle_info(:provider_panel_refresh, socket) do
    if socket.assigns[:selected_provider] do
      # Do the work first
      socket =
        socket
        |> fetch_connections()
        |> update_selected_provider_data()

      # Schedule next refresh AFTER work completes and store timer ref
      timer_ref = Process.send_after(self(), :provider_panel_refresh, 3_000)
      {:noreply, assign(socket, :provider_refresh_timer, timer_ref)}
    else
      # Provider no longer selected, clear timer ref and don't reschedule
      {:noreply, assign(socket, :provider_refresh_timer, nil)}
    end
  end

  # Live sync/block height updates from ProviderPool probes
  @impl true
  def handle_info(%{chain: _chain, provider_id: pid, block_height: _height} = _sync_update, socket) do
    # Update provider panel if this sync update is for the currently selected provider
    socket =
      if socket.assigns[:selected_provider] == pid do
        socket
        |> fetch_connections()
        |> update_selected_provider_data()
      else
        socket
      end

    {:noreply, socket}
  end

  # Real-time block updates from BlockCache (WebSocket newHeads)
  @impl true
  def handle_info(
        %{type: :block_update, provider_id: pid} = _block_update,
        socket
      ) do
    # Update provider panel if this block update is for the currently selected provider
    socket =
      if socket.assigns[:selected_provider] == pid do
        socket
        |> fetch_connections()
        |> update_selected_provider_data()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:flush_connections, socket) do
    Process.delete(:pending_connection_update)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:events_batch, events}, socket) do
    # Receive batched events from EventBuffer GenServer
    socket = push_event(socket, "events_batch", %{items: events})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:mode_change, mode}, socket) do
    # EventBuffer notifies of pressure mode changes
    message =
      case mode do
        :throttled -> "High event rate detected - adjusting update frequency"
        :summary -> "Critical event rate - dropping some events"
        _ -> "Event rate normalized"
      end

    socket = push_event(socket, "show_notification", %{message: message, type: "warning"})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_config_deleted, message}, socket) do
    socket =
      socket
      |> fetch_connections()
      |> push_event("show_notification", %{message: message, type: "warning"})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_config_test_results, results}, socket) do
    socket = push_event(socket, "show_test_results", %{results: results})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_config_notification, type, message}, socket) do
    socket = push_event(socket, "show_notification", %{message: message, type: Atom.to_string(type)})
    {:noreply, socket}
  end

  # Chain configuration change notifications (still needed for updating available chains)
  @impl true
  def handle_info({:chain_created, _chain_name, _chain_config}, socket) do
    socket =
      socket
      |> refresh_available_chains()
      |> fetch_connections()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_updated, _chain_name, _chain_config}, socket) do
    socket =
      socket
      |> refresh_available_chains()
      |> fetch_connections()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chain_deleted, _chain_name, _chain_config}, socket) do
    socket =
      socket
      |> refresh_available_chains()
      |> fetch_connections()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:config_restored, _backup_path, _}, socket) do
    socket =
      socket
      |> refresh_available_chains()
      |> fetch_connections()
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

      <DashboardHeader.header active_tab={@active_tab} />

    <!-- Content Section -->
      <div class="grid-pattern animate-fade-in relative flex-1 overflow-hidden">
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
              details_collapsed={@details_collapsed}
              events_collapsed={@events_collapsed}
              available_chains={@available_chains}
              chain_config_open={@chain_config_open}
              chain_config_collapsed={@chain_config_collapsed}
              selected_chain_metrics={@selected_chain_metrics}
              selected_chain_events={@selected_chain_events}
              selected_chain_unified_events={@selected_chain_unified_events}
              selected_chain_endpoints={@selected_chain_endpoints}
              selected_chain_provider_events={@selected_chain_provider_events}
              selected_provider_events={@selected_provider_events}
              selected_provider_unified_events={@selected_provider_unified_events}
              selected_provider_metrics={@selected_provider_metrics}
              latency_leaders={@latency_leaders}
            />
          <% "metrics" -> %>
            <.metrics_tab_content
              available_chains={@available_chains}
              metrics_selected_chain={@metrics_selected_chain}
              provider_metrics={@provider_metrics}
              method_metrics={@method_metrics}
              metrics_loading={@metrics_loading}
              metrics_last_updated={@metrics_last_updated}
            />
          <% "benchmarks" -> %>
            <DashboardComponents.benchmarks_tab_content />
          <% "system" -> %>
            <DashboardComponents.metrics_tab_content
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

  # Dashboard tab content attrs
  attr :connections, :list
  attr :routing_events, :list
  attr :provider_events, :list
  attr :client_events, :list
  attr :latest_blocks, :list
  attr :events, :list
  attr :selected_chain, :string
  attr :selected_provider, :string
  attr :details_collapsed, :boolean
  attr :events_collapsed, :boolean
  attr :available_chains, :list
  attr :chain_config_open, :boolean
  attr :chain_config_collapsed, :boolean, default: true
  attr :latency_leaders, :map, default: %{}
  attr :selected_chain_metrics, :map, default: %{}
  attr :selected_chain_events, :list, default: []
  attr :selected_chain_unified_events, :list, default: []
  attr :selected_chain_endpoints, :map, default: %{}
  attr :selected_chain_provider_events, :list, default: []
  attr :selected_provider_events, :list, default: []
  attr :selected_provider_unified_events, :list, default: []
  attr :selected_provider_metrics, :map, default: %{}

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
        available_chains={@available_chains}
      />

      <NetworkStatusLegend.legend />

      <.floating_details_window
        selected_chain={@selected_chain}
        selected_provider={@selected_provider}
        details_collapsed={@details_collapsed}
        connections={@connections}
        routing_events={@routing_events}
        provider_events={@provider_events}
        latest_blocks={@latest_blocks}
        events={@events}
        chain_config_open={@chain_config_open}
        chain_config_collapsed={@chain_config_collapsed}
        selected_chain_metrics={@selected_chain_metrics}
        selected_chain_events={@selected_chain_events}
        selected_chain_unified_events={@selected_chain_unified_events}
        selected_chain_endpoints={@selected_chain_endpoints}
        selected_chain_provider_events={@selected_chain_provider_events}
        selected_provider_events={@selected_provider_events}
        selected_provider_unified_events={@selected_provider_unified_events}
        selected_provider_metrics={@selected_provider_metrics}
      />

    </div>
    """
  end



  attr :chain, :string, required: true
  attr :connections, :list, required: true
  attr :routing_events, :list, required: true
  attr :provider_events, :list, required: true
  attr :events, :list, required: true
  attr :selected_chain_metrics, :map, required: true
  attr :selected_chain_events, :list, required: true
  attr :selected_chain_unified_events, :list, required: true
  attr :selected_chain_endpoints, :map, required: true
  attr :selected_chain_provider_events, :list, default: []

  def chain_details_panel(assigns) do
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    # Use cached chain data from socket assigns (updated by update_selected_chain_metrics/1)
    assigns = assigns
    |> assign(:chain_connections, chain_connections)
    |> assign(:chain_events, Map.get(assigns, :selected_chain_events, []))
    |> assign(:chain_provider_events, Map.get(assigns, :selected_chain_provider_events, []))
    |> assign(:chain_unified_events, Map.get(assigns, :selected_chain_unified_events, []))
    |> assign(:chain_endpoints, Map.get(assigns, :selected_chain_endpoints, %{}))
    |> assign(:chain_performance, Map.get(assigns, :selected_chain_metrics, %{}))
    |> assign(:last_decision, Helpers.get_last_decision(Map.get(assigns, :selected_chain_events, []), assigns.chain))


    ~H"""
    <div class="flex h-full flex-col" id={"chain-details-" <> @chain}>
      <!-- Header -->
      <div class="border-gray-700/50 border-b p-4">
        <% connected = Map.get(@chain_performance, :connected_providers, 0) %>
        <% total = Map.get(@chain_performance, :total_providers, 0) %>
        <div class="flex items-center justify-between">
          <div class="flex items-center space-x-3">
            <div class={[
              "h-3 w-3 rounded-full",
              if(connected == total && connected > 0,
                do: "bg-emerald-400",
                else: if(connected == 0, do: "bg-red-400", else: "bg-yellow-400")
              )
            ]}>
            </div>
            <div>
              <h3 class="text-lg font-semibold capitalize text-white">{@chain}</h3>
              <div class="text-xs text-gray-400 flex items-center gap-2">
                <span>{Helpers.get_chain_id(@chain)}</span>
                <span>•</span>
                <span><span class="text-emerald-400">{connected}</span>/<span class="text-gray-500">{total}</span> providers</span>
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
              <div class="text-lg font-bold text-sky-400">{if Map.get(@chain_performance, :p50_latency), do: "#{Map.get(@chain_performance, :p50_latency)}ms", else: "—"}</div>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Latency p95 (5m)</div>
            <div class="h-6 flex items-center justify-center">
              <div class="text-lg font-bold text-sky-400">{if Map.get(@chain_performance, :p95_latency), do: "#{Map.get(@chain_performance, :p95_latency)}ms", else: "—"}</div>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">Success (5m)</div>
            <div class="h-6 flex items-center justify-center">
              <% success_rate = Map.get(@chain_performance, :success_rate, 0.0) %>
              <div class={["text-lg font-bold", if(success_rate >= 95.0, do: "text-emerald-400", else: if(success_rate >= 80.0, do: "text-yellow-400", else: "text-red-400"))]}> {if success_rate > 0, do: "#{success_rate}%", else: "—"}</div>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-3 text-center overflow-hidden">
            <div class="text-[11px] leading-tight text-gray-400 truncate">RPS</div>
            <div class="h-6 flex items-center justify-center">
              <% rps = Map.get(@chain_performance, :rps, 0.0) %>
              <div class="text-lg font-bold text-purple-400">{if rps > 0, do: "#{rps}", else: "0"}</div>
            </div>
          </div>
        </div>
      </div>

      <!-- Routing decision context -->
      <div class="border-gray-700/50 border-t p-4">
        <h4 class="mb-2 text-sm font-semibold text-gray-300">Routing decisions</h4>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
          <.last_decision_card last_decision={@last_decision} connections={@connections} />
          <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-2">
            <div class="text-[11px] text-gray-400 mb-1">Decision breakdown (recent)</div>
            <% decision_share = Map.get(@chain_performance, :decision_share, []) %>
            <div class="space-y-1">
              <%= for {pid, pct} <- decision_share do %>
                <div class="flex items-center gap-2 text-[11px] text-gray-300">
                  <div class="w-28 truncate text-emerald-300">{pid}</div>
                  <div class="flex-1 bg-gray-900/60 rounded h-2">
                    <div class="bg-emerald-500 h-2 rounded" style={"width: #{Helpers.to_float(pct) |> Float.round(1)}%"}></div>
                  </div>
                  <div class="w-12 text-right text-gray-400">{Helpers.to_float(pct) |> Float.round(1)}%</div>
                </div>
              <% end %>
              <%= if Enum.empty?(decision_share) do %>
                <div class="text-xs text-gray-500">No decisions in the last 5 minutes</div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <!-- Endpoint Configuration -->
      <div id={"endpoint-config-#{@chain}"} class="border-gray-700/50 border-b p-4" phx-hook="TabSwitcher" data-chain={@chain} data-chain-id={Helpers.get_chain_id(@chain)}>
        <h4 class="mb-3 text-sm font-semibold text-gray-300">RPC Endpoints</h4>

        <div class="mb-4">
          <div class="text-xs text-gray-400 mb-2">Routing Strategy</div>
          <div class="flex flex-wrap gap-2">
            <%= for strategy <- EndpointHelpers.available_strategies() do %>
              <button
                data-strategy={strategy}
                class={[
                  "px-3 py-1 rounded-full text-xs transition-all border",
                  if strategy == "fastest" do
                    "border-sky-500 bg-sky-500/20 text-sky-300"
                  else
                    "border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300"
                  end
                ]}
              >
                <%= case strategy do %>
                  <% "fastest" -> %>⚡ Fastest
                  <% "round-robin" -> %>🔄 Round Robin
                  <% "latency-weighted" -> %>⚖️ Latency Weighted
                  <% other -> %>{other}
                <% end %>
              </button>
            <% end %>
          </div>
        </div>

        <div class="mb-2 text-xs text-gray-400">Provider Override (bypass routing)</div>
        <div class="mb-4 flex flex-wrap gap-2">
          <%= for provider <- @chain_connections do %>
            <% provider_status = StatusHelpers.determine_provider_status(provider) %>
            <%= if provider_status in [:healthy, :lagging, :recovering, :degraded] do %>
              <button
                data-provider={provider.id}
                data-provider-type={provider.type}
                data-provider-supports-ws={to_string(EndpointHelpers.provider_supports_websocket(provider))}
                class="px-3 py-1 rounded-full text-xs transition-all border border-gray-600 text-gray-300 hover:border-indigo-400 hover:text-indigo-300 flex items-center space-x-1"
              >
                <div class={["h-1.5 w-1.5 rounded-full", StatusHelpers.provider_status_indicator_class(provider)]}></div>
                <span>{provider.name}</span>
              </button>
            <% end %>
          <% end %>
          <% available_count = Enum.count(@chain_connections, fn p ->
            StatusHelpers.determine_provider_status(p) in [:healthy, :lagging, :recovering, :degraded]
          end) %>
          <%= if available_count == 0 do %>
            <span class="text-xs text-gray-500">No available providers</span>
          <% end %>
        </div>

        <!-- Endpoint Display -->
        <div class="bg-gray-800/30 rounded-lg p-3">
          <!-- HTTP Endpoint -->
          <div class="mb-3">
              <div class="mb-1 text-xs font-medium text-gray-300">HTTP</div>
            <div class="flex gap-1 items-center">
            <div class="flex-grow text-xs font-mono text-gray-500 bg-gray-900/50 rounded px-2 py-1 break-all" id="endpoint-url">
              {EndpointHelpers.get_strategy_http_url(@chain_endpoints, "fastest")}
            </div>
            <button
                data-copy-text={EndpointHelpers.get_strategy_http_url(@chain_endpoints, "fastest")}
                class="border border-gray-700 hover:border-gray-600 rounded px-2 py-1 text-xs text-white transition-colors"
              >
                Copy
              </button>
            </div>
          </div>

          <!-- WebSocket Endpoint -->
          <div class="mb-3">
            <div class="mb-1 text-xs font-medium text-gray-300">WebSocket</div>
            <div class="flex gap-1 items-center">
              <div class="flex-grow text-xs font-mono text-gray-500 bg-gray-900/50 rounded px-2 py-1 break-all" id="ws-endpoint-url">
                <%= if Enum.any?(@chain_connections, &EndpointHelpers.provider_supports_websocket/1) do %>
                  {EndpointHelpers.get_strategy_ws_url(@chain_endpoints, "fastest")}
                <% else %>
                  No WebSocket providers available for this chain
                <% end %>
              </div>
              <button
                data-copy-text={
                  if Enum.any?(@chain_connections, &EndpointHelpers.provider_supports_websocket/1) do
                    EndpointHelpers.get_strategy_ws_url(@chain_endpoints, "fastest")
                  else
                    ""
                  end
                }
                class="border border-gray-700 hover:border-gray-600 rounded px-2 py-1 text-xs text-white transition-colors"
              >
                Copy
              </button>
            </div>
          </div>

          <div class="text-xs text-gray-400" id="mode-description">
            Routes to fastest provider based on real-time latency benchmarks
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
                    <span class="font-mono text-gray-300">{to_string(event[:kind])}</span>
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
              <div class="text-center text-gray-500 text-xs py-4">No recent events for {Helpers.get_chain_display_name(@chain)}</div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def provider_details_panel(assigns) do
    # Use cached provider data from socket assigns (updated by update_selected_provider_data/1)
    assigns = assigns
      |> assign(:provider_connection, Enum.find(assigns.connections, &(&1.id == assigns.provider)))
      |> assign(:provider_events, Map.get(assigns, :selected_provider_events, []))
      |> assign(:provider_unified_events, Map.get(assigns, :selected_provider_unified_events, []))
      |> assign(:performance_metrics, Map.get(assigns, :selected_provider_metrics, %{}))



    ~H"""
    <div class="flex h-full flex-col overflow-y-auto" data-provider-id={@provider}>
      <!-- HEADER -->
      <div class="border-gray-700/50 border-b p-4">
        <div class="flex items-center justify-between">
          <div class="flex items-center space-x-3">
            <div class={[
              "h-3 w-3 rounded-full",
              StatusHelpers.provider_status_indicator_class(@provider_connection || %{})
            ]}>
            </div>
            <div>
              <h3 class="text-lg font-semibold text-white">
                {if @provider_connection, do: @provider_connection.name, else: @provider}
              </h3>
              <div class="text-xs text-gray-400">
                {if @provider_connection, do: Helpers.get_chain_display_name(@provider_connection.chain || "unknown"), else: "Provider"} • <span class={StatusHelpers.provider_status_class_text(@provider_connection || %{})}>{StatusHelpers.provider_status_label(@provider_connection || %{})}</span>
              </div>
            </div>
          </div>
          <button
            phx-click="select_provider"
            phx-value-provider=""
            class="rounded border border-gray-600 px-2 py-1 text-xs text-gray-400 transition-colors hover:border-gray-400 hover:text-white"
          >
            Close
          </button>
        </div>
      </div>

      <%= if @provider_connection do %>
        <!-- SYNC STATUS -->
        <div class="border-gray-700/50 border-b p-4">
          <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">Sync Status</h4>
          <% block_height = Map.get(@provider_connection, :block_height) %>
          <% consensus_height = Map.get(@provider_connection, :consensus_height) %>
          <% blocks_behind = Map.get(@provider_connection, :blocks_behind, 0) || 0 %>
          <%= if block_height && consensus_height do %>
            <div class="flex items-center justify-between text-sm mb-2">
              <span class="text-gray-400">Block Height: <span class="text-white font-mono">{Formatting.format_number(block_height)}</span></span>
              <span class="text-gray-400">Consensus: <span class="text-white font-mono">{Formatting.format_number(consensus_height)}</span></span>
              <span class={[
                "font-mono font-bold",
                cond do
                  blocks_behind <= 2 -> "text-emerald-400"
                  blocks_behind <= 10 -> "text-yellow-400"
                  true -> "text-red-400"
                end
              ]}>
                {cond do
                  blocks_behind >= 0 and blocks_behind <= 2 -> "Synced"
                  blocks_behind > 2 -> "-#{blocks_behind}"
                  blocks_behind < 0 -> "+#{abs(blocks_behind)}"
                end}
              </span>
            </div>
            <!-- Progress bar visualization -->
            <div class="h-2 bg-gray-800 rounded-full overflow-hidden mb-2">
              <% bar_width = if consensus_height > 0, do: min(100, (block_height / consensus_height) * 100), else: 100 %>
              <div
                class={[
                  "h-full rounded-full transition-all",
                  cond do
                    blocks_behind <= 2 -> "bg-emerald-500/60"
                    blocks_behind <= 10 -> "bg-yellow-500/60"
                    true -> "bg-red-500/60"
                  end
                ]}
                style={"width: #{bar_width}%"}
              />
            </div>
            <div class="text-xs text-gray-500 text-right">
              {cond do
                blocks_behind <= 2 -> "(within range)"
                blocks_behind <= 10 -> "(slightly behind)"
                true -> "(significantly behind)"
              end}
            </div>
          <% else %>
            <div class="text-sm text-gray-500">Block height data unavailable</div>
          <% end %>
        </div>

        <!-- PERFORMANCE -->
        <div class="border-gray-700/50 border-b p-4">
          <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">Performance</h4>
          <div class="grid grid-cols-4 gap-3">
            <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-700/50">
              <div class="text-[10px] text-gray-500 mb-1">p50</div>
              <div class="text-lg font-bold text-white">{if Map.get(@performance_metrics, :p50_latency), do: "#{Map.get(@performance_metrics, :p50_latency)}ms", else: "—"}</div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-700/50">
              <div class="text-[10px] text-gray-500 mb-1">p95</div>
              <div class="text-lg font-bold text-white">{if Map.get(@performance_metrics, :p95_latency), do: "#{Map.get(@performance_metrics, :p95_latency)}ms", else: "—"}</div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-700/50">
              <div class="text-[10px] text-gray-500 mb-1">Success</div>
              <% success_rate = Map.get(@performance_metrics, :success_rate, 0.0) %>
              <div class={[
                "text-lg font-bold",
                cond do
                  success_rate >= 99.0 -> "text-emerald-400"
                  success_rate >= 95.0 -> "text-yellow-400"
                  true -> "text-red-400"
                end
              ]}>{if success_rate > 0, do: "#{success_rate}%", else: "—"}</div>
            </div>
            <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-700/50">
              <div class="text-[10px] text-gray-500 mb-1">Traffic</div>
              <div class="text-lg font-bold text-white">{(Map.get(@performance_metrics, :pick_share_5m, 0.0) || 0.0) |> Helpers.to_float() |> Float.round(1)}%</div>
            </div>
          </div>
        </div>

        <!-- CONNECTION -->
        <div class="border-gray-700/50 border-b p-4">
          <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">Connection</h4>
          <div class="space-y-4">
            <!-- HTTP Circuit Breaker -->
            <% has_http = Map.get(@provider_connection, :url) != nil %>
            <%= if has_http do %>
              <div class="flex items-center gap-3">
                <span class="w-10 text-xs text-gray-400">HTTP</span>
                <div class="flex-1 flex items-center gap-1">
                  <% http_state = Map.get(@provider_connection, :http_circuit_state, :closed) %>
                  <div class={["w-3 h-3 rounded-full border-2", if(http_state == :closed, do: "bg-emerald-500 border-emerald-400", else: "border-gray-600")]}></div>
                  <div class="flex-1 h-0.5 bg-gray-700"></div>
                  <div class={["w-3 h-3 rounded-full border-2", if(http_state == :half_open, do: "bg-yellow-500 border-yellow-400", else: "border-gray-600")]}></div>
                  <div class="flex-1 h-0.5 bg-gray-700"></div>
                  <div class={["w-3 h-3 rounded-full border-2", if(http_state == :open, do: "bg-red-500 border-red-400", else: "border-gray-600")]}></div>
                </div>
                <span class={[
                  "w-20 text-xs text-right",
                  case http_state do
                    :closed -> "text-emerald-400"
                    :half_open -> "text-yellow-400"
                    :open -> "text-red-400"
                  end
                ]}>{http_state |> to_string() |> String.replace("_", "-") |> String.capitalize()}</span>
              </div>
              <div class="flex justify-between text-[10px] text-gray-600 px-11">
                <span>closed</span>
                <span>half-open</span>
                <span>open</span>
              </div>
            <% end %>

            <!-- WS Circuit Breaker -->
            <% has_ws = Map.get(@provider_connection, :ws_url) != nil %>
            <%= if has_ws do %>
              <div class="flex items-center gap-3 mt-3">
                <span class="w-10 text-xs text-gray-400">WS</span>
                <div class="flex-1 flex items-center gap-1">
                  <% ws_state = Map.get(@provider_connection, :ws_circuit_state, :closed) %>
                  <% ws_connected = Map.get(@provider_connection, :ws_connected, false) %>
                  <div class={["w-3 h-3 rounded-full border-2", if(ws_state == :closed, do: "bg-emerald-500 border-emerald-400", else: "border-gray-600")]}></div>
                  <div class="flex-1 h-0.5 bg-gray-700"></div>
                  <div class={["w-3 h-3 rounded-full border-2", if(ws_state == :half_open, do: "bg-yellow-500 border-yellow-400", else: "border-gray-600")]}></div>
                  <div class="flex-1 h-0.5 bg-gray-700"></div>
                  <div class={["w-3 h-3 rounded-full border-2", if(ws_state == :open, do: "bg-red-500 border-red-400", else: "border-gray-600")]}></div>
                </div>
                <span class={[
                  "w-20 text-xs text-right",
                  cond do
                    ws_state == :open -> "text-red-400"
                    ws_state == :half_open -> "text-yellow-400"
                    ws_connected -> "text-emerald-400"
                    true -> "text-gray-400"
                  end
                ]}>
                  {cond do
                    ws_state == :open -> "Open"
                    ws_state == :half_open -> "Half-open"
                    ws_connected -> "Connected"
                    true -> "Disconnected"
                  end}
                </span>
              </div>
              <div class="flex justify-between text-[10px] text-gray-600 px-11">
                <span>closed</span>
                <span>half-open</span>
                <span>open</span>
              </div>
            <% end %>

            <!-- Failure/Success Counters -->
            <div class="flex justify-between text-xs text-gray-400 pt-2 border-gray-800">
              <span>Failures: <span class={if Map.get(@provider_connection, :consecutive_failures, 0) > 0, do: "text-red-400", else: "text-gray-300"}>{Map.get(@provider_connection, :consecutive_failures, 0)}/5</span> threshold</span>
              <span>Successes: <span class="text-emerald-400">{Map.get(@provider_connection, :consecutive_successes, 0)}</span> consecutive</span>
            </div>
          </div>
        </div>

        <!-- ISSUES (infrastructure only) -->
        <div class="border-gray-700/50 border-b p-4">
          <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">Issues</h4>
          <%
            # Build active alerts from current state (compact status indicators)
            active_alerts = []

            # Circuit breaker alerts (most critical - show first)
            http_cb = Map.get(@provider_connection, :http_circuit_state)
            ws_cb = Map.get(@provider_connection, :ws_circuit_state)
            http_cb_error = Map.get(@provider_connection, :http_cb_error)
            ws_cb_error = Map.get(@provider_connection, :ws_cb_error)

            active_alerts = if http_cb == :open do
              error_detail = format_cb_error(http_cb_error)
              [{:error, "HTTP circuit OPEN", error_detail} | active_alerts]
            else
              active_alerts
            end

            active_alerts = if ws_cb == :open do
              error_detail = format_cb_error(ws_cb_error)
              [{:error, "WS circuit OPEN", error_detail} | active_alerts]
            else
              active_alerts
            end

            active_alerts = if http_cb == :half_open do
              [{:warn, "HTTP circuit recovering", nil} | active_alerts]
            else
              active_alerts
            end

            active_alerts = if ws_cb == :half_open do
              [{:warn, "WS circuit recovering", nil} | active_alerts]
            else
              active_alerts
            end

            # Rate limit alerts
            http_rate_limited = Map.get(@provider_connection, :http_rate_limited, false)
            ws_rate_limited = Map.get(@provider_connection, :ws_rate_limited, false)
            rate_limit_remaining = Map.get(@provider_connection, :rate_limit_remaining, %{})

            active_alerts =
              cond do
                http_rate_limited and ws_rate_limited ->
                  http_sec = div(Map.get(rate_limit_remaining, :http, 0), 1000)
                  ws_sec = div(Map.get(rate_limit_remaining, :ws, 0), 1000)
                  [{:warn, "Rate limited (HTTP: #{http_sec}s, WS: #{ws_sec}s)", nil} | active_alerts]
                http_rate_limited ->
                  sec = div(Map.get(rate_limit_remaining, :http, 0), 1000)
                  [{:warn, "HTTP rate limited (#{sec}s)", nil} | active_alerts]
                ws_rate_limited ->
                  sec = div(Map.get(rate_limit_remaining, :ws, 0), 1000)
                  [{:warn, "WS rate limited (#{sec}s)", nil} | active_alerts]
                true ->
                  active_alerts
              end

            # Consecutive failures alert
            failures = Map.get(@provider_connection, :consecutive_failures, 0)
            active_alerts = if failures > 0 do
              severity = if failures >= 3, do: :error, else: :warn
              [{severity, "#{failures} consecutive failures", nil} | active_alerts]
            else
              active_alerts
            end

            # WS disconnected alert (when WS is supported but not connected and circuit isn't open)
            has_ws = Map.get(@provider_connection, :ws_url) != nil
            ws_connected = Map.get(@provider_connection, :ws_connected, false)
            ws_circuit_ok = Map.get(@provider_connection, :ws_circuit_state) != :open
            active_alerts = if has_ws and not ws_connected and ws_circuit_ok do
              [{:warn, "WebSocket disconnected", nil} | active_alerts]
            else
              active_alerts
            end

            # Get event feed - filter for issues/events, not RPC successes
            event_feed = @provider_unified_events
              |> Enum.filter(fn e ->
                kind = e[:kind]
                severity = e[:severity]
                # Include circuit events, provider events, and warn/error RPC events
                kind in [:circuit, :provider, :error] or severity in [:warn, :error]
              end)
              |> Enum.take(15)
          %>

          <!-- Active Alerts (with error details for circuit breakers) -->
          <%= if length(active_alerts) > 0 do %>
            <div class="space-y-2 mb-3">
              <%= for alert <- active_alerts do %>
                <%
                  {severity, message, error_detail} = alert
                  border_class = case severity do
                    :error -> "border-l-red-500"
                    :warn -> "border-l-yellow-500"
                    _ -> "border-l-blue-500"
                  end
                  dot_class = case severity do
                    :error -> "bg-red-500"
                    :warn -> "bg-yellow-500"
                    _ -> "bg-blue-500"
                  end
                %>
                <div class={["bg-gray-800/40 rounded-lg border-l-2 p-2", border_class]}>
                  <div class="flex items-center gap-2">
                    <div class={["w-2 h-2 rounded-full shrink-0", dot_class]}></div>
                    <span class="text-xs text-gray-200 font-medium">{message}</span>
                  </div>
                  <%= if error_detail do %>
                    <div class="mt-1.5 ml-4 text-[11px] text-gray-400">
                      <%= if error_detail[:message] do %>
                        <div class="text-gray-300 mb-1">{error_detail[:message]}</div>
                      <% end %>
                      <div class="flex flex-wrap gap-1.5">
                        <%= if error_detail[:code] do %>
                          <span class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 font-mono">
                            ERR {error_detail[:code]}
                          </span>
                        <% end %>
                        <%= if error_detail[:category] do %>
                          <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400">
                            {error_detail[:category]}
                          </span>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- Event Feed -->
          <%= if length(event_feed) > 0 do %>
            <div class="max-h-64 overflow-y-auto space-y-1.5 pr-1">
              <%= for event <- event_feed do %>
                <%
                  severity_color = case event[:severity] do
                    :error -> "bg-red-500"
                    :warn -> "bg-yellow-500"
                    _ -> "bg-blue-500"
                  end
                  time_ago = if event[:ts_ms] do
                    diff_ms = System.system_time(:millisecond) - event[:ts_ms]
                    cond do
                      diff_ms < 60_000 -> "now"
                      diff_ms < 3_600_000 -> "#{div(diff_ms, 60_000)}m ago"
                      true -> "#{div(diff_ms, 3_600_000)}h ago"
                    end
                  else
                    "—"
                  end

                  # Format the message nicely
                  raw_message = event[:message] || "Unknown event"
                  display_message = format_event_message(raw_message)
                  is_expandable = String.length(display_message) > 80 or has_event_details?(event)
                  preview_message = if String.length(display_message) > 80 do
                    String.slice(display_message, 0, 77) <> "..."
                  else
                    display_message
                  end
                  event_id = "event-#{:erlang.phash2({event[:kind], event[:message], event[:ts_ms]})}"
                %>
                <%= if is_expandable do %>
                  <details id={event_id} phx-hook="ExpandableDetails" class="group bg-gray-800/30 rounded-lg hover:bg-gray-800/50 transition-colors">
                    <summary class="p-2 cursor-pointer list-none">
                      <div class="flex items-start justify-between gap-2">
                        <div class="flex items-start gap-2 min-w-0 flex-1">
                          <div class={["w-1.5 h-1.5 rounded-full mt-1.5 shrink-0", severity_color]}></div>
                          <span class="text-xs text-gray-300 break-words">{preview_message}</span>
                        </div>
                        <div class="flex items-center gap-1 shrink-0">
                          <svg class="w-3 h-3 text-gray-500 transition-transform group-open:rotate-180" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
                          </svg>
                          <span class="text-[10px] text-gray-500">{time_ago}</span>
                        </div>
                      </div>
                    </summary>
                    <div class="px-2 pb-2 pt-1 ml-3.5 space-y-2">
                      <!-- Full message if truncated -->
                      <%= if String.length(display_message) > 80 do %>
                        <div class="text-xs text-gray-300 break-words whitespace-pre-wrap">{display_message}</div>
                      <% end %>
                      <!-- Error details -->
                      <%= if get_in(event, [:meta, :error_code]) || get_in(event, [:meta, :error_message]) do %>
                        <div class="space-y-1.5">
                          <%= if get_in(event, [:meta, :error_message]) do %>
                            <div class="text-[11px] text-red-400 break-words">{get_in(event, [:meta, :error_message])}</div>
                          <% end %>
                          <div class="flex flex-wrap gap-1.5">
                            <%= if get_in(event, [:meta, :error_code]) do %>
                              <span class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 text-[10px] font-mono">
                                ERR {get_in(event, [:meta, :error_code])}
                              </span>
                            <% end %>
                            <%= if get_in(event, [:meta, :error_category]) do %>
                              <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400 text-[10px]">
                                {get_in(event, [:meta, :error_category])}
                              </span>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                      <!-- Event metadata tags -->
                      <div class="flex flex-wrap gap-1">
                        <%= if event[:kind] do %>
                          <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400">
                            {event[:kind] |> to_string() |> String.capitalize()}
                          </span>
                        <% end %>
                        <%= if get_in(event, [:meta, :transport]) do %>
                          <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400">
                            {get_in(event, [:meta, :transport])}
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </details>
                <% else %>
                  <div class="bg-gray-800/30 rounded-lg p-2 hover:bg-gray-800/50 transition-colors">
                    <div class="flex items-start justify-between gap-2">
                      <div class="flex items-start gap-2 min-w-0 flex-1">
                        <div class={["w-1.5 h-1.5 rounded-full mt-1.5 shrink-0", severity_color]}></div>
                        <span class="text-xs text-gray-300">{display_message}</span>
                      </div>
                      <span class="text-[10px] text-gray-500 shrink-0">{time_ago}</span>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
            <div class="mt-2 pt-1 text-center">
              <span class="text-[10px] text-gray-500">{length(event_feed)} events</span>
            </div>
          <% else %>
            <%= if length(active_alerts) == 0 do %>
              <div class="text-xs text-gray-500 text-center py-3">No issues detected</div>
            <% end %>
          <% end %>
        </div>

        <!-- METHOD PERFORMANCE -->
        <div class="p-4">
          <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">Method Performance</h4>
          <% rpc_stats = Map.get(@performance_metrics, :rpc_stats, []) %>
          <% max_calls = rpc_stats |> Enum.map(& &1.total_calls) |> Enum.max(fn -> 1 end) %>
          <%= if length(rpc_stats) > 0 do %>
            <div class="space-y-2">
              <%= for stat <- Enum.take(rpc_stats, 6) do %>
                <% bar_width = if max_calls > 0, do: (stat.total_calls / max_calls) * 100, else: 0 %>
                <div class="flex items-center gap-2 text-xs">
                  <span class="w-28 text-gray-300 truncate font-mono" title={stat.method}>{stat.method}</span>
                  <span class="w-16 text-gray-400">p50: {Helpers.to_float(stat.avg_duration_ms) |> Float.round(0)}ms</span>
                  <span class={[
                    "w-12",
                    if(stat.success_rate >= 0.99, do: "text-emerald-400", else: if(stat.success_rate >= 0.95, do: "text-yellow-400", else: "text-red-400"))
                  ]}>{(Helpers.to_float(stat.success_rate) * 100) |> Float.round(1)}%</span>
                  <div class="flex-1 bg-gray-800 rounded h-2">
                    <div class="bg-gray-600 h-2 rounded" style={"width: #{bar_width}%"}></div>
                  </div>
                  <span class="w-14 text-right text-gray-500">{stat.total_calls}</span>
                </div>
              <% end %>
            </div>
            <div class="text-[10px] text-gray-600 text-right mt-2">(calls)</div>
          <% else %>
            <div class="text-xs text-gray-500 text-center py-2">No recent method data</div>
          <% end %>
        </div>
      <% else %>
        <div class="flex-1 flex items-center justify-center">
          <div class="text-gray-500">Provider data not available</div>
        </div>
      <% end %>
    </div>
    """
  end

  # Floating details window wrapper (pinned top-right)
  attr :selected_chain, :string
  attr :selected_provider, :string
  attr :details_collapsed, :boolean
  attr :connections, :list
  attr :routing_events, :list
  attr :provider_events, :list
  attr :latest_blocks, :list
  attr :events, :list
  attr :chain_config_open, :boolean
  attr :chain_config_collapsed, :boolean
  attr :selected_chain_metrics, :map
  attr :selected_chain_events, :list
  attr :selected_chain_unified_events, :list
  attr :selected_chain_endpoints, :map
  attr :selected_chain_provider_events, :list, default: []
  attr :selected_provider_events, :list, default: []
  attr :selected_provider_unified_events, :list, default: []
  attr :selected_provider_metrics, :map, default: %{}

  def floating_details_window(assigns) do
    import LassoWeb.Components.FloatingWindow

    # Calculate system metrics
    total_connections = length(assigns.connections)
    connected_providers = Enum.count(assigns.connections, &(&1.status == :connected))
    total_chains = assigns.connections |> Enum.map(& &1.chain) |> Enum.uniq() |> length()

    # Determine status indicator
    status = if connected_providers == total_connections && total_connections > 0 do
      :healthy
    else
      :degraded
    end

    # Determine title based on selection
    title = cond do
      assigns.details_collapsed ->
        "System Overview"
      assigns.selected_provider ->
        case Enum.find(assigns.connections, &(&1.id == assigns.selected_provider)) do
          %{name: name} -> name
          _ -> assigns.selected_provider
        end
      assigns.selected_chain ->
        Helpers.get_chain_display_name(assigns.selected_chain)
      true ->
        "System Overview"
    end

    # Determine if toggle should be enabled (only when chain or provider is selected)
    on_toggle = if assigns.selected_chain || assigns.selected_provider do
      "toggle_details_panel"
    else
      nil
    end

    assigns =
      assigns
      |> assign(:total_connections, total_connections)
      |> assign(:connected_providers, connected_providers)
      |> assign(:total_chains, total_chains)
      |> assign(:status, status)
      |> assign(:title, title)
      |> assign(:on_toggle, on_toggle)

    ~H"""
    <.floating_window
      id="details-window"
      position={:top_right}
      collapsed={@details_collapsed}
      on_toggle={@on_toggle}
      size={%{collapsed: "w-96", expanded: "w-[36rem] max-h-[80vh]"}}
    >
      <:header>
        <.status_indicator status={@status} />
        <div class="truncate text-xs text-gray-300"><%= @title %></div>
      </:header>

      <:collapsed_preview>
        <div class="space-y-3 p-3">
          <!-- System metrics grid -->
          <div class="grid grid-cols-4 gap-3 bg-gray-800/40 rounded-md p-3">
            <div>
              <div class="text-[10px] tracking-wide text-gray-400">Providers</div>
              <div class="text-sm font-semibold text-white">
                <span class="text-emerald-300">{@total_connections}</span>
              </div>
            </div>
            <div>
              <div class="text-[10px] uppercase tracking-wide text-gray-400">Chains</div>
              <div class="text-sm font-semibold text-purple-300">{@total_chains}</div>
            </div>
            <div>
              <div class="text-[10px] text-gray-400">RPC/s</div>
              <div class="text-xs font-medium text-sky-300">
                {MetricsHelpers.rpc_calls_per_second(@routing_events)}
              </div>
            </div>
            <div>
              <div class="text-[10px] text-gray-400">Failovers (1m)</div>
              <div class="text-xs font-medium text-yellow-300">
                {MetricsHelpers.failovers_last_minute(@routing_events)}
              </div>
            </div>
          </div>

          <!-- Recent Activity feed -->
          <div>
            <div class="text-[10px] text-gray-400 mb-1.5">
              Recent Activity
            </div>
            <div
              id="recent-activity-feed"
              phx-hook="ActivityFeed"
              class="flex max-h-32 flex-col gap-1 overflow-y-auto"
              style="overflow-anchor: none;"
            >
              <%= for e <- Enum.take(@routing_events, 100) do %>
                <div data-event-id={e[:ts_ms]} class="text-[9px] text-gray-300 flex items-center gap-1 shrink-0">
                  <span class="text-purple-300">{e.chain}</span>
                  <span class="text-sky-300">{e.method}</span>
                  → <span class="text-emerald-300">{String.slice(e.provider_id, 0, 14)}…</span>
                  <span class={["", if(e[:result] == :error, do: "text-red-400", else: "text-yellow-300")]}>
                    ({e[:duration_ms] || 0}ms)
                  </span>
                  <%= if (e[:failovers] || 0) > 0 do %>
                    <span class="inline-flex items-center px-1 py-0.5 rounded text-[8px] text-orange-300 font-bold bg-orange-900/50" title={"#{e[:failovers]} failover(s)"}>
                      ↻{e[:failovers]}
                    </span>
                  <% end %>
                </div>
              <% end %>
              <%= if length(@routing_events) == 0 do %>
                <div class="text-[9px] text-gray-500">No recent activity</div>
              <% end %>
            </div>
          </div>
        </div>
      </:collapsed_preview>

      <:body>
        <%= if @selected_provider do %>
          <.provider_details_panel
            id={"provider-details-#{@selected_provider}"}
            provider={@selected_provider}
            connections={@connections}
            routing_events={@routing_events}
            provider_events={@provider_events}
            events={@events}
            selected_chain={@selected_chain}
            selected_provider_events={@selected_provider_events}
            selected_provider_unified_events={@selected_provider_unified_events}
            selected_provider_metrics={@selected_provider_metrics}
          />
        <% else %>
          <%= if @selected_chain do %>
            <.chain_details_panel
              chain={@selected_chain}
              connections={@connections}
              routing_events={@routing_events}
              provider_events={@provider_events}
              events={@events}
              selected_chain_metrics={@selected_chain_metrics}
              selected_chain_events={@selected_chain_events}
              selected_chain_unified_events={@selected_chain_unified_events}
              selected_chain_endpoints={@selected_chain_endpoints}
              selected_chain_provider_events={assigns[:selected_chain_provider_events] || []}
            />
          <% end %>
        <% end %>
      </:body>
    </.floating_window>
    """
  end




  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :active_tab, Map.get(params, "tab", "overview"))}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: "/dashboard?tab=#{tab}")}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => ""}, socket) do
    socket =
      socket
      |> assign(:selected_chain, nil)
      |> assign(:details_collapsed, true)
      |> update_selected_chain_metrics()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => chain}, socket) do
    socket =
      socket
      |> assign(:selected_chain, chain)
      |> assign(:selected_provider, nil)
      |> assign(:details_collapsed, false)
      |> update_selected_chain_metrics()

    # Re-enable auto-centering to animate pan to the selected chain
    socket =
      if chain != "", do: push_event(socket, "center_on_chain", %{chain: chain}), else: socket


    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => ""}, socket) do
    # Cancel any existing refresh timer when deselecting provider
    socket = cancel_provider_refresh_timer(socket)

    socket =
      socket
      |> assign(:selected_provider, nil)
      |> assign(:details_collapsed, true)
      |> update_selected_provider_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    # Cancel any existing refresh timer before starting a new one
    socket = cancel_provider_refresh_timer(socket)

    # Schedule periodic refresh for provider panel and store timer ref
    timer_ref = Process.send_after(self(), :provider_panel_refresh, 3_000)

    socket =
      socket
      |> assign(:selected_provider, provider)
      |> assign(:selected_chain, nil)
      |> assign(:details_collapsed, false)
      |> assign(:provider_refresh_timer, timer_ref)
      |> fetch_connections()
      |> update_selected_provider_data()
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
      |> push_event("zoom_out", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, fetch_connections(socket)}
  end

  @impl true
  def handle_event("select_metrics_chain", %{"chain" => chain}, socket) do
    socket =
      socket
      |> assign(:metrics_selected_chain, chain)
      |> load_provider_metrics()

    {:noreply, socket}
  end

  # Simulator Event Forwarding (only forwards when simulator is active)
  @impl true
  def handle_event("sim_stats", %{"http" => _http, "ws" => _ws} = stats, socket) do
    # Forward to SimulatorControls component
    send_update(Components.SimulatorControls, id: "simulator-controls", sim_stats: stats)
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_recent_calls", %{"calls" => calls}, socket) do
    # Forward to SimulatorControls component
    send_update(Components.SimulatorControls, id: "simulator-controls", recent_calls: calls)
    {:noreply, socket}
  end

  @impl true
  def handle_event("active_runs_update", %{"runs" => runs}, socket) do
    # Forward to SimulatorControls component
    send_update(Components.SimulatorControls, id: "simulator-controls", active_runs: runs)
    {:noreply, socket}
  end

  # Private helper for timer management
  defp cancel_provider_refresh_timer(socket) do
    case socket.assigns[:provider_refresh_timer] do
      nil -> socket
      timer_ref ->
        Process.cancel_timer(timer_ref)
        assign(socket, :provider_refresh_timer, nil)
    end
  end

  # Format error code for display (e.g., -32000 -> "ERR -32000")
  defp format_error_code(code) when is_integer(code), do: "ERR #{code}"
  defp format_error_code(code), do: inspect(code)

  # Format circuit breaker reason for display
  defp format_reason(:failure_threshold_exceeded), do: "failures exceeded"
  defp format_reason(:reopen_due_to_failure), do: "recovery failed"
  defp format_reason(:recovery_attempt), do: "attempting recovery"
  defp format_reason(:attempt_recovery), do: "attempting recovery"
  defp format_reason(:proactive_recovery), do: "auto recovery"
  defp format_reason(:recovered), do: "recovered"
  defp format_reason(:manual_open), do: "manually opened"
  defp format_reason(:manual_close), do: "manually closed"
  defp format_reason(reason), do: to_string(reason)

  # Format event messages for display (handles Lasso.JSONRPC.Error structs, etc.)
  defp format_event_message(message) when is_binary(message) do
    # Check if this looks like an inspected struct and try to clean it up
    cond do
      String.starts_with?(message, "%Lasso.JSONRPC.Error{") ->
        # Parse out key fields from the struct string representation
        code = extract_field(message, "code:")
        msg = extract_field(message, "message:")
        category = extract_field(message, "category:")

        parts = []
        parts = if msg && msg != "nil", do: [clean_string_value(msg) | parts], else: parts
        parts = if code && code != "nil", do: ["ERR #{code}" | parts], else: parts
        parts = if category && category != "nil", do: ["(#{category})" | parts], else: parts

        case parts do
          [] -> message
          _ -> Enum.reverse(parts) |> Enum.join(" ")
        end

      true ->
        message
    end
  end

  defp format_event_message(other), do: inspect(other)

  # Extract a field value from an inspect string like "code: -32000"
  defp extract_field(str, field) do
    case Regex.run(~r/#{Regex.escape(field)}\s*([^,}]+)/, str) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  # Clean up quoted string values
  defp clean_string_value(str) do
    str
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace(~r/\\\"/, "\"")
  end

  # Check if an event has expandable details
  defp has_event_details?(event) do
    get_in(event, [:meta, :error_code]) != nil or
      get_in(event, [:meta, :error_message]) != nil or
      get_in(event, [:meta, :error_category]) != nil
  end

  # Format circuit breaker error for display in active alerts
  # Returns a map with :code, :category, :message keys or nil
  defp format_cb_error(nil), do: nil
  defp format_cb_error(%{} = error) do
    # The error map from ProviderPool has :error_code, :error_category, :error_message keys
    # But the circuit breaker stores it as :code, :category, :message
    %{
      code: error[:code] || error[:error_code],
      category: error[:category] || error[:error_category],
      message: error[:message] || error[:error_message]
    }
  end

  # Shared components

  attr :last_decision, :map, default: nil
  attr :connections, :list, default: []

  def last_decision_card(assigns) do
    # Get provider name from connections if available
    provider_name = case assigns[:connections] do
      connections when is_list(connections) ->
        case assigns[:last_decision] && Enum.find(connections, &(&1.id == assigns.last_decision.provider_id)) do
          %{name: name} -> name
          _ -> assigns[:last_decision] && assigns.last_decision.provider_id
        end
      _ -> assigns[:last_decision] && assigns.last_decision.provider_id
    end

    assigns = assign(assigns, :provider_name, provider_name)

    ~H"""
    <div class="bg-gray-800/40 rounded-lg p-3 md:col-span-1">
      <div class="text-[11px] text-gray-400 mb-1">Last decision</div>
      <%= if @last_decision do %>
        <div class="text-xs text-gray-300 space-y-1">
          <div class="flex items-center justify-between gap-2">
            <div class="truncate">
              <span class="text-sky-300">{@last_decision.method}</span>
              <span class="text-gray-500">→</span>
              <span class="text-emerald-300 truncate" title={@last_decision.provider_id}>
                {@provider_name || @last_decision.provider_id}
              </span>
            </div>
            <div class="shrink-0 text-yellow-300 font-mono">{@last_decision.duration_ms}ms</div>
          </div>
          <div class="text-[11px] text-gray-400 flex items-center gap-2">
            <span>strategy: <span class="text-purple-300">{Map.get(@last_decision, :strategy, "—")}</span></span>
          </div>
        </div>
      <% else %>
        <div class="text-xs text-gray-500">No recent decisions</div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp refresh_available_chains(socket) do
    available_chains =
      Lasso.Config.ConfigStore.list_chains()
      |> Enum.map(fn chain_name ->
        %{
          name: chain_name,
          display_name: chain_name |> String.capitalize()
        }
      end)

    assign(socket, :available_chains, available_chains)
  end

  defp buffer_event(socket, event) do
    # Push event to EventBuffer GenServer
    EventBuffer.push(event)

    # Update local event history for display
    update(socket, :events, fn list ->
      [event | Enum.take(list, Constants.event_history_size() - 1)]
    end)
  end

  defp schedule_connection_refresh(socket, delay \\ 100) do
    case Process.get(:pending_connection_update) do
      nil ->
        Process.put(:pending_connection_update, true)
        Process.send_after(self(), :flush_connections, delay)
        fetch_connections(socket)

      _ ->
        socket
    end
  end

  defp update_selected_chain_metrics(socket) do
    case socket.assigns[:selected_chain] do
      nil ->
        # Clear all chain-specific data when no chain is selected
        socket
        |> assign(:selected_chain_metrics, %{})
        |> assign(:selected_chain_events, [])
        |> assign(:selected_chain_unified_events, [])
        |> assign(:selected_chain_endpoints, %{})
        |> assign(:selected_chain_provider_events, [])

      chain ->
        # Calculate chain-specific metrics (lightweight in-memory operations)
        chain_metrics = MetricsHelpers.get_chain_performance_metrics(socket.assigns, chain)

        # Get chain-specific endpoints
        chain_endpoints = EndpointHelpers.get_chain_endpoints(socket.assigns, chain)

        # Filter events for selected chain
        chain_events = Enum.filter(socket.assigns.routing_events, &(&1.chain == chain))
        chain_unified_events = Enum.filter(socket.assigns.events, fn e -> e[:chain] == chain end)
        chain_provider_events = Enum.filter(socket.assigns.provider_events, &(&1.chain == chain))

        # Update all chain-specific assigns at once to ensure consistency
        socket
        |> assign(:selected_chain_metrics, chain_metrics)
        |> assign(:selected_chain_events, chain_events)
        |> assign(:selected_chain_unified_events, chain_unified_events)
        |> assign(:selected_chain_endpoints, chain_endpoints)
        |> assign(:selected_chain_provider_events, chain_provider_events)
    end
  end

  defp update_selected_provider_data(socket) do
    case socket.assigns[:selected_provider] do
      nil ->
        # Clear all provider-specific data when no provider is selected
        socket
        |> assign(:selected_provider_events, [])
        |> assign(:selected_provider_unified_events, [])
        |> assign(:selected_provider_metrics, %{})

      provider_id ->
        # Filter events for selected provider (lightweight in-memory operations)
        provider_events = Enum.filter(socket.assigns.routing_events, &(&1.provider_id == provider_id))
        provider_unified_events = Enum.filter(socket.assigns.events, fn e -> e[:provider_id] == provider_id end)

        # Calculate provider-specific metrics
        provider_metrics =
          MetricsHelpers.get_provider_performance_metrics(
            provider_id,
            socket.assigns.connections,
            socket.assigns.routing_events
          )


        # Update all provider-specific assigns at once
        socket
        |> assign(:selected_provider_events, provider_events)
        |> assign(:selected_provider_unified_events, provider_unified_events)
        |> assign(:selected_provider_metrics, provider_metrics)
    end
  end

  defp fetch_connections(socket) do
    alias Lasso.Config.ConfigStore
    alias Lasso.RPC.ProviderPool
    alias Lasso.RPC.ChainState

    # Get all configured chains
    chains = ConfigStore.list_chains()

    # Get consensus heights for all chains upfront
    consensus_by_chain =
      chains
      |> Enum.map(fn chain_name ->
        consensus = case ChainState.consensus_height(chain_name, allow_stale: true) do
          {:ok, height} -> height
          {:ok, height, :stale} -> height
          {:error, _} -> nil
        end
        {chain_name, consensus}
      end)
      |> Enum.into(%{})

    # Fetch provider status from ProviderPool for each chain
    connections =
      chains
      |> Enum.flat_map(fn chain_name ->
        consensus_height = Map.get(consensus_by_chain, chain_name)

        case ProviderPool.get_status(chain_name) do
          {:ok, pool_status} ->
            # pool_status.providers is a list of provider maps
            pool_status.providers
            |> Enum.map(fn provider_map ->
              # Determine overall circuit state (if either transport is open, show open)
              overall_circuit_state =
                cond do
                  provider_map.http_cb_state == :open or provider_map.ws_cb_state == :open -> :open
                  provider_map.http_cb_state == :half_open or provider_map.ws_cb_state == :half_open -> :half_open
                  true -> :closed
                end

              # Determine provider type based on configuration
              provider_type =
                cond do
                  provider_map.config.url && provider_map.config.ws_url -> :both
                  provider_map.config.ws_url -> :websocket
                  true -> :http
                end

              # Check if WebSocket is connected (if provider supports WS)
              ws_connected =
                case provider_type do
                  :websocket -> provider_map.ws_status == :healthy
                  :both -> provider_map.ws_status == :healthy
                  _ -> false
                end

              # Map HealthPolicy availability to dashboard health_status
              # HealthPolicy uses: :up, :down, :limited, :misconfigured
              # StatusHelpers expects: :healthy, :unhealthy, :rate_limited, :connecting, etc.
              health_status =
                case provider_map.availability do
                  :up -> :healthy
                  :down -> :unhealthy
                  :limited -> :rate_limited
                  :misconfigured -> :misconfigured
                  other -> other  # Fallback for any new states
                end

              # Get provider block height and lag from ChainState
              {block_height, blocks_behind} =
                case ChainState.provider_lag(chain_name, provider_map.id) do
                  {:ok, lag} when is_integer(lag) and not is_nil(consensus_height) ->
                    # lag is negative when behind (e.g., -5 means 5 blocks behind)
                    # Convert to block_height and blocks_behind
                    height = consensus_height + lag
                    {height, -lag}  # blocks_behind is positive when behind

                  _ ->
                    {nil, nil}
                end

              # Map to dashboard connection format
              %{
                id: provider_map.id,
                chain: chain_name,
                name: provider_map.name,
                status: provider_map.status,  # For legacy compatibility
                health_status: health_status,
                type: provider_type,
                circuit_state: overall_circuit_state,
                http_circuit_state: provider_map.http_cb_state,
                ws_circuit_state: provider_map.ws_cb_state,
                # Circuit breaker errors (what caused the circuit to open)
                http_cb_error: Map.get(provider_map, :http_cb_error),
                ws_cb_error: Map.get(provider_map, :ws_cb_error),
                consecutive_failures: provider_map.consecutive_failures,
                consecutive_successes: provider_map.consecutive_successes,
                last_error: provider_map.last_error,
                # Rate limit state (from RateLimitState, auto-expires)
                http_rate_limited: Map.get(provider_map, :http_rate_limited, false),
                ws_rate_limited: Map.get(provider_map, :ws_rate_limited, false),
                rate_limit_remaining: Map.get(provider_map, :rate_limit_remaining, %{http: nil, ws: nil}),
                # Legacy cooldown fields for backwards compatibility
                is_in_cooldown: provider_map.is_in_cooldown,
                cooldown_until: provider_map.cooldown_until,
                reconnect_attempts: 0,  # Not tracked currently
                ws_connected: ws_connected,
                subscriptions: 0,  # Would need to query UpstreamSubscriptionPool
                url: provider_map.config.url,
                ws_url: provider_map.config.ws_url,
                # Block sync data
                block_height: block_height,
                consensus_height: consensus_height,
                blocks_behind: blocks_behind
              }
            end)

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to get provider status for chain #{chain_name}: #{inspect(reason)}")
            []
        end
      end)

    latency_leaders = MetricsHelpers.get_latency_leaders_by_chain(connections)

    socket
    |> assign(:connections, connections)
    |> assign(:latency_leaders, latency_leaders)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end

  defp load_provider_metrics(socket) do
    chain_name = socket.assigns.metrics_selected_chain

    try do
      alias Lasso.Config.ConfigStore
      alias Lasso.Benchmarking.BenchmarkStore

      {:ok, provider_configs} = ConfigStore.get_providers(chain_name)
      provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
      realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)

      # Get all RPC methods we have data for
      rpc_methods = Map.get(realtime_stats, :rpc_methods, [])
      provider_ids = Enum.map(provider_configs, & &1.id)

      # Collect detailed metrics by provider
      provider_metrics = collect_provider_metrics(
        chain_name,
        provider_ids,
        provider_configs,
        provider_leaderboard,
        rpc_methods
      )

      # Collect method-level metrics for comparison
      method_metrics = collect_method_metrics(
        chain_name,
        provider_ids,
        provider_configs,
        rpc_methods
      )

      socket
      |> assign(:metrics_loading, false)
      |> assign(:provider_metrics, provider_metrics)
      |> assign(:method_metrics, method_metrics)
      |> assign(:metrics_last_updated, DateTime.utc_now())
    rescue
      error ->
        require Logger
        Logger.error("Failed to load provider metrics: #{inspect(error)}")
        assign(socket, :metrics_loading, false)
    end
  end

  defp collect_provider_metrics(chain_name, provider_ids, provider_configs, leaderboard, rpc_methods) do
    alias Lasso.Benchmarking.BenchmarkStore

    provider_ids
    |> Enum.map(fn provider_id ->
      config = Enum.find(provider_configs, &(&1.id == provider_id))
      leaderboard_entry = Enum.find(leaderboard, &(&1.provider_id == provider_id))

      # Get aggregate stats across all methods
      method_stats = rpc_methods
        |> Enum.map(fn method ->
          BenchmarkStore.get_rpc_method_performance_with_percentiles(chain_name, provider_id, method)
        end)
        |> Enum.reject(&is_nil/1)

      # Calculate aggregates
      total_calls = Enum.reduce(method_stats, 0, fn stat, acc -> acc + stat.total_calls end)

      avg_latency = if total_calls > 0 do
        weighted_sum = Enum.reduce(method_stats, 0, fn stat, acc ->
          acc + (stat.avg_duration_ms * stat.total_calls)
        end)
        weighted_sum / total_calls
      else
        nil
      end

      p50_latency = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.percentiles.p50)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      p95_latency = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.percentiles.p95)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      p99_latency = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.percentiles.p99)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      success_rate = if length(method_stats) > 0 do
        method_stats
        |> Enum.map(& &1.success_rate)
        |> Enum.sum()
        |> Kernel./(length(method_stats))
      else
        nil
      end

      # Calculate variance/consistency (P99/P50 ratio)
      consistency_ratio = if p50_latency && p99_latency && p50_latency > 0 do
        p99_latency / p50_latency
      else
        nil
      end

      %{
        id: provider_id,
        name: if(config, do: config.name, else: provider_id),
        avg_latency: avg_latency,
        p50_latency: p50_latency,
        p95_latency: p95_latency,
        p99_latency: p99_latency,
        success_rate: success_rate,
        total_calls: total_calls,
        consistency_ratio: consistency_ratio,
        score: if(leaderboard_entry, do: leaderboard_entry.score, else: nil),
        win_rate: if(leaderboard_entry, do: leaderboard_entry.win_rate, else: nil),
        method_count: length(method_stats)
      }
    end)
    |> Enum.reject(&(&1.total_calls == 0))
    |> Enum.sort_by(& &1.avg_latency || 999_999)
  end

  defp collect_method_metrics(chain_name, provider_ids, provider_configs, rpc_methods) do
    alias Lasso.Benchmarking.BenchmarkStore

    rpc_methods
    |> Enum.map(fn method ->
      provider_stats = provider_ids
        |> Enum.map(fn provider_id ->
          config = Enum.find(provider_configs, &(&1.id == provider_id))

          case BenchmarkStore.get_rpc_method_performance_with_percentiles(chain_name, provider_id, method) do
            nil -> nil
            stats ->
              %{
                provider_id: provider_id,
                provider_name: if(config, do: config.name, else: provider_id),
                avg_latency: stats.avg_duration_ms,
                p50_latency: stats.percentiles.p50,
                p95_latency: stats.percentiles.p95,
                p99_latency: stats.percentiles.p99,
                success_rate: stats.success_rate,
                total_calls: stats.total_calls
              }
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.avg_latency)

      if Enum.empty?(provider_stats) do
        nil
      else
        %{
          method: method,
          providers: provider_stats,
          total_calls: Enum.reduce(provider_stats, 0, fn stat, acc -> acc + stat.total_calls end)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.total_calls, :desc)
  end

  # Metrics tab component
  attr :available_chains, :list, required: true
  attr :metrics_selected_chain, :string, required: true
  attr :provider_metrics, :list, required: true
  attr :method_metrics, :list, required: true
  attr :metrics_loading, :boolean, required: true
  attr :metrics_last_updated, :any, default: nil

  defp metrics_tab_content(assigns) do
    # Get chain config for the selected chain
    chain_config = case Lasso.Config.ConfigStore.get_chain(assigns.metrics_selected_chain) do
      {:ok, config} -> config
      {:error, _} -> %{chain_id: "Unknown"}
    end

    assigns = assign(assigns, :chain_config, chain_config)

    ~H"""
    <div class="h-full overflow-y-auto">
     <div class="mx-auto max-w-7xl px-4 pb-4">
      <div class="flex items-center justify-between mb-2 py-4">
          <div class="flex gap-2 ">
            <%= for chain <- @available_chains do %>
              <button
                phx-click="select_metrics_chain"
                phx-value-chain={chain.name}
                class={[
                  "px-4 py-2 rounded-lg text-sm font-medium transition-all",
                  if chain.name == @metrics_selected_chain do
                    "bg-sky-500/20 text-sky-300 border border-sky-500/50 shadow-md shadow-sky-500/10"
                  else
                    "bg-gray-800/50 text-gray-400 border border-gray-700 hover:border-sky-500/50 hover:text-sky-300 hover:bg-gray-800/80"
                  end
                ]}
              >
                <div class="flex items-center gap-2">
                  <span>{chain.display_name}</span>
                  <%= if chain.name == @metrics_selected_chain do %>
                    <span class="text-xs text-gray-500">ID: {@chain_config.chain_id}</span>
                  <% end %>
                </div>
              </button>
            <% end %>
          </div>
        </div>

        <%= if @metrics_loading do %>
          <div class="py-12">
            <div class="rounded-lg border border-gray-800 bg-gray-900/30 p-6 text-center">
              <div class="inline-block h-8 w-8 animate-spin rounded-full border-4 border-solid border-sky-500 border-r-transparent"></div>
              <p class="mt-4 text-gray-400">Loading metrics...</p>
            </div>
          </div>
        <% else %>
          <div class="space-y-6">
            <.render_provider_performance_table
              provider_metrics={@provider_metrics}
              metrics_last_updated={@metrics_last_updated}
            />
            <.render_method_performance_breakdown method_metrics={@method_metrics} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_provider_performance_table(assigns) do
    ~H"""
    <section>
      <div class="flex items-center justify-between mb-3 ">
        <h2 class="text-lg font-semibold flex items-center gap-2 text-white">
          <span>Provider Performance</span>
          <span class="text-xs text-gray-500 font-normal">({length(@provider_metrics)} providers)</span>
        </h2>
        <%= if @metrics_last_updated do %>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <div class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></div>
            <span class="font-mono text-gray-400">
              {Calendar.strftime(@metrics_last_updated, "%H:%M:%S")}
            </span>
          </div>
        <% end %>
      </div>

      <div class="bg-gray-900/95 backdrop-blur-lg rounded-xl border border-gray-700/60 shadow-2xl overflow-hidden">
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead class="bg-gray-800/50 border-b border-gray-700/50">
              <tr class="text-left text-xs text-gray-400 uppercase tracking-wider">
                <th class="px-4 py-3">Rank</th>
                <th class="px-4 py-3">Provider</th>
                <th class="px-4 py-3 text-right">Avg Latency</th>
                <th class="px-4 py-3 text-right">P50</th>
                <th class="px-4 py-3 text-right">P95</th>
                <th class="px-4 py-3 text-right">P99</th>
                <th class="px-4 py-3 text-right">P99/P50</th>
                <th class="px-4 py-3 text-right">Success Rate</th>
                <th class="px-4 py-3 text-right">Total Calls</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700/30">
              <%= for {provider, index} <- Enum.with_index(@provider_metrics, 1) do %>
                <tr class="hover:bg-gray-900/30 transition-colors">
                  <td class="px-4 py-3">
                    <span class={[
                      "inline-flex items-center justify-center w-6 h-6 rounded-full text-xs font-semibold",
                      case index do
                        1 -> "bg-yellow-500/20 text-yellow-400"
                        2 -> "bg-gray-400/20 text-gray-300"
                        3 -> "bg-orange-600/20 text-orange-400"
                        _ -> "bg-gray-800 text-gray-500"
                      end
                    ]}>
                      {index}
                    </span>
                  </td>
                  <td class="px-4 py-3 font-medium text-white">{provider.name}</td>
                  <td class="px-4 py-3 text-right">
                    <%= if provider.avg_latency do %>
                      <div class="flex items-center justify-end gap-2">
                        <div class="flex-1 max-w-[100px] h-1.5 bg-gray-800 rounded-full overflow-hidden">
                          <div
                            class="h-full bg-sky-500 rounded-full transition-all"
                            style={"width: #{Formatting.calculate_bar_width(provider.avg_latency, @provider_metrics, :avg_latency)}%"}
                          >
                          </div>
                        </div>
                        <span class="text-sky-400 font-mono text-sm w-16">
                          {Formatting.safe_round(provider.avg_latency, 0)}ms
                        </span>
                      </div>
                    <% else %>
                      <span class="text-gray-600">—</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                    <%= if provider.p50_latency, do: "#{Formatting.safe_round(provider.p50_latency, 0)}ms", else: "—" %>
                  </td>
                  <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                    <%= if provider.p95_latency, do: "#{Formatting.safe_round(provider.p95_latency, 0)}ms", else: "—" %>
                  </td>
                  <td class="px-4 py-3 text-right font-mono text-sm text-gray-300">
                    <%= if provider.p99_latency, do: "#{Formatting.safe_round(provider.p99_latency, 0)}ms", else: "—" %>
                  </td>
                  <td class="px-4 py-3 text-right">
                    <%= if provider.consistency_ratio do %>
                      <span class={[
                        "font-mono text-sm",
                        Status.consistency_color(provider.consistency_ratio)
                      ]}>
                        {Formatting.safe_round(provider.consistency_ratio, 1)}x
                      </span>
                    <% else %>
                      <span class="text-gray-600">—</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-right">
                    <%= if provider.success_rate do %>
                      <span class={[
                        "font-mono text-sm",
                        cond do
                          provider.success_rate >= 0.99 -> "text-emerald-400"
                          provider.success_rate >= 0.95 -> "text-yellow-400"
                          true -> "text-red-400"
                        end
                      ]}>
                        {Formatting.safe_round(provider.success_rate * 100, 1)}%
                      </span>
                    <% else %>
                      <span class="text-gray-600">—</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-right font-mono text-sm text-gray-400">
                    {Formatting.format_number(provider.total_calls)}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp render_method_performance_breakdown(assigns) do
    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-3 text-white">Method Performance Breakdown</h2>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <%= for method_data <- @method_metrics do %>
          <div class="bg-gray-900/95 backdrop-blur-lg rounded-xl border border-gray-700/60 shadow-2xl p-4">
            <div class="flex items-center justify-between mb-3 pb-2 border-b border-gray-700/50">
              <h3 class="font-mono text-sm text-sky-400">{method_data.method}</h3>
              <span class="text-xs text-gray-500">
                {Formatting.format_number(method_data.total_calls)} calls
              </span>
            </div>

            <div class="space-y-2">
              <%= for {provider_stat, idx} <- Enum.with_index(method_data.providers, 1) do %>
                <div class="flex items-center gap-2">
                  <div class="flex-none">
                    <span class={[
                      "inline-flex items-center justify-center w-4 h-4 rounded text-[9px] font-semibold",
                      case idx do
                        1 -> "bg-yellow-500/20 text-yellow-400"
                        2 -> "bg-gray-400/20 text-gray-300"
                        3 -> "bg-orange-600/20 text-orange-400"
                        _ -> "bg-gray-800 text-gray-500"
                      end
                    ]}>
                      {idx}
                    </span>
                  </div>

                  <div class="flex-none w-28 truncate text-xs text-gray-300">
                    {provider_stat.provider_name}
                  </div>

                  <div class="flex-1 flex items-center gap-1.5">
                    <div class="flex-1 h-4 bg-gray-800/50 rounded overflow-hidden">
                      <div
                        class="h-full bg-gradient-to-r from-emerald-500 to-sky-500 flex items-center justify-end px-1.5"
                        style={"width: #{Formatting.calculate_method_bar_width(provider_stat.avg_latency, method_data.providers)}%"}
                      >
                        <span class="text-[10px] font-mono text-white font-semibold">
                          {Formatting.safe_round(provider_stat.avg_latency, 0)}ms
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="flex-none flex items-center gap-2 text-[10px]">
                    <span class={[
                      "font-mono",
                      if(provider_stat.success_rate >= 0.99, do: "text-emerald-400", else: "text-yellow-400")
                    ]}>
                      {Formatting.safe_round(provider_stat.success_rate * 100, 0)}%
                    </span>
                    <span class="text-gray-500">
                      {Formatting.format_number(provider_stat.total_calls)}
                    </span>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

 end
