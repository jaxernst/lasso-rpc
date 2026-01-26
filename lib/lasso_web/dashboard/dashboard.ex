defmodule LassoWeb.Dashboard do
  @moduledoc "Main dashboard LiveView for monitoring RPC chains and providers."
  use LassoWeb, :live_view
  require Logger

  alias Lasso.Events.Provider
  alias LassoWeb.Components.ClusterStatus
  alias LassoWeb.Components.DashboardComponents
  alias LassoWeb.Components.DashboardHeader
  alias LassoWeb.Components.NetworkStatusLegend
  alias LassoWeb.Dashboard.Components
  alias LassoWeb.NetworkTopology
  alias LassoWeb.TopologyConfig

  alias LassoWeb.Dashboard.{
    Constants,
    EndpointHelpers,
    EventStream,
    Helpers,
    MessageHandlers,
    MetricsHelpers,
    MetricsStore,
    ProviderConnection
  }

  @staleness_threshold_ms 30_000
  @staleness_check_interval_ms 10_000

  @impl true
  def mount(params, session, socket) do
    alias Lasso.Config.ConfigStore

    socket = assign(socket, :active_tab, Map.get(params, "tab", "overview"))

    profiles = ConfigStore.list_profiles()
    selected_profile = determine_initial_profile(params, session, profiles)

    if connected?(socket) do
      subscribe_profile_topics(selected_profile)
      subscribe_global_topics(selected_profile)

      # Subscribe to real-time event stream
      EventStream.subscribe(selected_profile)

      if Lasso.VMMetricsCollector.enabled?() do
        Lasso.VMMetricsCollector.subscribe()
      end

      Process.send_after(self(), :load_metrics_on_connect, 0)
      Process.send_after(self(), :metrics_refresh, Constants.vm_metrics_interval())
      schedule_staleness_check()
    end

    # Transform profile's chain names into map structures for the UI
    available_chains =
      ConfigStore.list_chains_for_profile(selected_profile)
      |> Enum.map(fn chain_name ->
        %{
          name: chain_name,
          display_name: Helpers.get_chain_display_name(selected_profile, chain_name)
        }
      end)

    default_metrics_chain = default_metrics_chain(available_chains)

    initial_state =
      socket
      |> assign(:profiles, profiles)
      |> assign(:selected_profile, selected_profile)
      |> assign(:profile_chains, ConfigStore.list_chains_for_profile(selected_profile))
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
      |> assign(:metrics_selected_chain, default_metrics_chain)
      |> assign(:provider_metrics, [])
      |> assign(:method_metrics, [])
      |> assign(:metrics_loading, true)
      |> assign(:metrics_last_updated, nil)
      |> assign(:vm_metrics_enabled, Lasso.VMMetricsCollector.enabled?())
      |> assign(:metrics_task, nil)
      |> assign(:metrics_stale, false)
      |> assign(:metrics_coverage, %{responding: 1, total: 1})
      |> assign(:last_cluster_update, System.system_time(:millisecond))
      # Real-time aggregator state
      |> assign(:live_provider_metrics, %{})
      |> assign(:cluster_circuit_states, %{})
      |> assign(:cluster_health_counters, %{})
      |> assign(:cluster_block_heights, %{})
      |> assign(:available_regions, [])
      |> fetch_connections(selected_profile)

    {:ok, initial_state}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up PubSub subscriptions to prevent orphaned subscriptions
    if profile = socket.assigns[:selected_profile] do
      unsubscribe_profile_topics(profile)
      unsubscribe_global_topics(profile)
      EventStream.unsubscribe(profile)
    end

    if Lasso.VMMetricsCollector.enabled?() do
      Lasso.VMMetricsCollector.unsubscribe()
    end

    :ok
  end

  defp determine_initial_profile(params, session, profiles) do
    # Ensure we have a fallback if no profiles are configured
    profiles = if Enum.empty?(profiles), do: ["default"], else: profiles

    cond do
      profile = Map.get(params, "profile") ->
        if profile in profiles, do: profile, else: List.first(profiles)

      profile = Map.get(session, "selected_profile") ->
        if profile in profiles, do: profile, else: List.first(profiles)

      true ->
        List.first(profiles)
    end
  end

  defp subscribe_profile_topics(profile) do
    alias Lasso.Config.ConfigStore

    chains = ConfigStore.list_chains_for_profile(profile)

    # Only subscribe to topics NOT handled by EventStream
    # EventStream handles: circuit:events, block_sync (and forwards raw events)
    # Removed: ws:conn (handlers were no-ops)
    for chain <- chains do
      Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{profile}:#{chain}")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "health_probe:#{profile}:#{chain}")
    end
  end

  defp subscribe_global_topics(_profile) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "sync:updates")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_cache:updates")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "clients:events")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "chain_config_changes")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "chain_config_updates")
  end

  defp unsubscribe_global_topics(_profile) do
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, "sync:updates")
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, "block_cache:updates")
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, "clients:events")
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, "chain_config_changes")
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, "chain_config_updates")
  end

  defp unsubscribe_profile_topics(profile) do
    alias Lasso.Config.ConfigStore

    chains = ConfigStore.list_chains_for_profile(profile)

    # Only unsubscribe from topics we directly subscribe to
    # EventStream handles: circuit:events, block_sync
    for chain <- chains do
      Phoenix.PubSub.unsubscribe(Lasso.PubSub, "provider_pool:events:#{profile}:#{chain}")
      Phoenix.PubSub.unsubscribe(Lasso.PubSub, "health_probe:#{profile}:#{chain}")
    end
  end

  defp switch_profile(socket, new_profile) do
    alias Lasso.Config.ConfigStore

    # Mount guarantees selected_profile is set
    old_profile = socket.assigns.selected_profile

    unsubscribe_profile_topics(old_profile)
    subscribe_profile_topics(new_profile)

    # Switch event stream subscription
    EventStream.unsubscribe(old_profile)
    EventStream.subscribe(new_profile)

    available_chains =
      ConfigStore.list_chains_for_profile(new_profile)
      |> Enum.map(fn chain_name ->
        %{
          name: chain_name,
          display_name: Helpers.get_chain_display_name(new_profile, chain_name)
        }
      end)

    default_metrics_chain = default_metrics_chain(available_chains)

    socket
    |> assign(:selected_profile, new_profile)
    |> assign(:profile_chains, ConfigStore.list_chains_for_profile(new_profile))
    |> assign(:available_chains, available_chains)
    |> assign(:selected_chain, nil)
    |> assign(:selected_provider, nil)
    |> assign(:details_collapsed, true)
    |> assign(:events, [])
    |> assign(:routing_events, [])
    |> assign(:provider_events, [])
    |> assign(:metrics_selected_chain, default_metrics_chain)
    # Reset aggregator state for new profile
    |> assign(:live_provider_metrics, %{})
    |> assign(:cluster_circuit_states, %{})
    |> assign(:cluster_block_heights, %{})
    |> assign(:available_regions, [])
    |> fetch_connections(new_profile)
    |> push_event("persist_profile", %{profile: new_profile})
  end

  @impl true
  def handle_info({:connection_status_update, connections}, socket) do
    socket = MessageHandlers.handle_connection_status_update(connections, socket, &buffer_event/2)
    {:noreply, socket}
  end

  # Batched events from EventStream
  @impl true
  def handle_info({:events_batch, %{events: events}}, socket) do
    socket =
      socket
      |> MessageHandlers.handle_events_batch(events)
      |> refresh_selected_chain_events()
      |> mark_not_stale()

    {:noreply, socket}
  end

  @impl true
  def handle_info(evt, socket)
      when is_struct(evt, Provider.Healthy) or
             is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.HealthCheckFailed) or
             is_struct(evt, Provider.WSConnected) or
             is_struct(evt, Provider.WSClosed) do
    socket =
      MessageHandlers.handle_provider_event(
        evt,
        socket,
        &buffer_event/2,
        &fetch_connections/1,
        &update_selected_chain_metrics/1,
        &update_selected_provider_data/1
      )

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

    socket =
      update(socket, :client_events, fn list ->
        [entry | Enum.take(list, Constants.client_events_limit() - 1)]
      end)

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

    # Filter out events for chains not in the selected profile
    profile_chains = Map.get(socket.assigns, :profile_chains, [])

    if chain in profile_chains do
      # Extract error details if present (new format includes error info)
      error_info = Map.get(event_data, :error)

      # Build message with error details when available
      base_message = "circuit [#{transport}]: #{from_state} -> #{to_state}"

      message =
        case {reason, error_info} do
          {r, %{error_code: code, error_category: cat}}
          when r in [:failure_threshold_exceeded, :reopen_due_to_failure] ->
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

      socket =
        update(socket, :provider_events, fn list ->
          [entry | Enum.take(list, Constants.provider_events_limit() - 1)]
        end)

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
        |> fetch_connections()
        |> maybe_update_selected_provider(provider_id)
        |> maybe_update_selected_chain(chain)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
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

    socket =
      update(socket, :latest_blocks, fn list ->
        [entry | Enum.take(list, Constants.recent_blocks_limit() - 1)]
      end)

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
      |> buffer_event(uev)
      |> maybe_update_selected_chain(chain)

    {:noreply, socket}
  end

  # VM metrics update from centralized collector
  @impl true
  def handle_info({:vm_metrics_update, metrics}, socket) do
    {:noreply, assign(socket, :vm_metrics, metrics)}
  end

  # Load metrics immediately after socket connects
  @impl true
  def handle_info(:load_metrics_on_connect, socket) do
    send(self(), :refresh_cluster_metrics)
    {:noreply, socket}
  end

  # Provider metrics refresh
  @impl true
  def handle_info(:metrics_refresh, socket) do
    send(self(), :refresh_cluster_metrics)
    Process.send_after(self(), :metrics_refresh, 30_000)
    {:noreply, socket}
  end

  # Async cluster metrics refresh
  @impl true
  def handle_info(:refresh_cluster_metrics, socket) do
    if socket.assigns.metrics_task do
      {:noreply, socket}
    else
      profile = socket.assigns.selected_profile
      chain = socket.assigns.metrics_selected_chain

      task =
        Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
          fetch_cluster_metrics(profile, chain)
        end)

      {:noreply, assign(socket, :metrics_task, task)}
    end
  end

  # Handle async task completion
  @impl true
  def handle_info({ref, result}, socket)
      when is_reference(ref) and is_map_key(socket.assigns, :metrics_task) do
    if socket.assigns.metrics_task && socket.assigns.metrics_task.ref == ref do
      Process.demonitor(ref, [:flush])

      socket =
        case result do
          %{provider_metrics: metrics, method_metrics: methods, coverage: cov, stale: stale} ->
            socket
            |> assign(:provider_metrics, metrics)
            |> assign(:method_metrics, methods)
            |> assign(:metrics_loading, false)
            |> assign(:metrics_last_updated, DateTime.utc_now())
            |> assign(:metrics_coverage, %{
              responding: cov.responding,
              total: cov.total
            })
            |> assign(:metrics_stale, stale)
            |> assign(:metrics_task, nil)

          _ ->
            assign(socket, :metrics_task, nil)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle async task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
      when is_reference(ref) and is_map_key(socket.assigns, :metrics_task) do
    if socket.assigns.metrics_task && socket.assigns.metrics_task.ref == ref do
      socket
      |> assign(:metrics_stale, true)
      |> assign(:metrics_task, nil)
      |> then(&{:noreply, &1})
    else
      {:noreply, socket}
    end
  end

  # Staleness detection
  @impl true
  def handle_info(:check_staleness, socket) do
    now = System.system_time(:millisecond)
    time_since_update = now - socket.assigns.last_cluster_update

    # In single-node mode (total == 1), staleness doesn't apply since there's
    # no cluster to be out of sync with
    stale =
      socket.assigns.metrics_coverage.total > 1 and
        time_since_update > @staleness_threshold_ms

    schedule_staleness_check()
    {:noreply, assign(socket, :metrics_stale, stale)}
  end

  @impl true
  def handle_info({:metrics_chain_selected, chain}, socket) do
    socket = assign(socket, :metrics_selected_chain, chain)
    send(self(), :refresh_cluster_metrics)
    {:noreply, socket}
  end

  # Live sync/block height updates from ProviderPool probes
  @impl true
  def handle_info(%{chain: _chain, provider_id: pid, block_height: _height}, socket) do
    socket =
      socket
      |> schedule_connection_refresh()
      |> maybe_refresh_selected_provider(pid)

    {:noreply, socket}
  end

  # Real-time block updates from BlockCache (WebSocket newHeads)
  @impl true
  def handle_info(%{type: :block_update, provider_id: pid}, socket) do
    socket =
      socket
      |> schedule_connection_refresh()
      |> maybe_refresh_selected_provider(pid)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:flush_connections, socket) do
    Process.delete(:pending_connection_update)
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
    socket =
      push_event(socket, "show_notification", %{message: message, type: Atom.to_string(type)})

    {:noreply, socket}
  end

  # Chain configuration changes - refresh available chains and connections
  @impl true
  def handle_info({config_event, _arg1, _arg2}, socket)
      when config_event in [:chain_created, :chain_updated, :chain_deleted, :config_restored] do
    socket =
      socket
      |> refresh_available_chains()
      |> fetch_connections()

    {:noreply, socket}
  end

  def handle_info(
        {:block_height_update, {profile, provider_id}, height, source, timestamp},
        socket
      ) do
    event = %{
      type: :block_height_update,
      profile: profile,
      provider_id: provider_id,
      height: height,
      source: source,
      timestamp: timestamp
    }

    events = [event | Map.get(socket.assigns, :events, [])] |> Enum.take(100)
    socket = assign(socket, :events, events)

    # Refresh connections for all providers to update statuses in real-time
    socket =
      if profile == socket.assigns[:selected_profile] do
        socket
        |> schedule_connection_refresh()
        |> maybe_refresh_selected_provider(provider_id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:health_probe_recovery, {profile, provider_id}, transport, old_state, _new_state,
         timestamp},
        socket
      ) do
    event = %{
      type: :health_probe_recovery,
      profile: profile,
      provider_id: provider_id,
      transport: transport,
      after_failures: old_state.consecutive_failures,
      timestamp: timestamp
    }

    events = [event | Map.get(socket.assigns, :events, [])] |> Enum.take(100)

    socket =
      socket
      |> assign(:events, events)
      |> schedule_connection_refresh()
      |> maybe_refresh_selected_provider(provider_id)

    {:noreply, socket}
  end

  # EventStream messages (new map payload format)

  # Batched snapshot on subscribe (reduces 5 messages -> 1)
  def handle_info({:dashboard_snapshot, snapshot}, socket) do
    socket =
      socket
      |> assign(:live_provider_metrics, snapshot.metrics)
      |> assign(:cluster_circuit_states, snapshot.circuits)
      |> assign(:cluster_health_counters, snapshot.health_counters)
      |> assign(:cluster_status, snapshot.cluster)
      |> MessageHandlers.handle_events_snapshot(snapshot.events)
      |> refresh_selected_chain_events()
      |> mark_not_stale()

    {:noreply, socket}
  end

  def handle_info({:metrics_update, %{metrics: changed_metrics}}, socket) do
    live_metrics = Map.merge(socket.assigns.live_provider_metrics, changed_metrics)

    socket =
      socket
      |> assign(:live_provider_metrics, live_metrics)
      |> mark_not_stale()

    {:noreply, socket}
  end

  def handle_info(
        {:circuit_update, %{provider_id: provider_id, region: region, circuit: circuit}},
        socket
      ) do
    key = {provider_id, region}
    circuits = Map.put(socket.assigns.cluster_circuit_states, key, circuit)
    {:noreply, assign(socket, :cluster_circuit_states, circuits)}
  end

  def handle_info(
        {:health_pulse, %{provider_id: provider_id, region: region, counters: counters}},
        socket
      ) do
    key = {provider_id, region}
    health_counters = Map.put(socket.assigns.cluster_health_counters, key, counters)
    {:noreply, assign(socket, :cluster_health_counters, health_counters)}
  end

  def handle_info({:cluster_update, cluster_state}, socket) do
    socket =
      socket
      |> assign(:metrics_coverage, %{
        responding: cluster_state.responding,
        total: cluster_state.connected
      })
      |> assign(:available_regions, cluster_state.regions)
      |> mark_not_stale()

    {:noreply, socket}
  end

  # Heartbeat from EventStream - keeps connection marked as alive
  def handle_info({:heartbeat, %{ts: _ts}}, socket) do
    {:noreply, mark_not_stale(socket)}
  end

  def handle_info({:region_added, %{region: region}}, socket) do
    regions = [region | socket.assigns.available_regions] |> Enum.uniq()
    {:noreply, assign(socket, :available_regions, regions)}
  end

  def handle_info(
        {:block_update, %{provider_id: provider_id, region: region, height: height, lag: lag}},
        socket
      ) do
    key = {provider_id, region}
    heights = Map.put(socket.assigns.cluster_block_heights, key, %{height: height, lag: lag})
    {:noreply, assign(socket, :cluster_block_heights, heights)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="flex h-full w-full flex-col"
      phx-hook="ProfilePersistence"
      id="dashboard-profile-persistence"
    >
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

      <DashboardHeader.header
        active_tab={@active_tab}
        vm_metrics_enabled={@vm_metrics_enabled}
        profiles={@profiles}
        selected_profile={@selected_profile}
      />
      
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
              selected_profile={@selected_profile}
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
              live_provider_metrics={@live_provider_metrics}
              cluster_circuit_states={@cluster_circuit_states}
              cluster_health_counters={@cluster_health_counters}
              cluster_block_heights={@cluster_block_heights}
              available_regions={@available_regions}
            />
          <% "metrics" -> %>
            <.live_component
              module={LassoWeb.Dashboard.Components.MetricsTab}
              id="metrics-tab"
              available_chains={@available_chains}
              metrics_selected_chain={@metrics_selected_chain}
              selected_profile={@selected_profile}
              provider_metrics={@provider_metrics}
              method_metrics={@method_metrics}
              metrics_loading={@metrics_loading}
              metrics_last_updated={@metrics_last_updated}
            />
          <% "benchmarks" -> %>
            <DashboardComponents.benchmarks_tab_content />
          <% "system" -> %>
            <%= if @vm_metrics_enabled do %>
              <DashboardComponents.metrics_tab_content
                connections={@connections}
                routing_events={@routing_events}
                provider_events={@provider_events}
                last_updated={@last_updated}
                vm_metrics={@vm_metrics}
              />
            <% else %>
              <div class="flex h-full w-full items-center justify-center">
                <div class="text-center p-8">
                  <div class="text-gray-500 mb-2">System metrics are disabled</div>
                  <div class="text-sm text-gray-600">
                    Set <code class="bg-gray-800 px-1 rounded">LASSO_VM_METRICS_ENABLED=true</code>
                    to enable
                  </div>
                </div>
              </div>
            <% end %>
        <% end %>
      </div>
      
    <!-- Fixed cluster status indicator -->
      <ClusterStatus.fixed_cluster_status
        responding={@metrics_coverage.responding}
        total={@metrics_coverage.total}
        stale={@metrics_stale}
      />
    </div>
    """
  end

  # Dashboard tab content attrs
  attr(:connections, :list)
  attr(:routing_events, :list)
  attr(:provider_events, :list)
  attr(:client_events, :list)
  attr(:latest_blocks, :list)
  attr(:events, :list)
  attr(:selected_chain, :string)
  attr(:selected_provider, :string)
  attr(:selected_profile, :string, default: "default")
  attr(:details_collapsed, :boolean)
  attr(:events_collapsed, :boolean)
  attr(:available_chains, :list)
  attr(:chain_config_open, :boolean)
  attr(:chain_config_collapsed, :boolean, default: true)
  attr(:selected_chain_metrics, :map, default: %{})
  attr(:selected_chain_events, :list, default: [])
  attr(:selected_chain_unified_events, :list, default: [])
  attr(:selected_chain_endpoints, :map, default: %{})
  attr(:selected_chain_provider_events, :list, default: [])
  attr(:selected_provider_events, :list, default: [])
  attr(:selected_provider_unified_events, :list, default: [])
  attr(:selected_provider_metrics, :map, default: %{})
  attr(:live_provider_metrics, :map, default: %{})
  attr(:cluster_circuit_states, :map, default: %{})
  attr(:cluster_health_counters, :map, default: %{})
  attr(:cluster_block_heights, :map, default: %{})
  attr(:available_regions, :list, default: [])

  def dashboard_tab_content(assigns) do
    {center_x, center_y} = TopologyConfig.canvas_center()
    assigns = assign(assigns, canvas_center: "#{center_x},#{center_y}")

    ~H"""
    <div class="relative flex h-full w-full">
      <!-- Main Network Topology Area -->
      <div
        class="flex-1 overflow-hidden"
        phx-hook="DraggableNetworkViewport"
        id="draggable-viewport"
        data-canvas-center={@canvas_center}
      >
        <div class="h-full w-full" data-draggable-content>
          <div id="provider-request-animator" phx-hook="ProviderRequestAnimator" class="hidden"></div>
          <NetworkTopology.nodes_display
            id="network-topology"
            connections={@connections}
            selected_chain={@selected_chain}
            selected_provider={@selected_provider}
            selected_profile={@selected_profile}
            cluster_circuit_states={@cluster_circuit_states}
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
        selected_profile={@selected_profile}
      />

      <NetworkStatusLegend.legend />

      <.floating_details_window
        selected_profile={@selected_profile}
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
        live_provider_metrics={@live_provider_metrics}
        cluster_circuit_states={@cluster_circuit_states}
        cluster_health_counters={@cluster_health_counters}
        cluster_block_heights={@cluster_block_heights}
        available_regions={@available_regions}
      />
    </div>
    """
  end

  # Floating details window wrapper (pinned top-right)
  attr(:selected_profile, :string)
  attr(:selected_chain, :string)
  attr(:selected_provider, :string)
  attr(:details_collapsed, :boolean)
  attr(:connections, :list)
  attr(:routing_events, :list)
  attr(:provider_events, :list)
  attr(:latest_blocks, :list)
  attr(:events, :list)
  attr(:chain_config_open, :boolean)
  attr(:chain_config_collapsed, :boolean)
  attr(:selected_chain_metrics, :map)
  attr(:selected_chain_events, :list)
  attr(:selected_chain_unified_events, :list)
  attr(:selected_chain_endpoints, :map)
  attr(:selected_chain_provider_events, :list, default: [])
  attr(:selected_provider_events, :list, default: [])
  attr(:selected_provider_unified_events, :list, default: [])
  attr(:selected_provider_metrics, :map, default: %{})
  attr(:live_provider_metrics, :map, default: %{})
  attr(:cluster_circuit_states, :map, default: %{})
  attr(:cluster_health_counters, :map, default: %{})
  attr(:cluster_block_heights, :map, default: %{})
  attr(:available_regions, :list, default: [])

  def floating_details_window(assigns) do
    import LassoWeb.Components.FloatingWindow
    alias LassoWeb.Components.DetailPanelComponents

    # Calculate system metrics
    total_connections = length(assigns.connections)
    connected_providers = Enum.count(assigns.connections, &(&1.status == :connected))
    total_chains = assigns.connections |> Enum.map(& &1.chain) |> Enum.uniq() |> length()

    # Determine status indicator
    status =
      if connected_providers == total_connections && total_connections > 0 do
        :healthy
      else
        :degraded
      end

    # Determine title based on selection
    title =
      cond do
        assigns.details_collapsed ->
          "Routing Profile"

        assigns.selected_provider ->
          "Provider Details"

        assigns.selected_chain ->
          "Chain Details"

        true ->
          "Routing Profile"
      end

    # Determine if toggle should be enabled (only when chain or provider is selected)
    on_toggle =
      if assigns.selected_chain || assigns.selected_provider do
        "toggle_details_panel"
      else
        nil
      end

    # Get profile display name
    profile_display_name =
      case Lasso.Config.ConfigStore.get_profile(assigns.selected_profile) do
        {:ok, meta} -> meta.name
        _ -> assigns.selected_profile
      end

    assigns =
      assigns
      |> assign(:total_connections, total_connections)
      |> assign(:connected_providers, connected_providers)
      |> assign(:total_chains, total_chains)
      |> assign(:status, status)
      |> assign(:title, title)
      |> assign(:on_toggle, on_toggle)
      |> assign(:profile_display_name, profile_display_name)

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
        <div class="truncate text-xs text-gray-300">{@title}</div>
      </:header>

      <:collapsed_preview>
        <div class="space-y-3">
          <div class="px-5 pt-5 pb-1">
            <h3 class="text-2xl font-bold leading-none text-white tracking-tight capitalize">
              {@profile_display_name}
            </h3>
            <div class="text-sm text-gray-500 mt-0.5">
              <span class="text-gray-300">{@total_connections}</span>
              providers · <span class="text-gray-300">{@total_chains}</span>
              chains
            </div>
          </div>

          <DetailPanelComponents.metrics_strip class="border-y border-gray-800">
            <:metric
              label="RPS"
              value={format_rps(MetricsHelpers.rpc_calls_per_second(@routing_events))}
              value_class="text-sky-400"
            />
            <:metric
              label="Success"
              value={format_success_rate(MetricsHelpers.success_rate_percent(@routing_events))}
              value_class={success_rate_class(MetricsHelpers.success_rate_percent(@routing_events))}
            />
            <:metric
              label="Latency"
              value={format_latency(MetricsHelpers.avg_latency_ms(@routing_events))}
              value_class="text-purple-400"
            />
            <:metric
              label="Failovers"
              value={format_failovers(MetricsHelpers.failovers_last_minute(@routing_events))}
              value_class="text-yellow-300"
            />
          </DetailPanelComponents.metrics_strip>

          <div class="px-5 pb-4">
            <h4 class="text-xs font-semibold text-gray-500 mb-2">
              Recent Activity
            </h4>
            <div
              id="recent-activity-feed"
              phx-hook="ActivityFeed"
              class="flex max-h-32 flex-col gap-1 overflow-y-auto"
              style="overflow-anchor: none;"
            >
              <%= for e <- Enum.take(@routing_events, 100) do %>
                <div
                  data-event-id={e[:ts_ms]}
                  class="text-[9px] text-gray-300 flex items-center gap-1 shrink-0"
                >
                  <span class="text-purple-300">{e.chain}</span>
                  <span class="text-sky-300">{e.method}</span>
                  → <span class="text-emerald-300">{String.slice(e.provider_id, 0, 14)}…</span>
                  <span class={[
                    "",
                    if(e[:result] == :error, do: "text-red-400", else: "text-yellow-300")
                  ]}>
                    ({e[:duration_ms] || 0}ms)
                  </span>
                  <%= if (e[:failovers] || 0) > 0 do %>
                    <span
                      class="inline-flex items-center px-1 py-0.5 rounded text-[8px] text-orange-300 font-bold bg-orange-900/50"
                      title={"#{e[:failovers]} failover(s)"}
                    >
                      ↻{e[:failovers]}
                    </span>
                  <% end %>
                </div>
              <% end %>
              <%= if length(@routing_events) == 0 do %>
                <div class="text-[10px] text-gray-600">Waiting for requests...</div>
              <% end %>
            </div>
          </div>
        </div>
      </:collapsed_preview>

      <:body>
        <%= cond do %>
          <% @selected_provider -> %>
            <.live_component
              module={LassoWeb.Dashboard.Components.ProviderDetailsPanel}
              id={"provider-details-#{@selected_provider}"}
              provider_id={@selected_provider}
              connections={@connections}
              selected_profile={@selected_profile}
              selected_provider_unified_events={@selected_provider_unified_events}
              selected_provider_metrics={@selected_provider_metrics}
              live_provider_metrics={@live_provider_metrics}
              cluster_circuit_states={@cluster_circuit_states}
              cluster_health_counters={@cluster_health_counters}
              cluster_block_heights={@cluster_block_heights}
              available_regions={@available_regions}
            />
          <% @selected_chain -> %>
            <.live_component
              module={LassoWeb.Dashboard.Components.ChainDetailsPanel}
              id={"chain-details-#{@selected_chain}"}
              chain={@selected_chain}
              connections={@connections}
              routing_events={@routing_events}
              provider_events={@provider_events}
              events={@events}
              selected_profile={@selected_profile}
              selected_chain_metrics={@selected_chain_metrics}
              selected_chain_events={@selected_chain_events}
              selected_chain_unified_events={@selected_chain_unified_events}
              selected_chain_endpoints={@selected_chain_endpoints}
              selected_chain_provider_events={@selected_chain_provider_events}
              live_provider_metrics={@live_provider_metrics}
              cluster_circuit_states={@cluster_circuit_states}
              cluster_block_heights={@cluster_block_heights}
              available_regions={@available_regions}
            />
          <% true -> %>
        <% end %>
      </:body>
    </.floating_window>
    """
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab_param = Map.get(params, "tab")

    # Handle profile param changes
    socket =
      case Map.get(params, "profile") do
        nil ->
          # No profile in URL, redirect to selected profile
          # Mount guarantees selected_profile is set
          profile = socket.assigns.selected_profile
          tab = tab_param || Map.get(socket.assigns, :active_tab, "overview")
          push_patch(socket, to: ~p"/dashboard/#{profile}?tab=#{tab}")

        profile_slug ->
          current_profile = Map.get(socket.assigns, :selected_profile)
          profiles = Map.get(socket.assigns, :profiles, [])

          # Profile changed, switch if valid and different
          if profile_slug != current_profile and profile_slug in profiles do
            switch_profile(socket, profile_slug)
          else
            socket
          end
      end

    socket = assign(socket, :active_tab, Map.get(params, "tab", "overview"))

    socket =
      case Map.get(params, "chain") do
        chain when chain not in [nil, ""] ->
          socket
          |> assign(:selected_chain, chain)
          |> assign(:selected_provider, nil)
          |> assign(:details_collapsed, false)
          |> update_selected_chain_metrics()
          |> push_event("center_on_chain", %{chain: chain})

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Mount guarantees selected_profile is set
    profile = socket.assigns.selected_profile
    {:noreply, push_patch(socket, to: ~p"/dashboard/#{profile}?tab=#{tab}")}
  end

  @impl true
  def handle_event("select_profile", %{"profile" => profile_slug}, socket) do
    alias Lasso.Config.ConfigStore

    case ConfigStore.get_profile(profile_slug) do
      {:ok, _profile} ->
        {:noreply, push_patch(socket, to: ~p"/dashboard/#{profile_slug}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Profile not found")}
    end
  end

  @impl true
  def handle_event("restore_profile", %{"profile" => profile_slug}, socket) do
    profiles = Map.get(socket.assigns, :profiles, [])
    current_profile = Map.get(socket.assigns, :selected_profile)

    # Only switch if profile is valid and different from current
    if profile_slug in profiles and profile_slug != current_profile do
      {:noreply, push_patch(socket, to: ~p"/dashboard/#{profile_slug}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_chain", %{"chain" => chain}, socket) do
    socket =
      if chain == "" do
        socket
        |> assign(:selected_chain, nil)
        |> assign(:details_collapsed, true)
        |> update_selected_chain_metrics()
      else
        socket
        |> assign(:selected_chain, chain)
        |> assign(:selected_provider, nil)
        |> assign(:details_collapsed, false)
        |> update_selected_chain_metrics()
        |> push_event("center_on_chain", %{chain: chain})
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    socket =
      if provider == "" do
        socket
        |> assign(:selected_provider, nil)
        |> assign(:details_collapsed, true)
        |> update_selected_provider_data()
      else
        socket
        |> assign(:selected_provider, provider)
        |> assign(:selected_chain, nil)
        |> assign(:details_collapsed, false)
        |> fetch_connections()
        |> update_selected_provider_data()
        |> push_event("center_on_provider", %{provider: provider})
      end

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

  # Helper functions

  defp default_metrics_chain(available_chains) do
    cond do
      Enum.any?(available_chains, &(&1.name == "ethereum")) -> "ethereum"
      available_chains != [] -> hd(available_chains).name
      true -> nil
    end
  end

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

  defp average_field([], _extractor), do: nil

  defp average_field(items, extractor) do
    items |> Enum.map(extractor) |> Enum.sum() |> Kernel./(length(items))
  end

  defp buffer_event(socket, event) do
    # Update local event history for display
    update(socket, :events, fn list ->
      [event | Enum.take(list, Constants.event_history_size() - 1)]
    end)
  end

  defp schedule_staleness_check do
    Process.send_after(self(), :check_staleness, @staleness_check_interval_ms)
  end

  defp mark_not_stale(socket) do
    socket
    |> assign(:last_cluster_update, System.system_time(:millisecond))
    |> assign(:metrics_stale, false)
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
        socket
        |> assign(:selected_chain_metrics, %{})
        |> assign(:selected_chain_events, [])
        |> assign(:selected_chain_unified_events, [])
        |> assign(:selected_chain_endpoints, %{})
        |> assign(:selected_chain_provider_events, [])

      chain ->
        chain_metrics = MetricsHelpers.get_chain_performance_metrics(socket.assigns, chain)

        chain_endpoints =
          EndpointHelpers.get_chain_endpoints(socket.assigns.selected_profile, chain)

        chain_events = Enum.filter(socket.assigns.routing_events, &(&1.chain == chain))

        chain_unified_events =
          Enum.filter(socket.assigns.events, fn e -> Map.get(e, :chain) == chain end)

        chain_provider_events = Enum.filter(socket.assigns.provider_events, &(&1.chain == chain))

        socket
        |> assign(:selected_chain_metrics, chain_metrics)
        |> assign(:selected_chain_events, chain_events)
        |> assign(:selected_chain_unified_events, chain_unified_events)
        |> assign(:selected_chain_endpoints, chain_endpoints)
        |> assign(:selected_chain_provider_events, chain_provider_events)
    end
  end

  # Lightweight refresh of just the events for selected chain/provider (no metrics recompute)
  defp refresh_selected_chain_events(socket) do
    socket
    |> do_refresh_chain_events()
    |> do_refresh_provider_events()
  end

  defp do_refresh_chain_events(socket) do
    case socket.assigns[:selected_chain] do
      nil ->
        socket

      chain ->
        chain_events = Enum.filter(socket.assigns.routing_events, &(&1.chain == chain))

        chain_unified_events =
          Enum.filter(socket.assigns.events, fn e -> Map.get(e, :chain) == chain end)

        socket
        |> assign(:selected_chain_events, chain_events)
        |> assign(:selected_chain_unified_events, chain_unified_events)
    end
  end

  defp do_refresh_provider_events(socket) do
    case socket.assigns[:selected_provider] do
      nil ->
        socket

      provider_id ->
        provider_events =
          Enum.filter(socket.assigns.routing_events, &(&1.provider_id == provider_id))

        provider_unified_events =
          Enum.filter(socket.assigns.events, fn e -> Map.get(e, :provider_id) == provider_id end)

        socket
        |> assign(:selected_provider_events, provider_events)
        |> assign(:selected_provider_unified_events, provider_unified_events)
    end
  end

  defp update_selected_provider_data(socket) do
    case socket.assigns[:selected_provider] do
      nil ->
        socket
        |> assign(:selected_provider_events, [])
        |> assign(:selected_provider_unified_events, [])
        |> assign(:selected_provider_metrics, %{})

      provider_id ->
        provider_events =
          Enum.filter(socket.assigns.routing_events, &(&1.provider_id == provider_id))

        provider_unified_events =
          Enum.filter(socket.assigns.events, fn e -> Map.get(e, :provider_id) == provider_id end)

        provider_metrics =
          MetricsHelpers.get_provider_performance_metrics(
            provider_id,
            socket.assigns.connections,
            socket.assigns.routing_events,
            socket.assigns.selected_profile
          )

        socket
        |> assign(:selected_provider_events, provider_events)
        |> assign(:selected_provider_unified_events, provider_unified_events)
        |> assign(:selected_provider_metrics, provider_metrics)
    end
  end

  defp maybe_update_selected_chain(socket, chain) do
    if socket.assigns[:selected_chain] == chain do
      update_selected_chain_metrics(socket)
    else
      socket
    end
  end

  defp maybe_update_selected_provider(socket, provider_id) do
    if socket.assigns[:selected_provider] == provider_id do
      update_selected_provider_data(socket)
    else
      socket
    end
  end

  defp maybe_refresh_selected_provider(socket, provider_id) do
    if socket.assigns[:selected_provider] == provider_id do
      socket
      |> fetch_connections()
      |> update_selected_provider_data()
    else
      socket
    end
  end

  defp fetch_connections(socket, profile \\ nil) do
    profile = profile || socket.assigns.selected_profile
    connections = ProviderConnection.fetch_connections(profile)

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end

  defp fetch_cluster_metrics(profile, chain_name) do
    alias Lasso.Config.ConfigStore

    case ConfigStore.get_providers(profile, chain_name) do
      {:ok, provider_configs} ->
        # Fetch from cluster cache
        %{data: provider_leaderboard, coverage: coverage, stale: stale} =
          MetricsStore.get_provider_leaderboard(profile, chain_name)

        %{data: realtime_stats} = MetricsStore.get_realtime_stats(profile, chain_name)

        # Get all RPC methods we have data for
        rpc_methods = Map.get(realtime_stats, :rpc_methods, [])
        provider_ids = Enum.map(provider_configs, & &1.id)

        # Collect detailed metrics by provider
        provider_metrics =
          collect_provider_metrics_cached(
            profile,
            chain_name,
            provider_ids,
            provider_configs,
            provider_leaderboard,
            rpc_methods
          )

        # Collect method-level metrics for comparison
        method_metrics =
          collect_method_metrics_cached(
            profile,
            chain_name,
            provider_ids,
            provider_configs,
            rpc_methods
          )

        %{
          provider_metrics: provider_metrics,
          method_metrics: method_metrics,
          coverage: coverage,
          stale: stale
        }

      {:error, :not_found} ->
        # Chain not configured in this profile - return empty metrics
        %{
          provider_metrics: [],
          method_metrics: [],
          coverage: %{responding: 1, total: 1},
          stale: false
        }
    end
  end

  defp collect_provider_metrics_cached(
         profile,
         chain_name,
         provider_ids,
         provider_configs,
         leaderboard,
         rpc_methods
       ) do
    provider_ids
    |> Enum.map(fn provider_id ->
      config = Enum.find(provider_configs, &(&1.id == provider_id))
      leaderboard_entry = Enum.find(leaderboard, &(&1.provider_id == provider_id))

      # Get aggregate stats across all methods using cache
      method_stats =
        rpc_methods
        |> Enum.map(fn method ->
          %{data: data} =
            MetricsStore.get_rpc_method_performance(
              profile,
              chain_name,
              provider_id,
              method
            )

          data
        end)
        |> Enum.reject(&is_nil/1)

      total_calls = Enum.reduce(method_stats, 0, fn stat, acc -> acc + stat.total_calls end)

      avg_latency =
        if total_calls > 0 do
          weighted_sum =
            Enum.reduce(method_stats, 0, fn stat, acc ->
              acc + stat.avg_duration_ms * stat.total_calls
            end)

          weighted_sum / total_calls
        end

      p50_latency = average_field(method_stats, & &1.percentiles.p50)
      p95_latency = average_field(method_stats, & &1.percentiles.p95)
      p99_latency = average_field(method_stats, & &1.percentiles.p99)
      success_rate = average_field(method_stats, & &1.success_rate)

      consistency_ratio =
        if p50_latency && p99_latency && p50_latency > 0 do
          p99_latency / p50_latency
        end

      # Get latency_by_region from leaderboard entry (cluster-aggregated data)
      latency_by_region =
        if leaderboard_entry do
          Map.get(leaderboard_entry, :latency_by_region, [])
        else
          []
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
        method_count: length(method_stats),
        latency_by_region: latency_by_region
      }
    end)
    |> Enum.reject(&(&1.total_calls == 0))
    |> Enum.sort_by(&(&1.avg_latency || 999_999))
  end

  defp collect_method_metrics_cached(
         profile,
         chain_name,
         provider_ids,
         provider_configs,
         rpc_methods
       ) do
    rpc_methods
    |> Enum.map(fn method ->
      provider_stats =
        provider_ids
        |> Enum.map(fn provider_id ->
          config = Enum.find(provider_configs, &(&1.id == provider_id))

          case MetricsStore.get_rpc_method_performance(
                 profile,
                 chain_name,
                 provider_id,
                 method
               ) do
            %{data: nil} ->
              nil

            %{data: stats} ->
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

  # Formatting helpers for metrics display
  defp format_success_rate(nil), do: "—"
  defp format_success_rate(rate), do: "#{rate}%"

  defp success_rate_class(nil), do: "text-gray-500"
  defp success_rate_class(rate) when rate >= 99.0, do: "text-emerald-400"
  defp success_rate_class(rate) when rate >= 95.0, do: "text-yellow-400"
  defp success_rate_class(_), do: "text-red-400"

  defp format_rps(rps) when rps == 0 or rps == 0.0, do: "0/s"
  defp format_rps(rps), do: "#{rps}/s"

  defp format_latency(nil), do: "—"
  defp format_latency(ms), do: "#{ms}ms"

  defp format_failovers(0), do: "0/min"
  defp format_failovers(n), do: "#{n}/min"
end
