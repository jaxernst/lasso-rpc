defmodule Lasso.Providers.Readiness do
  @moduledoc "Shared node-local HTTP routing readiness from existing ETS evidence."
  alias Lasso.Providers.{CandidateListing, InstanceState}
  alias Lasso.RPC.{ChainState, SelectionFilters}

  @doc "Reports eligible HTTP alternatives and whether they have fresh head evidence."
  @spec check_chain(String.t(), pos_integer()) :: map()
  def check_chain(profile, chain_id) do
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
      eligible_upstreams: length(candidates),
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
