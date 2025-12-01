defmodule LassoWeb.Components.LandingHeroGraphic do
  use Phoenix.Component

  @doc """
  An abstract, artistic visualization showing Lasso routing requests
  in a hierarchical, orbital layout.
  """

  attr(:routing_decisions, :list, required: true)
  attr(:is_live, :boolean, default: false)

  def graphic(assigns) do
    # Large scale for "oversized" effect, centered at 400,400
    cx = 400
    cy = 400
    chain_radius = 260
    provider_radius = 420

    # Define Lasso Hubs (Mesh Core)
    # Increased radius to 90 to separate them further
    hubs = [
      %{id: "h1", angle: 90, r: 90, size: 32},
      %{id: "h2", angle: 210, r: 90, size: 32},
      %{id: "h3", angle: 330, r: 90, size: 32}
    ]

    # Define Chains (Inner Orbit)
    chains = [
      %{id: "c1", angle: 30, r: chain_radius, size: 24, delay: 0, hub_id: "h3"},
      %{id: "c2", angle: 150, r: chain_radius, size: 24, delay: 1.2, hub_id: "h1"},
      %{id: "c3", angle: 270, r: chain_radius, size: 24, delay: 2.4, hub_id: "h2"},
      %{id: "c4", angle: 90, r: chain_radius, size: 22, delay: 1.8, hub_id: "h1"},
      %{id: "c5", angle: 210, r: chain_radius, size: 22, delay: 0.6, hub_id: "h2"}
    ]

    # Define Providers (Outer Orbit)
    providers = [
      %{id: "p1-1", parent_id: "c1", angle: 15, r: provider_radius, size: 12, delay: 0.5},
      %{id: "p1-2", parent_id: "c1", angle: 45, r: provider_radius, size: 12, delay: 0.8},
      %{id: "p2-1", parent_id: "c2", angle: 135, r: provider_radius, size: 12, delay: 1.7},
      %{id: "p2-2", parent_id: "c2", angle: 165, r: provider_radius, size: 12, delay: 2.0},
      %{id: "p3-1", parent_id: "c3", angle: 255, r: provider_radius, size: 12, delay: 2.9},
      %{id: "p3-2", parent_id: "c3", angle: 285, r: provider_radius, size: 12, delay: 3.2},
      # Extra distributed nodes
      %{id: "p4-1", parent_id: "c4", angle: 80, r: provider_radius, size: 10, delay: 2.1},
      %{id: "p4-2", parent_id: "c4", angle: 100, r: provider_radius, size: 10, delay: 2.4},
      %{id: "p5-1", parent_id: "c5", angle: 200, r: provider_radius, size: 10, delay: 0.9},
      %{id: "p5-2", parent_id: "c5", angle: 220, r: provider_radius, size: 10, delay: 1.2}
    ]

    # Calculate coordinates
    hubs =
      Enum.map(hubs, fn h ->
        {x, y} = polar_to_cart(cx, cy, h.r, h.angle)
        Map.merge(h, %{x: x, y: y})
      end)

    chains =
      Enum.map(chains, fn c ->
        {x, y} = polar_to_cart(cx, cy, c.r, c.angle)
        hub = Enum.find(hubs, fn h -> h.id == c.hub_id end)
        Map.merge(c, %{x: x, y: y, hub_x: hub.x, hub_y: hub.y})
      end)

    providers =
      Enum.map(providers, fn p ->
        {x, y} = polar_to_cart(cx, cy, p.r, p.angle)
        parent = Enum.find(chains, fn c -> c.id == p.parent_id end)
        Map.merge(p, %{x: x, y: y, parent_x: parent.x, parent_y: parent.y})
      end)

    # Mesh connections between hubs
    hub_connections = [
      {Enum.at(hubs, 0), Enum.at(hubs, 1)},
      {Enum.at(hubs, 1), Enum.at(hubs, 2)},
      {Enum.at(hubs, 2), Enum.at(hubs, 0)}
    ]

    assigns =
      assigns
      |> assign(:hubs, hubs)
      |> assign(:hub_connections, hub_connections)
      |> assign(:chains, chains)
      |> assign(:providers, providers)
      |> assign(:cx, cx)
      |> assign(:cy, cy)
      |> assign(:chain_radius, chain_radius)
      |> assign(:provider_radius, provider_radius)

    ~H"""
    <div
      class="w-[120%] translate-x-[10%] absolute top-1/2 right-0 max-w-none -translate-y-1/2 transform md:w-[100%] lg:w-[110%] lg:translate-x-[5%]"
      style="mask-image: radial-gradient(circle at 50% 50%, black 40%, transparent 85%); -webkit-mask-image: radial-gradient(circle at 50% 50%, black 40%, transparent 85%);"
    >
      <svg
        class="h-auto w-full overflow-visible"
        viewBox="0 0 800 800"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <radialGradient id="node-grad" cx="30%" cy="30%">
            <stop offset="0%" stop-color="#334155" />
            <stop offset="100%" stop-color="#1e293b" />
          </radialGradient>
          <radialGradient id="hub-grad" cx="30%" cy="30%">
            <stop offset="0%" stop-color="#7c3aed" />
            <stop offset="100%" stop-color="#4c1d95" />
          </radialGradient>
          <filter id="blur-sm" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="2" />
          </filter>
        </defs>
        
    <!-- Orbit Rings -->
        <circle
          cx={@cx}
          cy={@cy}
          r={@chain_radius}
          stroke="#334155"
          stroke-width="1"
          stroke-dasharray="8 8"
          opacity="0.15"
        />
        <circle
          cx={@cx}
          cy={@cy}
          r={@provider_radius}
          stroke="#334155"
          stroke-width="1"
          stroke-dasharray="8 8"
          opacity="0.1"
        />
        
    <!-- Hub Mesh Connections (Geometric Triangle) -->
        <path
          d={"M #{Enum.at(@hubs, 0).x} #{Enum.at(@hubs, 0).y} L #{Enum.at(@hubs, 1).x} #{Enum.at(@hubs, 1).y} L #{Enum.at(@hubs, 2).x} #{Enum.at(@hubs, 2).y} Z"}
          stroke="#7c3aed"
          stroke-width="1"
          fill="#7c3aed"
          fill-opacity="0.05"
          opacity="0.4"
        />
        
    <!-- Connections: Hubs -> Chains -->
        <%= for chain <- @chains do %>
          <path
            d={"M #{chain.hub_x} #{chain.hub_y} L #{chain.x} #{chain.y}"}
            stroke="#334155"
            stroke-width="1"
            opacity="0.2"
          />
        <% end %>
        
    <!-- Connections: Chains -> Providers -->
        <%= for provider <- @providers do %>
          <path
            d={"M #{provider.parent_x} #{provider.parent_y} L #{provider.x} #{provider.y}"}
            stroke="#334155"
            stroke-width="1"
            opacity="0.15"
          />
        <% end %>
        
    <!-- Traffic: Hubs -> Chains -->
        <%= for chain <- @chains do %>
          <circle r="4" fill="#a78bfa" opacity="0">
            <animateMotion
              dur="4s"
              repeatCount="indefinite"
              begin={chain.delay}
              path={"M #{chain.hub_x} #{chain.hub_y} L #{chain.x} #{chain.y}"}
              keyPoints="0;1"
              keyTimes="0;1"
              calcMode="linear"
            />
            <animate
              attributeName="opacity"
              values="0;0.8;0"
              keyTimes="0;0.5;1"
              dur="4s"
              repeatCount="indefinite"
              begin={chain.delay}
            />
          </circle>
        <% end %>
        
    <!-- Traffic: Chains -> Providers -->
        <%= for provider <- @providers do %>
          <circle r="3" fill="#818cf8" opacity="0">
            <animateMotion
              dur="4s"
              repeatCount="indefinite"
              begin={provider.delay}
              path={"M #{provider.parent_x} #{provider.parent_y} L #{provider.x} #{provider.y}"}
              keyPoints="0;1"
              keyTimes="0;1"
              calcMode="linear"
            />
            <animate
              attributeName="opacity"
              values="0;0.6;0"
              keyTimes="0;0.5;1"
              dur="4s"
              repeatCount="indefinite"
              begin={provider.delay}
            />
          </circle>
        <% end %>
        
    <!-- Chain Nodes -->
        <%= for chain <- @chains do %>
          <circle
            cx={chain.x}
            cy={chain.y}
            r={chain.size}
            fill="url(#node-grad)"
            stroke="#475569"
            stroke-width="1"
          />
          <circle
            cx={chain.x - chain.size * 0.2}
            cy={chain.y - chain.size * 0.2}
            r={chain.size * 0.3}
            fill="white"
            opacity="0.05"
          />
        <% end %>
        
    <!-- Provider Nodes -->
        <%= for provider <- @providers do %>
          <circle
            cx={provider.x}
            cy={provider.y}
            r={provider.size}
            fill="url(#node-grad)"
            stroke="#334155"
            stroke-width="1"
            opacity="0.8"
          />
        <% end %>
        
    <!-- Lasso Hub Cluster -->
        <%= for hub <- @hubs do %>
          <g transform={"translate(#{hub.x}, #{hub.y})"}>
            <circle r={hub.size + 10} fill="#8b5cf6" opacity="0.1" filter="url(#blur-sm)" />
            <circle r={hub.size} fill="url(#hub-grad)" />
            <circle r={hub.size * 0.7} fill="none" stroke="white" stroke-width="1" opacity="0.15" />
            <!-- Lightning icon -->
            <path
              d="M3 -10 L-6 3 L0 3 L-3 10 L6 -3 L0 -3 Z"
              fill="white"
              opacity="0.9"
              transform="scale(0.8)"
            />
          </g>
        <% end %>
      </svg>
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
