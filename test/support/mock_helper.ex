defmodule Livechain.Test.MockHelper do
  @moduledoc """
  Test helpers for mock provider setup.

  Simplifies common mock provider patterns in integration tests.
  """

  alias Livechain.Testing.MockProvider

  @doc """
  Creates a fast, reliable mock provider for testing the happy path.

  ## Example

      test "happy path" do
        {:ok, provider_id} = MockHelper.create_fast_mock("ethereum")
        # Provider is ready for routing
      end
  """
  def create_fast_mock(chain, opts \\ []) do
    id = Keyword.get(opts, :id, "mock_fast_#{unique_id()}")

    MockProvider.start_mock(chain, %{
      id: id,
      latency: 10,
      reliability: 1.0,
      block_number: Keyword.get(opts, :block_number, 0x1000)
    })
  end

  @doc """
  Creates a slow, unreliable mock provider for testing failover.

  ## Example

      test "failover behavior" do
        {:ok, _fast} = MockHelper.create_fast_mock("ethereum")
        {:ok, _slow} = MockHelper.create_slow_mock("ethereum")
        # Test will use fast mock first, slow as backup
      end
  """
  def create_slow_mock(chain, opts \\ []) do
    id = Keyword.get(opts, :id, "mock_slow_#{unique_id()}")

    MockProvider.start_mock(chain, %{
      id: id,
      latency: 500,
      reliability: Keyword.get(opts, :reliability, 0.7)
    })
  end

  @doc """
  Creates multiple mock providers with varied characteristics.

  ## Example

      test "load balancing" do
        {:ok, providers} = MockHelper.create_provider_pool("ethereum", 3)
        # Creates mock_1, mock_2, mock_3 with different latencies
      end
  """
  def create_provider_pool(chain, count, opts \\ []) do
    base_latency = Keyword.get(opts, :base_latency, 50)

    specs =
      Enum.map(1..count, fn i ->
        %{
          id: "mock_#{i}",
          latency: base_latency * i,
          reliability: 1.0,
          priority: 100 - i * 10
        }
      end)

    MockProvider.start_mocks(chain, specs)
  end

  defp unique_id do
    :erlang.unique_integer([:positive])
  end
end
