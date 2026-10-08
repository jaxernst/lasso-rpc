defmodule LassoWeb.ReadyController do
  @moduledoc """
  Readiness for orchestrator probes, distinct from process liveness.

  Without query parameters the response says whether this replica can serve as
  well as its peers: configuration loaded, catalog published, and distribution
  running when clustering is configured. Upstream state is left out because an
  upstream outage affects every replica alike. With `profile` or `chain`, the
  response is the strict routing check for that scope: each checked chain needs
  an eligible HTTP route and a fresh head from that same eligible set. No
  upstream call is made by this endpoint.
  """

  use LassoWeb, :controller

  alias Lasso.Config.{ConfigStore, ProfileValidator}
  alias Lasso.Providers.Readiness

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, params) do
    case Map.take(params, ["profile", "chain"]) do
      scope when map_size(scope) == 0 -> node_ready(conn)
      scope -> routing_ready(conn, scope)
    end
  end

  defp node_ready(conn) do
    check = Readiness.check_node()
    respond(conn, check.status == "ready", check)
  end

  defp routing_ready(conn, scope) do
    profile = Map.get(scope, "profile", ProfileValidator.default_profile())
    configured = ConfigStore.list_chains_for_profile(profile)

    with true <- configured != [],
         {:ok, chains} <- selected_chains(profile, configured, scope) do
      checks =
        Enum.map(chains, fn chain ->
          profile |> Readiness.check_chain(chain) |> Map.take([:chain_id, :status, :reason])
        end)

      ready? = Enum.all?(checks, &(&1.status == "ready"))

      respond(conn, ready?, %{
        status: if(ready?, do: "ready", else: "not_ready"),
        profile: profile,
        checks: checks
      })
    else
      _ ->
        respond(conn, false, %{
          status: "not_ready",
          profile: profile,
          reason: "profile_or_chain_not_configured"
        })
    end
  end

  defp respond(conn, ready?, body) do
    conn
    |> put_status(if(ready?, do: :ok, else: :service_unavailable))
    |> json(body)
  end

  defp selected_chains(profile, _configured, %{"chain" => chain}) when is_binary(chain) do
    case ConfigStore.lookup_chain_id_in_profile(profile, chain) do
      {:ok, chain_id} -> {:ok, [chain_id]}
      _ -> :error
    end
  end

  defp selected_chains(_profile, _configured, %{"chain" => _invalid}), do: :error
  defp selected_chains(_profile, configured, _scope), do: {:ok, Enum.sort(configured)}
end
