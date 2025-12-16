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

    # Create ETS table for TransportRegistry channel cache.
    # This table enables lockless reads in the Selection hot path.
    # Owned by the Application process (never dies), managed by TransportRegistry.
    # See TransportRegistry moduledoc for cache coherence details.
    :ets.new(:transport_channel_cache, [:named_table, :public, :set, read_concurrency: true])

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

        # Start dynamic supervisor for chain supervisors
        {DynamicSupervisor, name: Lasso.RPC.Supervisor, strategy: :one_for_one},

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

      # Start all configured chains
      {:ok, started_count} = start_all_chains()
      Logger.info("Started #{started_count} chain supervisors")

      {:ok, supervisor}
    end
  end

  # Private helper functions

  defp start_all_chains do
    # Get all configured chains from ConfigStore
    all_chains = Lasso.Config.ConfigStore.get_all_chains()

    # Start chain supervisors for each configured chain
    results =
      Enum.map(all_chains, fn {chain_name, chain_config} ->
        case start_chain_supervisor(chain_name, chain_config) do
          {:ok, _pid} = result ->
            Logger.info("✓ Chain supervisor started successfully: #{chain_name}")
            {chain_name, result}

          {:error, reason} = result ->
            Logger.error("✗ Chain supervisor failed to start: #{chain_name} - #{inspect(reason)}")
            {chain_name, result}
        end
      end)

    # Count successful starts
    successful_count =
      results
      |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
      |> length()

    {:ok, successful_count}
  end

  defp start_chain_supervisor(chain_name, chain_config) do
    case Lasso.Config.ChainConfig.validate_chain_config(chain_config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Chain #{chain_name} validation failed: #{inspect(reason)}")
    end

    DynamicSupervisor.start_child(
      Lasso.RPC.Supervisor,
      {Lasso.RPC.ChainSupervisor, {chain_name, chain_config}}
    )
  end
end
