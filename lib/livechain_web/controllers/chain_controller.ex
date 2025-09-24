defmodule LivechainWeb.ChainController do
  use LivechainWeb, :controller

  alias Livechain.RPC.ChainRegistry
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
        providers = ChainRegistry.list_all_providers_comprehensive()

        chain_providers =
          providers
          |> Enum.filter(&(&1.chain == chain_name))

        connected = Enum.any?(chain_providers, &(&1.ws_connected == true))

        status = %{
          chain_id: chain_id,
          chain_name: chain_name,
          name: chain_config.name,
          connected: connected,
          reconnect_attempts:
            chain_providers
            |> Enum.map(&(&1.reconnect_attempts || 0))
            |> Enum.max(fn -> 0 end),
          subscriptions:
            chain_providers
            |> Enum.map(&(&1.subscriptions || 0))
            |> Enum.sum()
        }

        json(conn, status)
    end
  end
end
