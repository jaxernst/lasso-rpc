defmodule Livechain.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Start PubSub for real-time messaging
      {Phoenix.PubSub, name: Livechain.PubSub},

      # Start process registry for centralized process management
      {Livechain.RPC.ProcessRegistry, name: Livechain.RPC.ProcessRegistry},

      # Start dynamic supervisor for chain supervisors
      {DynamicSupervisor, strategy: :one_for_one, name: Livechain.RPC.Supervisor},

      # Start the chain manager for orchestrating all blockchain connections
      Livechain.RPC.ChainManager,

      # Start the WebSocket supervisor
      Livechain.RPC.WSSupervisor,

      # Start Phoenix endpoint
      LivechainWeb.Endpoint

      # Add simulator to children if in dev/test
    ] ++ maybe_add_simulator()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Livechain.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      # Attach telemetry handlers after supervisor is started
      Livechain.Telemetry.attach_default_handlers()
      
      # Auto-start simulator in dev/test environments
      if Mix.env() in [:dev, :test] do
        start_simulator_process()
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

  # Helper function to start and activate the simulator
  defp start_simulator_process do
    case Process.whereis(Livechain.Simulator) do
      pid when is_pid(pid) ->
        Livechain.Simulator.start_simulation()
        Logger.info("🎮 Auto-started WebSocket connection simulator in #{Mix.env()} environment")
      nil ->
        Logger.debug("Simulator not found in process registry")
    end
  end
end
