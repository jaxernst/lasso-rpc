defmodule LivechainWeb.OrchestrationLive do
  use LivechainWeb, :live_view

  def mount(_params, _session, socket) do
    socket = assign(socket, :layout, {LivechainWeb.Layouts, "observatory"})
    mount_logic(socket)
  end

  defp mount_logic(socket) do
    if false && connected?(socket) do

      # Subscribe to WebSocket connection events for real-time updates
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")

      # Subscribe to live message streams for the event feed
      Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:ethereum")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:polygon")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:arbitrum")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:bsc")

      # Also subscribe to direct blockchain channels as fallback
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:ethereum")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:polygon")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:arbitrum")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:bsc")

      # Subscribe to structured events from Broadway pipelines
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "broadway:processed")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "broadway:ethereum")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "broadway:polygon")
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "broadway:arbitrum")

      # Subscribe to analytics metrics
      # Phoenix.PubSub.subscribe(Livechain.PubSub, "analytics:metrics")

    end

    initial_state =
      socket
      |> fetch_connections()
      |> assign(:live_events, [])
      |> assign(:structured_events, [])
      |> assign(:analytics_metrics, %{})
      |> assign(:selected_chain, nil)
      |> assign(:selected_provider, nil)
      |> assign(:view_mode, :topology)
      |> assign(:event_filter, :all)

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
    # Throttle connection updates to prevent excessive re-renders
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
    # Throttle connection updates to prevent excessive re-renders
    if Process.get(:pending_connection_update) do
      {:noreply, socket}
    else
      Process.put(:pending_connection_update, true)
      Process.send_after(self(), :flush_connections, 500)
      {:noreply, fetch_connections(socket)}
    end
  end

  @impl true
  def handle_info({:blockchain_message, message}, socket) do
    # Handle direct blockchain messages as fallback
    event = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      provider_id: "blockchain",
      chain: extract_chain_from_message(message),
      message: message,
      type: detect_message_type(message)
    }

    # Keep only last 50 events
    updated_events = [event | socket.assigns.live_events] |> Enum.take(50)

    # Only update if we don't have a pending update
    if Process.get(:pending_event_update) do
      {:noreply, socket}
    else
      Process.put(:pending_event_update, true)
      Process.send_after(self(), :flush_events, 100)
      {:noreply, assign(socket, :live_events, updated_events)}
    end
  end

  @impl true
  def handle_info(%{payload: payload} = message, socket) when is_map(payload) do
    # Handle block events with payload structure
    event = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      provider_id: "blockchain",
      chain: extract_chain_from_message(message),
      message: message,
      type: :block
    }

    # Keep only last 50 events
    updated_events = [event | socket.assigns.live_events] |> Enum.take(50)

    # Only update if we don't have a pending update
    if Process.get(:pending_event_update) do
      {:noreply, socket}
    else
      Process.put(:pending_event_update, true)
      Process.send_after(self(), :flush_events, 100)
      {:noreply, assign(socket, :live_events, updated_events)}
    end
  end

  @impl true
  def handle_info({:fastest_message, provider_id, message}, socket) do
    # Add new live event to the feed
    event = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      provider_id: provider_id,
      chain: extract_chain_from_provider(provider_id),
      message: message,
      type: detect_message_type(message)
    }

    # Keep only last 50 events
    updated_events = [event | socket.assigns.live_events] |> Enum.take(50)

    # Only update if we don't have a pending update
    if Process.get(:pending_event_update) do
      {:noreply, socket}
    else
      Process.put(:pending_event_update, true)
      Process.send_after(self(), :flush_events, 100)
      {:noreply, assign(socket, :live_events, updated_events)}
    end
  end

  @impl true
  def handle_info({:structured_event, event}, socket) do
    # Add structured event from Broadway pipeline
    structured_event = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      type: event.type,
      chain: event.chain,
      usd_value: Map.get(event, :usd_value),
      data: event
    }

    # Keep only last 30 structured events
    updated_events = [structured_event | socket.assigns.structured_events] |> Enum.take(30)

    # Only update if we don't have a pending structured update
    if Process.get(:pending_structured_update) do
      {:noreply, socket}
    else
      Process.put(:pending_structured_update, true)
      Process.send_after(self(), :flush_structured_events, 150)
      {:noreply, assign(socket, :structured_events, updated_events)}
    end
  end

  @impl true
  def handle_info({:broadway_processed, event}, socket) do
    # Handle Broadway pipeline processed events
    structured_event = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      type: Map.get(event, :event_type, :unknown),
      chain: Map.get(event, :chain, "unknown"),
      usd_value: Map.get(event, :usd_value),
      data: event
    }

    updated_events = [structured_event | socket.assigns.structured_events] |> Enum.take(30)

    # Only update if we don't have a pending structured update
    if Process.get(:pending_structured_update) do
      {:noreply, socket}
    else
      Process.put(:pending_structured_update, true)
      Process.send_after(self(), :flush_structured_events, 150)
      {:noreply, assign(socket, :structured_events, updated_events)}
    end
  end

  @impl true
  def handle_info({:metrics_batch, metrics}, socket) do
    # Update analytics metrics
    current_metrics = socket.assigns.analytics_metrics

    updated_metrics = Enum.reduce(metrics, current_metrics, fn metric, acc ->
      chain = Map.get(metric, :chain, "unknown")

      chain_metrics = Map.get(acc, chain, %{
        events_count: 0,
        total_usd_value: 0.0,
        last_updated: 0
      })

      updated_chain_metrics = %{
        events_count: chain_metrics.events_count + Map.get(metric, :count, 0),
        total_usd_value: chain_metrics.total_usd_value + Map.get(metric, :total_usd_value, 0.0),
        last_updated: System.system_time(:millisecond)
      }

      Map.put(acc, chain, updated_chain_metrics)
    end)

    {:noreply, assign(socket, :analytics_metrics, updated_metrics)}
  end

  @impl true
  def handle_info(:tick, socket) do
    # Update timestamps and schedule next tick
    Process.send_after(self(), :tick, 1000)
    socket = assign(socket, :current_time, DateTime.utc_now())
    {:noreply, socket}
  end

  @impl true
  def handle_info(:flush_events, socket) do
    # Clear the pending update flag and trigger a render
    Process.delete(:pending_event_update)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:flush_structured_events, socket) do
    # Clear the pending structured update flag and trigger a render
    Process.delete(:pending_structured_update)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:flush_connections, socket) do
    # Clear the pending connection update flag and trigger a render
    Process.delete(:pending_connection_update)
    {:noreply, socket}
  end

  @impl true
  def handle_info(message, socket) do
    # Catch-all handler for unexpected messages
    {:noreply, socket}
  end


  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen bg-gradient-to-br from-slate-50 to-slate-100 overflow-hidden flex flex-col">
      <style>
        @keyframes slideInLeft {
          from {
            opacity: 0;
            transform: translateX(-20px);
          }
          to {
            opacity: 1;
            transform: translateX(0);
          }
        }

        .scrollbar-thin {
          scrollbar-width: thin;
        }

        .scrollbar-track-gray-800::-webkit-scrollbar-track {
          background-color: #1f2937;
        }

        .scrollbar-thumb-gray-600::-webkit-scrollbar-thumb {
          background-color: #4b5563;
          border-radius: 3px;
        }

        .scrollbar-track-blue-800::-webkit-scrollbar-track {
          background-color: #1e3a8a;
        }

        .scrollbar-thumb-blue-600::-webkit-scrollbar-thumb {
          background-color: #2563eb;
          border-radius: 3px;
        }

        .scrollbar-track-purple-800::-webkit-scrollbar-track {
          background-color: #581c87;
        }

        .scrollbar-thumb-purple-600::-webkit-scrollbar-thumb {
          background-color: #9333ea;
          border-radius: 3px;
        }

        ::-webkit-scrollbar {
          height: 6px;
        }

        .grid-pattern {
          background-image:
            linear-gradient(rgba(255, 255, 255, 0.1) 1px, transparent 1px),
            linear-gradient(90deg, rgba(255, 255, 255, 0.1) 1px, transparent 1px);
          background-size: 20px 20px;
        }
      </style>

      <!-- Header with controls -->
      <div class="bg-white/80 backdrop-blur-sm shadow-sm border-b border-gray-200 px-6 py-4 flex-shrink-0">
        <div class="flex items-center justify-between w-full">
          <div class="flex items-center space-x-4">
            <div class="flex items-center space-x-3">
              <h1 class="text-2xl leading-none font-bold bg-gradient-to-r from-gray-900 to-gray-600 bg-clip-text text-transparent">ChainPulse</h1>
              <div class="flex items-center space-x-1">
                <div class="flex-shrink-0 w-2 h-2 bg-emerald-400 rounded-full animate-pulse"></div>
                <span class="text-xs font-medium text-emerald-600">LIVE</span>
              </div>
            </div>
          </div>

          <div class="flex items-center space-x-4">
            <!-- Connection stats -->
            <div class="text-sm text-gray-600">
              <span class="font-medium"><%= length(@connections) %></span> connections
              <span class="ml-2 font-medium text-emerald-600"><%= Enum.count(@connections, &(&1.status == :connected)) %></span> active
            </div>

            <!-- View mode toggle -->
            <div class="flex items-center space-x-1 bg-gray-100 rounded-lg p-1">
              <button
                phx-click="toggle_view"
                phx-value-mode="topology"
                class={"px-3 py-1 text-sm font-medium rounded-md transition-all duration-200 #{if @view_mode == :topology, do: "bg-white text-gray-900 shadow-sm", else: "text-gray-500 hover:text-gray-900"}"}
              >
                Network
              </button>
              <button
                phx-click="toggle_view"
                phx-value-mode="table"
                class={"px-3 py-1 text-sm font-medium rounded-md transition-all duration-200 #{if @view_mode == :table, do: "bg-white text-gray-900 shadow-sm", else: "text-gray-500 hover:text-gray-900"}"}
              >
                Table
              </button>
            </div>

            <!-- Control buttons -->
            <div class="flex space-x-2">
              <button
                type="button"
                phx-click="refresh"
                class="px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-500 transition-all duration-200 transform hover:scale-105 shadow-sm"
              >
                <svg class="w-4 h-4 mr-1 inline" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
                Refresh
              </button>
              <button
                type="button"
                phx-click="clear_events"
                class="px-4 py-2 bg-gray-600 text-white text-sm font-medium rounded-lg hover:bg-gray-500 transition-all duration-200 shadow-sm"
              >
                Clear
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Collapsible Sections Container -->
      <div class="flex-1 p-6 flex flex-col space-y-4 overflow-y-auto min-h-0">
        <!-- Live Message Stream Section (Black) -->
        <.collapsible_section
          section_id="live_stream"
          title="Live Message Stream"
          subtitle="Real-time WebSocket messages from blockchain networks"
          count={length(@live_events)}
        >
          <:icon>
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
          </:icon>
          <div class="w-full">
            <div class="flex items-center justify-between mb-3">
              <div class="flex items-center space-x-2">
                <select phx-change="filter_events" class="bg-gray-800 text-white text-xs rounded px-2 py-1 border-gray-700">
                  <option value="all">All Events</option>
                  <option value="blocks">Blocks Only</option>
                  <option value="transactions">Transactions</option>
                  <option value="errors">Errors</option>
                </select>
                <span class="text-xs text-gray-400"><%= length(@live_events) %> events</span>
              </div>
            </div>

            <!-- Horizontal scrollable event stream -->
            <div class="overflow-x-auto scrollbar-thin scrollbar-track-gray-800 scrollbar-thumb-gray-600" style="height: 40px;">
              <%= if length(@live_events) > 0 do %>
                <div class="flex space-x-3 pb-2" style="width: max-content;">
                  <%= for {event, index} <- @live_events |> Enum.take(50) |> Enum.with_index() do %>
                    <div
                      class="flex-shrink-0 bg-gray-800 rounded-lg px-3 py-1 text-xs whitespace-nowrap transition-all duration-300 ease-out shadow-sm"
                      style="animation: slideInLeft 0.3s ease-out #{index * 0.05}s both;"
                    >
                      <span class={"font-medium #{event_color(event.type)}"}>[<%= String.upcase(event.chain) %>]</span>
                      <span class="text-gray-300 ml-1"><%= format_event_message(event) %></span>
                      <span class="text-gray-500 ml-2"><%= format_timestamp(event.timestamp) %></span>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="text-xs text-gray-500 text-center py-2">
                  No live events yet - waiting for WebSocket messages...
                </div>
              <% end %>
            </div>
          </div>
        </.collapsible_section>

        <!-- Broadway Pipeline Events Section (Blue) -->
        <.collapsible_section
          section_id="broadway_events"
          title="Broadway Pipeline Events"
          subtitle="Structured events processed through data pipelines"
          count={length(@structured_events)}
        >
          <:icon>
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
            </svg>
          </:icon>
          <div class="w-full">
            <div class="flex items-center justify-between mb-3">
              <div class="flex items-center space-x-4">
                <!-- Analytics Summary -->
                <div class="flex items-center space-x-3 text-xs">
                  <%= if map_size(@analytics_metrics) > 0 do %>
                    <%= for {chain, metrics} <- @analytics_metrics do %>
                      <div class="flex items-center space-x-1">
                        <span class="text-blue-200"><%= String.upcase(chain) %>:</span>
                        <span class="text-emerald-400 font-mono"><%= metrics.events_count %></span>
                        <%= if metrics.total_usd_value > 0 do %>
                          <span class="text-yellow-400 font-mono">$<%= Float.round(metrics.total_usd_value, 0) |> trunc() %></span>
                        <% end %>
                      </div>
                    <% end %>
                  <% else %>
                    <span class="text-blue-300 text-xs">Analytics loading...</span>
                  <% end %>
                </div>
                <span class="text-xs text-blue-400"><%= length(@structured_events) %> structured</span>
              </div>
            </div>

            <!-- Horizontal scrollable structured events -->
            <div class="overflow-x-auto scrollbar-thin scrollbar-track-blue-800 scrollbar-thumb-blue-600" style="height: 40px;">
              <%= if length(@structured_events) > 0 do %>
                <div class="flex space-x-3 pb-2" style="width: max-content;">
                  <%= for {event, index} <- @structured_events |> Enum.take(30) |> Enum.with_index() do %>
                    <div
                      class="flex-shrink-0 bg-blue-800 rounded-lg px-3 py-1 text-xs whitespace-nowrap transition-all duration-300 ease-out shadow-sm"
                      style="animation: slideInLeft 0.3s ease-out #{index * 0.05}s both;"
                    >
                      <span class={"font-medium #{structured_event_color(event.type)}"}>[<%= String.upcase(event.chain) %>]</span>
                      <span class="text-blue-200 ml-1"><%= format_structured_event(event) %></span>
                      <%= if event.usd_value do %>
                        <span class="text-yellow-300 ml-1 font-mono">$<%= Float.round(event.usd_value, 2) %></span>
                      <% end %>
                      <span class="text-blue-400 ml-2"><%= format_timestamp(event.timestamp) %></span>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="text-xs text-blue-400 text-center py-2">
                  No structured events yet - Broadway pipelines processing...
                </div>
              <% end %>
            </div>
          </div>
        </.collapsible_section>

        <!-- Network Topology Section (Purple) -->
        <.collapsible_section
          section_id="network_topology"
          title="Network Topology"
          subtitle="Real-time blockchain network connections and status"
          count={map_size(group_connections_by_chain(@connections))}
        >
          <:icon>
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3" />
            </svg>
          </:icon>

          <div class="w-full">
            <%= if @view_mode == :topology do %>
            <% else %>
              <.connection_table connections={@connections} current_time={@current_time} />
            <% end %>

            <!-- Detail Panel -->
            <%= if @selected_chain || @selected_provider do %>
              <.detail_panel
                selected_chain={@selected_chain}
                selected_provider={@selected_provider}
                connections={@connections}
              />
            <% end %>
          </div>
        </.collapsible_section>
        <.network_topology connections={@connections} selected_chain={@selected_chain} selected_provider={@selected_provider} />
      </div>
    </div>
    """
  end



  @impl true
  def handle_event("refresh", _params, socket) do
    # Clear events and refetch everything
    socket =
      socket
      |> assign(:live_events, [])
      |> assign(:structured_events, [])
      |> assign(:analytics_metrics, %{})
      |> fetch_connections()

    # Broadcast refresh to trigger new data
    Phoenix.PubSub.broadcast(Livechain.PubSub, "dashboard:refresh", {:refresh_requested, self()})

    {:noreply, socket}
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    # Manually trigger a status broadcast to test PubSub
    Livechain.RPC.WSSupervisor.broadcast_connection_status_update()

    # Also add some test events to the live stream
    test_events = [
      %{
        id: System.unique_integer([:positive]),
        timestamp: DateTime.utc_now(),
        provider_id: "test_ethereum_infura",
        chain: "eth",
        message: %{"result" => %{"hash" => "0x1234", "number" => "0x12345"}},
        type: :block
      },
      %{
        id: System.unique_integer([:positive]),
        timestamp: DateTime.utc_now(),
        provider_id: "test_polygon_alchemy",
        chain: "poly",
        message: %{"params" => %{"result" => %{"transactionHash" => "0x5678"}}},
        type: :transaction
      }
    ]

    # Add test structured events to verify Broadway pipeline display
    test_structured = [
      %{
        id: System.unique_integer([:positive]),
        timestamp: DateTime.utc_now(),
        type: :erc20_transfer,
        chain: "ethereum",
        usd_value: 1250.75,
        data: %{from: "0x123", to: "0x456", amount: 1000}
      },
      %{
        id: System.unique_integer([:positive]),
        timestamp: DateTime.utc_now(),
        type: :nft_transfer,
        chain: "polygon",
        usd_value: nil,
        data: %{from: "0x789", to: "0xabc", token_id: "42"}
      }
    ]

    updated_events = (test_events ++ socket.assigns.live_events) |> Enum.take(48)
    updated_structured = (test_structured ++ socket.assigns.structured_events) |> Enum.take(28)

    socket =
      socket
      |> assign(:live_events, updated_events)
      |> assign(:structured_events, updated_structured)

    {:noreply, socket}
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
  def handle_event("close_detail", _params, socket) do
    socket =
      socket
      |> assign(:selected_chain, nil)
      |> assign(:selected_provider, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    # log socket state and mode
    case mode do
      "topology" ->
        {:noreply, assign(socket, :view_mode, :topology)}
      "table" ->
        {:noreply, assign(socket, :view_mode, :table)}
    end
  end

  @impl true
  def handle_event("filter_events", %{"filter" => filter}, socket) do
    event_filter = String.to_atom(filter)
    {:noreply, assign(socket, :event_filter, event_filter)}
  end

  @impl true
  def handle_event("clear_events", _params, socket) do
    socket =
      socket
      |> assign(:live_events, [])
      |> assign(:structured_events, [])

    {:noreply, socket}
  end

  defp fetch_connections(socket) do
    connections = Livechain.RPC.WSSupervisor.list_connections()

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
    |> assign(:current_time, DateTime.utc_now())
  end

  def format_last_seen(connection) do
    case Map.get(connection, :last_seen) do
      nil ->
        "Unknown"

      last_seen ->
        diff_seconds = DateTime.diff(DateTime.utc_now(), last_seen, :second)

        cond do
          diff_seconds < 60 -> "#{diff_seconds}s ago"
          diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
          true -> "#{div(diff_seconds, 3600)}h ago"
        end
    end
  end

  # Helper functions for new visualization

  def calculate_spiral_position(index, _center_x, _center_y) do
    case index do
      0 ->
        # First chain goes in the center - use CSS transforms for centering
        {"50%", "50%"}

      _ ->
        # Spiral outward using a modified Archimedes spiral
        # Calculate which "ring" we're in and position within that ring
        ring = calculate_ring(index)
        position_in_ring = index - ring_start_index(ring)
        positions_in_ring = positions_per_ring(ring)

        # Calculate angle for this position in the ring
        angle = 2 * :math.pi() * position_in_ring / positions_in_ring

        # Distance from center increases with each ring (in viewport units)
        # Use viewport width units for responsiveness
        radius_vw = ring * 15 + 10
        # Use viewport height units for responsiveness
        radius_vh = ring * 12 + 8

        # Calculate offset from center using CSS calc()
        x_offset = radius_vw * :math.cos(angle)
        y_offset = radius_vh * :math.sin(angle)

        x = "calc(50% + #{round(x_offset)}vw)"
        y = "calc(50% + #{round(y_offset)}vh)"

        {x, y}
    end
  end

  def calculate_ring(index) when index <= 0, do: 0

  def calculate_ring(index) do
    # Each ring can hold more nodes: ring 1 = 6, ring 2 = 12, ring 3 = 18, etc.
    total = 0
    ring = 1

    calculate_ring_recursive(index, total, ring)
  end

  def calculate_ring_recursive(index, total, ring) do
    ring_capacity = ring * 6

    if index <= total + ring_capacity do
      ring
    else
      calculate_ring_recursive(index, total + ring_capacity, ring + 1)
    end
  end

  def ring_start_index(ring) when ring <= 1, do: 1

  def ring_start_index(ring) do
    # Sum of positions in all previous rings
    Enum.sum(1..(ring - 1) |> Enum.map(&(&1 * 6))) + 1
  end

  def positions_per_ring(ring) when ring <= 0, do: 1
  def positions_per_ring(ring), do: ring * 6

  def calculate_satellite_position(center_x, center_y, distance, index, total_satellites) do
    # Position WebSocket connections in a circle around their blockchain node
    angle = 2 * :math.pi() * index / max(total_satellites, 1)

    # Handle both pixel and percentage/calc positioning
    case {center_x, center_y} do
      {x, y} when is_binary(x) and is_binary(y) ->
        # For CSS calc() positioning, use CSS transforms with pixel offsets
        x_offset = distance * :math.cos(angle)
        y_offset = distance * :math.sin(angle)

        satellite_x = "calc(#{x} + #{round(x_offset)}px)"
        satellite_y = "calc(#{y} + #{round(y_offset)}px)"

        {satellite_x, satellite_y}

      {x, y} when is_number(x) and is_number(y) ->
        # Fallback for numeric positioning
        satellite_x = x + distance * :math.cos(angle)
        satellite_y = y + distance * :math.sin(angle)

        {round(satellite_x), round(satellite_y)}

      _ ->
        # Default fallback
        {"50%", "50%"}
    end
  end

  def extract_chain_from_message(message) do
    # Try to extract chain info from message metadata
    case message do
      %{"_livechain_meta" => %{"chain_name" => chain}} -> chain
      %{"chainId" => chain_id} when is_integer(chain_id) ->
        case chain_id do
          1 -> "ethereum"
          137 -> "polygon"
          42161 -> "arbitrum"
          56 -> "bsc"
          _ -> "unknown"
        end
      _ -> "unknown"
    end
  end

  def extract_chain_from_provider(provider_id) do
    cond do
      String.contains?(provider_id, "ethereum") -> "eth"
      String.contains?(provider_id, "polygon") -> "poly"
      String.contains?(provider_id, "arbitrum") -> "arb"
      String.contains?(provider_id, "optimism") -> "op"
      String.contains?(provider_id, "base") -> "base"
      String.contains?(provider_id, "bsc") -> "bsc"
      String.contains?(provider_id, "avalanche") -> "avax"
      String.contains?(provider_id, "zksync") -> "zk"
      String.contains?(provider_id, "linea") -> "linea"
      String.contains?(provider_id, "scroll") -> "scroll"
      String.contains?(provider_id, "mantle") -> "mantle"
      String.contains?(provider_id, "blast") -> "blast"
      String.contains?(provider_id, "mode") -> "mode"
      String.contains?(provider_id, "fantom") -> "ftm"
      String.contains?(provider_id, "celo") -> "celo"
      true -> "unknown"
    end
  end

  def detect_message_type(message) when is_map(message) do
    cond do
      Map.has_key?(message, "result") and is_map(message["result"]) and
          Map.has_key?(message["result"], "hash") ->
        :block

      Map.has_key?(message, "params") and is_map(message["params"]) ->
        :subscription

      Map.has_key?(message, "error") ->
        :error

      true ->
        :other
    end
  end

  def detect_message_type(_), do: :other

  def event_color(:block), do: "text-emerald-400"
  def event_color(:transaction), do: "text-blue-400"
  def event_color(:error), do: "text-red-400"
  def event_color(:subscription), do: "text-yellow-400"
  def event_color(_), do: "text-gray-400"

  def format_event_message(event) do
    case event.type do
      :block -> "New Block"
      :transaction -> "Transaction"
      :error -> "Error"
      :subscription -> "Event"
      _ -> "Message"
    end
  end

  def format_timestamp(timestamp) do
    DateTime.diff(DateTime.utc_now(), timestamp, :second)
    |> case do
      diff when diff < 60 -> "#{diff}s"
      diff when diff < 3600 -> "#{div(diff, 60)}m"
      _ -> DateTime.to_time(timestamp) |> Time.to_string() |> String.slice(0..7)
    end
  end

  def structured_event_color(:erc20_transfer), do: "text-emerald-300"
  def structured_event_color(:nft_transfer), do: "text-purple-300"
  def structured_event_color(:native_transfer), do: "text-blue-300"
  def structured_event_color(:block), do: "text-yellow-300"
  def structured_event_color(:transaction), do: "text-indigo-300"
  def structured_event_color(_), do: "text-gray-300"

  def format_structured_event(event) do
    case event.type do
      :erc20_transfer -> "Token Transfer"
      :nft_transfer -> "NFT Transfer"
      :native_transfer -> "Native Transfer"
      :block -> "New Block"
      :transaction -> "Transaction"
      _ -> "Event"
    end
  end

  def group_connections_by_chain(connections) do
    connections
    |> Enum.group_by(&extract_chain_from_connection_name(&1.name))
  end

  def extract_chain_from_connection_name(name) do
    name_lower = String.downcase(name)

    cond do
      String.contains?(name_lower, "ethereum") -> "ethereum"
      String.contains?(name_lower, "polygon") -> "polygon"
      String.contains?(name_lower, "arbitrum") -> "arbitrum"
      String.contains?(name_lower, "optimism") -> "optimism"
      String.contains?(name_lower, "base") -> "base"
      String.contains?(name_lower, "bsc") -> "bsc"
      String.contains?(name_lower, "avalanche") -> "avalanche"
      String.contains?(name_lower, "zksync") -> "zksync"
      String.contains?(name_lower, "linea") -> "linea"
      String.contains?(name_lower, "scroll") -> "scroll"
      String.contains?(name_lower, "mantle") -> "mantle"
      String.contains?(name_lower, "blast") -> "blast"
      String.contains?(name_lower, "mode") -> "mode"
      String.contains?(name_lower, "fantom") -> "fantom"
      String.contains?(name_lower, "celo") -> "celo"
      true -> "unknown"
    end
  end

  # Component functions

  def network_topology(assigns) do
    assigns = assign(assigns, :chains, group_connections_by_chain(assigns.connections))

    ~H"""
    <div class="h-full w-full bg-gradient-to-br from-slate-50 to-slate-100 relative overflow-hidden">
      <!-- Background grid pattern -->
      <div class="absolute inset-0 opacity-30" style="background-image: radial-gradient(circle, #e5e7eb 1px, transparent 1px); background-size: 50px 50px;"></div>

      <!-- Debug info -->
      <div class="absolute top-4 left-4 bg-white/90 backdrop-blur-sm p-3 rounded-lg text-xs font-mono z-50 shadow-sm border border-gray-200">
        Total connections: <%= length(@connections) %><br/>
        Chains found: <%= map_size(@chains) %><br/>
        Chain groups: <%= inspect(Map.keys(@chains)) %>
      </div>

      <%= if map_size(@chains) == 0 do %>
        <!-- No connections fallback -->
        <div class="flex items-center justify-center h-full">
          <div class="text-center">
            <div class="text-6xl text-gray-400 mb-4">🔗</div>
            <h2 class="text-xl font-semibold text-gray-700 mb-2">No Blockchain Connections</h2>
            <p class="text-gray-500">Start some WebSocket connections to see the network topology</p>
            <button phx-click="test_connection" class="mt-4 px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-500 transition-all duration-200">
              Test Connection
            </button>
          </div>
        </div>
      <% else %>
        <!-- Interactive nodes with spiral grid layout -->
        <%= for {{chain_name, chain_connections}, index} <- @chains |> Enum.with_index() do %>
          <% {x, y} = calculate_spiral_position(index, "50%", "50%") %>
          <% radius = 40 + min(length(chain_connections) * 3, 20) %>

          <!-- Chain node -->
          <div
            class={"absolute cursor-pointer transform -translate-x-1/2 -translate-y-1/2 rounded-full border-4 border-gray-700 transition-all duration-300 hover:scale-105 shadow-lg #{if @selected_chain == chain_name, do: "animate-pulse"}"}
            style={"left: #{x}; top: #{y}; width: #{radius * 2}px; height: #{radius * 2}px; background-color: #{chain_color(chain_name)};"}
            phx-click="select_chain"
            phx-value-chain={chain_name}
          >
            <div class="flex flex-col items-center justify-center h-full text-white">
              <div class="text-sm font-bold"><%= String.upcase(chain_name) %></div>
              <div class="text-xs"><%= length(chain_connections) %> connections</div>
            </div>
          </div>

          <!-- Provider nodes positioned around the chain node -->
          <%= for {connection, conn_index} <- Enum.with_index(chain_connections) do %>
            <% {provider_x, provider_y} = calculate_satellite_position(x, y, radius + 35, conn_index, length(chain_connections)) %>

            <div
              class={"absolute cursor-pointer transform -translate-x-1/2 -translate-y-1/2 w-6 h-6 rounded-full border-2 border-gray-700 transition-all duration-300 hover:scale-110 shadow-sm #{if @selected_provider == connection.id, do: "animate-bounce"}"}
              style={"left: #{provider_x}; top: #{provider_y}; background-color: #{provider_status_color(connection.status)};"}
              phx-click="select_provider"
              phx-value-provider={connection.id}
              title={connection.name}
            >
              <!-- Reconnect attempts indicator -->
              <%= if Map.get(connection, :reconnect_attempts, 0) > 0 do %>
                <div class="absolute -top-1 -right-1 w-3 h-3 bg-yellow-500 rounded-full flex items-center justify-center">
                  <span class="text-xs font-bold text-white" style="font-size: 8px;"><%= connection.reconnect_attempts %></span>
                </div>
              <% end %>
            </div>

            <!-- Provider label -->
            <div
              class="absolute text-xs text-gray-700 transform -translate-x-1/2 pointer-events-none"
              style={"left: #{provider_x}; top: calc(#{provider_y} + 20px); font-size: 10px;"}
            >
              <%= String.slice(connection.name, 0..8) %>
            </div>
          <% end %>
        <% end %>
      <% end %>

      <!-- Legend -->
      <div class="absolute bottom-6 right-6 bg-white/90 backdrop-blur-sm rounded-lg shadow-lg p-4 border border-gray-200">
        <h3 class="text-sm font-semibold text-gray-900 mb-2">Network Status</h3>
        <div class="space-y-1 text-xs">
          <div class="flex items-center space-x-2">
            <div class="w-3 h-3 bg-emerald-500 rounded-full"></div>
            <span>Connected</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="w-3 h-3 bg-yellow-500 rounded-full"></div>
            <span>Reconnecting</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="w-3 h-3 bg-red-500 rounded-full"></div>
            <span>Disconnected</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def connection_table(assigns) do
    ~H"""
    <div class="h-full w-full overflow-auto">
      <div class="p-6">
        <%= if length(@connections) == 0 do %>
          <div class="flex items-center justify-center h-96">
            <div class="text-center">
              <div class="text-6xl text-gray-400 mb-4">⚡</div>
              <h2 class="text-xl font-semibold text-gray-700 mb-2">No Active Connections</h2>
              <p class="text-gray-500">WebSocket connections will appear here when started</p>
              <button phx-click="test_connection" class="mt-4 px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-500 transition-all duration-200">
                Test Connection
              </button>
            </div>
          </div>
        <% else %>
          <div class="overflow-hidden bg-white shadow ring-1 ring-black ring-opacity-5 md:rounded-lg">
            <.table id="connections" rows={@connections} row_id={fn connection -> connection.id end}>
              <:col :let={connection} label="ID">
                <code class="text-sm font-mono text-gray-900"><%= connection.id %></code>
              </:col>
              <:col :let={connection} label="Name">
                <div class="flex items-center space-x-2">
                  <span><%= connection.name %></span>
                  <div class="flex-shrink-0 w-2 h-2 bg-emerald-400 rounded-full animate-pulse"
                       :if={connection.status == :connected}
                       title="Live connection">
                  </div>
                </div>
              </:col>
              <:col :let={connection} label="Chain">
                <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                  <%= extract_chain_from_connection_name(connection.name) %>
                </span>
              </:col>
              <:col :let={connection} label="Status">
                <.connection_status_badge status={connection.status} />
              </:col>
              <:col :let={connection} label="Reconnect Attempts">
                <span class="text-sm text-gray-500">
                  <%= Map.get(connection, :reconnect_attempts, "N/A") %>
                </span>
              </:col>
              <:col :let={connection} label="Subscriptions">
                <span class="text-sm text-gray-500">
                  <%= Map.get(connection, :subscriptions, "N/A") %>
                </span>
              </:col>
              <:col :let={connection} label="Last Seen">
                <span class="text-xs text-gray-400">
                  <%= if assigns[:current_time], do: format_last_seen(connection), else: "Just now" %>
                </span>
              </:col>
            </.table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def detail_panel(assigns) do
    ~H"""
    <div class="absolute right-0 top-0 h-full w-96 bg-white/95 backdrop-blur-sm shadow-xl border-l border-gray-200 z-10 transform transition-transform duration-300">
      <div class="p-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900">Details</h2>
          <button phx-click="close_detail" class="text-gray-400 hover:text-gray-600">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
            </svg>
          </button>
        </div>

        <%= if @selected_chain do %>
          <.chain_details chain={@selected_chain} connections={@connections} />
        <% end %>

        <%= if @selected_provider do %>
          <.provider_details provider_id={@selected_provider} connections={@connections} />
        <% end %>
      </div>
    </div>
    """
  end

  def chain_details(assigns) do
    chain_connections =
      Enum.filter(
        assigns.connections,
        &(extract_chain_from_connection_name(&1.name) == assigns.chain)
      )

    assigns = assign(assigns, :chain_connections, chain_connections)

    ~H"""
    <div class="space-y-4">
      <div>
        <h3 class="text-lg font-medium text-gray-900 capitalize"><%= @chain %> Chain</h3>
        <p class="text-sm text-gray-500">Detailed view of all providers</p>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900"><%= length(@chain_connections) %></div>
          <div class="text-sm text-gray-500">Total Providers</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-emerald-600">
            <%= Enum.count(@chain_connections, &(&1.status == :connected)) %>
          </div>
          <div class="text-sm text-gray-500">Connected</div>
        </div>
      </div>

      <div class="space-y-3">
        <h4 class="font-medium text-gray-900">Providers</h4>
        <%= for connection <- @chain_connections do %>
          <div class="border border-gray-200 rounded-lg p-3">
            <div class="flex items-center justify-between">
              <span class="font-medium text-gray-900"><%= connection.name %></span>
              <.connection_status_badge status={connection.status} />
            </div>
            <div class="mt-2 grid grid-cols-2 gap-2 text-sm text-gray-500">
              <div>Reconnects: <%= Map.get(connection, :reconnect_attempts, 0) %></div>
              <div>Subscriptions: <%= Map.get(connection, :subscriptions, 0) %></div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def provider_details(assigns) do
    connection = Enum.find(assigns.connections, &(&1.id == assigns.provider_id))
    assigns = assign(assigns, :connection, connection)

    ~H"""
    <%= if @connection do %>
      <div class="space-y-4">
        <div>
          <h3 class="text-lg font-medium text-gray-900"><%= @connection.name %></h3>
          <p class="text-sm text-gray-500">Provider details and statistics</p>
        </div>

        <div class="space-y-3">
          <div class="bg-gray-50 rounded-lg p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Status</span>
              <.connection_status_badge status={@connection.status} />
            </div>
          </div>

          <div class="bg-gray-50 rounded-lg p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Reconnect Attempts</span>
              <span class="text-sm text-gray-900"><%= Map.get(@connection, :reconnect_attempts, 0) %></span>
            </div>
          </div>

          <div class="bg-gray-50 rounded-lg p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Active Subscriptions</span>
              <span class="text-sm text-gray-900"><%= Map.get(@connection, :subscriptions, 0) %></span>
            </div>
          </div>

          <div class="bg-gray-50 rounded-lg p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Last Seen</span>
              <span class="text-sm text-gray-900"><%= format_last_seen(@connection) %></span>
            </div>
          </div>
        </div>
      </div>
    <% else %>
      <div class="text-center py-8">
        <p class="text-gray-500">Provider not found</p>
      </div>
    <% end %>
    """
  end

  # Color helper functions
  def chain_color("ethereum"), do: "#627EEA"
  def chain_color("polygon"), do: "#8247E5"
  def chain_color("arbitrum"), do: "#28A0F0"
  def chain_color("optimism"), do: "#FF0420"
  def chain_color("base"), do: "#0052FF"
  def chain_color("bsc"), do: "#F3BA2F"
  def chain_color("avalanche"), do: "#E84142"
  def chain_color("zksync"), do: "#4E529A"
  def chain_color("linea"), do: "#121212"
  def chain_color("scroll"), do: "#FFEEDA"
  def chain_color("mantle"), do: "#000000"
  def chain_color("blast"), do: "#FCFC03"
  def chain_color("mode"), do: "#DFFE00"
  def chain_color("fantom"), do: "#1969FF"
  def chain_color("celo"), do: "#35D07F"
  def chain_color(_), do: "#6B7280"

  def provider_status_color(:connected), do: "#10B981"
  def provider_status_color(:disconnected), do: "#EF4444"
  def provider_status_color(:connecting), do: "#F59E0B"
  def provider_status_color(_), do: "#6B7280"

  def connection_line_color(:connected), do: "#10B981"
  def connection_line_color(:disconnected), do: "#EF4444"
  def connection_line_color(:connecting), do: "#F59E0B"
  def connection_line_color(_), do: "#9CA3AF"

  def connection_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
      case @status do
        :connected -> "bg-emerald-100 text-emerald-800"
        :disconnected -> "bg-red-100 text-red-800"
        :connecting -> "bg-yellow-100 text-yellow-800"
        _ -> "bg-gray-100 text-gray-800"
      end
    ]}>
      <%= case @status do
        :connected -> "Connected"
        :disconnected -> "Disconnected"
        :connecting -> "Connecting"
        _ -> "Unknown"
      end %>
    </span>
    """
  end
end
