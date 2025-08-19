defmodule Livechain.Simulator.MockConnections do
  @moduledoc """
  Configuration module for creating mock WebSocket connections for all supported blockchain networks.

  This module generates mock WebSocket endpoints for all the chains defined in our chains.yml
  configuration, providing a comprehensive testing environment for the network topology
  visualization and connection management features.
  """

  alias Livechain.Simulator.MockWSEndpoint
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
        subscription_topics: ["newHeads", "logs", "newPendingTransactions"],

        # Mock-specific configuration
        mock_config: %{
          simulate_reconnects: true,
          # Public providers are less reliable
          simulate_failures: provider.type == "public",
          # 5% for public, 1% for paid
          failure_rate: if(provider.type == "public", do: 0.05, else: 0.01),
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
      create_mock_endpoint(
        "ethereum_infura",
        "Infura Ethereum",
        "ethereum",
        1,
        12000
      ),
      create_mock_endpoint(
        "ethereum_alchemy",
        "Alchemy Ethereum",
        "ethereum",
        1,
        12000
      ),
      create_mock_endpoint("ethereum_ankr", "Ankr Ethereum", "ethereum", 1, 12000),

      # Polygon
      create_mock_endpoint("polygon_infura", "Infura Polygon", "polygon", 137, 2100),
      create_mock_endpoint(
        "polygon_alchemy",
        "Alchemy Polygon",
        "polygon",
        137,
        2100
      ),
      create_mock_endpoint("polygon_ankr", "Ankr Polygon", "polygon", 137, 2100),

      # Arbitrum One
      create_mock_endpoint(
        "arbitrum_infura",
        "Infura Arbitrum",
        "arbitrum",
        42161,
        1000
      ),
      create_mock_endpoint(
        "arbitrum_alchemy",
        "Alchemy Arbitrum",
        "arbitrum",
        42161,
        1000
      ),
      create_mock_endpoint("arbitrum_ankr", "Ankr Arbitrum", "arbitrum", 42161, 1000),

      # Optimism
      create_mock_endpoint(
        "optimism_infura",
        "Infura Optimism",
        "optimism",
        10,
        2000
      ),
      create_mock_endpoint(
        "optimism_alchemy",
        "Alchemy Optimism",
        "optimism",
        10,
        2000
      ),
      create_mock_endpoint("optimism_ankr", "Ankr Optimism", "optimism", 10, 2000),

      # Base
      create_mock_endpoint("base_publicnode", "PublicNode Base", "base", 8453, 2000),
      create_mock_endpoint("base_infura", "Infura Base", "base", 8453, 2000),
      create_mock_endpoint("base_alchemy", "Alchemy Base", "base", 8453, 2000),

      # BNB Smart Chain
      create_mock_endpoint("bsc_binance", "Binance BSC", "bsc", 56, 3000),
      create_mock_endpoint("bsc_ankr", "Ankr BSC", "bsc", 56, 3000),
      create_mock_endpoint("bsc_nodereal", "NodeReal BSC", "bsc", 56, 3000),

      # Avalanche
      create_mock_endpoint(
        "avalanche_infura",
        "Infura Avalanche",
        "avalanche",
        43114,
        2000
      ),
      create_mock_endpoint(
        "avalanche_ankr",
        "Ankr Avalanche",
        "avalanche",
        43114,
        2000
      ),
      create_mock_endpoint(
        "avalanche_public",
        "Avalanche Public",
        "avalanche",
        43114,
        2000
      ),

      # zkSync Era
      create_mock_endpoint("zksync_infura", "Infura zkSync", "zksync", 324, 1000),
      create_mock_endpoint("zksync_ankr", "Ankr zkSync", "zksync", 324, 1000),
      create_mock_endpoint("zksync_public", "zkSync Public", "zksync", 324, 1000),

      # Linea
      create_mock_endpoint("linea_infura", "Infura Linea", "linea", 59144, 12000),
      create_mock_endpoint(
        "linea_consensys",
        "Consensys Linea",
        "linea",
        59144,
        12000
      ),

      # Scroll
      create_mock_endpoint("scroll_ankr", "Ankr Scroll", "scroll", 534_352, 3000),
      create_mock_endpoint("scroll_public", "Scroll Public", "scroll", 534_352, 3000),

      # Mantle
      create_mock_endpoint("mantle_public", "Mantle Public", "mantle", 5000, 1000),
      create_mock_endpoint("mantle_ankr", "Ankr Mantle", "mantle", 5000, 1000),

      # Blast
      create_mock_endpoint("blast_infura", "Infura Blast", "blast", 81457, 2000),
      create_mock_endpoint("blast_public", "Blast Public", "blast", 81457, 2000),

      # Mode
      create_mock_endpoint("mode_public", "Mode Public", "mode", 34443, 2000),

      # Fantom
      create_mock_endpoint("fantom_ankr", "Ankr Fantom", "fantom", 250, 1000),
      create_mock_endpoint("fantom_public", "Fantom Public", "fantom", 250, 1000),

      # Celo
      create_mock_endpoint("celo_infura", "Infura Celo", "celo", 42220, 5000),
      create_mock_endpoint("celo_ankr", "Ankr Celo", "celo", 42220, 5000)
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

  defp create_mock_endpoint(
         id,
         name,
         chain_name,
         chain_id,
         block_time
       ) do
    %MockWSEndpoint{
      id: id,
      name: "#{name} (Mock)",
      url: "wss://mock.#{chain_name}.example.com",
      chain_id: chain_id,
      chain_name: chain_name,
      block_time: block_time,
      # All fallback endpoints are public
      provider_type: "public",
      subscription_topics: ["newHeads", "logs", "newPendingTransactions"],
      mock_config: %{
        simulate_reconnects: true,
        # Public providers simulate failures
        simulate_failures: true,
        # 5% failure rate for public providers
        failure_rate: 0.05,
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
      # Very fast chains: message every 500ms
      time when time <= 1000 -> 500
      # Fast chains: message every 1000ms
      time when time <= 2000 -> 1000
      # Medium chains: message every 1500ms
      time when time <= 3000 -> 1500
      # Slower chains: message every 2500ms
      time when time <= 5000 -> 2500
      # Very slow chains: message every 5000ms
      _ -> 5000
    end
  end
end
