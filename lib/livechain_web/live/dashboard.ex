defmodule LivechainWeb.Dashboard do
  use LivechainWeb, :live_view

  alias Livechain.RPC.WSSupervisor
  import LivechainWeb.NetworkTopology

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :active_tab, "live_feed")

    if connected?(socket) do
      # Subscribe to WebSocket connection events for real-time updates
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")
    end

    initial_state =
      socket
      |> assign(:connections, [])
      |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
      |> assign(:selected_chain, nil)
      |> assign(:selected_provider, nil)

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
  def handle_info(:flush_connections, socket) do
    # Clear the pending connection update flag and trigger a render
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
              <!-- Glow effect -->
              <div class="absolute inset-0 rounded-2xl bg-gradient-to-r from-purple-600 to-purple-400 opacity-10 blur-xl">
              </div>
              <!-- Main logo container -->
              <div class="relative rounded-2xl ">
                <div class="flex items-center space-x-3">
                  <!-- Animated icon -->
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
                    <!-- Pulse animation -->
                    <div class="absolute inset-0 animate-ping rounded-lg bg-gradient-to-br from-purple-400 to-purple-600 opacity-20">
                    </div>
                  </div>
                  <div class="flex items-center space-x-2">
                    <h1 class="text-2xl font-bold text-white">
                      ChainPulse
                    </h1>

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
                %{id: "live_feed", label: "Live Feed", icon: "M13 10V3L4 14h7v7l9-11h-7z"},
                %{
                  id: "network",
                  label: "Live Network",
                  icon:
                    "M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"
                },
                %{
                  id: "simulator",
                  label: "Simulator",
                  icon:
                    "M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"
                }
              ]}
              active_tab={@active_tab}
            />
          </div>
        </div>
      </div>
      <!-- Content Section -->
      <div class="grid-pattern flex-1 overflow-hidden">
        <%= case @active_tab do %>
          <% "live_feed" -> %>
            <.live_feed_tab_content />
          <% "network" -> %>
            <.network_tab_content
              connections={@connections}
              selected_chain={@selected_chain}
              selected_provider={@selected_provider}
            />
          <% "simulator" -> %>
            <.simulator_tab_content />
        <% end %>
      </div>
    </div>
    """
  end

  def network_tab_content(assigns) do
    ~H"""
    <div class="h-full w-full">
      <.network_topology
        id="network-topology"
        connections={@connections}
        selected_chain={@selected_chain}
        selected_provider={@selected_provider}
        on_chain_select="select_chain"
        on_provider_select="select_provider"
        on_test_connection="test_connection"
      />
    </div>
    """
  end

  def simulator_tab_content(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col">
      <div class="flex flex-col">
        <h1 class="text-xl font-bold">Simulator</h1>
      </div>
    </div>
    """
  end

  def live_feed_tab_content(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col">
      <div class="flex flex-col"></div>
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
    # Manually trigger a status broadcast to test PubSub
    Livechain.RPC.WSSupervisor.broadcast_connection_status_update()
    {:noreply, socket}
  end

  # Helper functions

  defp fetch_connections(socket) do
    connections = Livechain.RPC.WSSupervisor.list_connections()

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
  end
end
