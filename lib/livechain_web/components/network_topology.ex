defmodule LivechainWeb.NetworkTopology do
  @moduledoc """
  Network topology visualization component for displaying blockchain rpc connections
  in an interactive grid layout.
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

  def nodes_display(assigns) do
    assigns = assign(assigns, :chains, group_connections_by_chain(assigns.connections))

    ~H"""
    <div class={["relative h-full w-full overflow-hidden", @class]}>
      
    <!-- Circular chain layout with orbiting providers -->
      <div class="flex h-full w-full items-center justify-center p-8">
        <div class="flex flex-wrap items-center justify-center gap-16">
          <%= for {chain_name, chain_connections} <- @chains do %>
            <div class="relative" style="width: 200px; height: 200px;">
              <!-- Connection lines from center to providers (drawn first, behind chain circle) -->
              <%= for {connection, index} <- Enum.with_index(chain_connections) do %>
                <% {x, y} = calculate_orbit_position(index, length(chain_connections), 75) %>
                <% {line_start_x, line_start_y, line_length, line_angle} =
                  calculate_line_properties(x, y, 100, 50, 10) %>
                <div
                  class="pointer-events-none absolute"
                  style={
                    "left: #{line_start_x}px; top: #{line_start_y}px; " <>
                    "width: #{line_length}px; height: 2px; " <>
                    "background: #{provider_line_color(connection.status)}; " <>
                    "transform-origin: 0 50%; " <>
                    "transform: rotate(#{line_angle}rad);"
                  }
                >
                </div>
              <% end %>
              
    <!-- Chain node (circular) - drawn on top of lines -->
              <div
                class={["absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 transform", "flex cursor-pointer items-center justify-center rounded-full border-2 bg-gradient-to-br shadow-xl transition-all duration-300 hover:scale-110", if(@selected_chain == chain_name,
    do: "ring-purple-400/30 border-purple-400 ring-4",
    else: "border-gray-500 hover:border-gray-400"), "from-gray-800 to-gray-900"]}
                style="width: 100px; height: 100px;"
                phx-click={@on_chain_select}
                phx-value-chain={chain_name}
              >
                <div class="text-center text-white">
                  <div class="text-base font-bold text-purple-300">{String.upcase(chain_name)}</div>
                  <div class="text-sm text-gray-300">{length(chain_connections)}</div>
                </div>
              </div>
              
    <!-- Orbiting provider nodes -->
              <%= for {connection, index} <- Enum.with_index(chain_connections) do %>
                <% {x, y} = calculate_orbit_position(index, length(chain_connections), 75) %>
                <div
                  class={["absolute -translate-x-1/2 -translate-y-1/2 transform", "flex cursor-pointer items-center justify-center rounded-full border-2 transition-all duration-200 hover:scale-125", if(@selected_provider == connection.id,
    do: "ring-purple-400/30 border-purple-400 ring-2",
    else: "border-gray-600"), provider_status_class(connection.status)]}
                  style={"width: 20px; height: 20px; left: #{x}px; top: #{y}px;"}
                  phx-click={@on_provider_select}
                  phx-value-provider={connection.id}
                  title={connection.name}
                >
                  <!-- Status indicator dot -->
                  <div class={["h-2 w-2 rounded-full", provider_status_dot_class(connection.status)]}>
                  </div>
                  
    <!-- Reconnect attempts indicator -->
                  <%= if Map.get(connection, :reconnect_attempts, 0) > 0 do %>
                    <div class="absolute -top-1 -right-1 flex h-3 w-3 items-center justify-center rounded-full bg-yellow-500 text-xs font-bold text-white">
                      {connection.reconnect_attempts}
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Status Legend -->
      <div class="bg-gray-900/90 absolute right-4 bottom-4 rounded-lg border border-gray-600 p-2 backdrop-blur-sm">
        <div class="flex items-center space-x-3 text-xs text-gray-300">
          <div class="flex items-center space-x-1">
            <div class="h-2 w-2 rounded-full bg-emerald-400"></div>
            <span>Connected</span>
          </div>
          <div class="flex items-center space-x-1">
            <div class="h-2 w-2 rounded-full bg-red-400"></div>
            <span>Disconnected</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def legend(assigns) do
    ~H"""
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
    """
  end

  # Helper functions for network topology

  defp group_connections_by_chain(connections) do
    connections
    |> Enum.group_by(&extract_chain_from_connection(&1))
  end

  defp calculate_orbit_position(index, total_providers, base_radius) do
    # Add randomness to the angle based on provider index for consistent positioning
    # Use index as seed for deterministic but varied positioning
    :rand.seed(:exsplus, {index * 13, index * 7, index * 19})

    # Calculate base angle for this provider (evenly distributed around circle)
    base_angle = 2 * :math.pi() * index / max(total_providers, 1)

    # Add random angle offset (-30 to +30 degrees)
    angle_offset = (:rand.uniform() - 0.5) * :math.pi() / 3
    angle = base_angle + angle_offset

    # Add randomness to radius (extend further out and vary distance)
    # -10 to +10 px variance
    radius_variance = :rand.uniform() * 20 - 10
    # Extend base radius by 15px + variance
    actual_radius = base_radius + 15 + radius_variance

    # Calculate position relative to center (100px from center of 200px container)
    center = 100
    x = center + actual_radius * :math.cos(angle)
    y = center + actual_radius * :math.sin(angle)

    {x, y}
  end

  defp calculate_line_properties(provider_x, provider_y, center, chain_radius, provider_radius) do
    # Calculate distance from center to provider (full distance from chain edge to provider edge)
    dx = provider_x - center
    dy = provider_y - center
    full_distance = :math.sqrt(dx * dx + dy * dy)

    # Add randomness to line length for more organic feel
    # Use provider position as seed for deterministic randomness
    :rand.seed(
      :exsplus,
      {round(provider_x * 17), round(provider_y * 23), round(full_distance * 11)}
    )

    # -4 to +4 px variance
    length_variance = (:rand.uniform() - 0.5) * 8

    # Line should go from chain circle edge to provider dot edge, with some variance
    base_line_length = full_distance - chain_radius - provider_radius
    # Ensure minimum length
    line_length = max(5, base_line_length + length_variance)

    # Calculate angle for rotation
    line_angle = :math.atan2(dy, dx)

    # Calculate start position for the line (at the edge of the chain circle)
    # We need to find the point on the chain circle's edge that's closest to the provider
    # This is done by normalizing the direction vector and scaling it by the chain radius
    {line_start_x, line_start_y} =
      if full_distance > 0 do
        # Normalize the direction vector
        normalized_dx = dx / full_distance
        normalized_dy = dy / full_distance

        # Start position is at the edge of the chain circle
        {center + normalized_dx * chain_radius, center + normalized_dy * chain_radius}
      else
        # Fallback if provider is at center (shouldn't happen in practice)
        {center, center}
      end

    {line_start_x, line_start_y, line_length, line_angle}
  end

  defp provider_line_color(:connected), do: "#10b981"
  defp provider_line_color(:disconnected), do: "#ef4444"
  defp provider_line_color(:connecting), do: "#f59e0b"
  defp provider_line_color(_), do: "#6b7280"

  defp extract_chain_from_connection(connection) do
    # Use the actual chain field from the connection if available
    case Map.get(connection, :chain) do
      chain when is_binary(chain) -> chain
      _ -> extract_chain_from_connection_name(connection.name)
    end
  end

  defp extract_chain_from_connection_name(name) do
    name_lower = String.downcase(name)

    cond do
      String.contains?(name_lower, "ethereum") -> "ethereum"
      String.contains?(name_lower, "polygon") -> "polygon"
      String.contains?(name_lower, "arbitrum") -> "arbitrum"
      String.contains?(name_lower, "optimism") -> "optimism"
      # Be more specific for base to avoid matching "blastapi"
      name_lower =~ ~r/\bbase\b/ -> "base"
      String.contains?(name_lower, "bsc") -> "bsc"
      String.contains?(name_lower, "avalanche") -> "avalanche"
      String.contains?(name_lower, "zksync") -> "zksync"
      String.contains?(name_lower, "linea") -> "linea"
      String.contains?(name_lower, "scroll") -> "scroll"
      String.contains?(name_lower, "mantle") -> "mantle"
      # Be more specific for blast chain to avoid matching "blastapi"
      name_lower =~ ~r/\bblast\b/ and not String.contains?(name_lower, "blastapi") -> "blast"
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

  defp chain_display_name("ethereum"), do: "Ethereum"
  defp chain_display_name("polygon"), do: "Polygon"
  defp chain_display_name("arbitrum"), do: "Arbitrum"
  defp chain_display_name("optimism"), do: "Optimism"
  defp chain_display_name("base"), do: "Base"
  defp chain_display_name("bsc"), do: "BSC"
  defp chain_display_name("avalanche"), do: "Avalanche"
  defp chain_display_name("zksync"), do: "zkSync"
  defp chain_display_name("linea"), do: "Linea"
  defp chain_display_name("scroll"), do: "Scroll"
  defp chain_display_name("mantle"), do: "Mantle"
  defp chain_display_name("blast"), do: "Blast"
  defp chain_display_name("mode"), do: "Mode"
  defp chain_display_name("fantom"), do: "Fantom"
  defp chain_display_name("celo"), do: "Celo"
  defp chain_display_name("unknown"), do: "Unknown Chain"
  defp chain_display_name(chain), do: String.capitalize(chain)

  defp provider_status_class(:connected), do: "bg-emerald-900/30 border-emerald-600"
  defp provider_status_class(:disconnected), do: "bg-red-900/30 border-red-600"
  defp provider_status_class(:connecting), do: "bg-yellow-900/30 border-yellow-600"
  defp provider_status_class(_), do: "bg-gray-900/30 border-gray-600"

  defp provider_status_dot_class(:connected), do: "bg-emerald-400"
  defp provider_status_dot_class(:disconnected), do: "bg-red-400"
  defp provider_status_dot_class(:connecting), do: "bg-yellow-400"
  defp provider_status_dot_class(_), do: "bg-gray-400"

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
