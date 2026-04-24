defmodule LassoWeb.NetworkTopology do
  @moduledoc """
  Network topology visualization component for RPC providers.

  Displays chains and their providers in a golden-angle spiral layout for organic,
  gap-free spacing at any node count. Chains are sorted by importance (provider count
  and configured size) with the most significant chains placed near center.

  Topology data is pre-computed via `compute_topology_data/3` and passed to
  `nodes_display/1` as a stable assign, keeping the render path zero-cost.
  """
  use Phoenix.Component

  alias Lasso.Config.ConfigStore
  alias LassoWeb.Dashboard.StatusHelpers
  alias LassoWeb.TopologyConfig

  def compute_topology_data(connections, profile) do
    layout = calculate_spiral_layout(connections, profile)
    profile_chains = get_profile_chain_configs(profile)

    chains =
      Map.new(layout.chains, fn {chain_name, chain_data} ->
        providers =
          Enum.map(chain_data.providers, fn {connection, provider_data} ->
            {sx, sy, ex, ey} =
              calculate_connection_line(
                chain_data.position,
                provider_data.position,
                chain_data.radius,
                provider_data.radius
              )

            %{
              id: connection.id,
              name: connection.name,
              position: provider_data.position,
              radius: provider_data.radius,
              line_start_x: sx,
              line_start_y: sy,
              line_end_x: ex,
              line_end_y: ey,
              has_ws: has_websocket_support?(connection)
            }
          end)

        logo = TopologyConfig.chain_logo(chain_name)

        {chain_name,
         %{
           position: chain_data.position,
           radius: chain_data.radius,
           display_name: get_chain_display_name(chain_name, profile_chains),
           chain_id_display: get_chain_id_display(chain_name, profile_chains),
           color: chain_color(chain_name, profile_chains),
           provider_count: length(providers),
           logo: logo,
           providers: providers
         }}
      end)

    %{chains: chains}
  end

  def compute_provider_statuses(connections, cluster_circuit_states) do
    merged = merge_worst_case_circuit_states(connections, cluster_circuit_states)

    Map.new(merged, fn connection ->
      {connection.id, StatusHelpers.determine_provider_status(connection)}
    end)
  end

  attr(:id, :string, required: true)
  attr(:topology_data, :map, required: true)
  attr(:selected_chain, :string, default: nil)
  attr(:selected_provider, :string, default: nil)
  attr(:on_chain_select, :string, default: "select_chain")
  attr(:on_provider_select, :string, default: "select_provider")
  attr(:class, :string, default: "")
  attr(:preview_mode, :boolean, default: false)

  def nodes_display(assigns) do
    ~H"""
    <div
      class={["relative h-full w-full overflow-hidden", @class]}
      id={@id}
      phx-hook="NetworkTopologyStatus"
    >
      <div
        class="relative cursor-default"
        data-network-canvas
        style="width: 4000px; height: 3000px; opacity: 0;"
        phx-click="deselect_all"
      >
        <svg class="pointer-events-none absolute inset-0 z-0 h-full w-full">
          <%= for {_chain_name, chain_data} <- @topology_data.chains do %>
            <%= for provider <- chain_data.providers do %>
              <line
                x1={provider.line_start_x}
                y1={provider.line_start_y}
                x2={provider.line_end_x}
                y2={provider.line_end_y}
                stroke="#4b5563"
                stroke-width={TopologyConfig.provider_line_width()}
                opacity={TopologyConfig.provider_line_opacity()}
                data-provider-line={provider.id}
              />
            <% end %>
          <% end %>
        </svg>

        <%= for {chain_name, chain_data} <- @topology_data.chains do %>
          <% {x, y} = chain_data.position %>
          <% radius = chain_data.radius %>
          <% selected = @selected_chain == chain_name and not @preview_mode %>
          <button
            type="button"
            class={[
              "absolute z-10 -translate-x-1/2 -translate-y-1/2",
              "flex items-center justify-center rounded-full border-[3px] border-gray-700/80 transition-[transform,box-shadow,ring-color] duration-200",
              if(@preview_mode,
                do: "cursor-default opacity-60",
                else: "cursor-pointer hover:scale-105"
              ),
              if(selected,
                do: "ring-2 ring-white/20",
                else: nil
              )
            ]}
            style={"left: #{x}px; top: #{y}px; width: #{radius * 2}px; height: #{radius * 2}px; background: linear-gradient(145deg, #{chain_data.color}dd 0%, #1a2332 100%); " <>
              if(selected, do: "box-shadow: 0 0 20px #{chain_data.color}50;", else: "box-shadow: 0 0 10px #{chain_data.color}20;")}
            phx-click={if @preview_mode, do: nil, else: @on_chain_select}
            phx-value-chain={chain_name}
            phx-value-highlight={chain_name}
            data-chain={chain_name}
            data-chain-center={"#{x},#{y}"}
          >
            <div
              class="flex flex-col items-center justify-center gap-0.5 overflow-hidden text-center"
              style={"max-width: #{radius * 1.6}px;"}
              title={"#{chain_data.display_name} (#{chain_data.chain_id_display})"}
            >
              <span class={"#{if radius < 65, do: "text-[11px]", else: "text-sm"} font-semibold leading-tight tracking-tight text-white"}>
                {chain_data.display_name}
              </span>
              <span class={"#{if radius < 65, do: "text-[9px]", else: "text-[11px]"} font-mono text-white/40"}>
                ID {chain_data.chain_id_display}
              </span>
            </div>
          </button>
        <% end %>

        <%= for {_chain_name, chain_data} <- @topology_data.chains do %>
          <%= for provider <- chain_data.providers do %>
            <% {x, y} = provider.position %>
            <% radius = provider.radius %>
            <div
              class={[
                "z-5 absolute -translate-x-1/2 -translate-y-1/2",
                "flex items-center justify-center rounded-full border border-gray-600/50 transition-[transform,box-shadow,border-color] duration-150",
                if(@preview_mode,
                  do: "cursor-default opacity-60",
                  else: "cursor-pointer hover:scale-125"
                ),
                if(@selected_provider == provider.id and not @preview_mode,
                  do: "ring-1 ring-white/20 !border-white/30",
                  else: nil
                )
              ]}
              style={"left: #{x}px; top: #{y}px; width: #{radius * 2}px; height: #{radius * 2}px; background: rgba(17,24,39,0.6); backdrop-filter: blur(4px); " <>
                if(@selected_provider == provider.id and not @preview_mode,
                  do: "box-shadow: 0 0 8px rgba(255,255,255,0.15);",
                  else: "")}
              phx-click={if @preview_mode, do: nil, else: @on_provider_select}
              phx-value-provider={provider.id}
              phx-value-highlight={provider.id}
              title={provider.name}
              data-provider={provider.id}
              data-provider-center={"#{x},#{y}"}
              id={"provider-#{provider.id}"}
            >
              <div
                class="rounded-full"
                data-dot
                style={"width: #{max(4, radius - 4)}px; height: #{max(4, radius - 4)}px; background-color: #6b7280;"}
              >
              </div>
              <%= if provider.has_ws do %>
                <div
                  class="absolute -right-1 -bottom-1 flex h-3.5 w-3.5 items-center justify-center rounded-full border border-blue-500/30 bg-blue-500/20"
                  title="WebSocket"
                >
                  <div class="h-1.5 w-1.5 rounded-full bg-blue-400"></div>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Layout: Golden-Angle Spiral ──

  defp calculate_spiral_layout(connections, profile) do
    chains = group_connections_by_chain(connections)
    {center_x, center_y} = TopologyConfig.canvas_center()
    all_chain_configs = get_profile_chain_configs(profile)

    sorted_chains = order_chains_by_importance(chains, all_chain_configs)
    padding = TopologyConfig.spiral_spacing(map_size(chains))

    positioned_chains =
      sorted_chains
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {{chain_name, chain_connections}, index}, {acc, placed} ->
        topology = get_chain_topology(chain_name, all_chain_configs)
        chain_radius = calculate_chain_radius_from_config(topology, length(chain_connections))

        footprint =
          TopologyConfig.provider_orbit_for_radius(chain_radius) +
            TopologyConfig.provider_node_radius()

        {chain_x, chain_y} =
          find_non_overlapping_position(index, placed, footprint, padding)

        chain_data =
          build_chain_node(
            chain_connections,
            center_x + chain_x,
            center_y + chain_y,
            chain_radius,
            TopologyConfig.provider_orbit_for_radius(chain_radius),
            TopologyConfig.provider_node_radius()
          )

        new_placed = [{chain_x, chain_y, footprint} | placed]
        {Map.put(acc, chain_name, chain_data), new_placed}
      end)
      |> elem(0)

    centered_chains = center_layout(positioned_chains, center_x, center_y)
    %{chains: centered_chains}
  end

  defp find_non_overlapping_position(0, _placed, _footprint, _padding), do: {0.0, 0.0}

  defp find_non_overlapping_position(index, placed, footprint, padding) do
    angle = index * TopologyConfig.golden_angle()
    initial_r = :math.sqrt(index) * padding

    push_outward(angle, initial_r, placed, footprint, padding)
  end

  defp push_outward(angle, r, placed, footprint, step) do
    x = :math.cos(angle) * r
    y = :math.sin(angle) * r

    if overlaps_any?(x, y, footprint, placed) do
      push_outward(angle, r + step * 0.25, placed, footprint, step)
    else
      {x, y}
    end
  end

  defp overlaps_any?(x, y, footprint, placed) do
    Enum.any?(placed, fn {px, py, pf} ->
      dx = x - px
      dy = y - py
      min_dist = footprint + pf + 20
      dx * dx + dy * dy < min_dist * min_dist
    end)
  end

  defp order_chains_by_importance(chains, all_chain_configs) do
    size_priority = %{xl: 0, lg: 1, md: 2, sm: 3}

    chains
    |> Enum.sort_by(fn {chain_name, connections} ->
      topology = get_chain_topology(chain_name, all_chain_configs)
      size = if topology, do: Map.get(topology, :size), else: nil
      priority = Map.get(size_priority, size, 4)
      {priority, -length(connections), chain_name}
    end)
  end

  defp center_layout(positioned_chains, target_x, target_y) do
    if map_size(positioned_chains) == 0 do
      positioned_chains
    else
      {centroid_x, centroid_y} = calculate_layout_centroid(positioned_chains)
      offset_x = target_x - centroid_x
      offset_y = target_y - centroid_y

      Map.new(positioned_chains, fn {chain_name, chain_data} ->
        {cx, cy} = chain_data.position

        adjusted_providers =
          Enum.map(chain_data.providers, fn {connection, pdata} ->
            {px, py} = pdata.position
            {connection, %{pdata | position: {px + offset_x, py + offset_y}}}
          end)

        {chain_name,
         %{chain_data | position: {cx + offset_x, cy + offset_y}, providers: adjusted_providers}}
      end)
    end
  end

  defp calculate_layout_centroid(positioned_chains) do
    {sum_x, sum_y, count} =
      Enum.reduce(positioned_chains, {0, 0, 0}, fn {_, chain_data}, {ax, ay, ac} ->
        {x, y} = chain_data.position
        {ax + x, ay + y, ac + 1}
      end)

    {sum_x / count, sum_y / count}
  end

  # ── Provider Positioning ──

  defp build_chain_node(chain_connections, x, y, chain_radius, provider_orbit, provider_radius) do
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

  # ── Connection Lines ──

  defp calculate_connection_line({chain_x, chain_y}, {provider_x, provider_y}, cr, pr) do
    dx = provider_x - chain_x
    dy = provider_y - chain_y
    distance = :math.sqrt(dx * dx + dy * dy)

    if distance > 0 do
      nx = dx / distance
      ny = dy / distance
      {chain_x + nx * cr, chain_y + ny * cr, provider_x - nx * pr, provider_y - ny * pr}
    else
      {chain_x, chain_y, provider_x, provider_y}
    end
  end

  # ── Data Helpers ──

  defp group_connections_by_chain(connections) do
    Enum.group_by(connections, &Map.get(&1, :chain, "unknown"))
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

  defp has_websocket_support?(%{type: type}) when type in [:websocket, :both], do: true
  defp has_websocket_support?(%{type: :http}), do: false
  defp has_websocket_support?(%{ws_url: ws_url}) when is_binary(ws_url) and ws_url != "", do: true
  defp has_websocket_support?(_), do: false

  # ── Circuit State Merging ──

  defp merge_worst_case_circuit_states(connections, cluster_circuit_states)
       when map_size(cluster_circuit_states) == 0 do
    connections
  end

  defp merge_worst_case_circuit_states(connections, cluster_circuit_states) do
    Enum.map(connections, fn conn ->
      provider_id = conn.id

      provider_circuits =
        cluster_circuit_states
        |> Enum.filter(fn {{pid, _region}, _circuit} -> pid == provider_id end)
        |> Enum.map(fn {{_pid, _region}, circuit} -> circuit end)

      if provider_circuits == [] do
        conn
      else
        http_worst = worst_circuit_state_from_list(provider_circuits, :http)
        ws_worst = worst_circuit_state_from_list(provider_circuits, :ws)
        overall_worst = worst_of_two_states(http_worst, ws_worst)

        conn
        |> Map.put(:circuit_state, overall_worst)
        |> Map.put(:http_circuit_state, http_worst)
        |> Map.put(:ws_circuit_state, ws_worst)
      end
    end)
  end

  defp worst_circuit_state_from_list(circuits, transport) do
    circuits
    |> Enum.map(&Map.get(&1, transport, :closed))
    |> Enum.reduce(:closed, &worst_of_two_states/2)
  end

  defp worst_of_two_states(a, b) do
    priority = %{open: 1, half_open: 2, closed: 3}
    if Map.get(priority, a, 3) < Map.get(priority, b, 3), do: a, else: b
  end
end
