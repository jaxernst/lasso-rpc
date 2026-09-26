defmodule LassoWeb.ReadyController do
  @moduledoc """
  Routing readiness for a file profile, distinct from process liveness.

  An eligible HTTP route and a fresh head from that same eligible set are
  required for each checked chain. No upstream call is made by this endpoint.
  """

  use LassoWeb, :controller

  alias Lasso.Config.{ConfigStore, ProfileValidator}
  alias Lasso.Providers.{CandidateListing, InstanceState}
  alias Lasso.RPC.{ChainState, SelectionFilters}

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, params) do
    profile = Map.get(params, "profile", ProfileValidator.default_profile())
    configured = ConfigStore.list_chains_for_profile(profile)

    with true <- configured != [],
         {:ok, chains} <- selected_chains(profile, configured, params) do
      checks = Enum.map(chains, &check_chain(profile, &1))
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

  defp check_chain(profile, chain_id) do
    candidates =
      profile
      |> CandidateListing.list_candidates(
        chain_id,
        SelectionFilters.new(protocol: :http, exclude_rate_limited: true)
      )
      |> Enum.filter(&eligible_http_candidate?/1)

    reason =
      cond do
        candidates == [] ->
          "no_eligible_upstream"

        match?(
          {:ok, _},
          ChainState.consensus_height(chain_id,
            provider_ids: Enum.map(candidates, & &1.instance_id)
          )
        ) ->
          nil

        true ->
          "stale_or_missing_head"
      end

    %{
      chain_id: chain_id,
      status: if(is_nil(reason), do: "ready", else: "not_ready"),
      reason: reason
    }
  end

  defp eligible_http_candidate?(candidate) do
    http_status = InstanceState.read_health(candidate.instance_id).http_status

    candidate.availability in [:up, :limited] and
      candidate.transport_availability.http in [:up, :limited] and
      InstanceState.status_to_availability(http_status) in [:up, :limited]
  end
end
