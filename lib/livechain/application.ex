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
      
      # Start the WebSocket supervisor
      Livechain.RPC.WSSupervisor,
      
      # Start Phoenix endpoint
      LivechainWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Livechain.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
