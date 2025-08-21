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
      
    <!-- Hierarchical orbital network layout -->
      <div class="relative" data-network-canvas style="width: 4000px; height: 3000px;">
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

    # Hierarchical orbital layout configuration
    config = %{
      l1_radius: 60,           # Ethereum L1 node size
      l2_orbit_min: 200,       # Minimum distance for L2 chains
      l2_orbit_max: 350,       # Maximum distance for L2 chains
      provider_orbit: 45,      # Provider orbit distance from their chain
      provider_radius: 10,     # Provider node size
      angle_spread: 2 * :math.pi(), # Full circle for L2 distribution
      other_chain_orbit: 500   # Distance for non-Ethereum chains
    }

    # Separate Ethereum L1 from major chains and others
    {ethereum_l1, major_chains, other_chains} = categorize_chains(chains)

    # Build hierarchical structure
    positioned_chains = build_orbital_structure(ethereum_l1, major_chains, other_chains, center_x, center_y, config)

    %{chains: positioned_chains}
  end

  # Categorize chains into L1 Ethereum, L2s/major chains, and others
  defp categorize_chains(chains) do
    ethereum_l1 = Map.get(chains, "ethereum", [])
    
    # Major chains that should orbit around Ethereum (actual L2s + major sidechains/alt-L1s)
    major_chain_names = ["arbitrum", "optimism", "base", "polygon", "avalanche", "bnb", "fantom"]
    
    {major_chains, other_chains} = 
      chains
      |> Map.drop(["ethereum"])
      |> Map.split(major_chain_names)
    
    {ethereum_l1, major_chains, other_chains}
  end

  # Build the orbital structure with Ethereum at center
  defp build_orbital_structure(ethereum_l1, major_chains, other_chains, center_x, center_y, config) do
    positioned = %{}
    
    # 1. Position Ethereum L1 at center if it exists
    positioned = 
      if length(ethereum_l1) > 0 do
        # Use the standard chain radius calculation for Ethereum too, not fixed l1_radius
        ethereum_radius = calculate_chain_radius(length(ethereum_l1))
        ethereum_data = build_chain_node("ethereum", ethereum_l1, center_x, center_y, ethereum_radius, config.provider_orbit, config.provider_radius)
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
        angle_variance = (seed / 1000 - 0.5) * :math.pi() / 4  # ±45 degrees
        distance_variance = (seed / 1000 - 0.5) * 50  # ±25px
        
        final_angle = base_angle + angle_variance
        orbit_distance = config.l2_orbit_min + 
                        (config.l2_orbit_max - config.l2_orbit_min) * (seed / 1000) +
                        distance_variance
        
        chain_x = center_x + orbit_distance * :math.cos(final_angle)
        chain_y = center_y + orbit_distance * :math.sin(final_angle)
        
        chain_radius = calculate_chain_radius(length(chain_connections))
        chain_data = build_chain_node(chain_name, chain_connections, chain_x, chain_y, chain_radius, config.provider_orbit, config.provider_radius)
        
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
        
        chain_radius = calculate_chain_radius(length(chain_connections))
        chain_data = build_chain_node(chain_name, chain_connections, chain_x, chain_y, chain_radius, config.provider_orbit, config.provider_radius)
        
        Map.put(acc, chain_name, chain_data)
      end)

    positioned
  end

  # Build a chain node with its orbiting providers
  defp build_chain_node(chain_name, chain_connections, x, y, chain_radius, provider_orbit, provider_radius) do
    provider_count = length(chain_connections)
    
    providers = 
      chain_connections
      |> Enum.with_index()
      |> Enum.map(fn {connection, provider_index} ->
        # Calculate provider orbital position
        base_angle = case provider_count do
          1 -> 
            # Single provider - use deterministic but varied position
            seed = :erlang.phash2(connection.id, 1000)
            (seed / 1000) * 2 * :math.pi()
          2 -> 
            # Two providers - opposite sides
            case provider_index do
              0 -> 0                    # Right
              1 -> :math.pi()           # Left
            end
          _ -> 
            # Multiple providers - even distribution
            base = 2 * :math.pi() * provider_index / provider_count
            base - :math.pi() / 2  # Start from top
        end
        
        # Add controlled randomness for organic look
        seed = :erlang.phash2(connection.id, 1000)
        angle_variance = (seed / 1000 - 0.5) * :math.pi() / 8  # ±22.5 degrees
        radius_variance = (seed / 1000 - 0.5) * 10  # ±5px
        
        final_angle = base_angle + angle_variance
        final_radius = provider_orbit + radius_variance
        
        provider_x = x + final_radius * :math.cos(final_angle)
        provider_y = y + final_radius * :math.sin(final_angle)

        {connection, %{
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

  defp calculate_chain_radius(provider_count) do
    max(30, min(80, 25 + provider_count * 3))
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

  # Calculate connection line with pseudo-random length variance
  defp calculate_connection_line_with_variance(
         {chain_x, chain_y},
         {provider_x, provider_y},
         chain_radius,
         provider_radius,
         seed_key
       ) do
    # Calculate direction vector
    dx = provider_x - chain_x
    dy = provider_y - chain_y
    distance = :math.sqrt(dx * dx + dy * dy)

    if distance > 0 do
      # Normalize direction
      norm_dx = dx / distance
      norm_dy = dy / distance

      # Add pseudo-random length variance
      seed = :erlang.phash2(seed_key, 1000)
      length_variance = (seed / 1000 - 0.5) * 30  # ±15px variance
      
      # Calculate start point (edge of chain circle with variance)
      start_radius = chain_radius + length_variance * 0.3
      start_x = chain_x + norm_dx * start_radius
      start_y = chain_y + norm_dy * start_radius

      # Calculate end point (edge of provider circle with variance)
      end_radius = provider_radius + length_variance * 0.7
      end_x = provider_x - norm_dx * end_radius
      end_y = provider_y - norm_dy * end_radius

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
      String.contains?(name_lower, "bsc") or String.contains?(name_lower, "bnb") -> "bnb"
      String.contains?(name_lower, "avalanche") or String.contains?(name_lower, "avax") -> "avalanche"
      String.contains?(name_lower, "fantom") or String.contains?(name_lower, "ftm") -> "fantom"
      String.contains?(name_lower, "cronos") -> "cronos"
      String.contains?(name_lower, "celo") -> "celo"
      String.contains?(name_lower, "gnosis") -> "gnosis"
      String.contains?(name_lower, "moonbeam") -> "moonbeam"
      String.contains?(name_lower, "kava") -> "kava"
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

  # Helper to identify major chains that orbit around Ethereum
  defp is_l2_chain?(chain_name) do
    major_chains = ["arbitrum", "optimism", "base", "polygon", "avalanche", "bnb", "fantom"]
    chain_name in major_chains
  end
end
