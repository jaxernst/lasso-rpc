defmodule LivechainWeb.ChainController do
  use LivechainWeb, :controller

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
    json(conn, %{status: "not implemented"})
  end
end
