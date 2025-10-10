defmodule Lasso.RPC.SelectionTest do
  @moduledoc """
  Tests for provider selection algorithms and failover logic.

  This tests the core logic that determines which provider to route requests to
  based on performance, availability, and strategy configuration.
  """

  use ExUnit.Case, async: false
  import Mox

  setup_all do
    # Ensure test environment is ready with all services
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  setup do
    # Mock the HTTP client for any background operations
    stub(Lasso.RPC.HttpClientMock, :request, &MockHttpClient.request/4)

    # Clean any existing metrics to ensure clean test state
    TestHelper.ensure_clean_state()

    # Start provider pools for the test chains if needed
    ensure_provider_pool_started("ethereum")
    ensure_provider_pool_started("polygon")

    :ok
  end

  defp ensure_provider_pool_started(chain_name) do
    # Check if provider pool is already running
    case Registry.lookup(Lasso.Registry, {:provider_pool, chain_name}) do
      [] ->
        # Provider pool not running, try to start it via ChainSupervisor
        case Lasso.Config.ConfigStore.get_chain(chain_name) do
          {:ok, chain_config} ->
            # Start minimal provider pool for testing
            case Lasso.RPC.ProviderPool.start_link({chain_name, chain_config}) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _}} -> :ok
              _ -> :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
