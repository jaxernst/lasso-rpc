defmodule Livechain.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Livechain.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      # Attach telemetry handlers after supervisor is started
      Livechain.Telemetry.attach_default_handlers()
      {:ok, supervisor}
    end
  end
end
