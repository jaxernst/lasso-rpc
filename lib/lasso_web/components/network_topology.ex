defmodule LassoWeb.NetworkTopology do
  use Phoenix.Component

  alias LassoWeb.Dashboard.Helpers
  alias LassoWeb.TopologyConfig
  alias Lasso.Config.ConfigStore

  attr(:id, :string, required: true, doc: "unique identifier for the topology component")
  attr(:connections, :list, required: true, doc: "list of connection maps")
  attr(:selected_chain, :string, default: nil, doc: "currently selected chain")
  attr(:selected_provider, :string, default: nil, doc: "currently selected provider")
  attr(:selected_profile, :string, default: nil, doc: "currently selected profile")
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
        <!-- Parent -> Child Connection lines (L1 to L2s) -->
        <%= for {chain_name, chain_data} <- @spiral_layout.chains do %>
          <%= if parent_name = Map.get(chain_data, :parent) do %>
            <%= if parent_data = Map.get(@spiral_layout.chains, parent_name) do %>
              <% {line_start_x, line_start_y, line_end_x, line_end_y} =
                calculate_connection_line_with_variance(
                  parent_data.position,
                  chain_data.position,
                  parent_data.radius,
                  chain_data.radius,
                  chain_name
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
                  stroke={TopologyConfig.l1_l2_line_color()}
                  stroke-width={TopologyConfig.l1_l2_line_width()}
                  opacity={TopologyConfig.l1_l2_line_opacity()}
                  stroke-dasharray={TopologyConfig.l1_l2_line_dash()}
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
            class={["absolute z-10 -translate-x-1/2 -translate-y-1/2 transform", "flex cursor-pointer items-center justify-center rounded-full border-2 bg-gradient-to-br shadow-xl transition-all duration-300 hover:scale-110", if(@selected_chain == chain_name,
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
              <div class={"#{if radius < 50, do: "text-xs", else: "text-sm"} mb-1 font-bold text-white"}>
                {Helpers.get_chain_display_name(chain_name)}
              </div>
              <div class={"#{if radius < 50, do: "text-xs", else: "text-sm"} text-gray-300"}>
                {Helpers.get_chain_id(chain_name)}
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
    do: "ring-purple-400/30 !border-purple-400 ring-2",
    else: provider_border_class(connection)), if(@selected_provider != connection.id,
    do: provider_status_bg_class(connection))]}
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
              
    <!-- WebSocket support indicator -->
              <%= if has_websocket_support?(connection) do %>
                <div
                  class="absolute -right-1.5 -bottom-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-blue-600 text-xs font-bold text-white shadow-md"
                  title="WebSocket Support"
                >
                  <svg class="h-2.5 w-2.5 text-white" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.94-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
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

  # Helper functions for network topology

  defp group_connections_by_chain(connections) do
    connections
    |> Enum.group_by(&extract_chain_from_connection(&1))
  end

  defp calculate_spiral_layout(connections) do
    chains = group_connections_by_chain(connections)
    {center_x, center_y} = TopologyConfig.canvas_center()

    # Layout configuration from centralized TopologyConfig
    config = %{
      l2_orbit_min: TopologyConfig.l2_orbit_min(),
      l2_orbit_max: TopologyConfig.l2_orbit_max(),
      provider_radius: TopologyConfig.provider_node_radius(),
      angle_spread: TopologyConfig.angle_spread(),
      other_chain_orbit: TopologyConfig.other_chain_orbit(),
      chain_angle_variance: TopologyConfig.chain_angle_variance(),
      chain_distance_variance: TopologyConfig.chain_distance_variance()
    }

    # Categorize chains using topology config from chains.yml
    {l1_chains, l2_chains, other_chains} = categorize_chains_by_config(chains)

    # Build hierarchical structure with parent-child relationships
    positioned_chains =
      build_orbital_structure(l1_chains, l2_chains, other_chains, center_x, center_y, config)

    %{chains: positioned_chains}
  end

  # Categorize chains using topology config from chains.yml
  # Returns {l1_chains, l2_chains, other_chains} where each is a map of chain_name => connections
  #
  # Key design decisions:
  # - L2s are only placed in l2_chains if their parent chain EXISTS in the active chains
  # - This ensures testnets (e.g., base_sepolia) don't connect to mainnet (ethereum)
  # - L2s with missing parents float independently in other_chains
  defp categorize_chains_by_config(chains) do
    # Get all chain configs from ConfigStore
    all_chain_configs = ConfigStore.get_all_chains()
    active_chain_names = Map.keys(chains)

    # Categorize based on topology config
    {l1_chains, l2_chains, other_chains} =
      Enum.reduce(chains, {%{}, %{}, %{}}, fn {chain_name, connections},
                                              {l1_acc, l2_acc, other_acc} ->
        topology = get_chain_topology(chain_name, all_chain_configs)

        cond do
          # L1 chains - check topology or fallback to known L1 patterns
          is_l1_chain?(topology, chain_name) ->
            {Map.put(l1_acc, chain_name, connections), l2_acc, other_acc}

          # L2 chains - ONLY if parent chain exists in active chains
          is_l2_with_active_parent?(topology, chain_name, active_chain_names) ->
            {l1_acc, Map.put(l2_acc, chain_name, connections), other_acc}

          # Everything else (including L2s with missing parents) floats independently
          true ->
            {l1_acc, l2_acc, Map.put(other_acc, chain_name, connections)}
        end
      end)

    {l1_chains, l2_chains, other_chains}
  end

  # Check if chain is an L1 (from topology config only)
  defp is_l1_chain?(%{category: :l1}, _chain_name), do: true
  defp is_l1_chain?(_, _), do: false

  # Check if chain is an L2 with an active parent chain
  # Parent must exist in the current set of active chains for connection to render
  defp is_l2_with_active_parent?(
         %{category: category, parent: parent},
         _chain_name,
         active_chain_names
       )
       when category in [:l2_optimistic, :l2_zk] and is_binary(parent) do
    parent in active_chain_names
  end

  # Chains without topology config are not treated as L2s
  defp is_l2_with_active_parent?(_, _, _), do: false

  # Get the parent chain for an L2 (from topology config only)
  defp get_l2_parent(%{parent: parent}, _chain_name) when is_binary(parent), do: parent
  defp get_l2_parent(_, _), do: nil

  # Get topology config for a chain, returns nil if not configured
  defp get_chain_topology(chain_name, all_chain_configs) do
    case Map.get(all_chain_configs, chain_name) do
      %{topology: topology} when not is_nil(topology) -> topology
      _ -> nil
    end
  end

  # Build the orbital structure with L1 chains at center, L2s orbiting their parents
  defp build_orbital_structure(
         l1_chains,
         l2_chains,
         other_chains,
         center_x,
         center_y,
         config
       ) do
    all_chain_configs = ConfigStore.get_all_chains()
    positioned = %{}

    # 1. Position L1 chains (spread around center if multiple)
    positioned =
      l1_chains
      |> Map.to_list()
      |> Enum.with_index()
      |> Enum.reduce(positioned, fn {{chain_name, chain_connections}, idx}, acc ->
        total_l1s = map_size(l1_chains)

        # If single L1, place at center. If multiple, spread them out
        {chain_x, chain_y} =
          if total_l1s == 1 do
            {center_x, center_y}
          else
            # Spread L1s in a circle around center using configurable distance
            angle = idx * config.angle_spread / total_l1s
            l1_spread = TopologyConfig.l1_spread_distance()
            {center_x + l1_spread * :math.cos(angle), center_y + l1_spread * :math.sin(angle)}
          end

        topology = get_chain_topology(chain_name, all_chain_configs)
        chain_radius = calculate_chain_radius_from_config(topology, length(chain_connections))

        chain_data =
          build_chain_node(
            chain_name,
            chain_connections,
            chain_x,
            chain_y,
            chain_radius,
            TopologyConfig.provider_orbit_for_radius(chain_radius),
            config.provider_radius
          )

        Map.put(acc, chain_name, chain_data)
      end)

    # 2. Position L2 chains in orbital pattern around their parent L1
    # First, group L2s by their parent to assign per-parent indices
    # Note: All L2s in l2_chains are guaranteed to have an existing parent (checked in categorization)
    l2s_by_parent =
      l2_chains
      |> Map.to_list()
      |> Enum.group_by(fn {chain_name, _conns} ->
        topology = get_chain_topology(chain_name, all_chain_configs)
        get_l2_parent(topology, chain_name)
      end)

    positioned =
      Enum.reduce(l2s_by_parent, positioned, fn {parent_name, sibling_chains}, acc ->
        # Get parent position (default to center if parent not found)
        {parent_x, parent_y} =
          case Map.get(acc, parent_name) do
            %{position: pos} -> pos
            _ -> {center_x, center_y}
          end

        sibling_count = length(sibling_chains)

        # Position each sibling with its index within this parent's orbit
        sibling_chains
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {{chain_name, chain_connections}, sibling_idx}, inner_acc ->
          topology = get_chain_topology(chain_name, all_chain_configs)

          # Calculate orbital position using sibling index for even distribution
          # Use seed-based offset to add variety when there's only 1 sibling
          seed = :erlang.phash2(chain_name, 1000)

          # Base angle includes configurable offset plus seed-based variance
          # This prevents single L2s from always pointing straight up
          # ±90° based on chain name
          seed_angle_offset = (seed / 1000 - 0.5) * :math.pi()

          base_angle =
            TopologyConfig.l2_base_angle_offset() +
              seed_angle_offset +
              sibling_idx * config.angle_spread / max(1, sibling_count)

          angle_variance = (seed / 1000 - 0.5) * config.chain_angle_variance
          distance_variance = (seed / 1000 - 0.5) * config.chain_distance_variance

          final_angle = base_angle + angle_variance

          orbit_distance =
            config.l2_orbit_min +
              (config.l2_orbit_max - config.l2_orbit_min) * (seed / 1000) +
              distance_variance

          chain_x = parent_x + orbit_distance * :math.cos(final_angle)
          chain_y = parent_y + orbit_distance * :math.sin(final_angle)

          chain_radius = calculate_chain_radius_from_config(topology, length(chain_connections))

          chain_data =
            build_chain_node(
              chain_name,
              chain_connections,
              chain_x,
              chain_y,
              chain_radius,
              TopologyConfig.provider_orbit_for_radius(chain_radius),
              config.provider_radius
            )

          # Store parent info for connection line drawing
          chain_data = Map.put(chain_data, :parent, parent_name)

          Map.put(inner_acc, chain_name, chain_data)
        end)
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

        topology = get_chain_topology(chain_name, all_chain_configs)
        chain_radius = calculate_chain_radius_from_config(topology, length(chain_connections))

        chain_data =
          build_chain_node(
            chain_name,
            chain_connections,
            chain_x,
            chain_y,
            chain_radius,
            TopologyConfig.provider_orbit_for_radius(chain_radius),
            config.provider_radius
          )

        Map.put(acc, chain_name, chain_data)
      end)

    positioned
  end

  # Calculate chain radius from topology config, with fallback to provider count
  defp calculate_chain_radius_from_config(nil, provider_count) do
    TopologyConfig.chain_radius(nil, provider_count)
  end

  defp calculate_chain_radius_from_config(%{size: size}, provider_count) do
    TopologyConfig.chain_radius(size, provider_count)
  end

  # Build a chain node with its orbiting providers
  defp build_chain_node(
         _chain_name,
         chain_connections,
         x,
         y,
         chain_radius,
         provider_orbit,
         provider_radius
       ) do
    provider_count = length(chain_connections)

    # Provider orbit is already adjusted for size via TopologyConfig.provider_orbit_for_size
    adjusted_provider_orbit = provider_orbit

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

        # Add controlled randomness for organic look (configurable in TopologyConfig)
        seed = :erlang.phash2(connection.id, 1000)
        angle_variance = (seed / 1000 - 0.5) * TopologyConfig.provider_angle_variance()
        radius_variance = (seed / 1000 - 0.5) * TopologyConfig.provider_distance_variance()

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

  # Use centralized StatusHelpers for all provider status colors
  alias LassoWeb.Dashboard.StatusHelpers

  defp provider_line_color(connection) do
    connection
    |> StatusHelpers.determine_provider_status()
    |> StatusHelpers.status_color_scheme()
    |> Map.get(:hex)
  end

  defp extract_chain_from_connection(connection) do
    Map.get(connection, :chain, "unknown")
  end

  defp provider_status_bg_class(connection) when is_map(connection) do
    connection
    |> StatusHelpers.determine_provider_status()
    |> StatusHelpers.status_color_scheme()
    |> Map.get(:bg_muted)
  end

  defp provider_border_class(connection) do
    connection
    |> StatusHelpers.determine_provider_status()
    |> StatusHelpers.status_color_scheme()
    |> Map.get(:border)
  end

  defp provider_status_dot_class(connection) do
    connection
    |> StatusHelpers.determine_provider_status()
    |> StatusHelpers.status_color_scheme()
    |> Map.get(:dot)
  end

  # Helper to check if a provider supports WebSocket connections
  defp has_websocket_support?(connection) do
    # Check if the connection has WebSocket support based on type or ws_url
    case Map.get(connection, :type) do
      :websocket ->
        true

      :both ->
        true

      :http ->
        false

      _ ->
        # Fallback: check if ws_url is present and not nil
        ws_url = Map.get(connection, :ws_url)
        is_binary(ws_url) and String.length(ws_url) > 0
    end
  end

  # Get chain color from topology config, with fallback to defaults
  defp chain_color(chain_name) do
    topology = get_chain_topology_from_config(chain_name)
    TopologyConfig.chain_color(topology, chain_name)
  end

  # Lookup chain topology from ConfigStore
  defp get_chain_topology_from_config(chain_name) do
    all_chain_configs = ConfigStore.get_all_chains()
    get_chain_topology(chain_name, all_chain_configs)
  end
end
