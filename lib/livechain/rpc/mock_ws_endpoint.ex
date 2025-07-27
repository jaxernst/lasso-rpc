defmodule Livechain.RPC.MockWSEndpoint do
  @moduledoc """
  A mock WebSocket endpoint that simulates blockchain RPC connections.

  This module provides a drop-in replacement for real WebSocket endpoints
  during development and testing. It uses the MockProvider to simulate
  blockchain data feeds without requiring actual network connections.

  ## Features

  - **Realistic Simulation**: Generates realistic blockchain data
  - **Configurable Behavior**: Customizable latency, failure rates, and block times
  - **Event Streaming**: Simulates WebSocket subscription events
  - **Easy Integration**: Compatible with existing WSEndpoint structure
  - **Multiple Networks**: Supports different blockchain networks

  ## Usage

      # Create a mock Ethereum endpoint
      endpoint = Livechain.RPC.MockWSEndpoint.new(
        id: "mock_ethereum",
        name: "Mock Ethereum",
        chain_id: 1,
        block_time: 12_000,
        failure_rate: 0.01
      )

      # Use with existing WSSupervisor
      {:ok, _pid} = Livechain.RPC.WSSupervisor.start_connection(endpoint)
  """

  alias Livechain.RPC.{WSEndpoint, MockProvider}

  @type t :: %__MODULE__{
          # Inherit from WSEndpoint
          id: String.t(),
          name: String.t(),
          url: String.t(),
          chain_id: non_neg_integer(),
          api_key: String.t() | nil,
          timeout: non_neg_integer(),
          max_retries: non_neg_integer(),
          enabled: boolean(),
          ws_url: String.t(),
          reconnect_interval: non_neg_integer(),
          heartbeat_interval: non_neg_integer(),
          max_reconnect_attempts: non_neg_integer() | :infinity,
          subscription_topics: [String.t()],

          # Mock-specific fields
          mock_provider: pid() | nil,
          block_time: non_neg_integer(),
          failure_rate: float(),
          latency_range: {non_neg_integer(), non_neg_integer()},
          enable_events: boolean()
        }

  defstruct [
    # Base WSEndpoint fields
    :id,
    :name,
    :url,
    :chain_id,
    :api_key,
    :ws_url,
    timeout: 30_000,
    max_retries: 3,
    enabled: true,
    reconnect_interval: 5_000,
    heartbeat_interval: 30_000,
    max_reconnect_attempts: :infinity,
    subscription_topics: [],

    # Mock-specific fields
    mock_provider: nil,
    block_time: 12_000,
    failure_rate: 0.0,
    latency_range: {50, 200},
    enable_events: true
  ]

  @doc """
  Creates a new mock WebSocket endpoint configuration.

  ## Examples

      iex> Livechain.RPC.MockWSEndpoint.new(
      ...>   id: "mock_ethereum",
      ...>   name: "Mock Ethereum",
      ...>   chain_id: 1,
      ...>   block_time: 12_000,
      ...>   failure_rate: 0.01
      ...> )
      %Livechain.RPC.MockWSEndpoint{
        id: "mock_ethereum",
        name: "Mock Ethereum",
        chain_id: 1,
        block_time: 12000,
        failure_rate: 0.01,
        ...
      }
  """
  def new(attrs) do
    # Set default URLs for mock endpoints
    attrs =
      attrs
      |> Keyword.put_new(:url, "mock://#{attrs[:id]}")
      |> Keyword.put_new(:ws_url, "mock://#{attrs[:id]}/ws")

    struct(__MODULE__, attrs)
  end

  @doc """
  Converts a WSEndpoint to a MockWSEndpoint.
  """
  def from_ws_endpoint(%WSEndpoint{} = endpoint, mock_opts \\ []) do
    struct(__MODULE__, Map.from_struct(endpoint) |> Map.merge(Enum.into(mock_opts, %{})))
  end

  @doc """
  Creates a mock endpoint for a specific blockchain network.

  ## Examples

      # Ethereum Mainnet
      ethereum = Livechain.RPC.MockWSEndpoint.ethereum_mainnet()

      # Polygon
      polygon = Livechain.RPC.MockWSEndpoint.polygon()

      # Arbitrum
      arbitrum = Livechain.RPC.MockWSEndpoint.arbitrum()
  """
  def ethereum_mainnet() do
    ethereum_mainnet([])
  end

  def ethereum_mainnet(opts) do
    new(
      [
        id: "mock_ethereum_mainnet",
        name: "Mock Ethereum Mainnet",
        chain_id: 1,
        block_time: 12_000,
        failure_rate: 0.01
      ] ++ opts
    )
  end

  def polygon() do
    polygon([])
  end

  def polygon(opts) do
    new(
      [
        id: "mock_polygon",
        name: "Mock Polygon",
        chain_id: 137,
        block_time: 2_000,
        failure_rate: 0.005
      ] ++ opts
    )
  end

  def arbitrum() do
    arbitrum([])
  end

  def arbitrum(opts) do
    new(
      [
        id: "mock_arbitrum",
        name: "Mock Arbitrum",
        chain_id: 42_161,
        block_time: 1_000,
        failure_rate: 0.002
      ] ++ opts
    )
  end

  def bsc() do
    bsc([])
  end

  def bsc(opts) do
    new(
      [
        id: "mock_bsc",
        name: "Mock BSC",
        chain_id: 56,
        block_time: 3_000,
        failure_rate: 0.008
      ] ++ opts
    )
  end

  @doc """
  Validates that a mock WebSocket endpoint configuration is complete and valid.

  Returns `{:ok, endpoint}` if valid, `{:error, reason}` otherwise.
  """
  def validate(%__MODULE__{} = endpoint) do
    with {:ok, _} <- validate_base(endpoint),
         {:ok, _} <- validate_mock_specific(endpoint) do
      {:ok, endpoint}
    end
  end

  defp validate_base(endpoint) do
    cond do
      is_nil(endpoint.id) or endpoint.id == "" ->
        {:error, "Endpoint ID is required"}

      is_nil(endpoint.name) or endpoint.name == "" ->
        {:error, "Endpoint name is required"}

      is_nil(endpoint.chain_id) ->
        {:error, "Chain ID is required"}

      endpoint.timeout <= 0 ->
        {:error, "Timeout must be greater than 0"}

      endpoint.max_retries < 0 ->
        {:error, "Max retries must be non-negative"}

      endpoint.block_time <= 0 ->
        {:error, "Block time must be greater than 0"}

      endpoint.failure_rate < 0.0 or endpoint.failure_rate > 1.0 ->
        {:error, "Failure rate must be between 0.0 and 1.0"}

      true ->
        {:ok, endpoint}
    end
  end

  defp validate_mock_specific(endpoint) do
    {min_latency, max_latency} = endpoint.latency_range

    cond do
      min_latency < 0 ->
        {:error, "Minimum latency must be non-negative"}

      max_latency <= min_latency ->
        {:error, "Maximum latency must be greater than minimum latency"}

      true ->
        {:ok, endpoint}
    end
  end

  @doc """
  Gets the mock provider process for this endpoint.
  """
  def get_mock_provider(%__MODULE__{} = endpoint) do
    case endpoint.mock_provider do
      nil ->
        {:error, :not_started}

      pid when is_pid(pid) ->
        {:ok, pid}

      _ ->
        {:error, :invalid_provider}
    end
  end

  @doc """
  Starts the mock provider for this endpoint.
  """
  def start_mock_provider(%__MODULE__{} = endpoint) do
    mock_opts = [
      chain_id: endpoint.chain_id,
      name: endpoint.name,
      block_time: endpoint.block_time,
      failure_rate: endpoint.failure_rate,
      latency_range: endpoint.latency_range,
      enable_events: endpoint.enable_events
    ]

    case MockProvider.start_link(mock_opts) do
      {:ok, pid} ->
        %{endpoint | mock_provider: pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the mock provider for this endpoint.
  """
  def stop_mock_provider(%__MODULE__{} = endpoint) do
    case endpoint.mock_provider do
      nil ->
        :ok

      pid when is_pid(pid) ->
        GenServer.stop(pid)
        %{endpoint | mock_provider: nil}

      _ ->
        %{endpoint | mock_provider: nil}
    end
  end
end
