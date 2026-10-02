defmodule LassoWeb.ReadyController do
  @moduledoc """
  Routing readiness for a file profile, distinct from process liveness.

  An eligible HTTP route and a fresh head from that same eligible set are
  required for each checked chain. No upstream call is made by this endpoint.
  """

  use LassoWeb, :controller

  alias Lasso.Config.{ConfigStore, ProfileValidator}
  alias Lasso.Providers.Readiness

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, params) do
    profile = Map.get(params, "profile", ProfileValidator.default_profile())
    configured = ConfigStore.list_chains_for_profile(profile)

    with true <- configured != [],
         {:ok, chains} <- selected_chains(profile, configured, params) do
      checks =
        Enum.map(chains, fn chain ->
          profile |> Readiness.check_chain(chain) |> Map.take([:chain_id, :status, :reason])
        end)

      ready? = Enum.all?(checks, &(&1.status == "ready"))

      conn
      |> put_status(if(ready?, do: :ok, else: :service_unavailable))
      |> json(%{
        status: if(ready?, do: "ready", else: "not_ready"),
        profile: profile,
        checks: checks
      })
    else
      _ ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "not_ready",
          profile: profile,
          reason: "profile_or_chain_not_configured"
        })
    end
  end

  defp selected_chains(profile, _configured, %{"chain" => chain}) when is_binary(chain) do
    case ConfigStore.lookup_chain_id_in_profile(profile, chain) do
      {:ok, chain_id} -> {:ok, [chain_id]}
      _ -> :error
    end
  end

  defp selected_chains(_profile, _configured, %{"chain" => _invalid}), do: :error
  defp selected_chains(_profile, configured, _params), do: {:ok, Enum.sort(configured)}
end
