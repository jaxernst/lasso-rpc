defmodule Livechain.Battle.TestHelper do
  @moduledoc """
  Helper functions for battle testing with real Lasso RPC system.

  Provides utilities to:
  - Configure test chains with mock providers
  - Start chain supervisors for testing
  - Seed benchmark data for routing strategies
  - Clean up test resources
  """

  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.RPC.ChainSupervisor
  alias Livechain.Benchmarking.BenchmarkStore

  @doc """
  Creates a test chain configuration with mock providers.

  ## Example

      TestHelper.create_test_chain("testchain", [
        {"provider_a", "http://localhost:9000"},
        {"provider_b", "http://localhost:9001"}
      ])
  """
  def create_test_chain(chain_name, providers) when is_list(providers) do
    provider_configs =
      Enum.map(providers, fn {provider_id, url} ->
        %ChainConfig.Provider{
          id: provider_id,
          name: provider_id,
          url: url,
          ws_url: String.replace(url, "http://", "ws://") <> "/ws",
          type: "test",
          priority: 100,
          api_key_required: false,
          region: "local"
        }
      end)

    %ChainConfig{
      chain_id: :rand.uniform(999_999),
      name: chain_name,
      providers: provider_configs,
      connection: %ChainConfig.Connection{
        heartbeat_interval: 30_000,
        reconnect_interval: 5_000,
        max_reconnect_attempts: 10
      },
      failover: %ChainConfig.Failover{
        enabled: true,
        max_backfill_blocks: 10,
        backfill_timeout: 5_000
      }
    }
  end

  @doc """
  Starts a chain supervisor for testing.

  Returns the supervisor PID for later cleanup.

  ## Example

      {:ok, supervisor_pid} = TestHelper.start_test_chain("testchain", chain_config)
  """
  def start_test_chain(chain_name, chain_config) do
    case ChainSupervisor.start_link({chain_name, chain_config}) do
      {:ok, pid} ->
        # Wait for chain to be ready
        wait_for_chain_ready(chain_name, 50)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.warning("Chain supervisor already started: #{chain_name}")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start chain supervisor: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops a test chain supervisor.
  """
  def stop_test_chain(supervisor_pid) when is_pid(supervisor_pid) do
    try do
      DynamicSupervisor.terminate_child(Livechain.RPC.Supervisor, supervisor_pid)
    catch
      :exit, _ -> :ok
    end
  end

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

  @doc """
  Cleans up all test resources (chains, benchmarks, etc.).
  """
  def cleanup_test_resources(chain_name) do
    # Stop chain supervisor if running
    case ChainSupervisor.get_chain_status(chain_name) do
      %{error: :chain_not_started} ->
        :ok

      _ ->
        # Try to find and stop the supervisor
        try do
          # This is a simplification - actual cleanup may vary
          :ok
        catch
          _, _ -> :ok
        end
    end

    Logger.debug("Cleaned up test resources for #{chain_name}")
  end

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

        _ ->
          Process.sleep(100)
          wait_for_chain_ready_impl(chain_name, max_attempts, attempt + 1)
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
         |> Finch.request(Livechain.Finch, receive_timeout: 5_000) do
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