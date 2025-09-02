defmodule LivechainWeb.StatusController do
  use LivechainWeb, :controller

  alias Livechain.RPC.ChainSupervisor
  alias Livechain.Config.ChainConfig

  def status(conn, _params) do
    # Get chains and their connection status
    chains_status = get_all_chains_status()

    # Calculate aggregated connection stats
    all_connections =
      Enum.flat_map(chains_status, fn {_chain, status} ->
        Map.get(status, :ws_connections, [])
      end)

    status = %{
      system: %{
        status: "operational",
        timestamp: DateTime.utc_now(),
        uptime: System.monotonic_time(:second),
        memory_usage: :erlang.memory(),
        process_count: :erlang.system_info(:process_count)
      },
      connections: %{
        total: length(all_connections),
        active: Enum.count(all_connections, &(&1.connected == true)),
        details: all_connections
      },
      chains: chains_status
    }

    json(conn, status)
  end

  defp get_all_chains_status do
    case ChainConfig.load_config("config/chains.yml") do
      {:ok, config} ->
        config.chains
        |> Map.keys()
        |> Enum.map(fn chain_name ->
          {chain_name, ChainSupervisor.get_chain_status(chain_name)}
        end)
        |> Enum.into(%{})

      {:error, _reason} ->
        %{}
    end
  end
end
