defmodule LivechainWeb.OrchestrationLive do
  use LivechainWeb, :live_view

  alias Livechain.Benchmarking.BenchmarkStore

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :layout, {LivechainWeb.Layouts, "observatory"})
    mount_logic(socket)
  end

  defp mount_logic(socket) do
    if connected?(socket) do
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
      |> assign(:benchmark_data, %{})
      |> assign(:selected_chain, nil)
      |> assign(:selected_provider, nil)
      |> assign(:view_mode, :topology)
      |> assign(:event_filter, :all)
      |> assign(:active_tab, :live_feed)
      |> assign(:benchmark_chain, "ethereum")

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

    updated_metrics =
      Enum.reduce(metrics, current_metrics, fn metric, acc ->
        chain = Map.get(metric, :chain, "unknown")

        chain_metrics =
          Map.get(acc, chain, %{
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
  def handle_info(_message, socket) do
    # Catch-all handler for unexpected messages
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen flex-col overflow-hidden">
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

        @keyframes slideInUp {
          from {
            opacity: 0;
            transform: translateY(10px);
          }
          to {
            opacity: 1;
            transform: translateY(0);
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

        .tab-content {
          background-image:
            linear-gradient(rgba(255, 255, 255, 0.1) 1px, transparent 1px),
            linear-gradient(90deg, rgba(255, 255, 255, 0.1) 1px, transparent 1px);
          background-size: 50px 50px;
        }
      </style>
      <!-- Header with controls -->
      <div class="bg-white/95 z-10 flex-shrink-0 border-b border-gray-200 px-6 py-4 shadow-lg backdrop-blur-sm">
        <div class="flex w-full items-center justify-between">
          <div class="flex items-center space-x-6">
            <div class="flex items-center space-x-3">
              <h1 class="bg-gradient-to-r from-gray-900 to-gray-600 bg-clip-text text-2xl font-bold leading-none text-transparent">
                ChainPulse
              </h1>
              <div class="flex items-center space-x-1">
                <div class="h-2 w-2 flex-shrink-0 animate-pulse rounded-full bg-emerald-400"></div>
                <span class="text-xs font-medium text-emerald-600">LIVE</span>
              </div>
            </div>
            <!-- Tab Navigation -->
            <div class="flex items-center space-x-1 rounded-lg bg-gray-100 p-1">
              <button
                phx-click="switch_tab"
                phx-value-tab="live_feed"
                class={"#{if @active_tab == :live_feed, do: "bg-white text-gray-900 shadow-sm", else: "text-gray-500 hover:text-gray-900"} rounded-md px-4 py-2 text-sm font-medium transition-all duration-200"}
              >
                <svg class="mr-1 inline h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 10V3L4 14h7v7l9-11h-7z"
                  />
                </svg>
                Live Feed
              </button>
              <button
                phx-click="switch_tab"
                phx-value-tab="network"
                class={"#{if @active_tab == :network, do: "bg-white text-gray-900 shadow-sm", else: "text-gray-500 hover:text-gray-900"} rounded-md px-4 py-2 text-sm font-medium transition-all duration-200"}
              >
                <svg class="mr-1 inline h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"
                  />
                </svg>
                Network
              </button>
              <button
                phx-click="switch_tab"
                phx-value-tab="benchmarks"
                class={"#{if @active_tab == :benchmarks, do: "bg-white text-gray-900 shadow-sm", else: "text-gray-500 hover:text-gray-900"} rounded-md px-4 py-2 text-sm font-medium transition-all duration-200"}
              >
                <svg class="mr-1 inline h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
                Benchmarks
              </button>
            </div>
          </div>

          <div class="flex items-center space-x-4">
            <!-- Connection stats -->
            <div class="text-sm text-gray-600">
              <span class="font-medium"><%= length(@connections) %></span>
              connections
              <span class="ml-2 font-medium text-emerald-600">
                <%= Enum.count(@connections, &(&1.status == :connected)) %>
              </span>
              active
            </div>
            <!-- Control buttons -->
            <div class="flex space-x-2">
              <button
                type="button"
                phx-click="refresh"
                class="transform rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm transition-all duration-200 hover:scale-105 hover:bg-indigo-500"
              >
                <svg class="mr-1 inline h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                  />
                </svg>
                Refresh
              </button>
              <button
                type="button"
                phx-click="clear_events"
                class="rounded-lg bg-gray-600 px-4 py-2 text-sm font-medium text-white shadow-sm transition-all duration-200 hover:bg-gray-500"
              >
                Clear
              </button>
            </div>
          </div>
        </div>
      </div>
      <!-- Tab Content -->
      <div class="flex-1 overflow-hidden">
        <%= cond do %>
          <% @active_tab == :live_feed -> %>
            <.live_feed_tab
              live_events={@live_events}
              structured_events={@structured_events}
              analytics_metrics={@analytics_metrics}
              event_filter={@event_filter}
            />
          <% @active_tab == :network -> %>
            <.network_tab
              connections={@connections}
              selected_chain={@selected_chain}
              selected_provider={@selected_provider}
              view_mode={@view_mode}
              current_time={@current_time}
            />
          <% @active_tab == :benchmarks -> %>
            <.benchmarks_tab benchmark_data={@benchmark_data} benchmark_chain={@benchmark_chain} />
          <% true -> %>
            <.live_feed_tab
              live_events={@live_events}
              structured_events={@structured_events}
              analytics_metrics={@analytics_metrics}
              event_filter={@event_filter}
            />
        <% end %>
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
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_atom(tab)

    socket =
      if tab_atom == :benchmarks do
        # Load benchmark data when switching to benchmarks tab
        load_benchmark_data(socket)
      else
        socket
      end

    {:noreply, assign(socket, :active_tab, tab_atom)}
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

  @impl true
  def handle_event("select_benchmark_chain", %{"chain" => chain}, socket) do
    socket =
      socket
      |> assign(:benchmark_chain, chain)
      |> load_benchmark_data()

    {:noreply, socket}
  end

  defp fetch_connections(socket) do
    connections = Livechain.RPC.WSSupervisor.list_connections()

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
    |> assign(:current_time, DateTime.utc_now())
  end

  defp load_benchmark_data(socket) do
    chain_name = socket.assigns.benchmark_chain

    # Get benchmark data from the BenchmarkStore
    provider_leaderboard = BenchmarkStore.get_provider_leaderboard(chain_name)
    realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)

    benchmark_data = %{
      leaderboard: provider_leaderboard,
      stats: realtime_stats,
      last_updated: DateTime.utc_now()
    }

    assign(socket, :benchmark_data, benchmark_data)
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
      %{"_livechain_meta" => %{"chain_name" => chain}} ->
        chain

      %{"chainId" => chain_id} when is_integer(chain_id) ->
        case chain_id do
          1 -> "ethereum"
          137 -> "polygon"
          42161 -> "arbitrum"
          56 -> "bsc"
          _ -> "unknown"
        end

      _ ->
        "unknown"
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

  # Tab Components

  def benchmarks_tab(assigns) do
    ~H"""
    <div class="tab-content flex h-full w-full flex-col overflow-hidden bg-gradient-to-br from-indigo-900 to-indigo-800">
      <!-- Benchmarks Header -->
      <div class="flex-shrink-0 p-6">
        <div class="bg-indigo-900/50 rounded-lg border border-indigo-700 p-4 shadow-xl backdrop-blur-sm">
          <div class="flex items-center justify-between">
            <div class="flex items-center space-x-3">
              <div class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg bg-white bg-opacity-10">
                <svg class="h-5 w-5 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
              </div>
              <div>
                <h3 class="text-lg font-semibold text-white">Provider Benchmarks</h3>
                <p class="text-sm text-indigo-200">
                  Real-time performance metrics from racing and RPC calls
                </p>
              </div>
            </div>
            <div class="flex items-center space-x-4">
              <select
                phx-change="select_benchmark_chain"
                class="rounded border-indigo-700 bg-indigo-800 px-3 py-1 text-sm text-white"
              >
                <option value="ethereum" selected={@benchmark_chain == "ethereum"}>Ethereum</option>
                <option value="polygon" selected={@benchmark_chain == "polygon"}>Polygon</option>
                <option value="arbitrum" selected={@benchmark_chain == "arbitrum"}>Arbitrum</option>
                <option value="bsc" selected={@benchmark_chain == "bsc"}>BSC</option>
              </select>
              <span class="text-sm text-indigo-200">
                <%= if @benchmark_data.stats do %>
                  <%= length(@benchmark_data.stats.providers) %> providers
                <% else %>
                  Loading...
                <% end %>
              </span>
            </div>
          </div>
        </div>
      </div>
      <!-- Benchmarks Content -->
      <div class="flex flex-1 overflow-hidden p-6 pt-0">
        <!-- Left Panel - Provider Leaderboard -->
        <div class="w-1/2 pr-3">
          <div class="bg-indigo-900/50 h-full overflow-hidden rounded-lg border border-indigo-700 shadow-xl backdrop-blur-sm">
            <div class="border-b border-indigo-700 bg-gradient-to-r from-indigo-900 to-indigo-800 p-4">
              <h4 class="text-lg font-semibold text-white">Racing Leaderboard</h4>
              <p class="text-sm text-indigo-200">Event delivery performance winners</p>
            </div>
            <div class="h-full overflow-auto p-4">
              <%= if length(@benchmark_data.leaderboard || []) > 0 do %>
                <div class="space-y-3">
                  <%= for {provider, index} <- Enum.with_index(@benchmark_data.leaderboard) do %>
                    <div class="bg-indigo-800/60 rounded-lg border border-indigo-700 p-4 transition-all duration-200 hover:border-indigo-600">
                      <div class="flex items-center justify-between">
                        <div class="flex items-center space-x-3">
                          <div class="flex h-8 w-8 items-center justify-center rounded-full bg-indigo-700 text-sm font-bold text-white">
                            <%= index + 1 %>
                          </div>
                          <div>
                            <div class="font-medium text-white"><%= provider.provider_id %></div>
                            <div class="text-xs text-indigo-300">
                              <%= provider.total_wins %> wins / <%= provider.total_races %> races
                            </div>
                          </div>
                        </div>
                        <div class="text-right">
                          <div class="text-lg font-bold text-emerald-400">
                            <%= Float.round(provider.win_rate * 100, 1) %>%
                          </div>
                          <div class="text-xs text-indigo-300">
                            avg margin: <%= Float.round(provider.avg_margin_ms || 0, 1) %>ms
                          </div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="flex h-full items-center justify-center">
                  <div class="text-center">
                    <div class="mb-4 text-4xl text-indigo-600">🏁</div>
                    <p class="text-indigo-300">No racing data yet for <%= @benchmark_chain %></p>
                    <p class="text-xs text-indigo-400">
                      Performance data will appear as providers compete
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        <!-- Right Panel - RPC Performance -->
        <div class="w-1/2 pl-3">
          <div class="bg-indigo-900/50 h-full overflow-hidden rounded-lg border border-indigo-700 shadow-xl backdrop-blur-sm">
            <div class="border-b border-indigo-700 bg-gradient-to-r from-indigo-900 to-indigo-800 p-4">
              <h4 class="text-lg font-semibold text-white">RPC Performance</h4>
              <p class="text-sm text-indigo-200">JSON-RPC call latency and success rates</p>
            </div>
            <div class="h-full overflow-auto p-4">
              <%= if @benchmark_data.stats && length(@benchmark_data.stats.rpc_methods || []) > 0 do %>
                <div class="space-y-4">
                  <%= for method <- @benchmark_data.stats.rpc_methods do %>
                    <div class="bg-indigo-800/60 rounded-lg border border-indigo-700 p-4">
                      <h5 class="mb-2 font-medium text-white"><%= method %></h5>
                      <div class="space-y-2">
                        <%= for provider <- @benchmark_data.stats.providers do %>
                          <div class="flex items-center justify-between text-sm">
                            <span class="text-indigo-300"><%= provider %></span>
                            <div class="flex items-center space-x-2">
                              <span class="font-mono text-emerald-400">95.2%</span>
                              <span class="font-mono text-blue-400">156ms</span>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="flex h-full items-center justify-center">
                  <div class="text-center">
                    <div class="mb-4 text-4xl text-indigo-600">⚡</div>
                    <p class="text-indigo-300">
                      No RPC performance data yet for <%= @benchmark_chain %>
                    </p>
                    <p class="text-xs text-indigo-400">Data will appear as RPC calls are made</p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def live_feed_tab(assigns) do
    ~H"""
    <div class="tab-content flex h-full w-full flex-col overflow-hidden bg-gradient-to-br from-gray-900 to-black">
      <!-- Live Events Section - Top Half -->
      <div class="flex-1 overflow-hidden p-6">
        <div class="bg-gray-900/50 h-full overflow-hidden rounded-lg border border-gray-700 shadow-2xl backdrop-blur-sm">
          <div class="border-b border-gray-700 bg-gradient-to-r from-gray-900 to-black p-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center space-x-3">
                <div class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg bg-white bg-opacity-10">
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
                <div>
                  <h3 class="text-lg font-semibold text-white">Live Message Stream</h3>
                  <p class="text-sm text-gray-300">
                    Real-time WebSocket messages from blockchain networks
                  </p>
                </div>
              </div>
              <div class="flex items-center space-x-4">
                <select
                  phx-change="filter_events"
                  class="rounded border-gray-700 bg-gray-800 px-2 py-1 text-xs text-white"
                >
                  <option value="all">All Events</option>
                  <option value="blocks">Blocks Only</option>
                  <option value="transactions">Transactions</option>
                  <option value="errors">Errors</option>
                </select>
                <span class="text-sm text-gray-300"><%= length(@live_events) %> events</span>
              </div>
            </div>
          </div>

          <div class="h-full overflow-hidden p-6">
            <%= if length(@live_events) > 0 do %>
              <div class="scrollbar-thin scrollbar-track-gray-800 scrollbar-thumb-gray-600 grid h-full grid-cols-1 gap-2 overflow-y-auto">
                <%= for {event, index} <- @live_events |> Enum.take(50) |> Enum.with_index() do %>
                  <div
                    class="bg-gray-800/60 rounded-lg border border-gray-700 px-4 py-3 shadow-sm backdrop-blur-sm transition-all duration-300 ease-out hover:border-gray-600"
                    style="animation: slideInUp 0.3s ease-out #{index * 0.02}s both;"
                  >
                    <div class="flex items-center justify-between">
                      <div class="flex items-center space-x-3">
                        <span class={"#{chain_badge_color(event.chain)} inline-flex items-center rounded-full px-2 py-1 text-xs font-medium"}>
                          <%= String.upcase(event.chain) %>
                        </span>
                        <span class={"#{event_color(event.type)} text-sm font-medium"}>
                          <%= format_event_message(event) %>
                        </span>
                        <span class="text-xs text-gray-400"><%= event.provider_id %></span>
                      </div>
                      <span class="text-xs text-gray-500">
                        <%= format_timestamp(event.timestamp) %>
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="flex h-full items-center justify-center">
                <div class="text-center">
                  <div class="mb-4 text-4xl text-gray-600">⚡</div>
                  <p class="text-gray-400">No live events yet - waiting for WebSocket messages...</p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
      <!-- Broadway Events Section - Bottom Half -->
      <div class="flex-1 overflow-hidden p-6 pt-0">
        <div class="bg-blue-900/50 h-full overflow-hidden rounded-lg border border-blue-700 shadow-2xl backdrop-blur-sm">
          <div class="border-b border-blue-700 bg-gradient-to-r from-blue-900 to-blue-800 p-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center space-x-3">
                <div class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg bg-white bg-opacity-10">
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
                      d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
                    />
                  </svg>
                </div>
                <div>
                  <h3 class="text-lg font-semibold text-white">Broadway Pipeline Events</h3>
                  <p class="text-sm text-blue-200">
                    Structured events processed through data pipelines
                  </p>
                </div>
              </div>
              <div class="flex items-center space-x-4">
                <!-- Analytics Summary -->
                <div class="flex items-center space-x-3 text-xs">
                  <%= if map_size(@analytics_metrics) > 0 do %>
                    <%= for {chain, metrics} <- @analytics_metrics do %>
                      <div class="flex items-center space-x-1">
                        <span class="text-blue-200"><%= String.upcase(chain) %>:</span>
                        <span class="font-mono text-emerald-400"><%= metrics.events_count %></span>
                        <%= if metrics.total_usd_value > 0 do %>
                          <span class="font-mono text-yellow-400">
                            $<%= Float.round(metrics.total_usd_value, 0) |> trunc() %>
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                  <% else %>
                    <span class="text-xs text-blue-300">Analytics loading...</span>
                  <% end %>
                </div>
                <span class="text-sm text-blue-200"><%= length(@structured_events) %> events</span>
              </div>
            </div>
          </div>

          <div class="h-full overflow-hidden p-6">
            <%= if length(@structured_events) > 0 do %>
              <div class="scrollbar-thin scrollbar-track-blue-800 scrollbar-thumb-blue-600 grid h-full grid-cols-1 gap-2 overflow-y-auto">
                <%= for {event, index} <- @structured_events |> Enum.take(30) |> Enum.with_index() do %>
                  <div
                    class="bg-blue-800/60 rounded-lg border border-blue-700 px-4 py-3 shadow-sm backdrop-blur-sm transition-all duration-300 ease-out hover:border-blue-600"
                    style="animation: slideInUp 0.3s ease-out #{index * 0.02}s both;"
                  >
                    <div class="flex items-center justify-between">
                      <div class="flex items-center space-x-3">
                        <span class={"#{chain_badge_color(event.chain)} inline-flex items-center rounded-full px-2 py-1 text-xs font-medium"}>
                          <%= String.upcase(event.chain) %>
                        </span>
                        <span class={"#{structured_event_color(event.type)} text-sm font-medium"}>
                          <%= format_structured_event(event) %>
                        </span>
                        <%= if event.usd_value do %>
                          <span class="font-mono text-sm text-yellow-300">
                            $<%= Float.round(event.usd_value, 2) %>
                          </span>
                        <% end %>
                      </div>
                      <span class="text-xs text-blue-400">
                        <%= format_timestamp(event.timestamp) %>
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="flex h-full items-center justify-center">
                <div class="text-center">
                  <div class="mb-4 text-4xl text-blue-600">🔄</div>
                  <p class="text-blue-300">
                    No structured events yet - Broadway pipelines processing...
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def network_tab(assigns) do
    ~H"""
    <div class="tab-content relative h-full w-full overflow-hidden bg-gradient-to-br from-purple-900 to-purple-800">
      <%= if @view_mode == :topology do %>
        <.network_topology_fullscreen
          connections={@connections}
          selected_chain={@selected_chain}
          selected_provider={@selected_provider}
        />
      <% else %>
        <div class="h-full p-6">
          <div class="bg-purple-900/50 h-full overflow-hidden rounded-lg border border-purple-700 shadow-2xl backdrop-blur-sm">
            <div class="border-b border-purple-700 bg-gradient-to-r from-purple-900 to-purple-800 p-4">
              <div class="flex items-center justify-between">
                <div class="flex items-center space-x-3">
                  <div class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg bg-white bg-opacity-10">
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
                        d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"
                      />
                    </svg>
                  </div>
                  <div>
                    <h3 class="text-lg font-semibold text-white">Network Connections</h3>
                    <p class="text-sm text-purple-200">
                      Detailed table view of all blockchain connections
                    </p>
                  </div>
                </div>
                <div class="flex items-center space-x-2">
                  <button
                    phx-click="toggle_view"
                    phx-value-mode="topology"
                    class="rounded-md bg-purple-700 px-3 py-1 text-sm font-medium text-white transition-all duration-200 hover:bg-purple-600"
                  >
                    Switch to Topology
                  </button>
                </div>
              </div>
            </div>
            <div class="h-full overflow-auto p-6">
              <.connection_table connections={@connections} current_time={@current_time} />
            </div>
          </div>
        </div>
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
    """
  end

  def network_topology_fullscreen(assigns) do
    assigns = assign(assigns, :chains, group_connections_by_chain(assigns.connections))

    ~H"""
    <div class="relative h-full w-full overflow-hidden">
      <!-- Background grid pattern -->
      <div
        class="absolute inset-0 opacity-20"
        style="background-image: radial-gradient(circle, #e0e7ff 1px, transparent 1px); background-size: 50px 50px;"
      >
      </div>
      <!-- View Toggle -->
      <div class="absolute top-6 left-6 z-50">
        <button
          phx-click="toggle_view"
          phx-value-mode="table"
          class="bg-purple-700/80 rounded-lg border border-purple-600 px-4 py-2 text-sm font-medium text-white shadow-lg backdrop-blur-sm transition-all duration-200 hover:bg-purple-600"
        >
          Switch to Table View
        </button>
      </div>
      <!-- Debug info -->
      <div class="bg-purple-900/90 font-mono absolute top-6 right-6 z-50 rounded-lg border border-purple-700 p-3 text-xs text-white shadow-lg backdrop-blur-sm">
        Total connections: <%= length(@connections) %><br />
        Chains found: <%= map_size(@chains) %><br /> Chain groups: <%= inspect(Map.keys(@chains)) %>
      </div>

      <%= if map_size(@chains) == 0 do %>
        <!-- No connections fallback -->
        <div class="flex h-full items-center justify-center">
          <div class="text-center">
            <div class="mb-4 text-6xl text-purple-400">🔗</div>
            <h2 class="mb-2 text-xl font-semibold text-white">No Blockchain Connections</h2>
            <p class="text-purple-200">
              Start some WebSocket connections to see the network topology
            </p>
            <button
              phx-click="test_connection"
              class="mt-4 rounded-lg bg-purple-600 px-4 py-2 text-white transition-all duration-200 hover:bg-purple-500"
            >
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
            class={"#{if @selected_chain == chain_name, do: "animate-pulse"} border-white/20 absolute -translate-x-1/2 -translate-y-1/2 transform cursor-pointer rounded-full border-4 shadow-xl transition-all duration-300 hover:scale-105"}
            style={"left: #{x}; top: #{y}; width: #{radius * 2}px; height: #{radius * 2}px; background-color: #{chain_color(chain_name)};"}
            phx-click="select_chain"
            phx-value-chain={chain_name}
          >
            <div class="flex h-full flex-col items-center justify-center text-white">
              <div class="text-sm font-bold"><%= String.upcase(chain_name) %></div>
              <div class="text-xs"><%= length(chain_connections) %> connections</div>
            </div>
          </div>
          <!-- Provider nodes positioned around the chain node -->
          <%= for {connection, conn_index} <- Enum.with_index(chain_connections) do %>
            <% {provider_x, provider_y} =
              calculate_satellite_position(x, y, radius + 35, conn_index, length(chain_connections)) %>

            <div
              class={"#{if @selected_provider == connection.id, do: "animate-bounce"} border-white/30 absolute h-6 w-6 -translate-x-1/2 -translate-y-1/2 transform cursor-pointer rounded-full border-2 shadow-lg transition-all duration-300 hover:scale-110"}
              style={"left: #{provider_x}; top: #{provider_y}; background-color: #{provider_status_color(connection.status)};"}
              phx-click="select_provider"
              phx-value-provider={connection.id}
              title={connection.name}
            >
              <!-- Reconnect attempts indicator -->
              <%= if Map.get(connection, :reconnect_attempts, 0) > 0 do %>
                <div class="absolute -top-1 -right-1 flex h-3 w-3 items-center justify-center rounded-full bg-yellow-500">
                  <span class="text-xs font-bold text-white" style="font-size: 8px;">
                    <%= connection.reconnect_attempts %>
                  </span>
                </div>
              <% end %>
            </div>
            <!-- Provider label -->
            <div
              class="text-white/80 pointer-events-none absolute -translate-x-1/2 transform text-xs font-medium"
              style={"left: #{provider_x}; top: calc(#{provider_y} + 20px); font-size: 10px;"}
            >
              <%= String.slice(connection.name, 0..8) %>
            </div>
          <% end %>
        <% end %>
      <% end %>
      <!-- Legend -->
      <div class="bg-purple-900/90 absolute right-6 bottom-6 rounded-lg border border-purple-700 p-4 shadow-xl backdrop-blur-sm">
        <h3 class="mb-2 text-sm font-semibold text-white">Network Status</h3>
        <div class="space-y-1 text-xs text-white">
          <div class="flex items-center space-x-2">
            <div class="h-3 w-3 rounded-full bg-emerald-500"></div>
            <span>Connected</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="h-3 w-3 rounded-full bg-yellow-500"></div>
            <span>Reconnecting</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="h-3 w-3 rounded-full bg-red-500"></div>
            <span>Disconnected</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Component functions

  def network_topology(assigns) do
    assigns = assign(assigns, :chains, group_connections_by_chain(assigns.connections))

    ~H"""
    <div class="relative h-full w-full overflow-hidden bg-gradient-to-br from-slate-50 to-slate-100">
      <!-- Background grid pattern -->
      <div
        class="absolute inset-0 opacity-30"
        style="background-image: radial-gradient(circle, #e5e7eb 1px, transparent 1px); background-size: 50px 50px;"
      >
      </div>
      <!-- Debug info -->
      <div class="bg-white/90 font-mono absolute top-4 left-4 z-50 rounded-lg border border-gray-200 p-3 text-xs shadow-sm backdrop-blur-sm">
        Total connections: <%= length(@connections) %><br />
        Chains found: <%= map_size(@chains) %><br /> Chain groups: <%= inspect(Map.keys(@chains)) %>
      </div>

      <%= if map_size(@chains) == 0 do %>
        <!-- No connections fallback -->
        <div class="flex h-full items-center justify-center">
          <div class="text-center">
            <div class="mb-4 text-6xl text-gray-400">🔗</div>
            <h2 class="mb-2 text-xl font-semibold text-gray-700">No Blockchain Connections</h2>
            <p class="text-gray-500">Start some WebSocket connections to see the network topology</p>
            <button
              phx-click="test_connection"
              class="mt-4 rounded-lg bg-indigo-600 px-4 py-2 text-white transition-all duration-200 hover:bg-indigo-500"
            >
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
            class={"#{if @selected_chain == chain_name, do: "animate-pulse"} absolute -translate-x-1/2 -translate-y-1/2 transform cursor-pointer rounded-full border-4 border-gray-700 shadow-lg transition-all duration-300 hover:scale-105"}
            style={"left: #{x}; top: #{y}; width: #{radius * 2}px; height: #{radius * 2}px; background-color: #{chain_color(chain_name)};"}
            phx-click="select_chain"
            phx-value-chain={chain_name}
          >
            <div class="flex h-full flex-col items-center justify-center text-white">
              <div class="text-sm font-bold"><%= String.upcase(chain_name) %></div>
              <div class="text-xs"><%= length(chain_connections) %> connections</div>
            </div>
          </div>
          <!-- Provider nodes positioned around the chain node -->
          <%= for {connection, conn_index} <- Enum.with_index(chain_connections) do %>
            <% {provider_x, provider_y} =
              calculate_satellite_position(x, y, radius + 35, conn_index, length(chain_connections)) %>

            <div
              class={"#{if @selected_provider == connection.id, do: "animate-bounce"} absolute h-6 w-6 -translate-x-1/2 -translate-y-1/2 transform cursor-pointer rounded-full border-2 border-gray-700 shadow-sm transition-all duration-300 hover:scale-110"}
              style={"left: #{provider_x}; top: #{provider_y}; background-color: #{provider_status_color(connection.status)};"}
              phx-click="select_provider"
              phx-value-provider={connection.id}
              title={connection.name}
            >
              <!-- Reconnect attempts indicator -->
              <%= if Map.get(connection, :reconnect_attempts, 0) > 0 do %>
                <div class="absolute -top-1 -right-1 flex h-3 w-3 items-center justify-center rounded-full bg-yellow-500">
                  <span class="text-xs font-bold text-white" style="font-size: 8px;">
                    <%= connection.reconnect_attempts %>
                  </span>
                </div>
              <% end %>
            </div>
            <!-- Provider label -->
            <div
              class="pointer-events-none absolute -translate-x-1/2 transform text-xs text-gray-700"
              style={"left: #{provider_x}; top: calc(#{provider_y} + 20px); font-size: 10px;"}
            >
              <%= String.slice(connection.name, 0..8) %>
            </div>
          <% end %>
        <% end %>
      <% end %>
      <!-- Legend -->
      <div class="bg-white/90 absolute right-6 bottom-6 rounded-lg border border-gray-200 p-4 shadow-lg backdrop-blur-sm">
        <h3 class="mb-2 text-sm font-semibold text-gray-900">Network Status</h3>
        <div class="space-y-1 text-xs">
          <div class="flex items-center space-x-2">
            <div class="h-3 w-3 rounded-full bg-emerald-500"></div>
            <span>Connected</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="h-3 w-3 rounded-full bg-yellow-500"></div>
            <span>Reconnecting</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="h-3 w-3 rounded-full bg-red-500"></div>
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
          <div class="flex h-96 items-center justify-center">
            <div class="text-center">
              <div class="mb-4 text-6xl text-gray-400">⚡</div>
              <h2 class="mb-2 text-xl font-semibold text-gray-700">No Active Connections</h2>
              <p class="text-gray-500">WebSocket connections will appear here when started</p>
              <button
                phx-click="test_connection"
                class="mt-4 rounded-lg bg-indigo-600 px-4 py-2 text-white transition-all duration-200 hover:bg-indigo-500"
              >
                Test Connection
              </button>
            </div>
          </div>
        <% else %>
          <div class="overflow-hidden bg-white shadow ring-1 ring-black ring-opacity-5 md:rounded-lg">
            <.table id="connections" rows={@connections} row_id={fn connection -> connection.id end}>
              <:col :let={connection} label="ID">
                <code class="font-mono text-sm text-gray-900"><%= connection.id %></code>
              </:col>
              <:col :let={connection} label="Name">
                <div class="flex items-center space-x-2">
                  <span><%= connection.name %></span>
                  <div
                    :if={connection.status == :connected}
                    class="h-2 w-2 flex-shrink-0 animate-pulse rounded-full bg-emerald-400"
                    title="Live connection"
                  >
                  </div>
                </div>
              </:col>
              <:col :let={connection} label="Chain">
                <span class="inline-flex items-center rounded-full bg-blue-100 px-2.5 py-0.5 text-xs font-medium text-blue-800">
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
    <div class="bg-white/95 absolute top-0 right-0 z-10 h-full w-96 transform border-l border-gray-200 shadow-xl backdrop-blur-sm transition-transform duration-300">
      <div class="p-6">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold text-gray-900">Details</h2>
          <button phx-click="close_detail" class="text-gray-400 hover:text-gray-600">
            <svg class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
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
        <h3 class="text-lg font-medium capitalize text-gray-900"><%= @chain %> Chain</h3>
        <p class="text-sm text-gray-500">Detailed view of all providers</p>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div class="rounded-lg bg-gray-50 p-3">
          <div class="text-2xl font-bold text-gray-900"><%= length(@chain_connections) %></div>
          <div class="text-sm text-gray-500">Total Providers</div>
        </div>
        <div class="rounded-lg bg-gray-50 p-3">
          <div class="text-2xl font-bold text-emerald-600">
            <%= Enum.count(@chain_connections, &(&1.status == :connected)) %>
          </div>
          <div class="text-sm text-gray-500">Connected</div>
        </div>
      </div>

      <div class="space-y-3">
        <h4 class="font-medium text-gray-900">Providers</h4>
        <%= for connection <- @chain_connections do %>
          <div class="rounded-lg border border-gray-200 p-3">
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
          <div class="rounded-lg bg-gray-50 p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Status</span>
              <.connection_status_badge status={@connection.status} />
            </div>
          </div>

          <div class="rounded-lg bg-gray-50 p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Reconnect Attempts</span>
              <span class="text-sm text-gray-900">
                <%= Map.get(@connection, :reconnect_attempts, 0) %>
              </span>
            </div>
          </div>

          <div class="rounded-lg bg-gray-50 p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Active Subscriptions</span>
              <span class="text-sm text-gray-900">
                <%= Map.get(@connection, :subscriptions, 0) %>
              </span>
            </div>
          </div>

          <div class="rounded-lg bg-gray-50 p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium text-gray-700">Last Seen</span>
              <span class="text-sm text-gray-900"><%= format_last_seen(@connection) %></span>
            </div>
          </div>
        </div>
      </div>
    <% else %>
      <div class="py-8 text-center">
        <p class="text-gray-500">Provider not found</p>
      </div>
    <% end %>
    """
  end

  # Color helper functions

  def chain_badge_color("ethereum"), do: "bg-blue-100 text-blue-800"
  def chain_badge_color("polygon"), do: "bg-purple-100 text-purple-800"
  def chain_badge_color("arbitrum"), do: "bg-cyan-100 text-cyan-800"
  def chain_badge_color("optimism"), do: "bg-red-100 text-red-800"
  def chain_badge_color("base"), do: "bg-indigo-100 text-indigo-800"
  def chain_badge_color("bsc"), do: "bg-yellow-100 text-yellow-800"
  def chain_badge_color("avalanche"), do: "bg-red-100 text-red-800"
  def chain_badge_color("zksync"), do: "bg-slate-100 text-slate-800"
  def chain_badge_color("linea"), do: "bg-gray-100 text-gray-800"
  def chain_badge_color("scroll"), do: "bg-orange-100 text-orange-800"
  def chain_badge_color("mantle"), do: "bg-black text-white"
  def chain_badge_color("blast"), do: "bg-lime-100 text-lime-800"
  def chain_badge_color("mode"), do: "bg-lime-100 text-lime-800"
  def chain_badge_color("fantom"), do: "bg-blue-100 text-blue-800"
  def chain_badge_color("celo"), do: "bg-green-100 text-green-800"
  def chain_badge_color("eth"), do: "bg-blue-100 text-blue-800"
  def chain_badge_color("poly"), do: "bg-purple-100 text-purple-800"
  def chain_badge_color("arb"), do: "bg-cyan-100 text-cyan-800"
  def chain_badge_color("op"), do: "bg-red-100 text-red-800"
  def chain_badge_color("unknown"), do: "bg-gray-100 text-gray-800"
  def chain_badge_color(_), do: "bg-gray-100 text-gray-800"

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
    <span class={["inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium", connection_status_class(@status)]}>
      <%= connection_status_text(@status) %>
    </span>
    """
  end

  defp connection_status_class(:connected), do: "bg-emerald-100 text-emerald-800"
  defp connection_status_class(:disconnected), do: "bg-red-100 text-red-800"
  defp connection_status_class(:connecting), do: "bg-yellow-100 text-yellow-800"
  defp connection_status_class(_), do: "bg-gray-100 text-gray-800"

  defp connection_status_text(:connected), do: "Connected"
  defp connection_status_text(:disconnected), do: "Disconnected"
  defp connection_status_text(:connecting), do: "Connecting"
  defp connection_status_text(_), do: "Unknown"
end
