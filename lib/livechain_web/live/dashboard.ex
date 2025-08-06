defmodule LivechainWeb.Dashboard do
  use LivechainWeb, :live_view

  alias Livechain.RPC.WSSupervisor

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :layout, {LivechainWeb.Layouts, "app"})

    if connected?(socket) do
      # Subscribe to WebSocket connection events for real-time updates
      Phoenix.PubSub.subscribe(Livechain.PubSub, "ws_connections")
    end

    initial_state =
      socket
      |> assign(:connections, [])
      |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())

    {:ok, initial_state}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="p-4">
        <div class="bg-indigo-500/10 w-fit rounded-lg px-3 py-2 text-white backdrop-blur-sm">
          <h1 class="text-xl font-bold">Chain Pulse Dashboard</h1>
        </div>
      </div>
    </div>
    """
  end
end
