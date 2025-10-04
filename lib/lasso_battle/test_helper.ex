defmodule Lasso.Battle.TestHelper do
  @moduledoc """
  Utility functions for battle testing with real Lasso RPC system.

  This module provides benchmark seeding and utility functions.
  For provider registration, use SetupHelper.setup_providers().

  Available utilities:
  - Seed benchmark data for routing strategies
  - Wait for chain readiness
  - Direct RPC requests for validation
  """

  require Logger

  alias Lasso.RPC.ChainSupervisor
  alias Lasso.Benchmarking.BenchmarkStore

  # REMOVED: create_test_chain, start_test_chain, stop_test_chain
  # These functions don't work with ConfigStore (read-only after app startup).
  # Use SetupHelper.setup_providers() for dynamic provider registration instead.

  @doc """
  Seeds benchmark data for a chain to influence routing strategies.

  ## Example

      TestHelper.seed_benchmarks("testchain", [
        {"provider_a", "eth_blockNumber", 50, :success},
        {"provider_b", "eth_blockNumber", 100, :success}
      ])
  """
  def seed_benchmarks(chain_name, benchmark_data) when is_list(benchmark_data) do
    Enum.each(benchmark_data, fn {provider_id, method, latency, result} ->
      # Record multiple samples for stability
      Enum.each(1..10, fn _ ->
        BenchmarkStore.record_rpc_call(chain_name, provider_id, method, latency, result)
      end)
    end)

    Logger.debug("Seeded benchmarks for #{chain_name}: #{length(benchmark_data)} entries")
  end

  @doc """
  Waits for a chain to become ready.
  """
  def wait_for_chain_ready(chain_name, max_attempts \\ 50) do
    wait_for_chain_ready_impl(chain_name, max_attempts, 0)
  end

  # REMOVED: cleanup_test_resources
  # Use SetupHelper.cleanup_providers() instead.

  # Private helpers

  defp wait_for_chain_ready_impl(chain_name, max_attempts, attempt) do
    if attempt >= max_attempts do
      Logger.error("Chain #{chain_name} did not become ready after #{max_attempts} attempts")
      {:error, :timeout}
    else
      case ChainSupervisor.get_chain_status(chain_name) do
        %{error: :chain_not_started} ->
          Process.sleep(100)
          wait_for_chain_ready_impl(chain_name, max_attempts, attempt + 1)

        status when is_map(status) ->
          :ok
      end
    end
  end

  @doc """
  Makes a direct HTTP RPC request (bypassing Lasso routing) for testing.

  Useful for verifying mock providers are responding.
  """
  def make_direct_rpc_request(url, method, params \\ []) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => 1
      })

    case Finch.build(:post, url, [{"content-type", "application/json"}], body)
         |> Finch.request(Lasso.Finch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => error}} -> {:error, error}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
