defmodule LivechainWeb.ChainController do
  use LivechainWeb, :controller

  alias Livechain.RPC.WSSupervisor
  alias Livechain.Config.ConfigStore

  def index(conn, _params) do
    all_chains = ConfigStore.get_all_chains()

    chains =
      Enum.map(all_chains, fn {chain_name, chain_config} ->
        %{
          chain_id: to_string(chain_config.chain_id),
          name: chain_config.name,
          chain_name: chain_name,
          supported: true
        }
      end)

    json(conn, %{chains: chains})
  end

  def status(conn, %{"chain_id" => chain_id}) do
    all_chains = ConfigStore.get_all_chains()

    # Find chain by chain_id (numeric string)
    chain_info =
      Enum.find(all_chains, fn {_chain_name, chain_config} ->
        to_string(chain_config.chain_id) == chain_id
      end)

    case chain_info do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Unsupported chain ID", chain_id: chain_id})

      {chain_name, chain_config} ->
        # Get connection status for this chain
        connections = WSSupervisor.list_connections()

        chain_connection =
          Enum.find(connections, fn conn ->
            String.contains?(String.downcase(conn.name), String.downcase(chain_config.name))
          end)

        status =
          if chain_connection do
            %{
              chain_id: chain_id,
              chain_name: chain_name,
              name: chain_config.name,
              connected: chain_connection.status == :connected,
              reconnect_attempts: chain_connection.reconnect_attempts || 0,
              subscriptions: chain_connection.subscriptions || 0
            }
          else
            %{
              chain_id: chain_id,
              chain_name: chain_name,
              name: chain_config.name,
              connected: false,
              reconnect_attempts: 0,
              subscriptions: 0
            }
          end

        json(conn, status)
    end
  end
end
