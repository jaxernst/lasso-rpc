defmodule Lasso.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  # Compile-time environment check
  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Store application start time for uptime calculation
    Application.put_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    children =
      [
        # Start PubSub for real-time messaging
        {Phoenix.PubSub, name: Lasso.PubSub},

        # Start Telemetry supervisor for metrics and monitoring
        Lasso.Telemetry,

        # Start Finch HTTP client for RPC provider requests
        # High connection limit per pool to handle concurrent requests to same provider
        # Each unique provider URL gets its own pool, so size must be high enough
        # to handle burst traffic without queueing
        {Finch,
         name: Lasso.Finch,
         pools: %{
           # Use :default atom with => syntax to apply to ALL unregistered hosts
           :default => [
             size: 500,
             # Max connections per pool (per unique host)
             count: 10,
             # Number of pools for load distribution
             pool_max_idle_time: :timer.seconds(30),
             conn_opts: [timeout: 30_000]
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

        # Start ETS table owner for blockchain metadata cache
        # MUST start before chain supervisors to ensure table exists
        Lasso.RPC.Caching.MetadataTableOwner,

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
    # Skip validation in test environment since providers are registered dynamically
    case @env do
      :test ->
        :ok

      _ ->
        case Lasso.Config.ChainConfig.validate_chain_config(chain_config) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Chain #{chain_name} validation failed: #{inspect(reason)}")
        end
    end

    DynamicSupervisor.start_child(
      Lasso.RPC.Supervisor,
      {Lasso.RPC.ChainSupervisor, {chain_name, chain_config}}
    )
  end
end
