defmodule LassoWeb.Components.LandingHeroGraphic do
  @moduledoc "Landing page hero graphic component with animated network visualization."
  use Phoenix.Component

  @doc """
  An abstract, artistic visualization showing Lasso routing requests
  in a hierarchical, orbital layout. Designed to be oversized and bleed
  past its container with smooth fade-out edges.

  Uses data attributes for node positions so JavaScript can dynamically
  recalculate connection paths during parallax scrolling and mouse interactions.
  """

  attr(:routing_decisions, :list, required: true)
  attr(:is_live, :boolean, default: false)

  def graphic(assigns) do
    # Center shifted right for better composition with left-aligned text
    cx = 640
    cy = 540
    inner_orbit = 80
    chain_radius = 210
    provider_radius = 380
    outer_orbit = 540
    edge_orbit = 720
    far_orbit = 900

    # Define Lasso Hubs (Mesh Core) - subtle, blend with network
    # Rotated 30 degrees and pushed further right via cx offset
    hubs = [
      %{id: "h1", angle: 60, r: 60, size: 17},
      %{id: "h2", angle: 180, r: 60, size: 17},
      %{id: "h3", angle: 300, r: 60, size: 17}
    ]

    # Define Chains (Inner Orbit) - more nodes, smaller, spread out more
    # Some chains have logos (grayscale) - currently showing Ethereum and Base for visible nodes
    chains = [
      %{id: "c1", angle: 0, r: chain_radius, size: 11, delay: 0, hub_id: "h3"},
      %{id: "c2", angle: 45, r: chain_radius, size: 8, delay: 1.2, hub_id: "h3"},
      %{id: "c3", angle: 90, r: chain_radius, size: 11, delay: 0.5, hub_id: "h1"},
      %{id: "c4", angle: 135, r: chain_radius, size: 8, delay: 1.8, hub_id: "h1"},
      %{id: "c5", angle: 180, r: chain_radius, size: 11, delay: 0.8, hub_id: "h2"},
      %{id: "c6", angle: 225, r: chain_radius, size: 8, delay: 2.2, hub_id: "h2"},
      %{
        id: "c7",
        angle: 270,
        r: chain_radius,
        size: 14,
        delay: 1.0,
        hub_id: "h2",
        logo: :ethereum
      },
      %{id: "c8", angle: 315, r: chain_radius, size: 12, delay: 2.5, hub_id: "h3", logo: :base}
    ]

    # Define Providers (Outer Orbit) - smaller, more numerous
    providers = [
      %{id: "p1-1", parent_id: "c1", angle: -15, r: provider_radius, size: 7, delay: 0.2},
      %{id: "p1-2", parent_id: "c1", angle: 15, r: provider_radius, size: 6, delay: 0.5},
      %{id: "p2-1", parent_id: "c2", angle: 30, r: provider_radius, size: 6, delay: 1.5},
      %{id: "p2-2", parent_id: "c2", angle: 60, r: provider_radius, size: 7, delay: 1.8},
      %{id: "p3-1", parent_id: "c3", angle: 75, r: provider_radius, size: 7, delay: 0.8},
      %{id: "p3-2", parent_id: "c3", angle: 105, r: provider_radius, size: 6, delay: 1.1},
      %{id: "p4-1", parent_id: "c4", angle: 120, r: provider_radius, size: 6, delay: 2.1},
      %{id: "p4-2", parent_id: "c4", angle: 150, r: provider_radius, size: 7, delay: 2.4},
      %{id: "p5-1", parent_id: "c5", angle: 165, r: provider_radius, size: 7, delay: 1.1},
      %{id: "p5-2", parent_id: "c5", angle: 195, r: provider_radius, size: 6, delay: 1.4},
      %{id: "p6-1", parent_id: "c6", angle: 210, r: provider_radius, size: 6, delay: 2.5},
      %{id: "p6-2", parent_id: "c6", angle: 240, r: provider_radius, size: 7, delay: 2.8},
      %{id: "p7-1", parent_id: "c7", angle: 255, r: provider_radius, size: 7, delay: 1.3},
      %{id: "p7-2", parent_id: "c7", angle: 285, r: provider_radius, size: 6, delay: 1.6},
      %{id: "p8-1", parent_id: "c8", angle: 300, r: provider_radius, size: 6, delay: 2.8},
      %{id: "p8-2", parent_id: "c8", angle: 330, r: provider_radius, size: 7, delay: 3.1}
    ]

    # Outer edge nodes - multiple rings for depth
    edge_nodes = [
      # First outer ring
      %{id: "e1", angle: 10, r: outer_orbit, size: 7, opacity: 0.35},
      %{id: "e2", angle: 55, r: outer_orbit, size: 6, opacity: 0.3},
      %{id: "e3", angle: 100, r: outer_orbit, size: 7, opacity: 0.35},
      %{id: "e4", angle: 145, r: outer_orbit, size: 6, opacity: 0.28},
      %{id: "e5", angle: 190, r: outer_orbit, size: 7, opacity: 0.32},
      %{id: "e6", angle: 235, r: outer_orbit, size: 6, opacity: 0.25},
      %{id: "e7", angle: 280, r: outer_orbit, size: 7, opacity: 0.3},
      %{id: "e8", angle: 325, r: outer_orbit, size: 6, opacity: 0.28},
      # Second outer ring
      %{id: "e9", angle: 25, r: edge_orbit, size: 5, opacity: 0.22},
      %{id: "e10", angle: 70, r: edge_orbit, size: 4, opacity: 0.18},
      %{id: "e11", angle: 115, r: edge_orbit, size: 5, opacity: 0.2},
      %{id: "e12", angle: 160, r: edge_orbit, size: 4, opacity: 0.16},
      %{id: "e13", angle: 205, r: edge_orbit, size: 5, opacity: 0.22},
      %{id: "e14", angle: 250, r: edge_orbit, size: 4, opacity: 0.15},
      %{id: "e15", angle: 295, r: edge_orbit, size: 5, opacity: 0.2},
      %{id: "e16", angle: 340, r: edge_orbit, size: 4, opacity: 0.18},
      # Far edge ring
      %{id: "e17", angle: 40, r: far_orbit, size: 4, opacity: 0.12},
      %{id: "e18", angle: 130, r: far_orbit, size: 3, opacity: 0.1},
      %{id: "e19", angle: 220, r: far_orbit, size: 4, opacity: 0.12},
      %{id: "e20", angle: 310, r: far_orbit, size: 3, opacity: 0.1}
    ]

    # Ambient particles (tiny dots for atmosphere)
    # Evenly distribute angles, randomize radius and other properties
    particles =
      for i <- 1..40 do
        # Evenly space angles around the circle
        base_angle = i * 9
        # Add small offset for variation
        angle_offset = rem(i * 137, 20) - 10
        angle = base_angle + angle_offset

        # Randomize radius with different seed
        seed2 = i * 3571
        r = 80 + rem(seed2, 400)

        # Tiny sizes with variation
        seed3 = i * 9281
        size = 0.5 + rem(seed3, 12) / 10

        # Very subtle opacity
        opacity = 0.06 + rem(i * 137, 12) / 100
        delay = rem(seed3, 100) / 10

        %{
          id: "particle-#{i}",
          angle: angle,
          r: r,
          size: size,
          opacity: opacity,
          delay: delay
        }
      end

    # Calculate coordinates
    hubs =
      Enum.map(hubs, fn h ->
        {x, y} = polar_to_cart(cx, cy, h.r, h.angle)
        Map.merge(h, %{x: x, y: y, layer: "core"})
      end)

    chains =
      Enum.map(chains, fn c ->
        {x, y} = polar_to_cart(cx, cy, c.r, c.angle)
        hub = Enum.find(hubs, fn h -> h.id == c.hub_id end)
        Map.merge(c, %{x: x, y: y, hub_x: hub.x, hub_y: hub.y, layer: "chains"})
      end)

    providers =
      Enum.map(providers, fn p ->
        {x, y} = polar_to_cart(cx, cy, p.r, p.angle)
        parent = Enum.find(chains, fn c -> c.id == p.parent_id end)
        Map.merge(p, %{x: x, y: y, parent_x: parent.x, parent_y: parent.y, layer: "providers"})
      end)

    edge_nodes =
      Enum.map(edge_nodes, fn e ->
        {x, y} = polar_to_cart(cx, cy, e.r, e.angle)
        Map.merge(e, %{x: x, y: y, layer: "edges"})
      end)

    particles =
      Enum.map(particles, fn p ->
        {x, y} = polar_to_cart(cx, cy, p.r, p.angle)
        Map.merge(p, %{x: x, y: y, layer: "particles"})
      end)

    # Define connection pairs for dynamic mesh
    # Hub-to-chain connections
    hub_chain_connections =
      Enum.map(chains, fn c ->
        hub = Enum.find(hubs, fn h -> h.id == c.hub_id end)

        %{
          from: hub.id,
          to: c.id,
          type: "hub-chain",
          stroke: "#475569",
          width: "0.8",
          opacity: "0.2"
        }
      end)

    # Chain-to-provider connections
    chain_provider_connections =
      Enum.map(providers, fn p ->
        %{
          from: p.parent_id,
          to: p.id,
          type: "chain-provider",
          stroke: "#334155",
          width: "0.6",
          opacity: "0.2"
        }
      end)

    # Cross-chain connections (curved through center)
    cross_chain_connections = [
      %{
        from: "c1",
        to: "c3",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c2",
        to: "c4",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c3",
        to: "c5",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c4",
        to: "c6",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c5",
        to: "c7",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c6",
        to: "c8",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c7",
        to: "c1",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      },
      %{
        from: "c8",
        to: "c2",
        type: "cross-chain",
        stroke: "#334155",
        width: "0.6",
        opacity: "0.4",
        dash: "3 2"
      }
    ]

    # Cross-provider connections (curved through center)
    cross_provider_connections = [
      %{
        from: "p1-1",
        to: "p3-1",
        type: "cross-provider",
        stroke: "#33D155",
        width: "0.3",
        opacity: "0.5",
        dash: "2 6"
      },
      %{
        from: "p2-1",
        to: "p5-1",
        type: "cross-provider",
        stroke: "#33D155",
        width: "0.3",
        opacity: "0.5",
        dash: "2 6"
      },
      %{
        from: "p4-1",
        to: "p7-1",
        type: "cross-provider",
        stroke: "#33D155",
        width: "0.3",
        opacity: "0.5",
        dash: "2 6"
      },
      %{
        from: "p6-1",
        to: "p8-1",
        type: "cross-provider",
        stroke: "#33D155",
        width: "0.3",
        opacity: "0.5",
        dash: "2 6"
      }
    ]

    # Provider-to-edge connections
    provider_edge_connections = [
      %{
        from: "p1-2",
        to: "e1",
        type: "provider-edge",
        stroke: "#334155",
        width: "0.4",
        opacity: "0.1"
      },
      %{
        from: "p3-2",
        to: "e3",
        type: "provider-edge",
        stroke: "#334155",
        width: "0.4",
        opacity: "0.1"
      },
      %{
        from: "p5-2",
        to: "e5",
        type: "provider-edge",
        stroke: "#334155",
        width: "0.4",
        opacity: "0.1"
      },
      %{
        from: "p7-2",
        to: "e7",
        type: "provider-edge",
        stroke: "#334155",
        width: "0.4",
        opacity: "0.1"
      }
    ]

    all_connections =
      hub_chain_connections ++
        chain_provider_connections ++
        cross_chain_connections ++
        cross_provider_connections ++
        provider_edge_connections

    assigns =
      assigns
      |> assign(:hubs, hubs)
      |> assign(:chains, chains)
      |> assign(:providers, providers)
      |> assign(:edge_nodes, edge_nodes)
      |> assign(:particles, particles)
      |> assign(:connections, all_connections)
      |> assign(:cx, cx)
      |> assign(:cy, cy)
      |> assign(:inner_orbit, inner_orbit)
      |> assign(:chain_radius, chain_radius)
      |> assign(:provider_radius, provider_radius)
      |> assign(:outer_orbit, outer_orbit)
      |> assign(:edge_orbit, edge_orbit)
      |> assign(:far_orbit, far_orbit)

    ~H"""
    <div class="pointer-events-none absolute inset-0 z-0 overflow-visible">
      <div
        class="h-[200%] w-[200%] absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 md:h-[180%] md:w-[180%] lg:h-[220%] lg:w-[220%] lg:-translate-x-[38%] lg:-translate-y-[48%]"
        style="mask-image: radial-gradient(ellipse 65% 65% at 50% 50%, black 15%, transparent 65%); -webkit-mask-image: radial-gradient(ellipse 65% 65% at 50% 50%, black 15%, transparent 65%);"
      >
        <svg
          id="hero-mesh-svg"
          phx-update="ignore"
          class="h-full w-full"
          viewBox="0 0 1300 1100"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          preserveAspectRatio="xMidYMid slice"
          data-mesh-cx={@cx}
          data-mesh-cy={@cy}
        >
          <defs>
            <radialGradient id="node-grad" cx="30%" cy="30%">
              <stop offset="0%" stop-color="#475569" />
              <stop offset="100%" stop-color="#1e293b" />
            </radialGradient>
            <radialGradient id="hub-grad" cx="30%" cy="30%">
              <stop offset="0%" stop-color="#a78bfa" />
              <stop offset="100%" stop-color="#7c3aed" />
            </radialGradient>
            <radialGradient id="glow-grad" cx="50%" cy="50%">
              <stop offset="0%" stop-color="#8b5cf6" stop-opacity="0.4" />
              <stop offset="40%" stop-color="#8b5cf6" stop-opacity="0.1" />
              <stop offset="100%" stop-color="#8b5cf6" stop-opacity="0" />
            </radialGradient>
            <filter id="blur-sm" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="2" />
            </filter>
            <filter id="blur-md" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="4" />
            </filter>
            <filter id="blur-lg" x="-100%" y="-100%" width="300%" height="300%">
              <feGaussianBlur stdDeviation="6" />
            </filter>
          </defs>
          
    <!-- Subtle ambient glow at center (static) -->
          <circle cx={@cx} cy={@cy} r="200" fill="url(#glow-grad)" opacity="0.3" />
          
    <!-- CONNECTION DEFINITIONS (parsed by HeroMesh JS) -->
          <g data-mesh-connection-defs="true" style="display: none;">
            <%= for conn <- @connections do %>
              <path
                data-mesh-connection={conn.type}
                data-mesh-from={conn.from}
                data-mesh-to={conn.to}
                data-mesh-connection-type={conn.type}
                stroke={conn.stroke}
                stroke-width={conn.width}
                opacity={conn.opacity}
                stroke-dasharray={Map.get(conn, :dash, "")}
              />
            <% end %>
          </g>
          
    <!-- ========== LAYER: PARTICLES (outermost - most parallax drift) ========== -->
          <g data-parallax-layer="particles" style={"transform-origin: #{@cx}px #{@cy}px"}>
            <%= for particle <- @particles do %>
              <circle
                data-mesh-node={particle.id}
                data-mesh-x={particle.x}
                data-mesh-y={particle.y}
                data-mesh-layer="particles"
                cx={particle.x}
                cy={particle.y}
                r={particle.size}
                fill="#44f44b"
                opacity={particle.opacity}
              >
                <animate
                  attributeName="opacity"
                  values={"#{particle.opacity};#{particle.opacity * 0.3};#{particle.opacity}"}
                  dur={"#{6 + particle.delay}s"}
                  repeatCount="indefinite"
                  begin={"#{particle.delay}s"}
                />
              </circle>
            <% end %>
          </g>
          
    <!-- ========== LAYER: EDGES (distant nodes - heavy parallax) ========== -->
          <g data-parallax-layer="edges" style={"transform-origin: #{@cx}px #{@cy}px"}>
            <%= for edge <- @edge_nodes do %>
              <circle
                data-mesh-node={edge.id}
                data-mesh-x={edge.x}
                data-mesh-y={edge.y}
                data-mesh-layer="edges"
                cx={edge.x}
                cy={edge.y}
                r={edge.size}
                fill="#334155"
                opacity={edge.opacity}
              />
            <% end %>
          </g>
          
    <!-- ========== LAYER: PROVIDERS (outer orbit - medium-heavy parallax) ========== -->
          <g data-parallax-layer="providers" style={"transform-origin: #{@cx}px #{@cy}px"}>
            <!-- Provider Nodes -->
            <%= for provider <- @providers do %>
              <g
                data-mesh-node={provider.id}
                data-mesh-x={provider.x}
                data-mesh-y={provider.y}
                data-mesh-layer="providers"
                data-mesh-parent={provider.parent_id}
              >
                <circle
                  cx={provider.x}
                  cy={provider.y}
                  r={provider.size + 2}
                  fill="#475569"
                  opacity="0.1"
                  filter="url(#blur-sm)"
                />
                <circle
                  cx={provider.x}
                  cy={provider.y}
                  r={provider.size}
                  fill="url(#node-grad)"
                  stroke="#475569"
                  stroke-width="0.5"
                />
              </g>
            <% end %>
          </g>
          
    <!-- ========== LAYER: CHAINS (inner orbit - light parallax) ========== -->
          <g data-parallax-layer="chains" style={"transform-origin: #{@cx}px #{@cy}px"}>
            <!-- Chain Nodes -->
            <%= for chain <- @chains do %>
              <g
                data-mesh-node={chain.id}
                data-mesh-x={chain.x}
                data-mesh-y={chain.y}
                data-mesh-layer="chains"
                data-mesh-hub={chain.hub_id}
              >
                <circle
                  cx={chain.x}
                  cy={chain.y}
                  r={chain.size + 3}
                  fill="#64748b"
                  opacity="0.12"
                  filter="url(#blur-sm)"
                />
                <circle
                  cx={chain.x}
                  cy={chain.y}
                  r={chain.size}
                  fill="url(#node-grad)"
                  stroke="#64748b"
                  stroke-width="0.8"
                />
              </g>
            <% end %>
          </g>
          
    <!-- ========== LAYER: CORE/HUBS (center - minimal/no parallax, anchor point) ========== -->
          <g data-parallax-layer="core" style={"transform-origin: #{@cx}px #{@cy}px"}>
            <!-- Hub mesh connections (subtle triangle) - static fallback -->
            <path
              id="hub-triangle"
              d={"M #{Enum.at(@hubs, 0).x} #{Enum.at(@hubs, 0).y} L #{Enum.at(@hubs, 1).x} #{Enum.at(@hubs, 1).y} L #{Enum.at(@hubs, 2).x} #{Enum.at(@hubs, 2).y} Z"}
              stroke="#a78bfa"
              stroke-width="1"
              fill="#8b5cf6"
              fill-opacity="0.04"
              opacity="0.35"
              stroke-dasharray="3 5"
            />
            <!-- Lasso Hub Cluster -->
            <%= for hub <- @hubs do %>
              <g
                data-mesh-node={hub.id}
                data-mesh-x={hub.x}
                data-mesh-y={hub.y}
                data-mesh-layer="core"
                transform={"translate(#{hub.x}, #{hub.y})"}
              >
                <!-- Very subtle glow -->
                <circle r={hub.size + 8} fill="#7c7aed" opacity=".08" filter="url(#blur-lg)" />
                <!-- Subtle pulse ring -->
                <circle
                  r={hub.size + 6}
                  fill="none"
                  stroke="#7c3aed"
                  stroke-width="0.4"
                  opacity="0.15"
                >
                  <animate
                    attributeName="r"
                    values={"#{hub.size + 3};#{hub.size + 8};#{hub.size + 3}"}
                    dur="5s"
                    repeatCount="indefinite"
                  />
                  <animate
                    attributeName="opacity"
                    values="0.15;0.03;0.15"
                    dur="5s"
                    repeatCount="indefinite"
                  />
                </circle>
                <!-- Main hub node -->
                <circle
                  r={hub.size}
                  fill="url(#node-grad)"
                  stroke="#7c3aed"
                  stroke-width="1"
                  opacity="0.9"
                />
                <!-- Lightning bolt icon -->
                <path
                  d="M1.5 -6 L-4 1.5 L0 1.5 L-1.5 6 L4 -1.5 L0 -1.5 Z"
                  fill="#a78bfa"
                  opacity="0.7"
                />
              </g>
            <% end %>
          </g>
        </svg>
      </div>
    </div>
    """
  end

  defp polar_to_cart(cx, cy, r, angle_deg) do
    rad = angle_deg * :math.pi() / 180.0

    {
      cx + r * :math.cos(rad),
      cy + r * :math.sin(rad)
    }
  end
end
