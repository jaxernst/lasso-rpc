defmodule LivechainWeb.OrchestrationLive do
  use LivechainWeb, :live_view

  alias Livechain.RPC.WSSupervisor

  @impl true
  def mount(_params, _session, socket) do
    IO.puts("🔌 LiveView mount - connected?: #{connected?(socket)}, PID: #{inspect(self())}")

    if connected?(socket) do
      # Subscribe to WebSocket connection events for real-time updates
      IO.puts("✅ LiveView subscribing to PubSub topic: ws_connections")
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")
      # Schedule periodic updates for timestamps
      Process.send_after(self(), :tick, 1000)
      IO.puts("✅ LiveView setup complete - should receive live updates now!")
    else
      IO.puts("📄 Static render - no live connection yet")
    end

    {:ok, fetch_connections(socket)}
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
  def handle_info({:connection_event, event_type, connection_id, _data}, socket) do
    # Refresh all connections when any connection event occurs
    IO.puts("LiveView received connection_event: #{event_type} for #{connection_id}")
    {:noreply, fetch_connections(socket)}
  end

  @impl true
  def handle_info({:connection_status_changed, connection_id, _connection_data}, socket) do
    # Refresh all connections when any connection status changes
    IO.puts("LiveView received connection_status_changed for #{connection_id}")
    {:noreply, fetch_connections(socket)}
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
    <div class="mx-auto max-w-6xl">
      <div class="sm:flex sm:items-center">
        <div class="sm:flex-auto">
          <div class="flex items-center space-x-3">
            <h1 class="text-base font-semibold leading-6 text-gray-900">WebSocket Connections</h1>
            <div class="flex items-center space-x-1">
              <div class="flex-shrink-0 w-2 h-2 bg-green-400 rounded-full animate-pulse"></div>
              <span class="text-xs font-medium text-green-600">LIVE</span>
            </div>
          </div>
          <p class="mt-2 text-sm text-gray-700">
            Real-time view of all active blockchain WebSocket connections. Updates automatically without refresh.
          </p>
        </div>
        <div class="mt-4 sm:ml-16 sm:mt-0 sm:flex-none">
          <div class="flex space-x-2">
            <button
              type="button"
              phx-click="refresh"
              class="block rounded-md bg-indigo-600 px-3 py-2 text-center text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
            >
              Refresh
            </button>
            <button
              type="button"
              phx-click="test_connection"
              class="block rounded-md bg-green-600 px-3 py-2 text-center text-sm font-semibold text-white shadow-sm hover:bg-green-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-green-600"
            >
              Test PubSub
            </button>
          </div>
        </div>
      </div>

      <div class="mt-8 flow-root">
        <div class="-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8">
          <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
            <div class="transition-all duration-300 ease-in-out">
              <.table id="connections" rows={@connections} row_id={fn connection -> connection.id end}>
                <:col :let={connection} label="ID">
                  <code class="text-sm font-mono text-gray-900"><%= connection.id %></code>
                </:col>
                <:col :let={connection} label="Name">
                  <div class="flex items-center space-x-2">
                    <span><%= connection.name %></span>
                    <div class="flex-shrink-0 w-2 h-2 bg-green-400 rounded-full animate-pulse"
                         :if={connection.status == :connected}
                         title="Live connection">
                    </div>
                  </div>
                </:col>
                <:col :let={connection} label="Status">
                  <.status_badge status={connection.status} />
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
          </div>
        </div>
      </div>

      <%= if @connections == [] do %>
        <div class="text-center py-12">
          <svg
            class="mx-auto h-12 w-12 text-gray-400"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9.172 16.172a4 4 0 015.656 0M9 12h6m-6 4h6m2 4H7a2 2 0 01-2-2V6a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V20a2 2 0 01-2 2z"
            />
          </svg>
          <h3 class="mt-2 text-sm font-semibold text-gray-900">No connections</h3>
          <p class="mt-1 text-sm text-gray-500">
            No WebSocket connections are currently active.
          </p>
        </div>
      <% end %>

      <div class="mt-8 flex justify-between text-sm text-gray-500">
        <div>
          <p>Total connections: <%= length(@connections) %></p>
          <p class="flex items-center space-x-1">
            <span>Updates:</span>
            <div class="flex-shrink-0 w-1.5 h-1.5 bg-green-400 rounded-full animate-pulse"></div>
            <span class="text-green-600 font-medium">Real-time</span>
          </p>
        </div>
        <div class="text-right">
          <p>Last updated: <%= @last_updated %></p>
          <p class="text-xs">No polling - pure event-driven updates</p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    IO.puts("Refreshing connections...")
    {:noreply, fetch_connections(socket)}
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    # Manually trigger a status broadcast to test PubSub
    IO.puts("Manually triggering connection status broadcast...")
    WSSupervisor.broadcast_connection_status_update()
    {:noreply, socket}
  end

  defp fetch_connections(socket) do
    connections = WSSupervisor.list_connections()

    IO.puts(
      "Fetched #{length(connections)} connections: #{inspect(Enum.map(connections, & &1.id))}"
    )

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
    |> assign(:current_time, DateTime.utc_now())
  end

  defp format_last_seen(connection) do
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
end
