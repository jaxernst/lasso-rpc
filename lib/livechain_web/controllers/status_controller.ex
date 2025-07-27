defmodule LivechainWeb.StatusController do
  use LivechainWeb, :controller

  alias Livechain.RPC.WSSupervisor

  def status(conn, _params) do
    # Get detailed system status
    connections = WSSupervisor.list_connections()
    
    status = %{
      system: %{
        status: "operational",
        timestamp: DateTime.utc_now(),
        uptime: System.uptime() |> trunc(),
        memory_usage: :erlang.memory(),
        process_count: :erlang.system_info(:process_count)
      },
      connections: %{
        total: length(connections),
        active: Enum.count(connections, &(&1.status == :connected)),
        details: connections
      }
    }

    json(conn, status)
  end
end