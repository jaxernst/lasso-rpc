defmodule Livechain.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # Start PubSub for real-time messaging
        {Phoenix.PubSub, name: Livechain.PubSub},

        # Start Finch HTTP client for RPC provider requests
        {Finch, name: Livechain.Finch},

        # Start benchmark store for performance metrics
        Livechain.Benchmarking.BenchmarkStore,

        # Start benchmark persistence for historical data
        Livechain.Benchmarking.Persistence,

        # Start process registry for centralized process management
        {Livechain.RPC.ProcessRegistry, name: Livechain.RPC.ProcessRegistry},

        # Add a local Registry for dynamic process names (high-cardinality)
        {Registry,
         keys: :unique, name: Livechain.Registry, partitions: System.schedulers_online()},

        # Start dynamic supervisor for chain supervisors
        {DynamicSupervisor, strategy: :one_for_one, name: Livechain.RPC.Supervisor},

        # Start configuration store for centralized config caching
        Livechain.Config.ConfigStore,

        # Start the chain registry for lifecycle management only
        Livechain.RPC.ChainRegistry,

        # Start the chain manager for blockchain orchestration
        Livechain.RPC.ChainManager,

        # Start the subscription manager for JSON-RPC subscriptions
        Livechain.RPC.SubscriptionManager,

        # Start Phoenix endpoint
        LivechainWeb.Endpoint

        # Add simulator to children if in dev/test
      ]

    # ++ maybe_add_simulator()

    # See https://hexdocs.pm/elixir/Supervisor.html
    opts = [strategy: :one_for_one, name: Livechain.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      # Attach telemetry handlers after supervisor is started
      Livechain.Telemetry.attach_default_handlers()

      # Start all configured chains
      case Livechain.RPC.ChainRegistry.start_all_chains() do
        {:ok, started_count} ->
          Logger.info("Started #{started_count} chain supervisors")

        {:error, reason} ->
          Logger.error("Failed to start chain supervisors: #{reason}")
      end

      # Auto-start simulator in dev/test environments
      if Mix.env() in [:dev, :test] do
        # start_simulator_process()
      end

      {:ok, supervisor}
    end
  end

end
