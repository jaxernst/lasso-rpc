defmodule LassoWeb.TopologyConfig do
  @moduledoc """
  Centralized configuration for the network topology visualization.

  All layout constants and sizing rules are defined here for easy tweaking.
  Uses a hexagonal packing layout with dynamic spacing based on chain count.
  Chain-specific metadata (color, size) comes from profile chain `ui-topology` config.
  """

  alias Lasso.Config.ChainConfig.Topology

  # ===========================================================================
  # Canvas Configuration
  # ===========================================================================

  def canvas_width, do: 4000
  def canvas_height, do: 3000
  def canvas_center, do: {div(canvas_width() - 100, 2), div(canvas_height(), 2)}

  # ===========================================================================
  # Provider Orbital Configuration
  # ===========================================================================

  def provider_orbit_gap, do: 40
  def provider_node_radius, do: 13
  def provider_angle_variance, do: :math.pi() / 13
  def provider_distance_variance, do: 15

  # ===========================================================================
  # Hexagonal Layout Configuration
  # ===========================================================================

  def hex_spacing(_chain_count), do: 225

  # ===========================================================================
  # Chain Size Configuration
  # ===========================================================================

  def chain_radius(:xl, _provider_count), do: 100
  def chain_radius(:lg, _provider_count), do: 87
  def chain_radius(:md, _provider_count), do: 73
  def chain_radius(:sm, _provider_count), do: 65
  def chain_radius(nil, _provider_count), do: 59

  def provider_orbit_for_radius(chain_radius), do: chain_radius + provider_orbit_gap()

  # ===========================================================================
  # Color Configuration
  # ===========================================================================

  @default_chain_color "#6B7280"

  def chain_color(%Topology{color: color}, _chain_name) when is_binary(color) and color != "",
    do: color

  def chain_color(_topology, _chain_name), do: @default_chain_color

  # ===========================================================================
  # Provider Connection Line Configuration
  # ===========================================================================

  def provider_line_width, do: 2
  def provider_line_opacity, do: 0.6
end
