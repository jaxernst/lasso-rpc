defmodule LivechainWeb.NetworkTopology do
  use Phoenix.Component

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

  attr(:class, :string, default: "", doc: "additional CSS classes")

  def nodes_display(assigns) do
    assigns =
      assigns
      |> assign(:chains, group_connections_by_chain(assigns.connections))
      |> assign(:spiral_layout, calculate_spiral_layout(assigns.connections))

    ~H"""
    <div class={["relative h-full w-full overflow-hidden", @class]}>
      
    <!-- Hierarchical orbital network layout -->
      <div
        class="relative cursor-default"
        data-network-canvas
        style="width: 4000px; height: 3000px;"
        phx-click="deselect_all"
      >
        <!-- L1 -> L2 Connection lines -->
        <%= if Map.has_key?(@spiral_layout.chains, "ethereum") do %>
          <% ethereum_pos = @spiral_layout.chains["ethereum"].position %>
          <% ethereum_radius = @spiral_layout.chains["ethereum"].radius %>
          <%= for {l2_name, l2_data} <- @spiral_layout.chains do %>
            <%= if is_l2_chain?(l2_name) do %>
              <% {line_start_x, line_start_y, line_end_x, line_end_y} =
                calculate_connection_line_with_variance(
                  ethereum_pos,
                  l2_data.position,
                  ethereum_radius,
                  l2_data.radius,
                  l2_name
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
                  stroke="#8B5CF6"
                  stroke-width="1"
                  opacity="0.3"
                  stroke-dasharray="2,2"
                />
              </svg>
            <% end %>
          <% end %>
        <% end %>
        
    <!-- Provider connection lines -->
        <%= for {chain_name, chain_data} <- @spiral_layout.chains do %>
          <%= for {connection, provider_data} <- chain_data.providers do %>
            <% {line_start_x, line_start_y, line_end_x, line_end_y} =
              calculate_connection_line_with_variance(
                chain_data.position,
                provider_data.position,
                chain_data.radius,
                provider_data.radius,
                connection.id
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
                stroke={provider_line_color(connection)}
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
            phx-value-highlight={chain_name}
            data-chain={chain_name}
            data-chain-center={"#{x},#{y}"}
          >
            <div class="px-2 py-1 text-center text-white">
              <div class={"#{if radius < 40, do: "text-xs", else: "text-sm"} mb-1 font-bold text-white"}>
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
    do: "ring-purple-400/30 !border-purple-400 border-purple-400 ring-2",
    else: "border-gray-600"), unless(@selected_provider == connection.id,
    do: provider_status_class(connection))]}
              style={"left: #{x}px; top: #{y}px; width: #{radius * 2}px; height: #{radius * 2}px; " <>
                if(@selected_provider == connection.id,
                  do: "box-shadow: 0 0 8px rgba(139, 92, 246, 0.4);",
                  else: "box-shadow: 0 0 4px rgba(255, 255, 255, 0.15);")}
              phx-click={@on_provider_select}
              phx-value-provider={connection.id}
              phx-value-highlight={connection.id}
              title={connection.name}
              data-provider={connection.id}
              data-provider-center={"#{x},#{y}"}
              id={"provider-#{connection.id}"}
            >
              <!-- Status indicator dot -->
              <div
                class={["rounded-full", provider_status_dot_class(connection)]}
                style={"width: #{max(4, radius - 4)}px; height: #{max(4, radius - 4)}px;"}
              >
              </div>
              
    <!-- Racing flag indicator for fastest provider -->
              <%= if is_fastest_provider?(connection, chain_name, @latency_leaders) do %>
                <div
                  class="absolute -top-2.5 -right-2.5 flex h-5 w-5 animate-pulse items-center justify-center rounded-full bg-purple-600 text-xs font-bold text-white shadow-lg"
                  title="Fastest average latency"
                >
                  <svg class="h-3.5 w-3.5 text-yellow-300" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M3 3v18l7-3 7 3V3H3z" />
                  </svg>
                </div>
              <% end %>
              
    <!-- Reconnect attempts indicator -->
              <%= if Map.get(connection, :reconnect_attempts, 0) > 0 do %>
                <div class="absolute -top-1.5 -right-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-yellow-500 text-xs font-bold text-white shadow-md">
                  <span class="text-[10px] font-bold leading-none">
                    {connection.reconnect_attempts}
                  </span>
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
        <div class="flex items-center space-x-2">
          <div class="h-3 w-3 rounded-full bg-purple-400"></div>
          <span>Rate limited</span>
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

    # Hierarchical orbital layout configuration
    config = %{
      # Ethereum L1 node size
      l1_radius: 60,
      # Minimum distance for L2 chains
      l2_orbit_min: 200,
      # Maximum distance for L2 chains
      l2_orbit_max: 350,
      # Provider orbit distance from their chain (increased from 45)
      provider_orbit: 65,
      # Provider node size
      provider_radius: 10,
      # Full circle for L2 distribution
      angle_spread: 2 * :math.pi(),
      # Distance for non-Ethereum chains
      other_chain_orbit: 500
    }

    # Separate Ethereum L1 from major chains and others
    {ethereum_l1, major_chains, other_chains} = categorize_chains(chains)

    # Build hierarchical structure
    positioned_chains =
      build_orbital_structure(ethereum_l1, major_chains, other_chains, center_x, center_y, config)

    %{chains: positioned_chains}
  end

  # Categorize chains into L1 Ethereum, L2s/major chains, and others
  defp categorize_chains(chains) do
    ethereum_l1 = Map.get(chains, "ethereum", [])

    # Major chains that should orbit around Ethereum (L2s and major networks)
    major_chain_names = ["arbitrum", "optimism", "base", "zksync", "linea"]

    # Smaller/newer chains for outer orbit
    {major_chains, other_chains} =
      chains
      |> Map.drop(["ethereum"])
      |> Map.split(major_chain_names)

    {ethereum_l1, major_chains, other_chains}
  end

  # Build the orbital structure with Ethereum at center
  defp build_orbital_structure(
         ethereum_l1,
         major_chains,
         other_chains,
         center_x,
         center_y,
         config
       ) do
    positioned = %{}

    # 1. Position Ethereum L1 at center if it exists
    positioned =
      if length(ethereum_l1) > 0 do
        # Use the standard chain radius calculation for Ethereum too, not fixed l1_radius
        ethereum_radius = calculate_chain_radius(length(ethereum_l1), "ethereum")

        ethereum_data =
          build_chain_node(
            "ethereum",
            ethereum_l1,
            center_x,
            center_y,
            ethereum_radius,
            config.provider_orbit,
            config.provider_radius
          )

        Map.put(positioned, "ethereum", ethereum_data)
      else
        positioned
      end

    # 2. Position major chains in orbital pattern around Ethereum
    positioned =
      major_chains
      |> Map.to_list()
      |> Enum.with_index()
      |> Enum.reduce(positioned, fn {{chain_name, chain_connections}, idx}, acc ->
        total_majors = map_size(major_chains)

        # Calculate orbital position with slight randomness
        base_angle = idx * config.angle_spread / max(1, total_majors)
        seed = :erlang.phash2(chain_name, 1000)
        # ±45 degrees
        angle_variance = (seed / 1000 - 0.5) * :math.pi() / 4
        # ±25px
        distance_variance = (seed / 1000 - 0.5) * 50

        final_angle = base_angle + angle_variance

        orbit_distance =
          config.l2_orbit_min +
            (config.l2_orbit_max - config.l2_orbit_min) * (seed / 1000) +
            distance_variance

        chain_x = center_x + orbit_distance * :math.cos(final_angle)
        chain_y = center_y + orbit_distance * :math.sin(final_angle)

        chain_radius = calculate_chain_radius(length(chain_connections), chain_name)

        chain_data =
          build_chain_node(
            chain_name,
            chain_connections,
            chain_x,
            chain_y,
            chain_radius,
            config.provider_orbit,
            config.provider_radius
          )

        Map.put(acc, chain_name, chain_data)
      end)

    # 3. Position other chains in outer orbital ring
    positioned =
      other_chains
      |> Map.to_list()
      |> Enum.with_index()
      |> Enum.reduce(positioned, fn {{chain_name, chain_connections}, idx}, acc ->
        total_others = map_size(other_chains)

        # Outer orbital positioning
        base_angle = idx * config.angle_spread / max(1, total_others)
        seed = :erlang.phash2(chain_name, 1000)
        angle_variance = (seed / 1000 - 0.5) * :math.pi() / 3

        final_angle = base_angle + angle_variance
        orbit_distance = config.other_chain_orbit + (seed / 1000 - 0.5) * 100

        chain_x = center_x + orbit_distance * :math.cos(final_angle)
        chain_y = center_y + orbit_distance * :math.sin(final_angle)

        chain_radius = calculate_chain_radius(length(chain_connections), chain_name)

        chain_data =
          build_chain_node(
            chain_name,
            chain_connections,
            chain_x,
            chain_y,
            chain_radius,
            config.provider_orbit,
            config.provider_radius
          )

        Map.put(acc, chain_name, chain_data)
      end)

    positioned
  end

  # Build a chain node with its orbiting providers
  defp build_chain_node(
         chain_name,
         chain_connections,
         x,
         y,
         chain_radius,
         provider_orbit,
         provider_radius
       ) do
    provider_count = length(chain_connections)

    # Use larger orbit distance for Ethereum to accommodate its bigger size
    adjusted_provider_orbit =
      case chain_name do
        # Add 25px for Ethereum's larger size
        "ethereum" -> provider_orbit + 25
        _ -> provider_orbit
      end

    providers =
      chain_connections
      |> Enum.with_index()
      |> Enum.map(fn {connection, provider_index} ->
        # Calculate provider orbital position
        base_angle =
          case provider_count do
            1 ->
              # Single provider - use deterministic but varied position
              seed = :erlang.phash2(connection.id, 1000)
              seed / 1000 * 2 * :math.pi()

            2 ->
              # Two providers - opposite sides
              case provider_index do
                # Right
                0 -> 0
                # Left
                1 -> :math.pi()
              end

            _ ->
              # Multiple providers - even distribution
              base = 2 * :math.pi() * provider_index / provider_count
              # Start from top
              base - :math.pi() / 2
          end

        # Add controlled randomness for organic look
        seed = :erlang.phash2(connection.id, 1000)
        # ±22.5 degrees
        angle_variance = (seed / 1000 - 0.5) * :math.pi() / 8
        # ±7.5px (increased from ±5px)
        radius_variance = (seed / 1000 - 0.5) * 15

        final_angle = base_angle + angle_variance
        final_radius = adjusted_provider_orbit + radius_variance

        provider_x = x + final_radius * :math.cos(final_angle)
        provider_y = y + final_radius * :math.sin(final_angle)

        {connection,
         %{
           position: {provider_x, provider_y},
           radius: provider_radius
         }}
      end)

    %{
      position: {x, y},
      radius: chain_radius,
      providers: providers
    }
  end

  defp calculate_chain_radius(provider_count, chain_name) do
    base_radius = max(35, min(85, 30 + provider_count * 4))

    # Make Ethereum the biggest node
    case chain_name do
      # Add 20px to make it significantly larger
      "ethereum" -> base_radius + 20
      _ -> base_radius
    end
  end


  # Calculate connection line with pseudo-random length variance
  defp calculate_connection_line_with_variance(
         {chain_x, chain_y},
         {provider_x, provider_y},
         chain_radius,
         provider_radius,
         _seed_key
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

      # Calculate end point (edge of provider circle) - extend all the way to provider edge
      end_x = provider_x - norm_dx * provider_radius
      end_y = provider_y - norm_dy * provider_radius

      {start_x, start_y, end_x, end_y}
    else
      # Fallback for zero distance
      {chain_x, chain_y, provider_x, provider_y}
    end
  end

  # Import StatusHelpers for comprehensive status determination
  alias LivechainWeb.Dashboard.StatusHelpers

  # Enhanced provider line colors based on comprehensive status
  defp provider_line_color(connection_status) when is_atom(connection_status) do
    case connection_status do
      :connected -> "#10b981"      # Green - healthy
      :disconnected -> "#ef4444"   # Red - failed
      :connecting -> "#f59e0b"     # Yellow/Orange - connecting 
      :rate_limited -> "#8B5CF6"   # Purple - rate limited
      _ -> "#6b7280"               # Gray - unknown
    end
  end

  # Enhanced provider line colors using comprehensive connection data
  defp provider_line_color(connection) when is_map(connection) do
    case StatusHelpers.determine_provider_status(connection) do
      :circuit_open -> "#dc2626"   # Dark red - circuit open
      :failed -> "#ef4444"         # Red - failed  
      :unhealthy -> "#f97316"      # Orange - unhealthy
      :unstable -> "#eab308"       # Yellow - unstable
      :rate_limited -> "#8b5cf6"   # Purple - rate limited
      :connecting -> "#f59e0b"     # Amber - connecting
      :recovering -> "#3b82f6"     # Blue - recovering
      :connected -> "#10b981"      # Green - healthy
      :unknown -> "#6b7280"        # Gray - unknown
    end
  end

  defp provider_line_color(status), do: provider_line_color(status)

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
      String.contains?(name_lower, "arbitrum") -> "arbitrum"
      String.contains?(name_lower, "optimism") -> "optimism"
      # Be more specific for base to avoid matching "blastapi"
      name_lower =~ ~r/\bbase\b/ -> "base"
      String.contains?(name_lower, "zksync") -> "zksync"
      String.contains?(name_lower, "linea") -> "linea"
      String.contains?(name_lower, "unichain") -> "unichain"
      true -> "unknown"
    end
  end


  # Enhanced provider status classes using comprehensive status
  defp provider_status_class(connection_status) when is_atom(connection_status) do
    case connection_status do
      :connected -> "bg-emerald-900/30 border-emerald-600"
      :disconnected -> "bg-red-900/30 border-red-600"
      :connecting -> "bg-yellow-900/30 border-yellow-600"
      :rate_limited -> "bg-purple-900/30 border-purple-600"
      _ -> "bg-gray-900/30 border-gray-600"
    end
  end

  defp provider_status_class(connection) when is_map(connection) do
    case StatusHelpers.determine_provider_status(connection) do
      :circuit_open -> "bg-red-900/40 border-red-500"      # Dark red - circuit open
      :failed -> "bg-red-900/30 border-red-600"            # Red - failed
      :unhealthy -> "bg-orange-900/30 border-orange-600"   # Orange - unhealthy  
      :unstable -> "bg-yellow-900/30 border-yellow-600"    # Yellow - unstable
      :rate_limited -> "bg-purple-900/30 border-purple-600" # Purple - rate limited
      :connecting -> "bg-amber-900/30 border-amber-600"    # Amber - connecting
      :recovering -> "bg-blue-900/30 border-blue-600"      # Blue - recovering
      :connected -> "bg-emerald-900/30 border-emerald-600" # Green - healthy
      :unknown -> "bg-gray-900/30 border-gray-600"         # Gray - unknown
    end
  end

  defp provider_status_dot_class(connection_status) when is_atom(connection_status) do
    case connection_status do
      :connected -> "bg-emerald-400"
      :disconnected -> "bg-red-400"
      :connecting -> "bg-yellow-400"
      :rate_limited -> "bg-purple-400"
      _ -> "bg-gray-400"
    end
  end

  defp provider_status_dot_class(connection) when is_map(connection) do
    case StatusHelpers.determine_provider_status(connection) do
      :circuit_open -> "bg-red-500"      # Dark red - circuit open
      :failed -> "bg-red-400"            # Red - failed
      :unhealthy -> "bg-orange-400"      # Orange - unhealthy
      :unstable -> "bg-yellow-400"       # Yellow - unstable
      :rate_limited -> "bg-purple-400"   # Purple - rate limited
      :connecting -> "bg-amber-400"      # Amber - connecting
      :recovering -> "bg-blue-400"       # Blue - recovering
      :connected -> "bg-emerald-400"     # Green - healthy
      :unknown -> "bg-gray-400"          # Gray - unknown
    end
  end

  defp chain_color("ethereum"), do: "#627EEA"
  defp chain_color("arbitrum"), do: "#28A0F0"
  defp chain_color("optimism"), do: "#FF0420"
  defp chain_color("base"), do: "#0052FF"
  defp chain_color("zksync"), do: "#4E529A"
  defp chain_color("linea"), do: "#61DFFF"
  defp chain_color("unichain"), do: "#FF007A"
  defp chain_color(_), do: "#6B7280"


  defp is_fastest_provider?(_connection, _chain_name, _latency_leaders) do
    false
  end

  # Helper to identify major chains that orbit around Ethereum
  defp is_l2_chain?(chain_name) do
    major_chains = ["arbitrum", "optimism", "base", "zksync", "linea"]
    chain_name in major_chains
  end
end
