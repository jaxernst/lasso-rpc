defmodule LivechainWeb.ChainController do
  use LivechainWeb, :controller

  alias Livechain.RPC.WSSupervisor

  @supported_chains %{
    "1" => %{name: "Ethereum Mainnet", function: :ethereum_mainnet},
    "137" => %{name: "Polygon", function: :polygon},
    "42161" => %{name: "Arbitrum", function: :arbitrum},
    "56" => %{name: "BSC", function: :bsc}
  }

  def index(conn, _params) do
    chains = Enum.map(@supported_chains, fn {chain_id, info} ->
      %{
        chain_id: chain_id,
        name: info.name,
        supported: true
      }
    end)

    json(conn, %{chains: chains})
  end

  def status(conn, %{"chain_id" => chain_id}) do
    case Map.get(@supported_chains, chain_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Unsupported chain ID", chain_id: chain_id})

      chain_info ->
        # Get connection status for this chain
        connections = WSSupervisor.list_connections()
        chain_connection = Enum.find(connections, fn conn ->
          String.contains?(String.downcase(conn.name), String.downcase(chain_info.name))
        end)

        status = if chain_connection do
          %{
            chain_id: chain_id,
            name: chain_info.name,
            connected: chain_connection.status == :connected,
            reconnect_attempts: chain_connection.reconnect_attempts || 0,
            subscriptions: chain_connection.subscriptions || 0
          }
        else
          %{
            chain_id: chain_id,
            name: chain_info.name,
            connected: false,
            reconnect_attempts: 0,
            subscriptions: 0
          }
        end

        json(conn, status)
    end
  end
end