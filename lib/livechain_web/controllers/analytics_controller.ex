defmodule LivechainWeb.AnalyticsController do
  @moduledoc """
  Analytics API controller providing insights from structured blockchain events.

  This controller exposes real-time and historical analytics derived from
  the Broadway-processed blockchain events, including:
  - Token transfer volumes and USD values
  - NFT activity trends
  - Cross-chain activity comparisons
  - DeFi protocol metrics
  """

  use LivechainWeb, :controller
  require Logger

  alias Livechain.Analytics.{QueryEngine, MetricsCollector}

  @doc """
  GET /api/analytics/overview
  Returns high-level analytics overview across all chains.
  """
  def overview(conn, _params) do
    overview_data = %{
      total_events_processed: get_total_events_processed(),
      total_usd_value_tracked: get_total_usd_value(),
      active_chains: get_active_chains(),
      top_tokens_by_volume: get_top_tokens_by_volume(5),
      recent_activity: get_recent_activity_summary(),
      processing_stats: get_processing_performance()
    }

    json(conn, %{
      success: true,
      data: overview_data,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  GET /api/analytics/tokens/volume
  Returns token transfer volume analytics.
  Query params: chain, timeframe (1h, 24h, 7d), limit
  """
  def token_volume(conn, params) do
    chain = Map.get(params, "chain", "all")
    timeframe = Map.get(params, "timeframe", "24h")
    limit = String.to_integer(Map.get(params, "limit", "10"))

    volume_data = %{
      timeframe: timeframe,
      chain: chain,
      token_volumes: get_token_volumes(chain, timeframe, limit),
      total_volume_usd: get_total_volume_usd(chain, timeframe),
      volume_by_hour: get_hourly_volume_breakdown(chain, timeframe)
    }

    json(conn, %{
      success: true,
      data: volume_data,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  GET /api/analytics/nft/activity
  Returns NFT transfer and marketplace activity.
  """
  def nft_activity(conn, params) do
    chain = Map.get(params, "chain", "all")
    timeframe = Map.get(params, "timeframe", "24h")

    nft_data = %{
      timeframe: timeframe,
      chain: chain,
      total_transfers: get_nft_transfer_count(chain, timeframe),
      active_collections: get_active_nft_collections(chain, timeframe),
      top_collections_by_volume: get_top_nft_collections(chain, timeframe, 10),
      transfer_activity_by_hour: get_nft_activity_by_hour(chain, timeframe)
    }

    json(conn, %{
      success: true,
      data: nft_data,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  GET /api/analytics/chains/comparison
  Returns cross-chain activity comparison.
  """
  def chain_comparison(conn, params) do
    timeframe = Map.get(params, "timeframe", "24h")

    comparison_data = %{
      timeframe: timeframe,
      chains: get_chain_comparison_metrics(timeframe),
      cross_chain_summary: %{
        total_events: get_cross_chain_event_count(timeframe),
        total_volume_usd: get_cross_chain_volume_usd(timeframe),
        most_active_chain: get_most_active_chain(timeframe),
        highest_volume_chain: get_highest_volume_chain(timeframe)
      }
    }

    json(conn, %{
      success: true,
      data: comparison_data,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  GET /api/analytics/real-time/events
  Returns real-time event stream metrics.
  """
  def realtime_events(conn, _params) do
    realtime_data = %{
      events_per_second: get_current_events_per_second(),
      active_pipelines: get_active_pipeline_count(),
      processing_latency: get_average_processing_latency(),
      recent_events: get_recent_structured_events(20),
      pipeline_health: get_pipeline_health_status()
    }

    json(conn, %{
      success: true,
      data: realtime_data,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  GET /api/analytics/performance
  Returns system performance metrics.
  """
  def performance_metrics(conn, _params) do
    performance_data = %{
      broadway_pipelines: get_broadway_pipeline_stats(),
      message_processing: get_message_processing_stats(),
      cache_performance: get_cache_performance_stats(),
      provider_health: get_provider_health_metrics(),
      system_resources: get_system_resource_usage()
    }

    json(conn, %{
      success: true,
      data: performance_data,
      timestamp: System.system_time(:millisecond)
    })
  end

  # Private helper functions for analytics data

  defp get_total_events_processed do
    # In production, would query time-series database
    # For demo, return aggregated stats from pipeline manager
    case Livechain.EventProcessing.Manager.get_stats() do
      stats when is_map(stats) ->
        stats
        |> Map.values()
        |> Enum.map(&Map.get(&1, :events_processed, 0))
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp get_total_usd_value do
    case Livechain.EventProcessing.Manager.get_stats() do
      stats when is_map(stats) ->
        stats
        |> Map.values()
        |> Enum.map(&Map.get(&1, :total_usd_value, 0.0))
        |> Enum.sum()
        |> Float.round(2)

      _ ->
        0.0
    end
  end

  defp get_active_chains do
    case Livechain.EventProcessing.Manager.get_pipeline_status() do
      pipelines when is_list(pipelines) ->
        pipelines
        |> Enum.filter(&(&1.status == :running))
        |> Enum.map(&Map.get(&1, :chain))

      _ ->
        []
    end
  end

  defp get_top_tokens_by_volume(limit) do
    # Mock data for demonstration
    [
      %{token: "USDC", volume_usd: 1_250_000.0, transfers: 450, chain: "ethereum"},
      %{token: "WETH", volume_usd: 980_000.0, transfers: 125, chain: "ethereum"},
      %{token: "USDC", volume_usd: 750_000.0, transfers: 320, chain: "polygon"},
      %{token: "MATIC", volume_usd: 420_000.0, transfers: 890, chain: "polygon"},
      %{token: "ARB", volume_usd: 350_000.0, transfers: 245, chain: "arbitrum"}
    ]
    |> Enum.take(limit)
  end

  defp get_recent_activity_summary do
    %{
      last_hour: %{
        events: 1_245,
        volume_usd: 125_000.0,
        unique_addresses: 892
      },
      last_24h: %{
        events: 28_450,
        volume_usd: 2_850_000.0,
        unique_addresses: 12_450
      }
    }
  end

  defp get_processing_performance do
    %{
      average_latency_ms: 45,
      events_per_second: 125,
      pipeline_uptime_percent: 99.8,
      cache_hit_rate_percent: 94.2
    }
  end

  defp get_token_volumes(chain, timeframe, limit) do
    # Mock implementation - in production would query time-series DB
    base_volumes = [
      %{symbol: "USDC", address: "0xa0b8...", volume_usd: 2_500_000, transfers: 1_250},
      %{symbol: "WETH", address: "0xc02a...", volume_usd: 1_800_000, transfers: 450},
      %{symbol: "USDT", address: "0xdac1...", volume_usd: 1_200_000, transfers: 890},
      %{symbol: "DAI", address: "0x6b17...", volume_usd: 950_000, transfers: 320}
    ]

    # Filter by chain and apply timeframe multipliers
    multiplier = case timeframe do
      "1h" -> 0.04
      "24h" -> 1.0
      "7d" -> 7.2
      _ -> 1.0
    end

    base_volumes
    |> Enum.map(fn token ->
      %{token | 
        volume_usd: Float.round(token.volume_usd * multiplier, 2),
        transfers: round(token.transfers * multiplier)
      }
    end)
    |> Enum.take(limit)
  end

  defp get_total_volume_usd(chain, timeframe) do
    # Mock calculation
    base_volume = 5_500_000.0
    
    multiplier = case timeframe do
      "1h" -> 0.04
      "24h" -> 1.0
      "7d" -> 7.2
      _ -> 1.0
    end

    Float.round(base_volume * multiplier, 2)
  end

  defp get_hourly_volume_breakdown(chain, timeframe) do
    # Generate mock hourly data
    hours = case timeframe do
      "1h" -> 1
      "24h" -> 24
      "7d" -> 24 * 7
      _ -> 24
    end

    1..hours
    |> Enum.map(fn hour ->
      %{
        hour: hour,
        volume_usd: :rand.uniform(500_000),
        transfers: :rand.uniform(200)
      }
    end)
  end

  defp get_nft_transfer_count(chain, timeframe) do
    base_count = 1_250
    
    multiplier = case timeframe do
      "1h" -> 0.04
      "24h" -> 1.0
      "7d" -> 7.2
      _ -> 1.0
    end

    round(base_count * multiplier)
  end

  defp get_active_nft_collections(chain, timeframe) do
    145  # Mock active collections
  end

  defp get_top_nft_collections(chain, timeframe, limit) do
    [
      %{name: "Bored Ape Yacht Club", transfers: 45, floor_price_eth: 12.5},
      %{name: "CryptoPunks", transfers: 32, floor_price_eth: 25.8},
      %{name: "Mutant Ape Yacht Club", transfers: 28, floor_price_eth: 4.2},
      %{name: "Azuki", transfers: 24, floor_price_eth: 3.1},
      %{name: "Otherdeed", transfers: 19, floor_price_eth: 1.8}
    ]
    |> Enum.take(limit)
  end

  defp get_nft_activity_by_hour(chain, timeframe) do
    hours = case timeframe do
      "1h" -> 1
      "24h" -> 24
      "7d" -> 24 * 7
      _ -> 24
    end

    1..hours
    |> Enum.map(fn hour ->
      %{
        hour: hour,
        transfers: :rand.uniform(50),
        unique_collections: :rand.uniform(20)
      }
    end)
  end

  defp get_chain_comparison_metrics(timeframe) do
    chains = ["ethereum", "polygon", "arbitrum", "bsc", "optimism"]
    
    Enum.map(chains, fn chain ->
      %{
        chain: chain,
        total_events: :rand.uniform(10_000) + 5_000,
        volume_usd: :rand.uniform(1_000_000) + 500_000,
        unique_addresses: :rand.uniform(5_000) + 1_000,
        avg_processing_latency_ms: :rand.uniform(100) + 20
      }
    end)
  end

  defp get_cross_chain_event_count(timeframe) do
    45_230  # Mock total
  end

  defp get_cross_chain_volume_usd(timeframe) do
    8_750_000.0  # Mock total USD volume
  end

  defp get_most_active_chain(timeframe) do
    "ethereum"
  end

  defp get_highest_volume_chain(timeframe) do
    "ethereum"
  end

  defp get_current_events_per_second do
    :rand.uniform(200) + 50  # Mock real-time EPS
  end

  defp get_active_pipeline_count do
    case Livechain.EventProcessing.Manager.get_pipeline_status() do
      pipelines when is_list(pipelines) ->
        Enum.count(pipelines, &(&1.status == :running))

      _ ->
        0
    end
  end

  defp get_average_processing_latency do
    # Mock average latency
    45 + :rand.uniform(20)
  end

  defp get_recent_structured_events(limit) do
    # Mock recent events
    1..limit
    |> Enum.map(fn i ->
      event_types = [:erc20_transfer, :nft_transfer, :block, :transaction]
      chains = ["ethereum", "polygon", "arbitrum"]
      
      %{
        id: i,
        type: Enum.random(event_types),
        chain: Enum.random(chains),
        timestamp: System.system_time(:millisecond) - (:rand.uniform(60_000)),
        usd_value: if(Enum.random([true, false]), do: :rand.uniform(10_000), else: nil)
      }
    end)
  end

  defp get_pipeline_health_status do
    case Livechain.EventProcessing.Manager.get_pipeline_status() do
      pipelines when is_list(pipelines) ->
        Enum.map(pipelines, fn pipeline ->
          %{
            chain: pipeline.chain,
            status: pipeline.status,
            uptime_ms: pipeline.uptime_ms,
            health: if(pipeline.status == :running, do: "healthy", else: "unhealthy")
          }
        end)

      _ ->
        []
    end
  end

  # Additional mock functions for performance metrics
  defp get_broadway_pipeline_stats do
    %{
      total_pipelines: 3,
      running_pipelines: 3,
      total_messages_processed: 125_450,
      messages_per_second: 125,
      average_batch_size: 15
    }
  end

  defp get_message_processing_stats do
    %{
      total_messages: 1_250_000,
      successful_messages: 1_248_750,
      failed_messages: 1_250,
      success_rate_percent: 99.9,
      average_processing_time_ms: 12
    }
  end

  defp get_cache_performance_stats do
    %{
      cache_hit_rate_percent: 94.2,
      cache_miss_rate_percent: 5.8,
      cache_size_mb: 45.2,
      eviction_rate_per_hour: 1_250
    }
  end

  defp get_provider_health_metrics do
    providers = ["infura", "alchemy", "quicknode"]
    
    Enum.map(providers, fn provider ->
      %{
        provider: provider,
        status: "healthy",
        uptime_percent: 99.5 + (:rand.uniform() * 0.5),
        average_response_time_ms: 150 + :rand.uniform(100),
        requests_per_minute: 450 + :rand.uniform(200)
      }
    end)
  end

  defp get_system_resource_usage do
    %{
      cpu_usage_percent: 45.2,
      memory_usage_mb: 512.8,
      network_bytes_per_second: 1_250_000,
      process_count: 125
    }
  end
end