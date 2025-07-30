defmodule Livechain.RPC.MockProvider do
  @moduledoc """
  A mock RPC provider that simulates blockchain data feeds for testing and development.

  This module provides a realistic simulation of blockchain RPC endpoints, including:
  - Simulated block generation
  - Transaction processing
  - Event streaming
  - Network latency simulation
  - Failure scenarios for testing reliability

  ## Features

  - **Realistic Data**: Generates realistic blockchain data structures
  - **Configurable Latency**: Simulates network delays and processing time
  - **Failure Simulation**: Can be configured to simulate various failure modes
  - **Event Streaming**: Provides WebSocket-like event streaming
  - **Multiple Chains**: Supports simulation of different blockchain networks

  ## Usage

      # Start a mock Ethereum provider
      {:ok, provider} = Livechain.RPC.MockProvider.start_link(
        chain_id: 1,
        name: "Mock Ethereum",
        block_time: 12_000,  # 12 seconds
        failure_rate: 0.01   # 1% failure rate
      )

      # Subscribe to new blocks
      Livechain.RPC.MockProvider.subscribe(provider, "newHeads")

      # Get current block
      {:ok, block} = Livechain.RPC.MockProvider.get_block_by_number(provider, "latest")
  """

  use GenServer
  require Logger

  alias Livechain.RPC.MockProvider.{BlockGenerator, EventStream}

  # Client API

  @doc """
  Starts a mock RPC provider.

  ## Options

  - `chain_id`: The blockchain network ID (default: 1 for Ethereum)
  - `name`: Provider name (default: "Mock Provider")
  - `block_time`: Time between blocks in milliseconds (default: 12_000)
  - `failure_rate`: Probability of simulated failures (default: 0.0)
  - `latency_range`: Range of simulated latency in milliseconds (default: {50, 200})
  - `enable_events`: Whether to enable event streaming (default: true)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: via_name(opts[:name] || "mock_provider"))
  end

  @doc """
  Gets the current block number.
  """
  def get_block_number(provider) do
    GenServer.call(provider, :get_block_number)
  end

  @doc """
  Gets a block by number or tag.
  """
  def get_block_by_number(provider, number) do
    GenServer.call(provider, {:get_block_by_number, number})
  end

  @doc """
  Gets transaction count for an address.
  """
  def get_transaction_count(provider, address) do
    GenServer.call(provider, {:get_transaction_count, address})
  end

  @doc """
  Gets balance for an address.
  """
  def get_balance(provider, address) do
    GenServer.call(provider, {:get_balance, address})
  end

  @doc """
  Subscribes to events.
  """
  def subscribe(provider, topic) do
    GenServer.cast(provider, {:subscribe, topic})
  end

  @doc """
  Unsubscribes from events.
  """
  def unsubscribe(provider, topic) do
    GenServer.cast(provider, {:unsubscribe, topic})
  end

  @doc """
  Sends a custom RPC request.
  """
  def call(provider, method, params \\ []) do
    GenServer.call(provider, {:rpc_call, method, params})
  end

  @doc """
  Gets provider status and statistics.
  """
  def status(provider) do
    GenServer.call(provider, :status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    chain_id = opts[:chain_id] || 1
    name = opts[:name] || "Mock Provider"
    block_time = opts[:block_time] || 12_000
    failure_rate = opts[:failure_rate] || 0.0
    latency_range = opts[:latency_range] || {50, 200}
    enable_events = opts[:enable_events] != false

    Logger.info("Starting mock RPC provider: #{name} (Chain ID: #{chain_id})")

    state = %{
      chain_id: chain_id,
      name: name,
      block_time: block_time,
      failure_rate: failure_rate,
      latency_range: latency_range,
      enable_events: enable_events,
      current_block: 0,
      subscribers: MapSet.new(),
      block_generator: nil,
      event_stream: nil,
      provider_pid: nil,
      stats: %{
        total_requests: 0,
        successful_requests: 0,
        failed_requests: 0,
        events_sent: 0
      }
    }

    # Set provider_pid first
    state = %{state | provider_pid: self()}

    # Start block generator if events are enabled
    state =
      if enable_events do
        {:ok, block_gen} = BlockGenerator.start_link(state)
        %{state | block_generator: block_gen}
      else
        state
      end

    # Start event stream
    {:ok, event_stream} = EventStream.start_link(state)
    state = %{state | event_stream: event_stream}

    {:ok, state}
  end

  @impl true
  def handle_call(:get_block_number, _from, state) do
    response =
      simulate_latency(
        fn ->
          if should_fail?(state.failure_rate) do
            {:error, "Simulated failure"}
          else
            {:ok, state.current_block}
          end
        end,
        state.latency_range
      )

    state = update_stats(state, response)
    {:reply, response, state}
  end

  @impl true
  def handle_call({:get_block_by_number, "latest"}, _from, state) do
    response =
      simulate_latency(
        fn ->
          if should_fail?(state.failure_rate) do
            {:error, "Simulated failure"}
          else
            {:ok, generate_block(state.current_block, state.chain_id)}
          end
        end,
        state.latency_range
      )

    state = update_stats(state, response)
    {:reply, response, state}
  end

  @impl true
  def handle_call({:get_block_by_number, number}, _from, state) when is_integer(number) do
    response =
      simulate_latency(
        fn ->
          if should_fail?(state.failure_rate) do
            {:error, "Simulated failure"}
          else
            if number <= state.current_block do
              {:ok, generate_block(number, state.chain_id)}
            else
              {:error, "Block not found"}
            end
          end
        end,
        state.latency_range
      )

    state = update_stats(state, response)
    {:reply, response, state}
  end

  @impl true
  def handle_call({:get_transaction_count, address}, _from, state) do
    response =
      simulate_latency(
        fn ->
          if should_fail?(state.failure_rate) do
            {:error, "Simulated failure"}
          else
            # Generate a realistic transaction count based on address
            count = :crypto.hash(:sha256, address) |> :binary.decode_unsigned() |> rem(1000)
            {:ok, count}
          end
        end,
        state.latency_range
      )

    state = update_stats(state, response)
    {:reply, response, state}
  end

  @impl true
  def handle_call({:get_balance, address}, _from, state) do
    response =
      simulate_latency(
        fn ->
          if should_fail?(state.failure_rate) do
            {:error, "Simulated failure"}
          else
            # Generate a realistic balance based on address
            balance =
              :crypto.hash(:sha256, address)
              |> :binary.decode_unsigned()
              |> rem(1_000_000_000_000_000_000_000)

            {:ok, balance}
          end
        end,
        state.latency_range
      )

    state = update_stats(state, response)
    {:reply, response, state}
  end

  @impl true
  def handle_call({:rpc_call, method, params}, _from, state) do
    response =
      simulate_latency(
        fn ->
          if should_fail?(state.failure_rate) do
            {:error, "Simulated failure"}
          else
            handle_rpc_method(method, params, state)
          end
        end,
        state.latency_range
      )

    state = update_stats(state, response)
    {:reply, response, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      name: state.name,
      chain_id: state.chain_id,
      current_block: state.current_block,
      subscribers: MapSet.size(state.subscribers),
      stats: state.stats,
      failure_rate: state.failure_rate,
      latency_range: state.latency_range
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:subscribe, topic}, state) do
    state = %{state | subscribers: MapSet.put(state.subscribers, topic)}
    Logger.info("New subscription to #{topic} on #{state.name}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:unsubscribe, topic}, state) do
    state = %{state | subscribers: MapSet.delete(state.subscribers, topic)}
    Logger.info("Unsubscribed from #{topic} on #{state.name}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:new_block, block_number, block_data}, state) do
    state = %{state | current_block: block_number}

    state = if state.enable_events do
      EventStream.broadcast(state.event_stream, "newHeads", block_data)
      
      # Also broadcast to Phoenix PubSub for channels
      broadcast_to_channels(state, "new_block", block_data)
      
      update_event_stats(state)
    else
      state
    end

    {:noreply, state}
  end

  # Private functions

  defp via_name(name) do
    {:via, :global, {:mock_provider, name}}
  end

  defp simulate_latency(fun, {min_latency, max_latency}) do
    latency = :rand.uniform(max_latency - min_latency) + min_latency
    Process.sleep(latency)
    fun.()
  end

  defp should_fail?(failure_rate) do
    :rand.uniform() < failure_rate
  end

  defp update_stats(state, {:ok, _}) do
    %{
      state
      | stats: %{
          state.stats
          | total_requests: state.stats.total_requests + 1,
            successful_requests: state.stats.successful_requests + 1
        }
    }
  end

  defp update_stats(state, {:error, _}) do
    %{
      state
      | stats: %{
          state.stats
          | total_requests: state.stats.total_requests + 1,
            failed_requests: state.stats.failed_requests + 1
        }
    }
  end

  defp update_event_stats(state) do
    %{state | stats: %{state.stats | events_sent: state.stats.events_sent + 1}}
  end

  defp generate_block(block_number, chain_id) do
    %{
      "number" => "0x#{Integer.to_string(block_number, 16)}",
      "hash" => generate_block_hash(block_number),
      "parentHash" => generate_block_hash(block_number - 1),
      "timestamp" => "0x#{Integer.to_string(System.system_time(:second), 16)}",
      "transactions" => generate_transactions(block_number),
      "gasLimit" => "0x1c9c380",
      "gasUsed" => "0x#{Integer.to_string(:rand.uniform(1_000_000), 16)}",
      "miner" => "0x#{generate_address()}",
      "difficulty" => "0x#{Integer.to_string(:rand.uniform(1_000_000_000), 16)}",
      "totalDifficulty" => "0x#{Integer.to_string(block_number * 1_000_000_000, 16)}",
      "size" => "0x#{Integer.to_string(:rand.uniform(100_000), 16)}",
      "extraData" => "0x",
      "nonce" => "0x#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}",
      "baseFeePerGas" => "0x#{Integer.to_string(:rand.uniform(100_000_000_000), 16)}",
      "chainId" => chain_id
    }
  end

  defp generate_block_hash(block_number) do
    :crypto.hash(:sha256, "block_#{block_number}")
    |> Base.encode16(case: :lower)
    |> then(&"0x#{&1}")
  end

  defp generate_transactions(block_number) do
    count = :rand.uniform(100)

    Enum.map(1..count, fn i ->
      %{
        "hash" => "0x#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}",
        "nonce" => "0x#{Integer.to_string(:rand.uniform(1_000_000), 16)}",
        "blockHash" => generate_block_hash(block_number),
        "blockNumber" => "0x#{Integer.to_string(block_number, 16)}",
        "transactionIndex" => "0x#{Integer.to_string(i - 1, 16)}",
        "from" => "0x#{generate_address()}",
        "to" => "0x#{generate_address()}",
        "value" => "0x#{Integer.to_string(:rand.uniform(1_000_000_000_000_000_000), 16)}",
        "gas" => "0x#{Integer.to_string(:rand.uniform(100_000), 16)}",
        "gasPrice" => "0x#{Integer.to_string(:rand.uniform(100_000_000_000), 16)}",
        "input" => "0x",
        "v" => "0x#{Integer.to_string(:rand.uniform(255), 16)}",
        "r" => "0x#{Integer.to_string(:rand.uniform(1_000_000_000_000_000_000), 16)}",
        "s" => "0x#{Integer.to_string(:rand.uniform(1_000_000_000_000_000_000), 16)}"
      }
    end)
  end

  defp generate_address do
    :crypto.strong_rand_bytes(20)
    |> Base.encode16(case: :lower)
  end

  defp handle_rpc_method("eth_blockNumber", _params, state) do
    {:ok, "0x#{Integer.to_string(state.current_block, 16)}"}
  end

  defp handle_rpc_method("eth_getBlockByNumber", [number, _full_tx], state) do
    case number do
      "latest" ->
        {:ok, generate_block(state.current_block, state.chain_id)}

      "earliest" ->
        {:ok, generate_block(0, state.chain_id)}

      "pending" ->
        {:ok, nil}

      _ when is_binary(number) ->
        case Integer.parse(number, 16) do
          {block_num, ""} -> {:ok, generate_block(block_num, state.chain_id)}
          _ -> {:error, "Invalid block number"}
        end
    end
  end

  defp handle_rpc_method("eth_getTransactionCount", [address, _block], _state) do
    count = :crypto.hash(:sha256, address) |> :binary.decode_unsigned() |> rem(1000)
    {:ok, "0x#{Integer.to_string(count, 16)}"}
  end

  defp handle_rpc_method("eth_getBalance", [address, _block], _state) do
    balance =
      :crypto.hash(:sha256, address)
      |> :binary.decode_unsigned()
      |> rem(1_000_000_000_000_000_000_000)

    {:ok, "0x#{Integer.to_string(balance, 16)}"}
  end

  defp handle_rpc_method("eth_subscribe", [_topic], _state) do
    subscription_id = "0x#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
    {:ok, subscription_id}
  end

  defp handle_rpc_method("eth_unsubscribe", [_subscription_id], _state) do
    {:ok, true}
  end

  defp handle_rpc_method(_method, _params, _state) do
    {:error, "Method not implemented in mock provider"}
  end

  defp broadcast_to_channels(state, event_type, data) do
    # Map chain_id to chain name for PubSub topics
    chain_name = case state.chain_id do
      1 -> "ethereum"
      137 -> "polygon"
      42_161 -> "arbitrum"
      56 -> "bsc"
      _ -> "unknown"
    end

    # Broadcast to general blockchain channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "blockchain:#{chain_name}",
      %{event: event_type, payload: data}
    )

    # Broadcast to specific event type channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "blockchain:#{chain_name}:blocks",
      %{event: event_type, payload: data}
    )
  end
end
