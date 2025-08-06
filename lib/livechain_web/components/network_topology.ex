defmodule LivechainWeb.NetworkTopology do
  @moduledoc """
  Network topology visualization component for displaying blockchain connections
  in an interactive spiral grid layout.
  """

  use Phoenix.Component

  @doc """
  Renders a network topology visualization component.

  ## Examples

      <.network_topology
        id="network-topology"
        connections={@connections}
        selected_chain={@selected_chain}
        selected_provider={@selected_provider}
        on_chain_select="select_chain"
        on_provider_select="select_provider"
        on_test_connection="test_connection"
      />
  """
  attr(:id, :string, required: true, doc: "unique identifier for the topology component")
  attr(:connections, :list, required: true, doc: "list of connection maps")
  attr(:selected_chain, :string, default: nil, doc: "currently selected chain")
  attr(:selected_provider, :string, default: nil, doc: "currently selected provider")
  attr(:on_chain_select, :string, default: "select_chain", doc: "event name for chain selection")

  attr(:on_provider_select, :string,
    default: "select_provider",
    doc: "event name for provider selection"
  )

  attr(:on_test_connection, :string,
    default: "test_connection",
    doc: "event name for test connection"
  )

  attr(:class, :string, default: "", doc: "additional CSS classes")

  def network_topology(assigns) do
    assigns = assign(assigns, :chains, group_connections_by_chain(assigns.connections))

    ~H"""
    <div class={["relative h-full w-full overflow-hidden", @class]}>
      <!-- Debug info
      # <div class="bg-purple-900/90 font-mono border-purple-500/30 absolute top-4 left-4 z-50 rounded-lg border p-3 text-xs text-white shadow-lg backdrop-blur-sm">
      #   Total connections: <%= length(@connections) %><br />
      #   Chains found: <%= map_size(@chains) %><br /> Chain groups: <%= inspect(Map.keys(@chains)) %>
      # </div>
      -->
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
              phx-click={@on_test_connection}
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
            phx-click={@on_chain_select}
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
              phx-click={@on_provider_select}
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

  # Helper functions for network topology

  defp group_connections_by_chain(connections) do
    connections
    |> Enum.group_by(&extract_chain_from_connection_name(&1.name))
  end

  defp extract_chain_from_connection_name(name) do
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

  defp calculate_spiral_position(index, _center_x, _center_y) do
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

  defp calculate_ring(index) when index <= 0, do: 0

  defp calculate_ring(index) do
    # Each ring can hold more nodes: ring 1 = 6, ring 2 = 12, ring 3 = 18, etc.
    total = 0
    ring = 1

    calculate_ring_recursive(index, total, ring)
  end

  defp calculate_ring_recursive(index, total, ring) do
    ring_capacity = ring * 6

    if index <= total + ring_capacity do
      ring
    else
      calculate_ring_recursive(index, total + ring_capacity, ring + 1)
    end
  end

  defp ring_start_index(ring) when ring <= 1, do: 1

  defp ring_start_index(ring) do
    # Sum of positions in all previous rings
    Enum.sum(1..(ring - 1) |> Enum.map(&(&1 * 6))) + 1
  end

  defp positions_per_ring(ring) when ring <= 0, do: 1
  defp positions_per_ring(ring), do: ring * 6

  defp calculate_satellite_position(center_x, center_y, distance, index, total_satellites) do
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

  defp chain_color("ethereum"), do: "#627EEA"
  defp chain_color("polygon"), do: "#8247E5"
  defp chain_color("arbitrum"), do: "#28A0F0"
  defp chain_color("optimism"), do: "#FF0420"
  defp chain_color("base"), do: "#0052FF"
  defp chain_color("bsc"), do: "#F3BA2F"
  defp chain_color("avalanche"), do: "#E84142"
  defp chain_color("zksync"), do: "#4E529A"
  defp chain_color("linea"), do: "#121212"
  defp chain_color("scroll"), do: "#FFEEDA"
  defp chain_color("mantle"), do: "#000000"
  defp chain_color("blast"), do: "#FCFC03"
  defp chain_color("mode"), do: "#DFFE00"
  defp chain_color("fantom"), do: "#1969FF"
  defp chain_color("celo"), do: "#35D07F"
  defp chain_color(_), do: "#6B7280"

  defp provider_status_color(:connected), do: "#10B981"
  defp provider_status_color(:disconnected), do: "#EF4444"
  defp provider_status_color(:connecting), do: "#F59E0B"
  defp provider_status_color(_), do: "#6B7280"
end
