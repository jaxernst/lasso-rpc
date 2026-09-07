defmodule Lasso.Discovery.ChainLogo do
  @moduledoc """
  Resolves a curated chain mark for a numeric `chain_id`.

  Marks are static SVGs under `priv/static/images/chains`. Identity is
  the EVM chain ID. Testnets reuse the parent mark. Unknown chains
  resolve to `nil` so the dashboard can keep the colour chip.
  """

  @type t :: %{slug: String.t(), path: String.t()}

  @static_prefix "/images/chains"

  # chain_id => asset slug (filename without .svg)
  @marks %{
    1 => "ethereum",
    11_155_111 => "ethereum",
    8453 => "base",
    84_532 => "base",
    42_161 => "arbitrum",
    421_614 => "arbitrum",
    10 => "optimism",
    11_155_420 => "optimism",
    137 => "polygon",
    80_002 => "polygon",
    80_001 => "polygon",
    130 => "unichain",
    1301 => "unichain",
    480 => "world",
    4801 => "world",
    4217 => "tempo",
    42_431 => "tempo",
    4663 => "robinhood",
    56 => "bsc",
    97 => "bsc",
    43_114 => "avalanche",
    43_113 => "avalanche",
    59_144 => "linea",
    59_141 => "linea",
    534_352 => "scroll",
    534_351 => "scroll",
    324 => "zksync",
    300 => "zksync",
    5000 => "mantle",
    5003 => "mantle",
    81_457 => "blast",
    168_587_773 => "blast",
    143 => "monad",
    10_143 => "monad",
    100 => "gnosis",
    42_220 => "celo",
    7_777_777 => "zora",
    167_000 => "taiko",
    80_094 => "berachain",
    1329 => "sei",
    1868 => "soneium",
    57_073 => "ink",
    25 => "cronos",
    1088 => "metis",
    169 => "manta",
    250 => "fantom",
    1101 => "polygon-zkevm",
    314 => "filecoin",
    146 => "sonic",
    999 => "hyperliquid"
  }

  @spec resolve(term()) :: t() | nil
  def resolve(chain_id) when is_integer(chain_id) and chain_id > 0 do
    case Map.get(@marks, chain_id) do
      nil -> nil
      slug -> %{slug: slug, path: "#{@static_prefix}/#{slug}.svg"}
    end
  end

  def resolve(_), do: nil

  @spec path(term()) :: String.t() | nil
  def path(chain_id) do
    case resolve(chain_id) do
      %{path: path} -> path
      nil -> nil
    end
  end

  @spec slug(term()) :: String.t() | nil
  def slug(chain_id) do
    case resolve(chain_id) do
      %{slug: slug} -> slug
      nil -> nil
    end
  end

  @spec known?(term()) :: boolean()
  def known?(chain_id), do: match?(%{slug: _}, resolve(chain_id))

  @spec marks() :: %{pos_integer() => String.t()}
  def marks, do: @marks
end
