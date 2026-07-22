defmodule LassoWeb.ChainController do
  use LassoWeb, :controller

  alias Lasso.Config.{ChainAlias, ConfigStore}

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    all_chains = ConfigStore.get_all_chains()

    chains =
      Enum.map(all_chains, fn {chain_id, chain_config} ->
        chain_slug = ChainAlias.canonical_slug(chain_id, chain_config.url_aliases)

        %{
          chain_id: to_string(chain_id),
          name: ChainAlias.display_name(chain_id, chain_config.display_name),
          chain_name: chain_slug,
          supported: true
        }
      end)

    json(conn, %{chains: chains})
  end
end
