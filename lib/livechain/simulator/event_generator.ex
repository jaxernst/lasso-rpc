defmodule Livechain.Simulator.EventGenerator do
  @moduledoc """
  Generates realistic blockchain events for simulation purposes.

  This module will be used by the simulator to broadcast mock blockchain
  events like new blocks, transactions, and network status changes to
  populate a future event feed in the LiveView dashboard.
  """

  @doc """
  Generates a realistic blockchain event for the given chain.
  """
  def generate_event(chain_name, connection_id) do
    event_type = random_event_type()

    base_event = %{
      event_type: event_type,
      chain: chain_name,
      connection_id: connection_id,
      timestamp: DateTime.utc_now(),
      id: generate_event_id()
    }

    case event_type do
      :new_block -> generate_block_event(base_event, chain_name)
      :new_transaction -> generate_transaction_event(base_event, chain_name)
      :network_status -> generate_network_status_event(base_event, chain_name)
      :subscription_update -> generate_subscription_event(base_event, chain_name)
    end
  end

  @doc """
  Broadcasts an event to the appropriate PubSub channels.
  """
  def broadcast_event(event) do
    # Broadcast to general event feed
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "simulator_events",
      {:new_event, event}
    )

    # Broadcast to chain-specific channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "simulator_events:#{event.chain}",
      {:new_event, event}
    )

    # Future: Add more specific channels as needed
    :ok
  end

  # Private Functions

  defp random_event_type do
    events = [:new_block, :new_transaction, :network_status, :subscription_update]
    # Weighted probabilities
    weights = [50, 30, 10, 10]

    weighted_random(events, weights)
  end

  defp generate_block_event(base_event, chain_name) do
    # Realistic block numbers
    block_number = :rand.uniform(1_000_000) + 18_000_000

    Map.merge(base_event, %{
      title: "New Block ##{block_number}",
      description: "Block mined on #{format_chain_name(chain_name)}",
      data: %{
        block_number: block_number,
        hash: generate_hash(),
        transaction_count: :rand.uniform(200) + 50,
        gas_used: :rand.uniform(15_000_000) + 5_000_000,
        miner: generate_address(),
        size_bytes: :rand.uniform(100_000) + 20_000
      },
      priority: :high,
      category: :blockchain
    })
  end

  defp generate_transaction_event(base_event, chain_name) do
    value_eth = :rand.uniform(100) + 0.1

    Map.merge(base_event, %{
      title: "Transaction #{Float.round(value_eth, 3)} ETH",
      description: "Transaction processed on #{format_chain_name(chain_name)}",
      data: %{
        hash: generate_hash(),
        from: generate_address(),
        to: generate_address(),
        value: value_eth,
        gas_price: :rand.uniform(100) + 20,
        gas_used: :rand.uniform(100_000) + 21_000
      },
      priority: :medium,
      category: :transaction
    })
  end

  defp generate_network_status_event(base_event, chain_name) do
    status_types = [
      "High network activity",
      "Gas price spike",
      "Network congestion",
      "Fast confirmation times"
    ]

    status = Enum.random(status_types)

    Map.merge(base_event, %{
      title: "Network Status: #{status}",
      description: "#{format_chain_name(chain_name)} network update",
      data: %{
        status: status,
        tps: :rand.uniform(1000) + 100,
        avg_gas_price: :rand.uniform(200) + 20,
        pending_transactions: :rand.uniform(50_000) + 10_000
      },
      priority: :low,
      category: :network
    })
  end

  defp generate_subscription_event(base_event, chain_name) do
    subscription_types = ["newHeads", "pendingTransactions", "logs", "newPendingTransactions"]
    sub_type = Enum.random(subscription_types)

    Map.merge(base_event, %{
      title: "Subscription Update: #{sub_type}",
      description: "WebSocket subscription event on #{format_chain_name(chain_name)}",
      data: %{
        subscription_type: sub_type,
        subscriber_count: :rand.uniform(100) + 10,
        events_per_second: :rand.uniform(50) + 5
      },
      priority: :low,
      category: :websocket
    })
  end

  defp generate_event_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_hash do
    "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  defp generate_address do
    "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
  end

  defp format_chain_name(chain_name) do
    case chain_name do
      :ethereum -> "Ethereum"
      :polygon -> "Polygon"
      :arbitrum -> "Arbitrum"
      :bsc -> "BSC"
      _ -> String.capitalize("#{chain_name}")
    end
  end

  defp weighted_random(items, weights) do
    total_weight = Enum.sum(weights)
    random_value = :rand.uniform(total_weight)

    {item, _} =
      items
      |> Enum.zip(weights)
      |> Enum.reduce_while({nil, 0}, fn {item, weight}, {_current_item, cumulative} ->
        new_cumulative = cumulative + weight

        if random_value <= new_cumulative do
          {:halt, {item, new_cumulative}}
        else
          {:cont, {item, new_cumulative}}
        end
      end)

    item
  end
end
