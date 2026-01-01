defmodule LassoWeb.TopologyConfig do
  @moduledoc """
  Centralized configuration for the network topology visualization.

  All layout constants and sizing rules are defined here for easy tweaking.
  Chain-specific metadata (category, parent, color) comes from chains.yml topology config.
  """

  alias Lasso.Config.ChainConfig.Topology

  # ===========================================================================
  # Layout Constants - Adjust these to change the overall topology appearance
  # ===========================================================================

  @doc """
  Canvas dimensions for the topology view.
  """
  def canvas_width, do: 4000
  def canvas_height, do: 3000
  def canvas_center, do: {div(canvas_width(), 2), div(canvas_height(), 2)}

  @doc """
  Provider orbital configuration.
  Controls how provider nodes are positioned around chain nodes.
  """
  # Gap between chain edge and provider orbit (providers orbit at chain_radius + this gap)
  def provider_orbit_gap, do: 40

  # Provider node radius (size of the provider dots)
  def provider_node_radius, do: 13

  # Angular variance for organic look (radians, ~22.5 degrees)
  def provider_angle_variance, do: :math.pi() / 13

  # Distance variance for organic look (pixels)
  def provider_distance_variance, do: 15

  @doc """
  Chain orbital configuration.
  Controls how L2 chains orbit around their parent L1.
  """
  # Minimum orbit distance for L2 chains from parent
  def l2_orbit_min, do: 290

  # Maximum orbit distance for L2 chains from parent
  def l2_orbit_max, do: 340

  # Orbit distance for non-connected chains (other L1s, sidechains)
  def other_chain_orbit, do: 280

  # Angular variance for chain positions (radians, ~45 degrees)
  def chain_angle_variance, do: :math.pi() / 4

  # Distance variance for chain positions (pixels)
  def chain_distance_variance, do: 25

  @doc """
  L1 chain positioning configuration.
  Controls how multiple L1 chains are spread around the canvas center.
  """
  # Distance from center for spreading multiple L1s
  def l1_spread_distance, do: -280

  # Base angular offset for L2 chains (radians, ~-30 degrees from vertical)
  # This prevents single L2s from always pointing straight up
  def l2_base_angle_offset, do: -:math.pi() / 6

  @doc """
  Full angular spread for orbital distribution (2*pi = full circle).
  """
  def angle_spread, do: 2 * :math.pi()

  # ===========================================================================
  # Size Configuration - Maps topology size to actual pixel radii
  # ===========================================================================

  @doc """
  Get the chain node radius based on topology size config.
  Sizes are generous enough to fit typical chain names with CSS truncation.
  """
  def chain_radius(:xl, _provider_count), do: 90
  def chain_radius(:lg, _provider_count), do: 75
  def chain_radius(:md, _provider_count), do: 60
  def chain_radius(:sm, _provider_count), do: 50
  def chain_radius(nil, _provider_count), do: 55

  @doc """
  Get provider orbit distance from chain center.
  Derived from chain radius + gap (providers orbit just outside the chain edge).
  """
  def provider_orbit_for_radius(chain_radius), do: chain_radius + provider_orbit_gap()

  # ===========================================================================
  # Color Configuration
  # ===========================================================================

  # Default fallback color for chains without topology config
  @default_chain_color "#6B7280"

  @doc """
  Get chain color from topology config.
  Chain colors are defined in chains.yml topology config.
  Falls back to a neutral gray for unconfigured chains.
  """
  def chain_color(%Topology{color: color}, _chain_name) when is_binary(color) and color != "",
    do: color

  def chain_color(_topology, _chain_name), do: @default_chain_color

  # ===========================================================================
  # Connection Line Configuration
  # ===========================================================================

  @doc """
  L1 to L2 connection line style.
  """
  def l1_l2_line_color, do: "#8B5CF6"
  def l1_l2_line_width, do: 1
  def l1_l2_line_opacity, do: 0.3
  def l1_l2_line_dash, do: "2,2"

  @doc """
  Provider connection line width.
  """
  def provider_line_width, do: 2
  def provider_line_opacity, do: 0.6
end
