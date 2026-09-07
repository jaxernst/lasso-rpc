defmodule LassoWeb.TopologyConfig do
  @moduledoc """
  Centralized configuration for the network topology visualization.

  All layout constants and sizing rules are defined here for easy tweaking.
  Chains render as rectangular modules whose providers attach as pins on the
  four edges; module boxes grow to fit their pin count. Modules are packed with
  a golden-angle spiral and an axis-aligned overlap test.
  Chain-specific metadata (color, size) comes from profile chain `ui-topology` config.
  """

  alias Lasso.Config.ChainConfig.Topology

  # ===========================================================================
  # Canvas Configuration
  # ===========================================================================

  def canvas_width, do: 4000
  def canvas_height, do: 3000
  def canvas_center, do: {div(canvas_width(), 2), div(canvas_height(), 2)}

  # ===========================================================================
  # Provider Pin Configuration
  # ===========================================================================

  # Providers attach to module edges in this rotation. Sides fill first: a
  # vertical edge costs less width per pin than a horizontal edge costs height,
  # so leading with :left/:right keeps dense chains closer to square.
  @edge_order [:left, :right, :top, :bottom]

  def edge_order, do: @edge_order

  def pad_size, do: 10
  def pin_stub, do: 20

  # Horizontal edges need more room per pin because their labels run across the
  # edge rather than away from it.
  def pin_spacing_x, do: 48
  def pin_spacing_y, do: 30

  # Perpendicular offset of each conductor in the doubled websocket trace.
  def ws_trace_gap, do: 2.5

  # Clearance reserved around a module for its pins and their labels, used by
  # the packing overlap test so labels of neighbouring chains do not collide.
  def label_allowance_x, do: 42
  def label_allowance_y, do: 14
  def module_gap, do: 28

  # ===========================================================================
  # Golden-Angle Spiral Layout Configuration
  # ===========================================================================

  # 2.4 for canonical fib spiral
  @golden_angle 1.8

  def golden_angle, do: @golden_angle

  def spiral_spacing(_chain_count), do: 150

  # ===========================================================================
  # Chain Module Sizing
  # ===========================================================================

  # Widths seat the colour chip beside a chain name; heights leave room under the
  # label block for the block-height readout.
  def module_min_size(:xl), do: {256, 110}
  def module_min_size(:lg), do: {234, 100}
  def module_min_size(:md), do: {212, 92}
  def module_min_size(:sm), do: {196, 86}
  def module_min_size(_), do: {184, 82}

  @doc """
  Box dimensions for a chain module: the configured minimum, widened and
  heightened as needed so every edge can seat its pins at full spacing.
  """
  def module_size(size, provider_count) do
    {base_w, base_h} = module_min_size(size)
    {left, right, top, bottom} = edge_counts(provider_count)

    {max(base_w, (max(top, bottom) + 1) * pin_spacing_x()),
     max(base_h, (max(left, right) + 1) * pin_spacing_y())}
  end

  @doc """
  Providers per edge, in `edge_order/0`, for a round-robin assignment.
  """
  def edge_counts(provider_count) when provider_count <= 0, do: {0, 0, 0, 0}

  def edge_counts(provider_count) do
    base = div(provider_count, 4)
    extra = rem(provider_count, 4)

    [left, right, top, bottom] =
      Enum.map(0..3, fn i -> base + if(i < extra, do: 1, else: 0) end)

    {left, right, top, bottom}
  end

  @doc """
  Half-extents of a module including its pins and label gutters.
  """
  def module_footprint(width, height) do
    {width / 2 + pin_stub() + pad_size() / 2 + label_allowance_x(),
     height / 2 + pin_stub() + pad_size() / 2 + label_allowance_y()}
  end

  # ===========================================================================
  # Color Configuration
  # ===========================================================================

  @default_chain_color "#6B7280"

  # Two callers, two shapes: `ConfigStore`-backed renders pass the
  # `%Topology{}` struct; edit-mode renders (via `DraftTopology`) pass
  # the plain `EditState` topology map (`%{color: ..., size: ...}`).
  # Both must resolve here or the canvas falls back to the default
  # color even when the user has explicitly picked one.
  def chain_color(%Topology{color: color}, _chain_name) when is_binary(color) and color != "",
    do: color

  def chain_color(%{color: color}, _chain_name) when is_binary(color) and color != "",
    do: color

  def chain_color(%{"color" => color}, _chain_name) when is_binary(color) and color != "",
    do: color

  def chain_color(_topology, _chain_name), do: @default_chain_color

  # ===========================================================================
  # Provider Connection Line Configuration
  # ===========================================================================

  # Connectors stay a neutral grey: status is the pads' job, and colouring both
  # doubles the ink for one fact while making a chain of many providers read as
  # a starburst of competing hues.
  def provider_line_color, do: "#6b7280"
  def provider_line_width, do: 1.5
  def provider_line_opacity, do: 0.55

  # ===========================================================================
  # Chain Marks
  # ===========================================================================

  @doc """
  Static path of the curated chain mark, or `nil` when none is known.
  """
  def chain_logo(chain_id), do: Lasso.Discovery.ChainLogo.path(chain_id)
end
