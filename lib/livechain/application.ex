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

        # Start price oracle for USD pricing
        Livechain.EventProcessing.PriceOracle,

        # Start dynamic supervisor for chain supervisors
        {DynamicSupervisor, strategy: :one_for_one, name: Livechain.RPC.Supervisor},

        # Start dynamic supervisor for Broadway pipelines
        {DynamicSupervisor, strategy: :one_for_one, name: Livechain.EventProcessing.Supervisor},

        # Start the chain manager for orchestrating all blockchain connections
        Livechain.RPC.ChainManager,

        # Start the WebSocket supervisor
        Livechain.RPC.WSSupervisor,

        # Start the subscription manager for JSON-RPC subscriptions
        Livechain.RPC.SubscriptionManager,

        # Start Phoenix endpoint
        LivechainWeb.Endpoint

        # Add simulator to children if in dev/test
      ] ++ maybe_add_simulator() ++ maybe_add_broadway_pipelines()

    # See https://hexdocs.pm/elixir/Supervisor.html
    opts = [strategy: :one_for_one, name: Livechain.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      # Attach telemetry handlers after supervisor is started
      Livechain.Telemetry.attach_default_handlers()

      # Start all configured chains
      case Livechain.RPC.ChainManager.start_all_chains() do
        {:ok, started_count} ->
          Logger.info("Started #{started_count} chain supervisors")
        {:error, reason} ->
          Logger.error("Failed to start chain supervisors: #{reason}")
      end

      # Auto-start simulator in dev/test environments
      if Mix.env() in [:dev, :test] do
        # start_simulator_process()
        start_broadway_pipelines()
      end

      {:ok, supervisor}
    end
  end

  # Helper function to conditionally include simulator in supervision tree
  defp maybe_add_simulator do
    case Mix.env() do
      env when env in [:dev, :test] ->
        [{Livechain.Simulator, mode: "normal"}]

      _ ->
        []
    end
  end

  # Helper function to conditionally include Broadway pipelines
  defp maybe_add_broadway_pipelines do
    case Mix.env() do
      env when env in [:dev, :test] ->
        # Start Broadway pipelines for common chains in development
        []

      _ ->
        []
    end
  end

  # Helper function to start and activate the simulator
  defp start_simulator_process do
    case Process.whereis(Livechain.Simulator) do
      pid when is_pid(pid) ->
        # Start all configured mock connections for a comprehensive demo
        Livechain.Simulator.start_all_mock_connections()
        Logger.info("Auto-started comprehensive mock WebSocket connections")

        # Also start the dynamic simulator for additional variety
        Livechain.Simulator.start_simulation()
        Logger.info("Auto-started dynamic WebSocket connection simulator")

      nil ->
        Logger.debug("Simulator not found in process registry")
    end
  end

  # Helper function to start Broadway pipelines for active chains
  defp start_broadway_pipelines do
    # Start Broadway pipelines for all configured chains
    chains = get_configured_chain_names()

    Enum.each(chains, fn chain ->
      case DynamicSupervisor.start_child(
             Livechain.EventProcessing.Supervisor,
             {Livechain.EventProcessing.Pipeline, chain}
           ) do
        {:ok, _pid} ->
          Logger.info("Started Broadway pipeline for #{chain}")

        {:error, {:already_started, _pid}} ->
          Logger.debug("Broadway pipeline for #{chain} already running")

        {:error, reason} ->
          Logger.error("Failed to start Broadway pipeline for #{chain}: #{reason}")
      end
    end)
  end

  # TODO: No need to fallback to pre-defined chains. We should just fail if the config is not loaded.
  defp get_configured_chain_names do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        Map.keys(config.chains)

      {:error, reason} ->
        Logger.error("Failed to load chain configuration: #{reason}")
        # Fallback to default chains if config loading fails
        ["ethereum", "polygon", "arbitrum"]
    end
  end
end
