defmodule Lasso.Discovery.ChainRegistry do
  @moduledoc """
  Static registry of known EVM chain metadata.

  Pure data module — no process, no state. Maps chain IDs to
  human-readable names and block timing parameters.
  """

  @type chain_info :: %{
          name: String.t(),
          display_name: String.t(),
          is_testnet: boolean(),
          block_time_ms: pos_integer()
        }

  @chains %{
    1 => %{
      name: "ethereum",
      display_name: "Ethereum",
      is_testnet: false,
      block_time_ms: 12_000
    },
    8453 => %{
      name: "base",
      display_name: "Base",
      is_testnet: false,
      block_time_ms: 2_000
    },
    42_161 => %{
      name: "arbitrum",
      display_name: "Arbitrum One",
      is_testnet: false,
      block_time_ms: 250
    },
    11_155_111 => %{
      name: "ethereum-sepolia",
      display_name: "Sepolia",
      is_testnet: true,
      block_time_ms: 12_000
    },
    84_532 => %{
      name: "base-sepolia",
      display_name: "Base Sepolia",
      is_testnet: true,
      block_time_ms: 2_000
    },
    421_614 => %{
      name: "arbitrum-sepolia",
      display_name: "Arbitrum Sepolia",
      is_testnet: true,
      block_time_ms: 250
    },
    10 => %{
      name: "optimism",
      display_name: "Optimism",
      is_testnet: false,
      block_time_ms: 2_000
    },
    137 => %{
      name: "polygon",
      display_name: "Polygon",
      is_testnet: false,
      block_time_ms: 2_000
    },
    130 => %{
      name: "unichain",
      display_name: "Unichain",
      is_testnet: false,
      block_time_ms: 1_000
    },
    480 => %{
      name: "world",
      display_name: "World Chain",
      is_testnet: false,
      block_time_ms: 2_000
    },
    4217 => %{
      name: "tempo",
      display_name: "Tempo",
      is_testnet: false,
      block_time_ms: 500
    },
    4663 => %{
      name: "robinhood",
      display_name: "Robinhood Chain",
      is_testnet: false,
      block_time_ms: 100
    },
    56 => %{
      name: "bsc",
      display_name: "BNB Smart Chain",
      is_testnet: false,
      block_time_ms: 3_000
    },
    43_114 => %{
      name: "avalanche",
      display_name: "Avalanche C-Chain",
      is_testnet: false,
      block_time_ms: 2_000
    },
    59_144 => %{
      name: "linea",
      display_name: "Linea",
      is_testnet: false,
      block_time_ms: 12_000
    },
    534_352 => %{
      name: "scroll",
      display_name: "Scroll",
      is_testnet: false,
      block_time_ms: 3_000
    },
    324 => %{
      name: "zksync",
      display_name: "zkSync Era",
      is_testnet: false,
      block_time_ms: 1_000
    },
    5000 => %{
      name: "mantle",
      display_name: "Mantle",
      is_testnet: false,
      block_time_ms: 2_000
    },
    81_457 => %{
      name: "blast",
      display_name: "Blast",
      is_testnet: false,
      block_time_ms: 2_000
    },
    143 => %{
      name: "monad",
      display_name: "Monad",
      is_testnet: false,
      block_time_ms: 400
    },
    10_143 => %{
      name: "monad-testnet",
      display_name: "Monad Testnet",
      is_testnet: true,
      block_time_ms: 400
    },
    42_431 => %{
      name: "tempo-testnet",
      display_name: "Tempo Testnet",
      is_testnet: true,
      block_time_ms: 1_000
    }
  }

  @spec known_ids() :: [pos_integer()]
  def known_ids, do: Map.keys(@chains)

  @spec lookup(integer()) :: {:ok, chain_info()} | :unknown
  def lookup(chain_id) when is_integer(chain_id) do
    case Map.get(@chains, chain_id) do
      nil -> :unknown
      info -> {:ok, info}
    end
  end

  @spec name_for(integer()) :: String.t()
  def name_for(chain_id) when is_integer(chain_id) do
    case lookup(chain_id) do
      {:ok, info} -> info.name
      :unknown -> "chain-#{chain_id}"
    end
  end

  @spec display_name_for(integer()) :: String.t()
  def display_name_for(chain_id) when is_integer(chain_id) do
    case lookup(chain_id) do
      {:ok, info} -> info.display_name
      :unknown -> "Chain #{chain_id}"
    end
  end

  @spec block_time_ms_for(integer()) :: pos_integer()
  def block_time_ms_for(chain_id) when is_integer(chain_id) do
    case lookup(chain_id) do
      {:ok, info} -> info.block_time_ms
      :unknown -> 12_000
    end
  end

  @spec block_time_ms_for_name(String.t()) :: pos_integer()
  def block_time_ms_for_name(chain_name) when is_binary(chain_name) do
    case Enum.find(@chains, fn {_id, info} -> info.name == chain_name end) do
      {_id, info} -> info.block_time_ms
      nil -> 12_000
    end
  end

  @spec id_for_name(String.t()) :: {:ok, integer()} | :unknown
  def id_for_name(chain_name) when is_binary(chain_name) do
    case Enum.find(@chains, fn {_id, info} -> info.name == chain_name end) do
      {id, _info} -> {:ok, id}
      nil -> :unknown
    end
  end
end
