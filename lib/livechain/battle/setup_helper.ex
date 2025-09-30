defmodule Livechain.Battle.SetupHelper do
  @moduledoc """
  Helper for dynamically registering providers in battle tests.

  Supports mixing real providers with mock providers for flexible testing.

  Now uses the production Livechain.Providers API for cleaner, more maintainable tests.
  """

  require Logger
  alias Livechain.Providers
  alias Livechain.Battle.MockProvider
  alias Livechain.Benchmarking.BenchmarkStore

  @doc """
  Registers battle test providers (mix of real + mock) with an existing chain.

  ## Options

  Provider specs can be:
  - `{:real, provider_id, url}` - Real provider
  - `{:real, provider_id, url, ws_url}` - Real provider with custom WS URL
  - `{:mock, provider_id, opts}` - Mock provider (see MockProvider for opts)

  ## Example

      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com"},
        {:real, "ankr", "https://rpc.ankr.com/eth"},
        {:mock, "mock_fast", latency: 50, reliability: 1.0}
      ])
  """
  @spec setup_providers(String.t(), list()) :: :ok
  def setup_providers(chain_name, provider_specs) do
    provider_ids =
      Enum.map(provider_specs, fn
        {:real, provider_id, _url} -> provider_id
        {:real, provider_id, _url, _ws_url} -> provider_id
        {:mock, provider_id, _opts} -> provider_id
      end)

    Logger.info("Setting up #{length(provider_specs)} providers for #{chain_name}")

    Enum.each(provider_specs, fn spec ->
      case spec do
        {:real, provider_id, url} ->
          register_real_provider(chain_name, provider_id, url, derive_ws_url(url))

        {:real, provider_id, url, ws_url} ->
          register_real_provider(chain_name, provider_id, url, ws_url)

        {:mock, provider_id, opts} ->
          register_mock_provider(chain_name, provider_id, opts)
      end
    end)

    # Wait for providers to stabilize (especially WS connections)
    Process.sleep(1000)

    Logger.info("✓ Registered providers for #{chain_name}: #{inspect(provider_ids)}")
    :ok
  end

  @doc """
  Seeds benchmark data for a chain to influence routing strategies.

  ## Example

      SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
        {"llamarpc", 50},
        {"ankr", 100}
      ])
  """
  @spec seed_benchmarks(String.t(), String.t(), list({String.t(), integer()})) :: :ok
  def seed_benchmarks(chain_name, method, latency_specs) do
    # Note: BenchmarkStore doesn't have a clear function, but recording new data will update averages

    # Record multiple samples for stability (ETS-based moving average)
    Enum.each(latency_specs, fn {provider_id, latency} ->
      Enum.each(1..20, fn _ ->
        BenchmarkStore.record_rpc_call(chain_name, provider_id, method, latency, :success)
      end)
    end)

    Logger.debug("Seeded benchmarks for #{chain_name}/#{method}")
    :ok
  end

  @doc """
  Cleans up dynamically registered providers for a chain.

  Note: This removes providers from the running system and stops mock provider servers.
  """
  @spec cleanup_providers(String.t(), list(String.t())) :: :ok
  def cleanup_providers(chain_name, provider_ids) do
    Enum.each(provider_ids, fn provider_id ->
      try do
        Providers.remove_provider(chain_name, provider_id)
      catch
        _, _ -> :ok
      end
    end)

    # Stop all mock providers
    MockProvider.stop_providers(Enum.map(provider_ids, &String.to_atom/1))
    :ok
  end

  @doc """
  Waits for a provider to reach a specific status.

  Useful for ensuring providers are ready before starting tests.
  """
  @spec wait_for_provider_status(String.t(), String.t(), atom(), integer()) ::
          :ok | {:error, :timeout}
  def wait_for_provider_status(chain_name, provider_id, expected_status, timeout_ms \\ 10_000) do
    wait_for_provider_status_impl(chain_name, provider_id, expected_status, timeout_ms, 0)
  end

  # Private helpers

  defp register_real_provider(chain_name, provider_id, url, ws_url) do
    config = %{
      id: provider_id,
      name: provider_id,
      url: url,
      ws_url: ws_url,
      type: "real",
      priority: 100,
      api_key_required: false,
      region: "global"
    }

    # Use the production Providers API
    case Providers.add_provider(chain_name, config, validate: false) do
      {:ok, _id} ->
        Logger.debug("Registered real provider: #{provider_id} (#{url})")
        :ok

      {:error, {:already_exists, _}} ->
        Logger.debug("Provider #{provider_id} already exists, skipping")
        :ok

      {:error, reason} ->
        Logger.error("Failed to register real provider #{provider_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp register_mock_provider(chain_name, provider_id, opts) do
    # Start mock provider HTTP server
    [{^provider_id, port}] = MockProvider.start_providers([{String.to_atom(provider_id), opts}])

    config = %{
      id: provider_id,
      name: provider_id,
      url: "http://localhost:#{port}",
      ws_url: "ws://localhost:#{port}/ws",
      type: "mock",
      priority: 100,
      api_key_required: false,
      region: "local"
    }

    # Use the production Providers API
    case Providers.add_provider(chain_name, config, validate: false) do
      {:ok, _id} ->
        Logger.debug("Registered mock provider: #{provider_id} (port #{port})")
        :ok

      {:error, {:already_exists, _}} ->
        Logger.debug("Provider #{provider_id} already exists, skipping")
        :ok

      {:error, reason} ->
        Logger.error("Failed to register mock provider #{provider_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp derive_ws_url(http_url) do
    http_url
    |> String.replace("https://", "wss://")
    |> String.replace("http://", "ws://")
  end

  defp wait_for_provider_status_impl(
         chain_name,
         provider_id,
         expected_status,
         timeout_ms,
         elapsed_ms
       ) do
    if elapsed_ms >= timeout_ms do
      {:error, :timeout}
    else
      case Providers.get_provider(chain_name, provider_id) do
        {:ok, provider_config} ->
          # Get status from Providers.list_providers
          case Providers.list_providers(chain_name) do
            {:ok, providers} ->
              provider = Enum.find(providers, fn p -> p.id == provider_id end)

              if provider && provider.status == expected_status do
                :ok
              else
                Process.sleep(100)

                wait_for_provider_status_impl(
                  chain_name,
                  provider_id,
                  expected_status,
                  timeout_ms,
                  elapsed_ms + 100
                )
              end

            {:error, _} ->
              Process.sleep(100)

              wait_for_provider_status_impl(
                chain_name,
                provider_id,
                expected_status,
                timeout_ms,
                elapsed_ms + 100
              )
          end

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, _} ->
          Process.sleep(100)

          wait_for_provider_status_impl(
            chain_name,
            provider_id,
            expected_status,
            timeout_ms,
            elapsed_ms + 100
          )
      end
    end
  end
end
