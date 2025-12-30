defmodule Lasso.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Store application start time for uptime calculation
    Application.put_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    # Create ETS tables owned by Application process (never dies).
    # These tables survive GenServer restarts and provide stable storage.

    # TransportRegistry channel cache - enables lockless reads in Selection hot path
    :ets.new(:transport_channel_cache, [:named_table, :public, :set, read_concurrency: true])

    # Profile and chain configuration storage (written by ConfigStore)
    # Keys: {:profile, slug, :meta}, {:profile, slug, :chains}, {:profile_list}, etc.
    # Note: :public access is required because ConfigStore GenServer writes to this table
    # but the table is owned by Application process for stability
    :ets.new(:lasso_config_store, [:named_table, :public, :set, read_concurrency: true])

    # Runtime provider state (written by ProviderPool, BlockSync, etc.)
    # Keys: {:provider_sync, profile, chain, provider_id}, {:block_height, chain, {profile, provider_id}}
    :ets.new(:lasso_provider_state, [:named_table, :public, :set, read_concurrency: true])

    # Chain reference counting for cleanup tracking (atomic counters)
    # Keys: chain_name => count of profiles using this chain
    :ets.new(:lasso_chain_refcount, [:named_table, :public, :set, read_concurrency: true])

    children =
      [
        # Start PubSub for real-time messaging
        {Phoenix.PubSub, name: Lasso.PubSub},

        # Start event buffer for dashboard event batching
        LassoWeb.Dashboard.EventBuffer,

        # Start Telemetry supervisor for metrics and monitoring
        Lasso.Telemetry,

        # Start Finch HTTP client for RPC provider requests
        # Pool size tuned for typical RPC proxy workloads:
        # - size: max connections per pool (per unique host)
        # - count: number of independent pools for parallel access
        # For shared-cpu instances, keep this modest to avoid scheduler overhead
        {Finch,
         name: Lasso.Finch,
         pools: %{
           :default => [
             size: 200,
             count: 5,
             pool_max_idle_time: :timer.seconds(60),
             conn_opts: [
               timeout: 30_000,
               idle_timeout: 60_000
             ]
           ]
         }},

        # Start benchmark store for performance metrics
        Lasso.Benchmarking.BenchmarkStore,

        # Start benchmark persistence for historical data
        Lasso.Benchmarking.Persistence,

        # Start centralized VM metrics collector for dashboard
        Lasso.VMMetricsCollector,

        # Start process registry for centralized process management
        {Lasso.RPC.ProcessRegistry, name: Lasso.RPC.ProcessRegistry},

        # Add a local Registry for dynamic process names (high-cardinality)
        {Registry, keys: :unique, name: Lasso.Registry, partitions: System.schedulers_online()},

        # Start Task.Supervisor for async operations
        {Task.Supervisor, name: Lasso.TaskSupervisor},

        # Start block cache for real-time block data from WebSocket subscriptions
        Lasso.Core.BlockCache,

        # Start BlockSync registry (single source of truth for block heights)
        Lasso.BlockSync.Registry,

        # Start upstream subscription registry for tracking subscription consumers
        Lasso.Core.Streaming.UpstreamSubscriptionRegistry,

        # Global chain supervisor for shared components (BlockSync, HealthProbe per chain)
        Lasso.GlobalChainSupervisor,

        # Profile-scoped chain supervisor for (profile, chain) pairs
        Lasso.ProfileChainSupervisor,

        # Start configuration store for centralized config caching
        {Lasso.Config.ConfigStore,
         Application.get_env(:lasso, :chains_config_path, "config/chains.yml")},

        # Start Phoenix endpoint
        LassoWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    opts = [strategy: :one_for_one, name: Lasso.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      # Attach telemetry handlers after supervisor is started
      Lasso.Telemetry.attach_default_handlers()

      # Load all profiles from configuration backend
      # This must happen after ConfigStore starts but before chains are started
      case Lasso.Config.ConfigStore.load_all_profiles() do
        {:ok, profile_slugs} ->
          Logger.info("Loaded #{length(profile_slugs)} profiles: #{Enum.join(profile_slugs, ", ")}")

        {:error, reason} ->
          Logger.warning("Failed to load profiles: #{inspect(reason)}")
      end

      # Start all configured chains
      {:ok, started_count} = start_all_chains()
      Logger.info("Started #{started_count} chain supervisors")

      {:ok, supervisor}
    end
  end

  # Private helper functions

  defp start_all_chains do
    alias Lasso.Config.ConfigStore
    alias Lasso.GlobalChainSupervisor

    # Get all profiles from ConfigStore
    profiles = ConfigStore.list_profiles()

    if Enum.empty?(profiles) do
      Logger.warning("No profiles loaded - skipping chain startup")
      {:ok, 0}
    else
      # Track unique chains for global process startup
      started_global_chains = MapSet.new()

      # Start chains for each profile
      {results, _} =
        Enum.flat_map_reduce(profiles, started_global_chains, fn profile, global_chains ->
          case ConfigStore.get_profile_chains(profile) do
            {:ok, chains} ->
              profile_results =
                Enum.map(chains, fn {chain_name, chain_config} ->
                  # Start global chain processes if not already started
                  global_chains =
                    if chain_name in global_chains do
                      global_chains
                    else
                      case GlobalChainSupervisor.ensure_chain_processes(chain_name) do
                        :ok ->
                          Logger.debug("Started global processes for chain: #{chain_name}")
                          MapSet.put(global_chains, chain_name)

                        {:error, reason} ->
                          Logger.error("Failed to start global processes for #{chain_name}: #{inspect(reason)}")
                          global_chains
                      end
                    end

                  # Start profile chain supervisor
                  result = start_profile_chain(profile, chain_name, chain_config)
                  {{profile, chain_name, result}, global_chains}
                end)

              # Extract results and last global_chains state
              {results, last_global} =
                Enum.map_reduce(profile_results, global_chains, fn {result, gc}, _acc ->
                  {result, gc}
                end)

              {results, last_global}

            {:error, :not_found} ->
              Logger.warning("Profile #{profile} not found during chain startup")
              {[], global_chains}
          end
        end)

      # Count successful starts
      successful_count =
        results
        |> Enum.filter(fn {_, _, result} -> match?({:ok, _}, result) end)
        |> length()

      {:ok, successful_count}
    end
  end

  defp start_profile_chain(profile, chain_name, chain_config) do
    case Lasso.Config.ChainConfig.validate_chain_config(chain_config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Chain #{chain_name} validation failed for profile #{profile}: #{inspect(reason)}")
    end

    case Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_name, chain_config) do
      {:ok, _pid} = result ->
        Logger.info("✓ Started chain supervisor: #{profile}/#{chain_name}")
        result

      {:error, reason} = result ->
        Logger.error("✗ Failed to start chain supervisor: #{profile}/#{chain_name} - #{inspect(reason)}")
        result
    end
  end
end
