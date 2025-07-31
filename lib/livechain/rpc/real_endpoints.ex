defmodule Livechain.RPC.RealEndpoints do
  @moduledoc """
  Helper module for creating real blockchain endpoint configurations.

  This module provides functions to create WSEndpoint configurations
  for connecting to real blockchain RPC providers.
  """

  alias Livechain.RPC.WSEndpoint

  @doc """
  Creates an Ethereum mainnet endpoint using Infura.

  You'll need an Infura API key to use this.
  """
  def ethereum_mainnet_infura(api_key) do
    WSEndpoint.new(
      id: "ethereum_mainnet_infura",
      name: "Ethereum Mainnet (Infura)",
      url: "https://mainnet.infura.io/v3/#{api_key}",
      ws_url: "wss://mainnet.infura.io/ws/v3/#{api_key}",
      chain_id: 1,
      api_key: api_key,
      heartbeat_interval: 30_000,
      reconnect_interval: 5_000,
      max_reconnect_attempts: 10,
      subscription_topics: ["newHeads"]
    )
  end

  @doc """
  Creates an Ethereum mainnet endpoint using Alchemy.
  """
  def ethereum_mainnet_alchemy(api_key) do
    WSEndpoint.new(
      id: "ethereum_mainnet_alchemy",
      name: "Ethereum Mainnet (Alchemy)",
      url: "https://eth-mainnet.g.alchemy.com/v2/#{api_key}",
      ws_url: "wss://eth-mainnet.g.alchemy.com/v2/#{api_key}",
      chain_id: 1,
      api_key: api_key,
      heartbeat_interval: 30_000,
      reconnect_interval: 5_000,
      max_reconnect_attempts: 10,
      subscription_topics: ["newHeads"]
    )
  end

  @doc """
  Creates an Ethereum mainnet endpoint using a public RPC.

  Note: Public RPCs may be less reliable and have rate limits.
  """
  def ethereum_mainnet_public() do
    WSEndpoint.new(
      id: "ethereum_mainnet_public",
      name: "Ethereum Mainnet (Public)",
      url: "https://eth.llamarpc.com",
      ws_url: "wss://eth.llamarpc.com",
      chain_id: 1,
      heartbeat_interval: 30_000,
      reconnect_interval: 10_000,
      max_reconnect_attempts: 5,
      subscription_topics: ["newHeads"]
    )
  end

  @doc """
  Creates a Polygon endpoint using Infura.
  """
  def polygon_infura(api_key) do
    WSEndpoint.new(
      id: "polygon_infura",
      name: "Polygon (Infura)",
      url: "https://polygon-mainnet.infura.io/v3/#{api_key}",
      ws_url: "wss://polygon-mainnet.infura.io/ws/v3/#{api_key}",
      chain_id: 137,
      api_key: api_key,
      heartbeat_interval: 30_000,
      reconnect_interval: 5_000,
      max_reconnect_attempts: 10,
      subscription_topics: ["newHeads"]
    )
  end

  @doc """
  Creates an Arbitrum endpoint using Infura.
  """
  def arbitrum_infura(api_key) do
    WSEndpoint.new(
      id: "arbitrum_infura",
      name: "Arbitrum (Infura)",
      url: "https://arbitrum-mainnet.infura.io/v3/#{api_key}",
      ws_url: "wss://arbitrum-mainnet.infura.io/ws/v3/#{api_key}",
      chain_id: 42_161,
      api_key: api_key,
      heartbeat_interval: 30_000,
      reconnect_interval: 5_000,
      max_reconnect_attempts: 10,
      subscription_topics: ["newHeads"]
    )
  end

  @doc """
  Creates a Base mainnet endpoint using the official Base public RPC.

  Note: This is a public RPC that may be rate-limited.
  """
  def base_mainnet_public() do
    WSEndpoint.new(
      id: "base_mainnet_public",
      name: "Base Mainnet (Public)",
      url: "https://base-rpc.publicnode.com",
      ws_url: "wss://base-rpc.publicnode.com",
      chain_id: 8453,
      heartbeat_interval: 30_000,
      reconnect_interval: 10_000,
      max_reconnect_attempts: 5,
      subscription_topics: ["newHeads", "logs"]
    )
  end

  @doc """
  Creates a Base mainnet endpoint using Ankr's public RPC.

  Note: This is a public RPC that may be rate-limited.
  """
  def base_mainnet_ankr() do
    WSEndpoint.new(
      id: "base_mainnet_ankr",
      name: "Base Mainnet (Ankr)",
      url: "https://rpc.ankr.com/base",
      ws_url: "wss://rpc.ankr.com/base/ws",
      chain_id: 8453,
      heartbeat_interval: 30_000,
      reconnect_interval: 10_000,
      max_reconnect_attempts: 5,
      subscription_topics: ["newHeads", "logs"]
    )
  end

  @doc """
  Creates a Base mainnet endpoint using Infura.
  """
  def base_mainnet_infura(api_key) do
    WSEndpoint.new(
      id: "base_mainnet_infura",
      name: "Base Mainnet (Infura)",
      url: "https://base-mainnet.infura.io/v3/#{api_key}",
      ws_url: "wss://base-mainnet.infura.io/ws/v3/#{api_key}",
      chain_id: 8453,
      api_key: api_key,
      heartbeat_interval: 30_000,
      reconnect_interval: 5_000,
      max_reconnect_attempts: 10,
      subscription_topics: ["newHeads", "logs"]
    )
  end

  @doc """
  Creates a Base sepolia testnet endpoint using the official Base public RPC.

  Note: This is a public RPC that may be rate-limited.
  """
  def base_sepolia_public() do
    WSEndpoint.new(
      id: "base_sepolia_public",
      name: "Base Sepolia (Public)",
      url: "https://sepolia.base.org",
      ws_url: "wss://sepolia.base.org",
      chain_id: 84532,
      heartbeat_interval: 30_000,
      reconnect_interval: 10_000,
      max_reconnect_attempts: 5,
      subscription_topics: ["newHeads", "logs"]
    )
  end
end
