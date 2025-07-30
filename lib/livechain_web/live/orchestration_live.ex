defmodule LivechainWeb.OrchestrationLive do
  use LivechainWeb, :live_view

  alias Livechain.RPC.WSSupervisor

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh connections every 2 seconds
      :timer.send_interval(2000, self(), :refresh_connections)
    end

    {:ok, fetch_connections(socket)}
  end

  @impl true
  def handle_info(:refresh_connections, socket) do
    {:noreply, fetch_connections(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl">
      <div class="sm:flex sm:items-center">
        <div class="sm:flex-auto">
          <h1 class="text-base font-semibold leading-6 text-gray-900">WebSocket Connections</h1>
          <p class="mt-2 text-sm text-gray-700">
            Live view of all active blockchain WebSocket connections managed by the WSSupervisor.
          </p>
        </div>
        <div class="mt-4 sm:ml-16 sm:mt-0 sm:flex-none">
          <button
            type="button"
            phx-click="refresh"
            class="block rounded-md bg-indigo-600 px-3 py-2 text-center text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
          >
            Refresh
          </button>
        </div>
      </div>

      <div class="mt-8 flow-root">
        <div class="-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8">
          <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
            <.table id="connections" rows={@connections}>
              <:col :let={connection} label="ID">
                <code class="text-sm font-mono text-gray-900"><%= connection.id %></code>
              </:col>
              <:col :let={connection} label="Name">
                <%= connection.name %>
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
            </.table>
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

      <div class="mt-8 text-sm text-gray-500">
        <p>Last updated: <%= @last_updated %></p>
        <p>Total connections: <%= length(@connections) %></p>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_connections(socket)}
  end

  defp fetch_connections(socket) do
    connections = WSSupervisor.list_connections()
    
    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end
end