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
  attr(:latency_leaders, :map, default: %{}, doc: "map of chain names to fastest provider ids")
  attr(:on_chain_select, :string, default: "select_chain", doc: "event name for chain selection")

  attr(:on_provider_select, :string,
    default: "select_provider",
    doc: "event name for provider selection"
  )

  attr(:on_test_connection, :string,
    default: "test_connection",
    doc: "event name for test connection"
  )

  attr(:on_chain_hover, :string, default: nil, doc: "event name for chain hover (mouseenter)")

  attr(:on_provider_hover, :string,
    default: nil,
    doc: "event name for provider hover (mouseenter)"
  )

  attr(:class, :string, default: "", doc: "additional CSS classes")

  def nodes_display(assigns) do
    assigns =
      assigns
      |> assign(:chains, group_connections_by_chain(assigns.connections))
      |> assign(:spiral_layout, calculate_spiral_layout(assigns.connections))

    ~H"""
    <div class={["relative h-full w-full overflow-hidden", @class]}>
      
    <!-- Spiral network layout -->
      <div class="relative" data-network-canvas style="width: 4000px; height: 3000px;">
        <!-- Connection lines -->
        <%= for {chain_name, chain_data} <- @spiral_layout.chains do %>
          <%= for {connection, provider_data} <- chain_data.providers do %>
            <% {line_start_x, line_start_y, line_end_x, line_end_y} =
              calculate_connection_line(
                chain_data.position,
                provider_data.position,
                chain_data.radius,
                provider_data.radius
              ) %>
            <svg
              class="pointer-events-none absolute z-0"
              style="left: 0; top: 0; width: 100%; height: 100%;"
            >
              <line
                x1={line_start_x}
                y1={line_start_y}
                x2={line_end_x}
                y2={line_end_y}
                stroke={provider_line_color(connection.status)}
                stroke-width="2"
                opacity="0.6"
              />
            </svg>
          <% end %>
        <% end %>
        
    <!-- Chain nodes -->
        <%= for {chain_name, chain_data} <- @spiral_layout.chains do %>
          <% {x, y} = chain_data.position %>
          <% radius = chain_data.radius %>
          <div
            class={["absolute z-10 -translate-x-1/2 -translate-y-1/2 transform", "flex cursor-pointer items-center justify-center rounded-full border-2 bg-gradient-to-br shadow-xl shadow-inner transition-all duration-300 hover:scale-110", if(@selected_chain == chain_name,
    do: "ring-purple-400/30 border-purple-400 ring-4",
    else: "border-gray-500 hover:border-gray-400"), "from-gray-800 to-gray-900"]}
            style={"left: #{x}px; top: #{y}px; width: #{radius * 2}px; height: #{radius * 2}px; background: linear-gradient(135deg, #{chain_color(chain_name)} 0%, #111827 100%); " <>
              if(@selected_chain == chain_name,
                do: "box-shadow: 0 0 15px rgba(139, 92, 246, 0.4), inset 0 0 15px rgba(0, 0, 0, 0.3);",
                else: "box-shadow: 0 0 8px rgba(139, 92, 246, 0.2), inset 0 0 15px rgba(0, 0, 0, 0.3);")}
            phx-click={@on_chain_select}
            phx-value-chain={chain_name}
            phx-mouseenter={@on_chain_hover}
            phx-value-highlight={chain_name}
            data-chain={chain_name}
            data-chain-center={"#{x},#{y}"}
          >
            <div class="text-center text-white">
              <div class={"#{if radius < 40, do: "text-xs", else: "text-sm"} font-bold text-white"}>
                {String.upcase(chain_name)}
              </div>
              <div class={"#{if radius < 40, do: "text-xs", else: "text-sm"} text-gray-300"}>
                {length(chain_data.providers)}
              </div>
            </div>
          </div>
        <% end %>
        
    <!-- Provider nodes -->
        <%= for {chain_name, chain_data} <- @spiral_layout.chains do %>
          <%= for {connection, provider_data} <- chain_data.providers do %>
            <% {x, y} = provider_data.position %>
            <% radius = provider_data.radius %>
            <div
              class={["z-5 absolute -translate-x-1/2 -translate-y-1/2 transform", "flex cursor-pointer items-center justify-center rounded-full border-2 transition-all duration-200 hover:scale-125", if(@selected_provider == connection.id,
    do: "ring-purple-400/30 border-purple-400 ring-2",
    else: "border-gray-600"), provider_status_class(connection.status)]}
              style={"left: #{x}px; top: #{y}px; width: #{radius * 2}px; height: #{radius * 2}px; " <>
                if(@selected_provider == connection.id,
                  do: "box-shadow: 0 0 8px rgba(139, 92, 246, 0.4);",
                  else: "box-shadow: 0 0 4px rgba(255, 255, 255, 0.15);")}
              phx-click={@on_provider_select}
              phx-value-provider={connection.id}
              phx-mouseenter={@on_provider_hover}
              phx-value-highlight={connection.id}
              title={connection.name}
              data-provider={connection.id}
              data-provider-center={"#{x},#{y}"}
            >
              <!-- Status indicator dot -->
              <div
                class={["rounded-full", provider_status_dot_class(connection.status)]}
                style={"width: #{max(4, radius - 4)}px; height: #{max(4, radius - 4)}px;"}
              >
              </div>
              
    <!-- Racing flag indicator for fastest provider -->
              <%= if is_fastest_provider?(connection, chain_name, @latency_leaders) do %>
                <div
                  class="absolute -top-2 -right-2 flex h-4 w-4 animate-pulse items-center justify-center rounded-full bg-purple-600 text-xs font-bold text-white shadow-lg"
                  title="Fastest average latency"
                >
                  <svg class="h-3 w-3 text-yellow-300" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M3 3v18l7-3 7 3V3H3z" />
                  </svg>
                </div>
              <% end %>
              
    <!-- Reconnect attempts indicator -->
              <%= if Map.get(connection, :reconnect_attempts, 0) > 0 do %>
                <div class="absolute -top-1 -right-1 flex h-3 w-3 items-center justify-center rounded-full bg-yellow-500 text-xs font-bold text-white">
                  {connection.reconnect_attempts}
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
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

  defp calculate_spiral_layout(connections) do
    chains = group_connections_by_chain(connections)
    center_x = 2000
    center_y = 1500

    # Triangular grid parameters
    total_chains = length(Map.keys(chains))
    spacing = 350  # Distance between adjacent chain centers
    
    # Generate triangular positions for chains
    chain_positions = generate_hex_positions(total_chains, center_x, center_y, spacing)

    # Position chains on hexagonal grid
    positioned_chains =
      chains
      |> Map.to_list()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{chain_name, chain_connections}, idx}, acc ->
        {chain_x, chain_y} = Enum.at(chain_positions, idx, {center_x, center_y})
        
        provider_count = length(chain_connections)
        chain_radius = calculate_chain_radius(provider_count)
        orbit_radius = chain_radius + 50
        provider_radius = 10

        # Position providers around their chain
        providers =
          chain_connections
          |> Enum.with_index()
          |> Enum.map(fn {connection, provider_index} ->
            base_angle = case provider_count do
              1 -> 
                # Single provider - use consistent position
                seed = :erlang.phash2(connection.id, 1000)
                (seed / 1000) * 2 * :math.pi()
              2 -> 
                # For 2 providers, use vertical positioning
                case provider_index do
                  0 -> :math.pi() / 2      # 90 degrees (top)
                  1 -> 3 * :math.pi() / 2  # 270 degrees (bottom)
                end
              _ -> 
                # For 3+ providers, use regular circular distribution
                base = 2 * :math.pi() * provider_index / provider_count
                base + :math.pi() / 2  # Start from top
            end
            
            # Add slight randomness for visual variety
            seed = :erlang.phash2(connection.id, 1000)
            angle_variance = (seed / 1000 - 0.5) * :math.pi() / 6  # ±30 degrees variance
            radius_variance = (seed / 1000 - 0.5) * 15  # ±7.5px radius variance
            
            final_angle = base_angle + angle_variance
            final_radius = orbit_radius + radius_variance
            
            provider_x = chain_x + final_radius * :math.cos(final_angle)
            provider_y = chain_y + final_radius * :math.sin(final_angle)

            {connection, %{
              position: {provider_x, provider_y},
              radius: provider_radius
            }}
          end)

        chain_data = %{
          position: {chain_x, chain_y},
          radius: chain_radius,
          providers: providers
        }

        Map.put(acc, chain_name, chain_data)
      end)

    %{chains: positioned_chains}
  end

  defp calculate_chain_radius(provider_count) do
    max(30, min(80, 25 + provider_count * 3))
  end

  # Generate triangular grid positions for chains with better spacing
  defp generate_hex_positions(count, center_x, center_y, spacing) do
    cond do
      count == 1 ->
        [{center_x, center_y}]
      
      count == 2 ->
        # Two nodes: place horizontally
        offset = spacing / 2
        [{center_x - offset, center_y}, {center_x + offset, center_y}]
      
      count == 3 ->
        # Three nodes: equilateral triangle
        height = spacing * :math.sqrt(3) / 2
        [
          {center_x, center_y - height * 2/3},           # top
          {center_x - spacing/2, center_y + height/3},   # bottom left
          {center_x + spacing/2, center_y + height/3}    # bottom right
        ]
      
      count <= 6 ->
        # 4-6 nodes: center + triangular arrangement
        positions = [{center_x, center_y}]  # center
        
        # Triangular ring around center
        triangle_positions = for i <- 0..(count - 2) do
          angle = i * 2 * :math.pi() / (count - 1) - :math.pi() / 2  # Start from top
          x = center_x + spacing * :math.cos(angle)
          y = center_y + spacing * :math.sin(angle)
          {x, y}
        end
        
        positions ++ triangle_positions
      
      true ->
        # 7+ nodes: multiple triangular rings
        positions = [{center_x, center_y}]  # center
        
        # First ring: 6 positions in circle
        first_ring = for i <- 0..5 do
          angle = i * :math.pi() / 3 - :math.pi() / 2  # Start from top, 60-degree increments
          x = center_x + spacing * :math.cos(angle)
          y = center_y + spacing * :math.sin(angle)
          {x, y}
        end
        
        # Second ring: positions at wider spacing
        second_ring = for i <- 0..11 do
          angle = i * :math.pi() / 6 - :math.pi() / 2  # Start from top, 30-degree increments
          radius = spacing * 1.8  # Wider spacing for second ring
          x = center_x + radius * :math.cos(angle)
          y = center_y + radius * :math.sin(angle)
          {x, y}
        end
        
        all_positions = positions ++ first_ring ++ second_ring
        Enum.take(all_positions, count)
    end
  end

  defp calculate_connection_line(
         {chain_x, chain_y},
         {provider_x, provider_y},
         chain_radius,
         provider_radius
       ) do
    # Calculate direction vector
    dx = provider_x - chain_x
    dy = provider_y - chain_y
    distance = :math.sqrt(dx * dx + dy * dy)

    if distance > 0 do
      # Normalize direction
      norm_dx = dx / distance
      norm_dy = dy / distance

      # Calculate start point (edge of chain circle)
      start_x = chain_x + norm_dx * chain_radius
      start_y = chain_y + norm_dy * chain_radius

      # Calculate end point (edge of provider circle)
      end_x = provider_x - norm_dx * provider_radius
      end_y = provider_y - norm_dy * provider_radius

      {start_x, start_y, end_x, end_y}
    else
      # Fallback for zero distance
      {chain_x, chain_y, provider_x, provider_y}
    end
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

  defp is_fastest_provider?(connection, chain_name, latency_leaders) do
    case Map.get(latency_leaders, chain_name) do
      fastest_provider_id when fastest_provider_id == connection.id -> true
      _ -> false
    end
  end
end
