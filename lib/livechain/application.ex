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
        {DynamicSupervisor, name: Livechain.RPC.Supervisor, strategy: :one_for_one},

        # Start configuration store for centralized config caching
        Livechain.Config.ConfigStore,

        # Start the chain registry for lifecycle management
        Livechain.RPC.ChainRegistry,

        # Start Phoenix endpoint
        LivechainWeb.Endpoint
      ]

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

      {:ok, supervisor}
    end
  end
end
