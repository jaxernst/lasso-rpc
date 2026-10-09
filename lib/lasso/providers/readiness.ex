defmodule Lasso.Providers.Readiness do
  @moduledoc """
  Node-local readiness from the published routing plan and ETS evidence.

  `check_node/0` answers whether this replica can serve as well as its peers:
  configuration loaded, catalog published, and distribution running when
  clustering is configured. Upstream state is left out because an upstream
  outage affects every replica alike and must not unready the fleet.
  `check_chain/2` is the strict upstream-backed check for one profile and chain.
  """
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{CandidateListing, Catalog, InstanceState}
  alias Lasso.RPC.{ChainState, SelectionFilters}

  @doc "Reports whether this replica has loaded configuration, published its catalog, and joined a configured cluster."
  @spec check_node() :: map()
  def check_node do
    checks = %{
      configuration: ConfigStore.list_profiles() != [],
      catalog: Catalog.ready?(),
      cluster: cluster_joined?()
    }

    reason =
      cond do
        not checks.configuration -> "configuration_not_loaded"
        not checks.catalog -> "catalog_not_published"
        not checks.cluster -> "cluster_not_joined"
        true -> nil
      end

    %{status: status(reason), reason: reason, checks: checks}
  end

  @doc "Reports eligible HTTP alternatives and whether they have fresh head evidence."
  @spec check_chain(String.t(), pos_integer()) :: map()
  def check_chain(profile, chain_id) do
    candidates =
      with %{} = catalog <- Catalog.snapshot(),
           {:ok, plan} <- Catalog.get_routing_plan(catalog, profile, chain_id) do
        plan
        |> CandidateListing.list_routing_candidates_from_plan(
          SelectionFilters.new(
            protocol: :http,
            exclude_rate_limited: true,
            include_half_open: true
          )
        )
        |> Enum.filter(&eligible_http_candidate?/1)
      else
        _unpublished -> []
      end

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
      status: status(reason),
      reason: reason
    }
  end

  defp status(nil), do: "ready"
  defp status(_reason), do: "not_ready"

  # Peer coverage is a fleet condition that /api/health reports; a replica has
  # joined once distribution runs and libcluster can connect it to its peers.
  defp cluster_joined? do
    Application.get_env(:libcluster, :topologies, []) == [] or Node.alive?()
  end

  defp eligible_http_candidate?(candidate) do
    http_status = InstanceState.read_health(candidate.instance_id).http_status

    :http in candidate.transports and
      candidate.circuit_state.http in [:closed, :half_open] and
      InstanceState.status_to_availability(http_status) in [:up, :limited]
  end
end
