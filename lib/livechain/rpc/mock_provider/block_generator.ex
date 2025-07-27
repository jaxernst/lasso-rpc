defmodule Livechain.RPC.MockProvider.BlockGenerator do
  @moduledoc """
  Generates simulated blockchain blocks at regular intervals.

  This module simulates the block generation process of a real blockchain,
  creating new blocks at configurable intervals and broadcasting them
  to subscribers.
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts a block generator process.
  """
  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: via_name(state.name))
  end

  @doc """
  Gets the current block number.
  """
  def get_current_block(pid) do
    GenServer.call(pid, :get_current_block)
  end

  @doc """
  Manually triggers a new block generation.
  """
  def generate_block(pid) do
    GenServer.cast(pid, :generate_block)
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Logger.info("Starting block generator for #{state.name} (block time: #{state.block_time}ms)")

    # Schedule the first block
    Process.send_after(self(), :generate_block, state.block_time)

    {:ok, %{state | current_block: 0}}
  end

  @impl true
  def handle_call(:get_current_block, _from, state) do
    {:reply, state.current_block, state}
  end

  @impl true
  def handle_cast(:generate_block, state) do
    new_block_number = state.current_block + 1
    block_data = generate_block_data(new_block_number, state.chain_id)

    Logger.debug("Generated block #{new_block_number} for #{state.name}")

    # Notify the parent provider
    send(state.provider_pid, {:new_block, new_block_number, block_data})

    # Schedule the next block
    Process.send_after(self(), :generate_block, state.block_time)

    {:noreply, %{state | current_block: new_block_number}}
  end

  @impl true
  def handle_info(:generate_block, state) do
    GenServer.cast(self(), :generate_block)
    {:noreply, state}
  end

  # Private functions

  defp via_name(name) do
    {:via, :global, {:block_generator, name}}
  end

  defp generate_block_data(block_number, chain_id) do
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
end
