defmodule LassoWeb.NetworkTopology do
  @moduledoc """
  Network topology visualization component for RPC providers.

  Displays chains and their providers in a hexagonal packed layout for even
  spacing and visual consistency. Chains are positioned in a spiral pattern
  starting from the center, with providers orbiting each chain node.
  """
  use Phoenix.Component

  alias Lasso.Config.ConfigStore
  alias LassoWeb.Dashboard.StatusHelpers
  alias LassoWeb.TopologyConfig

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
    profile = assigns[:selected_profile] || "default"

    assigns =
      assigns
      |> assign(:chains, group_connections_by_chain(assigns.connections))
      |> assign(:hex_layout, calculate_hexagonal_layout(assigns.connections, profile))
      |> assign(:profile_chains, get_profile_chain_configs(profile))

    ~H"""
    <div class={["relative h-full w-full overflow-hidden", @class]}>
      <!-- Hexagonal packed network layout -->
      <div
        class="relative cursor-default"
        data-network-canvas
        style="width: 4000px; height: 3000px;"
        phx-click="deselect_all"
      >
        <!-- Provider connection lines -->
        <%= for {chain_name, chain_data} <- @hex_layout.chains do %>
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
                stroke-width={TopologyConfig.provider_line_width()}
                opacity={TopologyConfig.provider_line_opacity()}
              />
            </svg>
          <% end %>
        <% end %>
        
    <!-- Chain nodes -->
        <%= for {chain_name, chain_data} <- @hex_layout.chains do %>
          <% {x, y} = chain_data.position %>
          <% radius = chain_data.radius %>
          <div
            class={[
              "absolute z-10 -translate-x-1/2 -translate-y-1/2 transform",
              "flex cursor-pointer items-center justify-center rounded-full border-2 bg-gradient-to-br shadow-xl transition-transform duration-200 hover:scale-110",
              if(@selected_chain == chain_name,
                do: "ring-purple-400/30 border-purple-400 ring-4",
                else: "border-gray-500 hover:border-gray-400"
              ),
              "from-gray-800 to-gray-900"
            ]}
            style={"left: #{x}px; top: #{y}px; width: #{radius * 2}px; height: #{radius * 2}px; background: linear-gradient(135deg, #{chain_color(chain_name, @profile_chains)} 0%, #111827 100%); " <>
              if(@selected_chain == chain_name,
                do: "box-shadow: 0 0 15px rgba(139, 92, 246, 0.4), inset 0 0 15px rgba(0, 0, 0, 0.3);",
                else: "box-shadow: 0 0 8px rgba(139, 92, 246, 0.2), inset 0 0 15px rgba(0, 0, 0, 0.3);")}
            phx-click={@on_chain_select}
            phx-value-chain={chain_name}
            phx-value-highlight={chain_name}
            data-chain={chain_name}
            data-chain-center={"#{x},#{y}"}
          >
            <div
              class="flex flex-col items-center justify-center overflow-hidden px-1 text-center"
              style={"max-width: #{radius * 1.7}px;"}
              title={"#{get_chain_display_name(chain_name, @profile_chains)} (#{get_chain_id_display(chain_name, @profile_chains)})"}
            >
              <div class={"#{if radius < 55, do: "text-xs", else: "text-sm"} w-full truncate font-semibold text-white"}>
                {get_chain_display_name(chain_name, @profile_chains)}
              </div>
              <div class={"#{if radius < 55, do: "text-[10px]", else: "text-xs"} text-gray-400"}>
                {get_chain_id_display(chain_name, @profile_chains)}
              </div>
            </div>
          </div>
        <% end %>
        
    <!-- Provider nodes -->
        <%= for {chain_name, chain_data} <- @hex_layout.chains do %>
          <%= for {connection, provider_data} <- chain_data.providers do %>
            <% {x, y} = provider_data.position %>
            <% radius = provider_data.radius %>
            <div
              class={[
                "z-5 absolute -translate-x-1/2 -translate-y-1/2 transform",
                "flex cursor-pointer items-center justify-center rounded-full border-2 transition-transform duration-150 hover:scale-125",
                if(@selected_provider == connection.id,
                  do: "ring-purple-400/30 !border-purple-400 ring-2",
                  else: provider_border_class(connection)
                ),
                if(@selected_provider != connection.id,
                  do: provider_status_bg_class(connection)
                )
              ]}
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

  defp generate_hex_spiral_coordinates(1), do: [{0, 0}]

  defp generate_hex_spiral_coordinates(count) when count > 1 do
    rings_needed = calculate_rings_needed(count - 1)

    ring_coords = Enum.flat_map(1..rings_needed, &generate_ring_coordinates/1)
    Enum.take([{0, 0} | ring_coords], count)
  end

  defp generate_ring_coordinates(ring) do
    directions = [{1, 0}, {0, 1}, {-1, 1}, {-1, 0}, {0, -1}, {1, -1}]
    start_pos = {0, -ring}

    for {dq, dr} <- directions,
        _step <- 1..ring,
        reduce: {start_pos, []} do
      {{q, r}, coords} ->
        {
          {q + dq, r + dr},
          coords ++ [{q, r}]
        }
    end
    |> elem(1)
  end

  defp calculate_rings_needed(remaining) when remaining <= 0, do: 0

  defp calculate_rings_needed(remaining) do
    calculate_rings_needed(remaining, 1)
  end

  defp calculate_rings_needed(remaining, ring) when remaining <= 0, do: ring - 1

  defp calculate_rings_needed(remaining, ring) do
    hexes_in_ring = 6 * ring
    calculate_rings_needed(remaining - hexes_in_ring, ring + 1)
  end

  defp axial_to_pixel(q, r, spacing) do
    x = spacing * (3.0 / 2.0 * q)
    y = spacing * (:math.sqrt(3.0) * r + :math.sqrt(3.0) / 2.0 * q)
    {x, y}
  end

  defp order_chains_for_hex_layout(chains) do
    chains
    |> Map.keys()
    |> Enum.sort_by(&:erlang.phash2/1)
  end

  defp group_connections_by_chain(connections) do
    connections
    |> Enum.group_by(&extract_chain_from_connection(&1))
  end

  defp calculate_hexagonal_layout(connections, profile) do
    chains = group_connections_by_chain(connections)
    {center_x, center_y} = TopologyConfig.canvas_center()

    all_chain_configs = get_profile_chain_configs(profile)
    chain_names = order_chains_for_hex_layout(chains)

    hex_coords = generate_hex_spiral_coordinates(length(chain_names))
    spacing = TopologyConfig.hex_spacing(map_size(chains))

    positioned_chains =
      chain_names
      |> Enum.zip(hex_coords)
      |> Enum.reduce(%{}, fn {chain_name, {q, r}}, acc ->
        chain_connections = Map.get(chains, chain_name)

        {hex_x, hex_y} = axial_to_pixel(q, r, spacing)
        chain_x = center_x + hex_x
        chain_y = center_y + hex_y

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
            TopologyConfig.provider_node_radius()
          )

        Map.put(acc, chain_name, chain_data)
      end)

    # Calculate centroid of all chain positions and center the layout
    {centroid_x, centroid_y} = calculate_layout_centroid(positioned_chains)
    offset_x = center_x - centroid_x
    offset_y = center_y - centroid_y

    # Apply offset to all chain and provider positions
    centered_chains =
      positioned_chains
      |> Enum.map(fn {chain_name, chain_data} ->
        {chain_x, chain_y} = chain_data.position
        adjusted_chain_x = chain_x + offset_x
        adjusted_chain_y = chain_y + offset_y

        # Adjust provider positions relative to the chain
        adjusted_providers =
          Enum.map(chain_data.providers, fn {connection, provider_data} ->
            {provider_x, provider_y} = provider_data.position
            adjusted_provider_x = provider_x + offset_x
            adjusted_provider_y = provider_y + offset_y

            {connection,
             Map.put(provider_data, :position, {adjusted_provider_x, adjusted_provider_y})}
          end)

        adjusted_chain_data =
          chain_data
          |> Map.put(:position, {adjusted_chain_x, adjusted_chain_y})
          |> Map.put(:providers, adjusted_providers)

        {chain_name, adjusted_chain_data}
      end)
      |> Enum.into(%{})

    %{chains: centered_chains}
  end

  defp calculate_layout_centroid(positioned_chains) do
    if map_size(positioned_chains) == 0 do
      {0, 0}
    else
      {sum_x, sum_y, count} =
        positioned_chains
        |> Enum.reduce({0, 0, 0}, fn {_chain_name, chain_data}, {acc_x, acc_y, acc_count} ->
          {x, y} = chain_data.position
          {acc_x + x, acc_y + y, acc_count + 1}
        end)

      {sum_x / count, sum_y / count}
    end
  end

  defp get_profile_chain_configs(profile) do
    case ConfigStore.get_profile_chains(profile) do
      {:ok, chains} -> chains
      {:error, :not_found} -> %{}
    end
  end

  defp get_chain_topology(chain_name, all_chain_configs) do
    case Map.get(all_chain_configs, chain_name) do
      %{topology: topology} when not is_nil(topology) -> topology
      _ -> nil
    end
  end

  defp calculate_chain_radius_from_config(topology, provider_count) do
    size = if topology, do: Map.get(topology, :size), else: nil
    TopologyConfig.chain_radius(size, provider_count)
  end

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

    providers =
      chain_connections
      |> Enum.with_index()
      |> Enum.map(fn {connection, provider_index} ->
        base_angle = calculate_provider_base_angle(provider_count, provider_index, connection.id)

        seed = :erlang.phash2(connection.id, 1000)
        variance_factor = seed / 1000 - 0.5
        angle_variance = variance_factor * TopologyConfig.provider_angle_variance()
        radius_variance = variance_factor * TopologyConfig.provider_distance_variance()

        final_angle = base_angle + angle_variance
        final_radius = provider_orbit + radius_variance

        provider_x = x + final_radius * :math.cos(final_angle)
        provider_y = y + final_radius * :math.sin(final_angle)

        {connection, %{position: {provider_x, provider_y}, radius: provider_radius}}
      end)

    %{position: {x, y}, radius: chain_radius, providers: providers}
  end

  defp calculate_provider_base_angle(1, _index, connection_id) do
    seed = :erlang.phash2(connection_id, 1000)
    seed / 1000 * 2 * :math.pi()
  end

  defp calculate_provider_base_angle(2, 0, _connection_id), do: 0
  defp calculate_provider_base_angle(2, 1, _connection_id), do: :math.pi()

  defp calculate_provider_base_angle(count, index, _connection_id) do
    2 * :math.pi() * index / count - :math.pi() / 2
  end

  defp calculate_connection_line_with_variance(
         {chain_x, chain_y},
         {provider_x, provider_y},
         chain_radius,
         provider_radius,
         _seed_key
       ) do
    dx = provider_x - chain_x
    dy = provider_y - chain_y
    distance = :math.sqrt(dx * dx + dy * dy)

    if distance > 0 do
      norm_dx = dx / distance
      norm_dy = dy / distance

      start_x = chain_x + norm_dx * chain_radius
      start_y = chain_y + norm_dy * chain_radius
      end_x = provider_x - norm_dx * provider_radius
      end_y = provider_y - norm_dy * provider_radius

      {start_x, start_y, end_x, end_y}
    else
      {chain_x, chain_y, provider_x, provider_y}
    end
  end

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

  defp has_websocket_support?(%{type: type}) when type in [:websocket, :both], do: true
  defp has_websocket_support?(%{type: :http}), do: false
  defp has_websocket_support?(%{ws_url: ws_url}) when is_binary(ws_url) and ws_url != "", do: true
  defp has_websocket_support?(_), do: false

  defp chain_color(chain_name, profile_chains) do
    topology = get_chain_topology(chain_name, profile_chains)
    TopologyConfig.chain_color(topology, chain_name)
  end

  defp get_chain_display_name(chain_name, profile_chains) do
    case Map.get(profile_chains, chain_name) do
      %{name: display_name} when is_binary(display_name) ->
        display_name

      _ ->
        chain_name
        |> String.replace("_", " ")
        |> String.split(" ")
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp get_chain_id_display(chain_name, profile_chains) do
    case Map.get(profile_chains, chain_name) do
      %{chain_id: chain_id} when is_integer(chain_id) ->
        Integer.to_string(chain_id)

      _ ->
        chain_name
    end
  end
end
