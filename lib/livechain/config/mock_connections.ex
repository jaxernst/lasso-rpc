defmodule Livechain.Config.MockConnections do
  @moduledoc """
  Configuration module for creating mock WebSocket connections for all supported blockchain networks.

  This module generates mock WebSocket endpoints for all the chains defined in our chains.yml
  configuration, providing a comprehensive testing environment for the network topology
  visualization and connection management features.
  """

  alias Livechain.RPC.MockWSEndpoint
  require Logger

  @doc """
  Creates mock WebSocket endpoints for all configured blockchain networks.

  Each blockchain gets multiple provider connections based on the chains.yml configuration.
  """
  def create_all_mock_connections do
    with {:ok, config} <- Livechain.Config.ChainConfig.load_config() do
      config.chains
      |> Enum.flat_map(fn {chain_name, chain_config} ->
        create_chain_mock_connections(chain_name, chain_config)
      end)
    else
      {:error, reason} ->
        Logger.error("Failed to load chain configuration: #{inspect(reason)}")
        create_fallback_mock_connections()
    end
  end

  @doc """
  Creates mock connections for a specific blockchain chain.
  """
  def create_chain_mock_connections(chain_name, chain_config) do
    chain_config.providers
    |> Enum.map(fn provider ->
      %MockWSEndpoint{
        id: provider.id,
        name: "#{provider.name} (Mock)",
        url: provider.ws_url || "wss://mock.#{chain_name}.example.com",
        chain_id: chain_config.chain_id,
        chain_name: chain_name,
        block_time: chain_config.block_time,
        provider_type: provider.type,
        reliability: provider.reliability || 0.95,
        latency_target: provider.latency_target || 150,
        rate_limit: provider.rate_limit || 1000,
        subscription_topics: ["newHeads", "logs", "newPendingTransactions"],
        
        # Mock-specific configuration
        mock_config: %{
          simulate_reconnects: true,
          simulate_failures: provider.reliability < 0.98,
          failure_rate: 1.0 - (provider.reliability || 0.95),
          message_frequency: calculate_message_frequency(chain_config.block_time),
          generate_blocks: true,
          generate_transactions: true,
          generate_logs: chain_name in ["ethereum", "polygon", "arbitrum", "optimism", "base"]
        }
      }
    end)
  end

  @doc """
  Creates a comprehensive set of fallback mock connections if configuration loading fails.
  """
  def create_fallback_mock_connections do
    [
      # Ethereum Mainnet
      create_mock_endpoint("ethereum_infura", "Infura Ethereum", "ethereum", 1, 12000, 0.999, 100),
      create_mock_endpoint("ethereum_alchemy", "Alchemy Ethereum", "ethereum", 1, 12000, 0.999, 80),
      create_mock_endpoint("ethereum_ankr", "Ankr Ethereum", "ethereum", 1, 12000, 0.95, 200),

      # Polygon
      create_mock_endpoint("polygon_infura", "Infura Polygon", "polygon", 137, 2100, 0.999, 120),
      create_mock_endpoint("polygon_alchemy", "Alchemy Polygon", "polygon", 137, 2100, 0.999, 100),
      create_mock_endpoint("polygon_ankr", "Ankr Polygon", "polygon", 137, 2100, 0.93, 250),

      # Arbitrum One
      create_mock_endpoint("arbitrum_infura", "Infura Arbitrum", "arbitrum", 42161, 1000, 0.999, 100),
      create_mock_endpoint("arbitrum_alchemy", "Alchemy Arbitrum", "arbitrum", 42161, 1000, 0.999, 80),
      create_mock_endpoint("arbitrum_ankr", "Ankr Arbitrum", "arbitrum", 42161, 1000, 0.94, 200),

      # Optimism
      create_mock_endpoint("optimism_infura", "Infura Optimism", "optimism", 10, 2000, 0.999, 110),
      create_mock_endpoint("optimism_alchemy", "Alchemy Optimism", "optimism", 10, 2000, 0.999, 90),
      create_mock_endpoint("optimism_ankr", "Ankr Optimism", "optimism", 10, 2000, 0.96, 180),

      # Base
      create_mock_endpoint("base_publicnode", "PublicNode Base", "base", 8453, 2000, 0.98, 150),
      create_mock_endpoint("base_infura", "Infura Base", "base", 8453, 2000, 0.999, 100),
      create_mock_endpoint("base_alchemy", "Alchemy Base", "base", 8453, 2000, 0.999, 80),

      # BNB Smart Chain
      create_mock_endpoint("bsc_binance", "Binance BSC", "bsc", 56, 3000, 0.98, 150),
      create_mock_endpoint("bsc_ankr", "Ankr BSC", "bsc", 56, 3000, 0.95, 200),
      create_mock_endpoint("bsc_nodereal", "NodeReal BSC", "bsc", 56, 3000, 0.97, 170),

      # Avalanche
      create_mock_endpoint("avalanche_infura", "Infura Avalanche", "avalanche", 43114, 2000, 0.999, 120),
      create_mock_endpoint("avalanche_ankr", "Ankr Avalanche", "avalanche", 43114, 2000, 0.96, 180),
      create_mock_endpoint("avalanche_public", "Avalanche Public", "avalanche", 43114, 2000, 0.94, 200),

      # zkSync Era
      create_mock_endpoint("zksync_infura", "Infura zkSync", "zksync", 324, 1000, 0.999, 100),
      create_mock_endpoint("zksync_ankr", "Ankr zkSync", "zksync", 324, 1000, 0.96, 150),
      create_mock_endpoint("zksync_public", "zkSync Public", "zksync", 324, 1000, 0.95, 180),

      # Linea
      create_mock_endpoint("linea_infura", "Infura Linea", "linea", 59144, 12000, 0.999, 120),
      create_mock_endpoint("linea_consensys", "Consensys Linea", "linea", 59144, 12000, 0.97, 150),

      # Scroll
      create_mock_endpoint("scroll_ankr", "Ankr Scroll", "scroll", 534352, 3000, 0.95, 200),
      create_mock_endpoint("scroll_public", "Scroll Public", "scroll", 534352, 3000, 0.96, 180),

      # Mantle
      create_mock_endpoint("mantle_public", "Mantle Public", "mantle", 5000, 1000, 0.96, 150),
      create_mock_endpoint("mantle_ankr", "Ankr Mantle", "mantle", 5000, 1000, 0.94, 200),

      # Blast
      create_mock_endpoint("blast_infura", "Infura Blast", "blast", 81457, 2000, 0.999, 110),
      create_mock_endpoint("blast_public", "Blast Public", "blast", 81457, 2000, 0.96, 160),

      # Mode
      create_mock_endpoint("mode_public", "Mode Public", "mode", 34443, 2000, 0.95, 170),

      # Fantom
      create_mock_endpoint("fantom_ankr", "Ankr Fantom", "fantom", 250, 1000, 0.95, 180),
      create_mock_endpoint("fantom_public", "Fantom Public", "fantom", 250, 1000, 0.93, 200),

      # Celo
      create_mock_endpoint("celo_infura", "Infura Celo", "celo", 42220, 5000, 0.999, 140),
      create_mock_endpoint("celo_ankr", "Ankr Celo", "celo", 42220, 5000, 0.94, 220)
    ]
  end

  @doc """
  Starts all mock WebSocket connections.
  """
  def start_all_mock_connections do
    endpoints = create_all_mock_connections()
    
    Logger.info("Starting #{length(endpoints)} mock WebSocket connections...")
    
    results = 
      endpoints
      |> Enum.map(fn endpoint ->
        case Livechain.RPC.WSSupervisor.start_connection(endpoint) do
          {:ok, _pid} ->
            Logger.debug("Started mock connection: #{endpoint.name}")
            {:ok, endpoint.id}
          
          {:error, reason} ->
            Logger.warning("Failed to start mock connection #{endpoint.name}: #{inspect(reason)}")
            {:error, endpoint.id, reason}
        end
      end)
    
    successes = Enum.count(results, fn {result, _} -> result == :ok end)
    failures = Enum.count(results, fn {result, _} -> result == :error end)
    
    Logger.info("Mock connections started: #{successes} successful, #{failures} failed")
    
    {:ok, %{started: successes, failed: failures, results: results}}
  end

  @doc """
  Stops all mock WebSocket connections.
  """
  def stop_all_mock_connections do
    connections = Livechain.RPC.WSSupervisor.list_connections()
    
    mock_connections = 
      connections
      |> Enum.filter(fn conn -> String.contains?(conn.name || "", "Mock") end)
    
    Logger.info("Stopping #{length(mock_connections)} mock WebSocket connections...")
    
    results =
      mock_connections
      |> Enum.map(fn conn ->
        case Livechain.RPC.WSSupervisor.stop_connection(conn.id) do
          :ok ->
            Logger.debug("Stopped mock connection: #{conn.name}")
            {:ok, conn.id}
          
          {:error, reason} ->
            Logger.warning("Failed to stop mock connection #{conn.name}: #{inspect(reason)}")
            {:error, conn.id, reason}
        end
      end)
    
    successes = Enum.count(results, fn {result, _} -> result == :ok end)
    failures = Enum.count(results, fn {result, _} -> result == :error end)
    
    Logger.info("Mock connections stopped: #{successes} successful, #{failures} failed")
    
    {:ok, %{stopped: successes, failed: failures, results: results}}
  end

  # Private helper functions

  defp create_mock_endpoint(id, name, chain_name, chain_id, block_time, reliability, latency_target) do
    %MockWSEndpoint{
      id: id,
      name: "#{name} (Mock)",
      url: "wss://mock.#{chain_name}.example.com",
      chain_id: chain_id,
      chain_name: chain_name,
      block_time: block_time,
      provider_type: if(reliability > 0.98, do: "paid", else: "public"),
      reliability: reliability,
      latency_target: latency_target,
      rate_limit: if(reliability > 0.98, do: 100000, else: 1000),
      subscription_topics: ["newHeads", "logs", "newPendingTransactions"],
      
      mock_config: %{
        simulate_reconnects: true,
        simulate_failures: reliability < 0.98,
        failure_rate: 1.0 - reliability,
        message_frequency: calculate_message_frequency(block_time),
        generate_blocks: true,
        generate_transactions: true,
        generate_logs: chain_name in ["ethereum", "polygon", "arbitrum", "optimism", "base"]
      }
    }
  end

  defp calculate_message_frequency(block_time) do
    # Calculate how often to generate mock messages based on block time
    # More frequent messages for faster chains
    case block_time do
      time when time <= 1000 -> 500   # Very fast chains: message every 500ms
      time when time <= 2000 -> 1000  # Fast chains: message every 1000ms  
      time when time <= 3000 -> 1500  # Medium chains: message every 1500ms
      time when time <= 5000 -> 2500  # Slower chains: message every 2500ms
      _ -> 5000                       # Very slow chains: message every 5000ms
    end
  end
end