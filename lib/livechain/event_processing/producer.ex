defmodule Livechain.EventProcessing.Producer do
  @moduledoc """
  Broadway producer that consumes blockchain events from the message aggregator.

  This producer subscribes to aggregated blockchain messages and feeds them
  into the Broadway pipeline for structured processing and enrichment.
  """

  use GenStage
  require Logger

  defstruct [
    :chain,
    :demand,
    :events
  ]

  @doc """
  Starts the producer for a specific blockchain.
  """
  def start_link(opts) do
    chain = Keyword.fetch!(opts, :chain)
    GenStage.start_link(__MODULE__, chain, name: via_name(chain))
  end

  # GenStage callbacks

  @impl true
  def init(opts) when is_list(opts) do
    chain = Keyword.fetch!(opts, :chain)
    Logger.info("Starting Broadway producer for chain: #{chain}")

    # Subscribe to aggregated messages for this chain
    Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:#{chain}")

    # Also subscribe to blockchain messages  
    Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{chain}")

    state = %__MODULE__{
      chain: chain,
      demand: 0,
      events: :queue.new()
    }

    {:producer, state}
  end

  @impl true
  def init(chain) when is_binary(chain) do
    Logger.info("Starting Broadway producer for chain: #{chain}")

    # Subscribe to aggregated messages for this chain
    Phoenix.PubSub.subscribe(Livechain.PubSub, "aggregated:#{chain}")

    # Also subscribe to blockchain messages  
    Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:#{chain}")

    state = %__MODULE__{
      chain: chain,
      demand: 0,
      events: :queue.new()
    }

    {:producer, state}
  end

  @impl true
  def handle_demand(demand, state) do
    Logger.debug("Broadway producer received demand: #{demand} for chain: #{state.chain}")
    
    new_state = %{state | demand: state.demand + demand}
    dispatch_events(new_state)
  end

  @impl true
  def handle_info({:fastest_message, provider_id, message}, state) do
    Logger.debug("Producer received fastest message from #{provider_id} for #{state.chain}")
    
    event = create_event(message, provider_id, state.chain)
    new_events = :queue.in(event, state.events)
    new_state = %{state | events: new_events}
    
    dispatch_events(new_state)
  end

  @impl true
  def handle_info({:blockchain_message, message}, state) do
    Logger.debug("Producer received blockchain message for #{state.chain}")
    
    event = create_event(message, "unknown", state.chain)
    new_events = :queue.in(event, state.events)
    new_state = %{state | events: new_events}
    
    dispatch_events(new_state)
  end

  @impl true
  def handle_info({:raw_message, provider_id, message, received_at}, state) do
    Logger.debug("Producer received raw message from #{provider_id} for #{state.chain}")
    
    event = create_event_with_timestamp(message, provider_id, state.chain, received_at)
    new_events = :queue.in(event, state.events)
    new_state = %{state | events: new_events}
    
    dispatch_events(new_state)
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("Producer received unhandled message: #{inspect(message)}")
    {:noreply, [], state}
  end

  # Private functions

  defp dispatch_events(%{demand: 0} = state) do
    {:noreply, [], state}
  end

  defp dispatch_events(%{demand: demand, events: events} = state) when demand > 0 do
    case :queue.out(events) do
      {{:value, event}, remaining_events} ->
        new_state = %{state | demand: demand - 1, events: remaining_events}
        {:noreply, [event], new_state}

      {:empty, _} ->
        {:noreply, [], state}
    end
  end

  defp create_event(message, provider_id, chain) do
    create_event_with_timestamp(message, provider_id, chain, System.system_time(:millisecond))
  end

  defp create_event_with_timestamp(message, provider_id, chain, received_at) do
    # Ensure message has metadata
    enriched_message = if is_map(message) do
      livechain_meta = Map.get(message, "_livechain_meta", %{})
      
      updated_meta = Map.merge(livechain_meta, %{
        "provider_id" => provider_id,
        "chain_name" => chain,
        "received_at" => received_at,
        "producer_processed_at" => System.system_time(:millisecond)
      })

      Map.put(message, "_livechain_meta", updated_meta)
    else
      %{
        "raw_data" => message,
        "_livechain_meta" => %{
          "provider_id" => provider_id,
          "chain_name" => chain,
          "received_at" => received_at,
          "producer_processed_at" => System.system_time(:millisecond)
        }
      }
    end

    # Add event metadata for Broadway processing
    %{
      id: generate_event_id(),
      data: enriched_message,
      metadata: %{
        chain: chain,
        provider_id: provider_id,
        received_at: received_at,
        source: :message_aggregator
      }
    }
  end

  defp generate_event_id do
    System.unique_integer([:positive])
  end

  defp via_name(chain) do
    :"#{__MODULE__}.#{chain}"
  end
end