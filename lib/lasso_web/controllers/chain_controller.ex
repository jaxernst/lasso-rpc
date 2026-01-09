defmodule LassoWeb.ChainController do
  use LassoWeb, :controller

  alias Lasso.Config.ConfigStore

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
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

  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(conn, %{"chain_id" => _chain_id}) do
    json(conn, %{status: "not implemented"})
  end
end
