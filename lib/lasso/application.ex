defmodule Lasso.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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

    # Shared provider instance state (health, circuit, rate limits)
    # Written by ProbeCoordinator, CircuitBreaker, Observability; read by CandidateListing
    :ets.new(:lasso_instance_state, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(:block_sync_registry, [
      :set,
      :public,
      :named_table,
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

        # Error classification sample store (attaches to telemetry)
        Lasso.Core.Support.ErrorClassificationStore,

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

        # Stable owners retain ETS snapshots across ConfigStore/Catalog restarts.
        Lasso.Providers.Catalog.Owner,
        Lasso.Config.ConfigStore.Owner,

        # Start configuration store for centralized config caching
        {Lasso.Config.ConfigStore, get_config_store_opts()},

        # Supervised bootstrap loads profiles and starts shared infrastructure.
        Lasso.Boot.InfrastructureStarter,

        # Start Phoenix endpoint
        LassoWeb.Endpoint,

        # Drain in-flight HTTP requests on shutdown (SIGTERM during deploys).
        # Must be AFTER the endpoint so it starts after and stops before it.
        {Plug.Cowboy.Drainer, refs: [LassoWeb.Endpoint.HTTP], shutdown: 30_000}
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    opts = [strategy: :one_for_one, name: Lasso.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      Lasso.Telemetry.attach_default_handlers()

      {:ok, supervisor}
    end
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
end
