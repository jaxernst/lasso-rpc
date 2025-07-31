defmodule LivechainWeb.TableLive do
  use LivechainWeb, :live_view

  alias Livechain.RPC.WSSupervisor

  # Use custom observatory layout without width constraints
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
      Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:polygon")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:arbitrum")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:bsc")

      # Schedule periodic updates for timestamps
      Process.send_after(self(), :tick, 1000)
    end

    initial_state =
      socket
      |> fetch_connections()
      |> assign(:live_events, [])
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
    # Refresh all connections when any connection event occurs
    {:noreply, fetch_connections(socket)}
  end

  @impl true
  def handle_info({:connection_status_changed, _connection_id, _connection_data}, socket) do
    # Refresh all connections when any connection status changes
    {:noreply, fetch_connections(socket)}
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

    {:noreply, assign(socket, :live_events, updated_events)}
  end

  @impl true
  def handle_info(:tick, socket) do
    # Update timestamps and schedule next tick
    Process.send_after(self(), :tick, 1000)
    socket = assign(socket, :current_time, DateTime.utc_now())
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen bg-gray-50 overflow-hidden flex flex-col">
      <!-- Navigation Header -->
      <div class="bg-white shadow-sm border-b border-gray-200 px-6 py-4 flex-shrink-0">
        <div class="flex items-center justify-between w-full">
          <div class="flex items-center space-x-4">
            <div class="flex items-center space-x-3">
              <h1 class="text-2xl font-bold text-gray-900">Connection Analytics</h1>
              <div class="flex items-center space-x-1">
                <div class="flex-shrink-0 w-3 h-3 bg-green-400 rounded-full animate-pulse"></div>
                <span class="text-sm font-medium text-green-600">LIVE</span>
              </div>
            </div>
          </div>

          <div class="flex items-center space-x-4">
            <!-- Connection stats -->
            <div class="text-sm text-gray-600">
              <span class="font-medium"><%= length(@connections) %></span> connections
              <span class="ml-2 font-medium text-green-600"><%= Enum.count(@connections, &(&1.status == :connected)) %></span> active
            </div>

            <!-- Navigation -->
            <div class="flex items-center space-x-1 bg-gray-100 rounded-lg p-1">
              <.link
                navigate={~p"/network"}
                class="px-3 py-1 text-sm font-medium rounded-md text-gray-500 hover:text-gray-900"
              >
                Network
              </.link>
              <.link
                navigate={~p"/table"}
                class="px-3 py-1 text-sm font-medium rounded-md bg-white text-gray-900 shadow-sm"
              >
                Table
              </.link>
            </div>

            <!-- Control buttons -->
            <div class="flex space-x-2">
              <button
                type="button"
                phx-click="refresh"
                class="px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-500 transition-colors"
              >
                Refresh
              </button>
              <button
                type="button"
                phx-click="test_connection"
                class="px-4 py-2 bg-green-600 text-white text-sm font-medium rounded-lg hover:bg-green-500 transition-colors"
              >
                Test
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Live Event Stream -->
      <div class="bg-gray-900 text-white flex-shrink-0">
        <div class="px-6 py-2">
          <div class="flex items-center justify-between mb-2">
            <h2 class="text-sm font-semibold text-gray-300">Live Message Stream</h2>
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

          <div class="overflow-hidden" style="height: 28px;">
            <%= if length(@live_events) > 0 do %>
              <div class="flex space-x-4 animate-marquee">
                <%= for event <- @live_events |> Enum.take(10) do %>
                  <div class="flex-shrink-0 bg-gray-800 rounded-lg px-3 py-1 text-xs whitespace-nowrap">
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
      </div>

      <!-- Table View -->
      <div class="flex-1 relative overflow-hidden">
        <.connection_table connections={@connections} current_time={@current_time} />
      </div>
    </div>
    """
  end

  # All the same event handlers as OrchestrationLive
  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_connections(socket)}
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

    updated_events = (test_events ++ socket.assigns.live_events) |> Enum.take(48)

    {:noreply, assign(socket, :live_events, updated_events)}
  end

  @impl true
  def handle_event("filter_events", %{"filter" => filter}, socket) do
    event_filter = String.to_atom(filter)
    {:noreply, assign(socket, :event_filter, event_filter)}
  end

  # Include all the same helper functions from OrchestrationLive
  defp fetch_connections(socket) do
    connections = Livechain.RPC.WSSupervisor.list_connections()

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
    |> assign(:current_time, DateTime.utc_now())
  end

  # Import helper functions from OrchestrationLive
  defdelegate extract_chain_from_provider(provider_id), to: LivechainWeb.OrchestrationLive
  defdelegate detect_message_type(message), to: LivechainWeb.OrchestrationLive
  defdelegate event_color(type), to: LivechainWeb.OrchestrationLive
  defdelegate format_event_message(event), to: LivechainWeb.OrchestrationLive
  defdelegate format_timestamp(timestamp), to: LivechainWeb.OrchestrationLive
  defdelegate extract_chain_from_connection_name(name), to: LivechainWeb.OrchestrationLive
  defdelegate connection_table(assigns), to: LivechainWeb.OrchestrationLive
  defdelegate connection_status_badge(assigns), to: LivechainWeb.OrchestrationLive
  defdelegate format_last_seen(connection), to: LivechainWeb.OrchestrationLive
end