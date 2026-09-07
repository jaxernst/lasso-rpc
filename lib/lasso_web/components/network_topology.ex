defmodule LassoWeb.NetworkTopology do
  @moduledoc """
  Network topology visualization component for RPC providers.

  Each chain renders as a rectangular module and its providers attach as pins on
  the module's four edges, connected by short axis-aligned stubs. Modules grow to
  seat their pin count and are packed with a golden-angle spiral, so chains sorted
  by importance (provider count and configured size) land nearest the center.

  Topology data is pre-computed via `compute_topology_data/3` and passed to
  `nodes_display/1` as a stable assign, keeping the render path zero-cost.

  Chain identity is `chain_id` (positive integer) throughout — the
  topology data map is keyed by chain_id, `phx-value-chain` payloads
  serialize the integer, and slugs are only computed at the leaf for
  display labels via `ChainAlias`. Marks resolve from `chain_id`.
  """
  use Phoenix.Component

  alias Lasso.Config.{ChainAlias, ConfigStore}
  alias LassoWeb.Dashboard.ProviderStatusProjection
  alias LassoWeb.TopologyConfig

  def compute_topology_data(connections, profile, opts \\ []) do
    layout = calculate_module_layout(connections, profile)

    profile_chains = Keyword.get(opts, :chain_configs) || get_profile_chain_configs(profile)

    chains =
      Map.new(layout.chains, fn {chain_id, chain_data} ->
        {chain_id,
         %{
           position: chain_data.position,
           width: chain_data.width,
           height: chain_data.height,
           display_name: get_chain_display_name(chain_id, profile_chains),
           chain_id_display: Integer.to_string(chain_id),
           color: chain_color(chain_id, profile_chains),
           provider_count: length(chain_data.providers),
           logo: TopologyConfig.chain_logo(chain_id),
           providers: chain_data.providers
         }}
      end)

    %{chains: chains}
  end

  def compute_provider_statuses(connections, cluster_circuit_states, opts \\ []) do
    opts = Keyword.put(opts, :cluster_circuits, cluster_circuit_states)

    Map.new(connections, fn connection ->
      {connection.id, ProviderStatusProjection.status(connection, opts)}
    end)
  end

  attr(:id, :string, required: true)
  attr(:topology_data, :map, required: true)
  attr(:selected_chain, :integer, default: nil)
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
        class="network-canvas relative cursor-default"
        data-network-canvas
        phx-click="deselect_all"
      >
        <svg class="pointer-events-none absolute inset-0 z-0 h-full w-full">
          <%= for {_chain_id, chain_data} <- @topology_data.chains do %>
            <%= for provider <- chain_data.providers, stub <- provider.stubs do %>
              <line
                x1={stub.x1}
                y1={stub.y1}
                x2={stub.x2}
                y2={stub.y2}
                stroke={TopologyConfig.provider_line_color()}
                stroke-width={TopologyConfig.provider_line_width()}
                opacity={TopologyConfig.provider_line_opacity()}
              />
            <% end %>
          <% end %>
        </svg>

        <%= for {chain_id, chain_data} <- @topology_data.chains do %>
          <% {x, y} = chain_data.position %>
          <% selected = @selected_chain == chain_id and not @preview_mode %>
          <button
            type="button"
            id={"chain-node-#{chain_id}"}
            class={[
              "chain-module absolute z-10 -translate-x-1/2 -translate-y-1/2",
              "flex flex-col items-start justify-start overflow-hidden",
              if(@preview_mode, do: "cursor-default opacity-60", else: "cursor-pointer")
            ]}
            style={"left: #{x}px; top: #{y}px; width: #{chain_data.width}px; height: #{chain_data.height}px; " <>
              "--chain-color: #{chain_data.color};"}
            phx-click={if @preview_mode, do: nil, else: @on_chain_select}
            phx-value-chain={chain_id}
            phx-value-highlight={chain_id}
            data-chain={chain_id}
            data-chain-center={"#{x},#{y}"}
            data-selected={to_string(selected)}
            title={"#{chain_data.display_name} (#{chain_data.chain_id_display})"}
          >
            <span class="chain-module-head">
              <img
                :if={chain_data.logo}
                class="chain-module-logo"
                src={chain_data.logo}
                alt=""
                width="24"
                height="24"
              />
              <span :if={!chain_data.logo} class="chain-module-chip"></span>
              <span class="chain-module-label">
                <span class={[
                  "chain-module-name",
                  if(chain_data.height < 86, do: "text-[13px]", else: "text-[15px]")
                ]}>
                  {chain_data.display_name}
                </span>
                <span class="chain-module-id">ID {chain_data.chain_id_display}</span>
              </span>
            </span>
            <span
              class="chain-module-block"
              id={"chain-block-#{chain_id}"}
              phx-update="ignore"
              data-chain-block={chain_id}
            >
              <i class="chain-module-block-tick"></i>
              <b class="chain-module-block-height" data-block-height></b>
            </span>
          </button>
        <% end %>

        <%= for {_chain_id, chain_data} <- @topology_data.chains do %>
          <%= for provider <- chain_data.providers do %>
            <% {x, y} = provider.position %>
            <div
              class={[
                "provider-pin z-5 absolute -translate-x-1/2 -translate-y-1/2",
                if(@preview_mode,
                  do: "provider-pin-static cursor-default opacity-60",
                  else: "cursor-pointer"
                )
              ]}
              style={"left: #{x}px; top: #{y}px;"}
              phx-click={if @preview_mode, do: nil, else: @on_provider_select}
              phx-value-provider={provider.id}
              phx-value-highlight={provider.id}
              title={"#{provider.name} · #{if(provider.has_ws, do: "HTTP + WebSocket", else: "HTTP")} · Awaiting live evidence"}
              data-provider-title={
                "#{provider.name} · #{if(provider.has_ws, do: "HTTP + WebSocket", else: "HTTP")}"
              }
              data-provider={provider.id}
              data-provider-center={"#{x},#{y}"}
              data-selected={to_string(@selected_provider == provider.id and not @preview_mode)}
              data-edge={provider.edge}
              data-ws={to_string(provider.has_ws)}
              id={"provider-#{provider.id}"}
            >
              <span class="provider-pad" data-pad></span>
            </div>
          <% end %>
        <% end %>

        <div class="provider-labels-layer" data-provider-labels>
          <%= for {_chain_id, chain_data} <- @topology_data.chains do %>
            <%= for provider <- chain_data.providers do %>
              <% {px, py} = provider.position %>
              <div
                class={["provider-label", "provider-label-#{provider.edge}"]}
                data-provider-label={provider.id}
                style={"left: #{px}px; top: #{py}px;"}
              >
                {provider.name}
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Layout: Golden-Angle Spiral of Rectangular Modules ──

  defp calculate_module_layout(connections, profile) do
    chains = group_connections_by_chain(connections)
    {center_x, center_y} = TopologyConfig.canvas_center()
    all_chain_configs = get_profile_chain_configs(profile)

    sorted_chains = order_chains_by_importance(chains, all_chain_configs)
    padding = TopologyConfig.spiral_spacing(map_size(chains))

    positioned_chains =
      sorted_chains
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {{chain_id, chain_connections}, index}, {acc, placed} ->
        topology = get_chain_topology(chain_id, all_chain_configs)
        size = if topology, do: Map.get(topology, :size), else: nil
        {width, height} = TopologyConfig.module_size(size, length(chain_connections))
        footprint = TopologyConfig.module_footprint(width, height)

        {chain_x, chain_y} = find_non_overlapping_position(index, placed, footprint, padding)

        chain_data =
          build_chain_node(
            chain_connections,
            center_x + chain_x,
            center_y + chain_y,
            width,
            height
          )

        {half_w, half_h} = footprint
        {Map.put(acc, chain_id, chain_data), [{chain_x, chain_y, half_w, half_h} | placed]}
      end)
      |> elem(0)

    %{chains: center_layout(positioned_chains, center_x, center_y)}
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

  defp overlaps_any?(x, y, {half_w, half_h}, placed) do
    gap = TopologyConfig.module_gap()

    Enum.any?(placed, fn {px, py, phw, phh} ->
      abs(x - px) < half_w + phw + gap and abs(y - py) < half_h + phh + gap
    end)
  end

  defp order_chains_by_importance(chains, all_chain_configs) do
    size_priority = %{xl: 0, lg: 1, md: 2, sm: 3}

    chains
    |> Enum.sort_by(fn {chain_id, connections} ->
      topology = get_chain_topology(chain_id, all_chain_configs)
      size = if topology, do: Map.get(topology, :size), else: nil
      priority = Map.get(size_priority, size, 4)
      {priority, -length(connections), chain_id}
    end)
  end

  defp center_layout(positioned_chains, target_x, target_y) do
    if map_size(positioned_chains) == 0 do
      positioned_chains
    else
      {centroid_x, centroid_y} = calculate_layout_centroid(positioned_chains)
      offset_x = target_x - centroid_x
      offset_y = target_y - centroid_y

      Map.new(positioned_chains, fn {chain_id, chain_data} ->
        {cx, cy} = chain_data.position

        adjusted_providers =
          Enum.map(chain_data.providers, &shift_provider(&1, offset_x, offset_y))

        {chain_id,
         %{chain_data | position: {cx + offset_x, cy + offset_y}, providers: adjusted_providers}}
      end)
    end
  end

  defp shift_provider(provider, offset_x, offset_y) do
    {px, py} = provider.position

    stubs =
      Enum.map(provider.stubs, fn stub ->
        %{
          stub
          | x1: stub.x1 + offset_x,
            y1: stub.y1 + offset_y,
            x2: stub.x2 + offset_x,
            y2: stub.y2 + offset_y
        }
      end)

    %{provider | position: {px + offset_x, py + offset_y}, stubs: stubs}
  end

  defp calculate_layout_centroid(positioned_chains) do
    {sum_x, sum_y, count} =
      Enum.reduce(positioned_chains, {0, 0, 0}, fn {_, chain_data}, {ax, ay, ac} ->
        {x, y} = chain_data.position
        {ax + x, ay + y, ac + 1}
      end)

    {sum_x / count, sum_y / count}
  end

  # ── Provider Pin Placement ──

  defp build_chain_node(chain_connections, x, y, width, height) do
    edges = TopologyConfig.edge_order()
    edge_count = length(edges)

    buckets =
      chain_connections
      |> Enum.with_index()
      |> Enum.group_by(
        fn {_connection, index} -> Enum.at(edges, rem(index, edge_count)) end,
        fn {connection, _index} -> connection end
      )

    providers =
      Enum.flat_map(edges, fn edge ->
        seats = Map.get(buckets, edge, [])
        count = length(seats)

        seats
        |> Enum.with_index()
        |> Enum.map(fn {connection, seat} ->
          build_pin(connection, edge, (seat + 1) / (count + 1), x, y, width, height)
        end)
      end)

    %{position: {x, y}, width: width, height: height, providers: providers}
  end

  # Seats a provider at fraction `t` along `edge`, running its stub straight out
  # from the module boundary to the pad. `{dx, dy}` is the outward normal, so the
  # same arithmetic serves all four edges.
  defp build_pin(connection, edge, t, cx, cy, width, height) do
    half_w = width / 2
    half_h = height / 2

    {anchor_x, anchor_y, dx, dy} =
      case edge do
        :left -> {cx - half_w, cy - half_h + height * t, -1, 0}
        :right -> {cx + half_w, cy - half_h + height * t, 1, 0}
        :top -> {cx - half_w + width * t, cy - half_h, 0, -1}
        :bottom -> {cx - half_w + width * t, cy + half_h, 0, 1}
      end

    stub = TopologyConfig.pin_stub()
    pad_x = anchor_x + dx * stub
    pad_y = anchor_y + dy * stub

    # Stop the stub at the pad's inward face so the stroke never shows through it.
    tip_x = pad_x - dx * TopologyConfig.pad_size() / 2
    tip_y = pad_y - dy * TopologyConfig.pad_size() / 2

    has_ws = has_websocket_support?(connection)

    %{
      id: connection.id,
      name: connection.name,
      position: {pad_x, pad_y},
      edge: edge,
      has_ws: has_ws,
      stubs: pin_stubs(has_ws, {anchor_x, anchor_y}, {tip_x, tip_y}, {dx, dy})
    }
  end

  # A websocket-capable provider is drawn as a doubled conductor: two traces
  # offset either side of the pin axis, which reads as a second transport
  # without competing with the status colour the pad already carries. Each trace
  # names its transport so a tripped circuit can be marked on that line alone.
  defp pin_stubs(false, {ax, ay}, {tx, ty}, _normal) do
    [%{transport: :http, x1: ax, y1: ay, x2: tx, y2: ty}]
  end

  defp pin_stubs(true, {ax, ay}, {tx, ty}, {dx, dy}) do
    offset_x = dy * TopologyConfig.ws_trace_gap()
    offset_y = dx * TopologyConfig.ws_trace_gap()

    [
      %{
        transport: :http,
        x1: ax + offset_x,
        y1: ay + offset_y,
        x2: tx + offset_x,
        y2: ty + offset_y
      },
      %{
        transport: :ws,
        x1: ax - offset_x,
        y1: ay - offset_y,
        x2: tx - offset_x,
        y2: ty - offset_y
      }
    ]
  end

  # ── Data Helpers ──

  defp group_connections_by_chain(connections) do
    Enum.group_by(connections, & &1.chain_id)
  end

  defp get_profile_chain_configs(profile) do
    case ConfigStore.get_profile_chains(profile) do
      {:ok, chains} -> chains
      {:error, :not_found} -> %{}
    end
  end

  defp get_chain_topology(chain_id, all_chain_configs) do
    case Map.get(all_chain_configs, chain_id) do
      %{topology: topology} when not is_nil(topology) -> topology
      _ -> nil
    end
  end

  defp chain_color(chain_id, profile_chains) do
    topology = get_chain_topology(chain_id, profile_chains)
    TopologyConfig.chain_color(topology, ChainAlias.canonical_slug(chain_id))
  end

  defp get_chain_display_name(chain_id, profile_chains) when is_integer(chain_id) do
    case Map.get(profile_chains, chain_id) do
      %{display_name: display_name} when is_binary(display_name) and display_name != "" ->
        display_name

      cc when is_map(cc) ->
        ChainAlias.display_name(chain_id, Map.get(cc, :name))

      _ ->
        ChainAlias.display_name(chain_id, nil)
    end
  end

  defp get_chain_display_name(_, _), do: "(unknown chain)"

  defp has_websocket_support?(%{type: type}) when type in [:websocket, :both], do: true
  defp has_websocket_support?(%{type: :http}), do: false
  defp has_websocket_support?(%{ws_url: ws_url}) when is_binary(ws_url) and ws_url != "", do: true
  defp has_websocket_support?(_), do: false
end
