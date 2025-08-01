defmodule Livechain.EventProcessing.Pipeline do
  @moduledoc """
  Broadway pipeline for processing blockchain events.

  This pipeline takes raw blockchain messages and transforms them into structured,
  enriched events with additional metadata like:
  - USD values for token transfers
  - Contract metadata and labels
  - Event classification and tagging
  - Cross-chain event normalization

  The pipeline publishes processed events to Phoenix PubSub for consumption by
  LiveView dashboards, analytics APIs, and external subscribers.
  """

  use Broadway
  require Logger

  alias Livechain.EventProcessing.{EventEnricher, EventClassifier, PriceOracle}

  @doc """
  Starts the Broadway pipeline for a specific chain.
  """
  def start_link(chain_name) do
    Broadway.start_link(__MODULE__,
      name: via_name(chain_name),
      producer: [
        module: {Livechain.EventProcessing.Producer, chain: chain_name},
        transformer: {__MODULE__, :transform, []}
      ],
      processors: [
        default: [
          concurrency: 10,
          min_demand: 5,
          max_demand: 20
        ]
      ],
      batchers: [
        analytics: [
          concurrency: 2,
          batch_size: 50,
          batch_timeout: 2000
        ],
        notifications: [
          concurrency: 5,
          batch_size: 10,
          batch_timeout: 1000
        ]
      ]
    )
  end

  @doc """
  Transform raw messages into Broadway messages.
  """
  def transform(event, _opts) do
    %Broadway.Message{
      data: event,
      acknowledger: {__MODULE__, :ack_id, :ack_data}
    }
  end

  # Broadway callbacks

  @impl true
  def handle_message(_processor, %Broadway.Message{data: event} = message, _context) do
    try do
      # Classify the event type
      event_type = EventClassifier.classify(event)
      
      # Enrich with additional metadata
      enriched_event = EventEnricher.enrich(event, event_type)
      
      # Add USD pricing for token transfers
      priced_event = add_usd_pricing(enriched_event, event_type)
      
      # Add routing information for batchers
      message
      |> Broadway.Message.put_data(priced_event)
      |> add_batcher_routing(event_type)
      
    rescue
      error ->
        Logger.error("Failed to process event: #{inspect(error)}")
        Broadway.Message.failed(message, error)
    end
  end

  @impl true
  def handle_batch(:analytics, messages, _batch_info, _context) do
    # Batch process events for analytics storage
    events = Enum.map(messages, & &1.data)
    
    Logger.info("Processing #{length(events)} events for analytics")
    
    # Store in time-series database (implement later)
    # Livechain.Analytics.store_events(events)
    
    # Publish aggregated metrics
    publish_analytics_metrics(events)
    
    messages
  end

  @impl true
  def handle_batch(:notifications, messages, _batch_info, _context) do
    # Process events that need immediate notification
    events = Enum.map(messages, & &1.data)
    
    Logger.info("Processing #{length(events)} events for notifications")
    
    # Publish to real-time channels
    Enum.each(events, &publish_real_time_event/1)
    
    messages
  end

  # Private functions

  defp add_usd_pricing(event, event_type) do
    case event_type do
      :erc20_transfer ->
        add_token_usd_value(event)
        
      :native_transfer ->
        add_native_usd_value(event)
        
      _ ->
        event
    end
  end

  defp add_token_usd_value(event) do
    with {:ok, token_address} <- Map.fetch(event, :token_address),
         {:ok, amount} <- Map.fetch(event, :amount),
         {:ok, usd_price} <- PriceOracle.get_token_price(token_address, event.chain) do
      
      usd_value = calculate_usd_value(amount, usd_price, event.decimals || 18)
      
      Map.put(event, :usd_value, usd_value)
    else
      _ ->
        Map.put(event, :usd_value, nil)
    end
  end

  defp add_native_usd_value(event) do
    with {:ok, amount} <- Map.fetch(event, :amount),
         {:ok, usd_price} <- PriceOracle.get_native_price(event.chain) do
      
      usd_value = calculate_usd_value(amount, usd_price, 18)
      
      Map.put(event, :usd_value, usd_value)
    else
      _ ->
        Map.put(event, :usd_value, nil)
    end
  end

  defp calculate_usd_value(amount, price, decimals) do
    amount
    |> Decimal.new()
    |> Decimal.div(Decimal.new(10) |> Decimal.power(decimals))
    |> Decimal.mult(Decimal.new(price))
    |> Decimal.to_float()
  end

  defp add_batcher_routing(message, event_type) do
    case event_type do
      type when type in [:erc20_transfer, :native_transfer, :nft_transfer] ->
        Broadway.Message.put_batcher(message, :notifications)
        
      type when type in [:block, :transaction] ->
        Broadway.Message.put_batcher(message, :analytics)
        
      _ ->
        Broadway.Message.put_batcher(message, :analytics)
    end
  end

  defp publish_analytics_metrics(events) do
    # Group events by type and calculate metrics
    metrics = events
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, type_events} ->
      %{
        type: type,
        count: length(type_events),
        total_usd_value: calculate_total_usd_value(type_events),
        timestamp: System.system_time(:millisecond)
      }
    end)

    # Publish metrics to analytics channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "analytics:metrics",
      {:metrics_batch, metrics}
    )
  end

  defp publish_real_time_event(event) do
    # Publish to chain-specific channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "events:#{event.chain}",
      {:structured_event, event}
    )

    # Publish to type-specific channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "events:#{event.type}",
      {:structured_event, event}
    )

    # Publish to global events channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "events:all",
      {:structured_event, event}
    )

    # Publish to Broadway processing channel for dashboard
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "broadway:processed",
      {:broadway_processed, event}
    )

    # Also publish to chain-specific Broadway channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "broadway:#{event.chain}",
      {:broadway_processed, event}
    )
  end

  defp calculate_total_usd_value(events) do
    events
    |> Enum.map(&Map.get(&1, :usd_value, 0))
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  defp via_name(chain_name) do
    :"#{__MODULE__}.#{chain_name}"
  end

  # Acknowledger callbacks (required by Broadway)
  def ack(_ack_ref, _successful, _failed) do
    :ok
  end
end