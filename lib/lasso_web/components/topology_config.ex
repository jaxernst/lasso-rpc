defmodule LassoWeb.TopologyConfig do
  @moduledoc """
  Centralized configuration for the network topology visualization.

  All layout constants and sizing rules are defined here for easy tweaking.
  Uses a golden-angle spiral layout for organic, gap-free spacing at any node count.
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
  # Provider Orbital Configuration
  # ===========================================================================

  def provider_orbit_gap, do: 32
  def provider_node_radius, do: 13
  def provider_angle_variance, do: :math.pi() / 13
  def provider_distance_variance, do: 15

  # ===========================================================================
  # Golden-Angle Spiral Layout Configuration
  # ===========================================================================

  @golden_angle 2.399963229728653

  def golden_angle, do: @golden_angle

  def spiral_spacing(_chain_count), do: 130

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

  # ===========================================================================
  # Chain Logo SVG Paths
  # ===========================================================================

  @chain_logos %{
    "ethereum" => %{
      viewbox: "0 0 256 417",
      paths: [
        {"M127.961 0l-2.795 9.5v275.668l2.795 2.79 127.962-75.638z", "#343434"},
        {"M127.962 0L0 212.32l127.962 75.639V154.158z", "#8C8C8C"},
        {"M127.961 312.187l-1.575 1.92v98.199l1.575 4.601L256 236.587z", "#3C3C3C"},
        {"M127.962 416.905v-104.72L0 236.585z", "#8C8C8C"},
        {"M127.961 287.958l127.96-75.637-127.96-58.162z", "#141414"},
        {"M0 212.32l127.96 75.638v-133.8z", "#393939"}
      ]
    },
    "base" => %{
      viewbox: "0 0 111 111",
      paths: [
        {"M54.921 110.034c30.36 0 54.983-24.53 54.983-54.809C109.903 24.647 85.28.117 54.921.117 26.046.117 2.542 22.283.075 50.653h72.624v9.3H.076c2.467 28.37 25.97 50.08 54.845 50.08z",
         "#0052FF"}
      ]
    },
    "arbitrum" => %{
      viewbox: "0 0 256 256",
      paths: [
        {"M128 0C57.308 0 0 57.308 0 128s57.308 128 128 128 128-57.308 128-128S198.692 0 128 0z",
         "#213147"},
        {"M151.818 133.636l20.364 32.728L192 140.364l-40.182-6.728zM64 140.364l19.818 26L128 108.364l-44.364-4.364L64 140.364z",
         "#12AAFF"},
        {"M128 108.364l-44.182 58 44.182 25.636 44.182-25.636L128 108.364z", "#9DCCED"}
      ]
    },
    "polygon" => %{
      viewbox: "0 0 38 33",
      paths: [
        {"M29 10.2c-0.7-0.4-1.6-0.4-2.4 0l-5.6 3.3-3.8 2.1-5.5 3.3c-0.7 0.4-1.6 0.4-2.4 0l-4.3-2.6c-0.7-0.4-1.2-1.2-1.2-2.1v-5c0-0.8 0.4-1.6 1.2-2.1l4.3-2.5c0.7-0.4 1.6-0.4 2.4 0l4.3 2.6c0.7 0.4 1.2 1.2 1.2 2.1v3.3l3.8-2.2V7c0-0.8-0.4-1.6-1.2-2.1l-8-4.7c-0.7-0.4-1.6-0.4-2.4 0L1.2 5C0.4 5.4 0 6.2 0 7v9.4c0 0.8 0.4 1.6 1.2 2.1l8.1 4.7c0.7 0.4 1.6 0.4 2.4 0l5.5-3.2 3.8-2.2 5.5-3.2c0.7-0.4 1.6-0.4 2.4 0l4.3 2.5c0.7 0.4 1.2 1.2 1.2 2.1v5c0 0.8-0.4 1.6-1.2 2.1l-4.2 2.5c-0.7 0.4-1.6 0.4-2.4 0l-4.3-2.5c-0.7-0.4-1.2-1.2-1.2-2.1v-3.2l-3.8 2.2v3.3c0 0.8 0.4 1.6 1.2 2.1l8.1 4.7c0.7 0.4 1.6 0.4 2.4 0l8.1-4.7c0.7-0.4 1.2-1.2 1.2-2.1V11c0-0.8-0.4-1.6-1.2-2.1L29 10.2z",
         "#8247E5"}
      ]
    },
    "optimism" => %{
      viewbox: "0 0 500 500",
      paths: [
        {"M250 0C111.929 0 0 111.929 0 250s111.929 250 250 250 250-111.929 250-250S388.071 0 250 0z",
         "#FF0420"},
        {"M177.133 316.446c-26.152 0-46.566-6.678-61.242-20.033-14.511-13.52-21.767-32.727-21.767-57.62 0-25.222 7.585-46.237 22.754-63.044 15.334-16.972 35.419-25.458 60.255-25.458 25.823 0 45.414 6.843 58.772 20.528 13.358 13.52 20.037 32.234 20.037 56.139 0 25.717-7.585 47.06-22.754 64.032-15.005 17.136-34.926 25.458-56.055 25.458z",
         "white"}
      ]
    },
    "avalanche" => %{
      viewbox: "0 0 254 254",
      paths: [
        {"M127 0C56.85 0 0 56.85 0 127s56.85 127 127 127 127-56.85 127-127S197.15 0 127 0z",
         "#E84142"},
        {"M171.8 130.3c4.4-7.6 11.5-7.6 15.9 0l27.6 48.1c4.4 7.6.8 13.8-8 13.8h-55.5c-8.7 0-12.3-6.2-8-13.8l28-48.1zM118.8 47.4c4.4-7.6 11.4-7.6 15.8 0l5.3 9.5 12.3 22.2c3.5 7.5 3.5 16.3 0 23.8L109.3 178.5c-4.4 7-11.8 11.4-20 12h-47c-8.8 0-12.4-6.1-8-13.8l84.5-129.3z",
         "white"}
      ]
    },
    "bsc" => %{
      viewbox: "0 0 126 126",
      paths: [
        {"M63 0L26.46 21v42L63 84l36.54-21V21L63 0z", "#F3BA2F"},
        {"M63 42L42 54v24l21 12 21-12V54L63 42z", "#F3BA2F"}
      ]
    }
  }

  @chain_name_aliases %{
    "ethereum_sepolia" => "ethereum",
    "base_sepolia" => "base",
    "arbitrum_sepolia" => "arbitrum",
    "polygon_mumbai" => "polygon",
    "polygon_amoy" => "polygon",
    "optimism_sepolia" => "optimism",
    "avalanche_fuji" => "avalanche",
    "bsc_testnet" => "bsc",
    "arbitrum_one" => "arbitrum",
    "arbitrum_nova" => "arbitrum"
  }

  def chain_logo(chain_name) do
    canonical = Map.get(@chain_name_aliases, chain_name, chain_name)
    Map.get(@chain_logos, canonical)
  end
end
