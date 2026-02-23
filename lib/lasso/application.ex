defmodule Lasso.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Lasso.Config.ProfileValidator
  alias Lasso.Config.{ChainConfig, ConfigStore}

  @impl true
  def start(_type, _args) do
    # Store application start time for uptime calculation
    Application.put_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    # Set node_id persistent_term before supervision tree starts.
    # This guarantees Topology.self_node_id/0 is available to any process from boot.
    node_id = Application.fetch_env!(:lasso, :node_id)
    :persistent_term.put({Lasso.Cluster.Topology, :self_node_id}, node_id)

    # Create ETS tables owned by Application process (never dies).
    # These tables survive GenServer restarts and provide stable storage.

    # TransportRegistry channel cache - enables lockless reads in Selection hot path
    :ets.new(:transport_channel_cache, [:named_table, :public, :set, read_concurrency: true])

    # Profile and chain configuration storage (written by ConfigStore)
    # Keys: {:profile, slug, :meta}, {:profile, slug, :chains}, {:profile_list}, etc.
    # Note: :public access is required because ConfigStore GenServer writes to this table
    # but the table is owned by Application process for stability
    :ets.new(:lasso_config_store, [:named_table, :public, :set, read_concurrency: true])

    # Shared provider instance state (health, circuit, rate limits)
    # Written by ProbeCoordinator, CircuitBreaker, Observability; read by CandidateListing
    :ets.new(:lasso_instance_state, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    children =
      [
        # Start PubSub for real-time messaging
        # Uses default :pg adapter for distributed clustering across BEAM nodes
        {Phoenix.PubSub, name: Lasso.PubSub},

        # Start libcluster supervisor for node discovery (if configured)
        {Cluster.Supervisor,
         [
           Application.get_env(:libcluster, :topologies, []),
           [name: Lasso.ClusterSupervisor]
         ]},

        # Task supervisor for async operations (needed by Topology)
        {Task.Supervisor, name: Lasso.TaskSupervisor},

        # Cluster topology - single source of truth for cluster membership
        Lasso.Cluster.Topology,

        # Start Telemetry supervisor for metrics and monitoring
        Lasso.Telemetry,

        # Start Finch HTTP client for RPC provider requests
        # Pool size tuned for typical RPC proxy workloads:
        # - size: max connections per pool (per unique host)
        # - count: number of independent pools for parallel access
        # - pool_max_idle_time: keep pools alive longer to reduce TLS handshake overhead
        # - idle_timeout: individual connection idle timeout
        # - transport_opts: TLS session reuse to reduce handshake CPU cost
        {Finch,
         name: Lasso.Finch,
         pools: %{
           :default => [
             size: 30,
             count: 3,
             pool_max_idle_time: :timer.seconds(60),
             conn_opts: [
               timeout: 30_000,
               idle_timeout: 60_000,
               transport_opts: [
                 reuse_sessions: true
               ]
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
        {Lasso.Core.Support.ProcessRegistry, name: Lasso.Core.Support.ProcessRegistry},

        # Add a local Registry for dynamic process names (high-cardinality)
        {Registry, keys: :unique, name: Lasso.Registry, partitions: System.schedulers_online()},

        # Registry for dashboard event stream lookup
        {Registry, keys: :unique, name: Lasso.Dashboard.StreamRegistry},

        # DynamicSupervisor for per-profile event stream processes
        {DynamicSupervisor, name: Lasso.Dashboard.StreamSupervisor, strategy: :one_for_one},

        # Metrics store for cached cluster-wide metrics
        LassoWeb.Dashboard.MetricsStore,

        # Start block cache for real-time block data from WebSocket subscriptions
        Lasso.Core.BlockCache,

        # Start BlockSync registry (single source of truth for block heights)
        Lasso.BlockSync.Registry,

        # Start instance subscription registry for tracking subscription consumers
        Lasso.Core.Streaming.InstanceSubscriptionRegistry,

        # DynamicSupervisor for per-instance BlockSync workers
        {DynamicSupervisor, name: Lasso.BlockSync.DynamicSupervisor, strategy: :one_for_one},

        # DynamicSupervisor for per-instance supervisors (shared CBs)
        {DynamicSupervisor,
         name: Lasso.Providers.InstanceDynamicSupervisor, strategy: :one_for_one},

        # DynamicSupervisor for per-chain probe coordinators
        {DynamicSupervisor, name: Lasso.Providers.ProbeSupervisor, strategy: :one_for_one},

        # Profile-scoped chain supervisor for (profile, chain) pairs
        Lasso.ProfileChainSupervisor,

        # Start configuration store for centralized config caching
        {Lasso.Config.ConfigStore, get_config_store_opts()},

        # Start Phoenix endpoint
        LassoWeb.Endpoint,

        # Drain in-flight HTTP requests on shutdown (SIGTERM during deploys).
        # Must be AFTER the endpoint so it starts after and stops before it.
        {Plug.Cowboy.Drainer, refs: [LassoWeb.Endpoint.HTTP], shutdown: 30_000}
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
          Logger.info(
            "Loaded #{length(profile_slugs)} profiles: #{Enum.join(profile_slugs, ", ")}"
          )

          # Validate that "default" profile exists after loading all profiles
          # This ensures the system can always fall back to "default" profile
          case ProfileValidator.validate("default") do
            {:ok, _} ->
              Logger.info("Startup validation passed: 'default' profile found")

            {:error, _type, message} ->
              Logger.error("STARTUP FAILURE: #{message}")
              Logger.error("The 'default' profile must be configured at startup")
              Logger.error("Ensure config/profiles/default.yml exists and is valid")
              raise "Default profile validation failed: #{message}"
          end

          # Validate that all provider URLs have resolved environment variables
          # This prevents silent failures where URLs contain literal ${VAR_NAME} placeholders
          validate_all_providers_configured(profile_slugs)

          # Build provider catalog (maps profiles to shared provider instances)
          Lasso.Providers.Catalog.build_from_config()

          Logger.info(
            "Provider catalog built: #{Lasso.Providers.Catalog.instance_count()} unique instances"
          )

          # Start InstanceSupervisors and ProbeCoordinators for shared infrastructure
          start_shared_infrastructure()

        {:error, reason} ->
          Logger.warning("Failed to load profiles: #{inspect(reason)}")
      end

      # Start all configured chains
      case start_all_chains() do
        {:ok, 0} ->
          Logger.info("No chains configured - starting in minimal mode")

        {:ok, count} ->
          Logger.info("Started #{count} chain supervisors")
      end

      {:ok, supervisor}
    end
  end

  # Private helper functions

  defp start_shared_infrastructure do
    alias Lasso.Providers.{Catalog, InstanceSupervisor, ProbeCoordinator}

    instance_ids = Catalog.list_all_instance_ids()

    for instance_id <- instance_ids do
      case DynamicSupervisor.start_child(
             Lasso.Providers.InstanceDynamicSupervisor,
             {InstanceSupervisor, instance_id}
           ) do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to start InstanceSupervisor for #{instance_id}: #{inspect(reason)}"
          )
      end
    end

    Logger.info("Started #{length(instance_ids)} instance supervisors")

    chains = ConfigStore.list_chains()

    for chain <- chains do
      case DynamicSupervisor.start_child(
             Lasso.Providers.ProbeSupervisor,
             {ProbeCoordinator, chain}
           ) do
        {:ok, _} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to start ProbeCoordinator for #{chain}: #{inspect(reason)}")
      end
    end

    Logger.info("Started #{length(chains)} probe coordinators")

    # Start BlockSync workers per chain (after InstanceSupervisors are up)
    for chain <- chains do
      Lasso.BlockSync.Initializer.start_workers_for_chain(chain)
    end

    Logger.info("Started BlockSync workers for #{length(chains)} chains")
  rescue
    e -> Logger.warning("Failed to start shared infrastructure: #{inspect(e)}")
  end

  defp validate_all_providers_configured(profile_slugs) do
    profile_slugs
    |> Enum.flat_map(&collect_profile_validation_errors/1)
    |> case do
      [] ->
        Logger.info("Startup validation passed: all provider URLs resolved")

      errors ->
        log_validation_errors(errors)
        raise "Provider configuration validation failed: unresolved environment variables"
    end
  end

  defp collect_profile_validation_errors(profile) do
    case ConfigStore.get_profile_chains(profile) do
      {:ok, chains} ->
        Enum.flat_map(chains, fn {chain_name, chain_config} ->
          case ChainConfig.validate_no_unresolved_placeholders(chain_config) do
            :ok -> []
            {:error, {:unresolved_env_vars, providers}} -> [{profile, chain_name, providers}]
          end
        end)

      _ ->
        []
    end
  end

  defp log_validation_errors(errors) do
    Logger.error("""
    STARTUP FAILURE: Unresolved environment variables in provider configuration

    #{format_validation_errors(errors)}

    Please ensure all required environment variables are set in your .env file or system environment.
    """)
  end

  defp format_validation_errors(errors) do
    Enum.map_join(errors, "\n\n", fn {profile, chain, providers} ->
      "Profile '#{profile}', Chain '#{chain}':\n#{format_provider_issues(providers)}"
    end)
  end

  defp format_provider_issues(providers) do
    Enum.map_join(providers, "\n", fn {provider_id, issues} ->
      issue_list = Enum.map_join(issues, "\n", fn {type, url} -> "    - #{type}: #{url}" end)
      "  Provider '#{provider_id}':\n#{issue_list}"
    end)
  end

  defp get_config_store_opts do
    # Check for explicit backend_config first (test environment)
    case Application.get_env(:lasso, :backend_config) do
      nil ->
        # Fall back to legacy chains_config_path
        Application.get_env(:lasso, :chains_config_path, "config/chains.yml")

      backend_config ->
        # Use explicit backend config (allows test env to specify profiles_dir)
        backend_config
    end
  end

  defp start_all_chains do
    alias Lasso.Config.ConfigStore

    # Get all profiles from ConfigStore
    profiles = ConfigStore.list_profiles()

    if Enum.empty?(profiles) do
      Logger.warning("No profiles loaded - skipping chain startup")
      {:ok, 0}
    else
      # Start chains for each profile
      results =
        Enum.flat_map(profiles, fn profile ->
          case ConfigStore.get_profile_chains(profile) do
            {:ok, chains} ->
              Enum.map(chains, fn {chain_name, chain_config} ->
                result = start_profile_chain(profile, chain_name, chain_config)
                {profile, chain_name, result}
              end)

            {:error, :not_found} ->
              Logger.warning("Profile #{profile} not found during chain startup")
              []
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
    validate_chain_config(profile, chain_name, chain_config)

    result = Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_name, chain_config)
    log_chain_start_result(profile, chain_name, result)
    result
  end

  defp validate_chain_config(profile, chain_name, chain_config) do
    case Lasso.Config.ChainConfig.validate_chain_config(chain_config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Chain #{chain_name} validation failed for profile #{profile}: #{inspect(reason)}"
        )
    end
  end

  defp log_chain_start_result(profile, chain_name, {:ok, _pid}) do
    Logger.info("Started chain supervisor: #{profile}/#{chain_name}")
  end

  defp log_chain_start_result(profile, chain_name, {:error, reason}) do
    Logger.error(
      "Failed to start chain supervisor: #{profile}/#{chain_name} - #{inspect(reason)}"
    )
  end
end
