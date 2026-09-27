defmodule Lasso.Providers.HeadEvidence do
  @moduledoc """
  Reads Core's current block-sync facts as a profile-scoped head snapshot.

  This adapter does not publish routing policy. It uses the catalog's active
  profile-to-instance mapping, so another profile's upstream never votes in a
  snapshot, even when both profiles share the same chain ID.
  """

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.ConfigStore
  alias Lasso.Observations.{HeadComparison, HeadScope, HeadSnapshot}
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.RoutingPlan

  @default_block_time_ms 12_000
  @default_freshness_ms 30_000
  @max_freshness_ms 60_000
  @agreement_window_ms 2_000

  @doc "Captures head evidence for the exact routing-plan generation."
  @spec snapshot_for_plan(RoutingPlan.t()) :: HeadSnapshot.t() | :unavailable
  def snapshot_for_plan(%RoutingPlan{} = plan) do
    generation = plan.generation

    case snapshot(plan.profile, plan.chain_id) do
      {:ok, %HeadSnapshot{revision: ^generation} = snapshot} ->
        snapshot

      _unavailable ->
        :unavailable
    end
  end

  @spec snapshot(String.t(), pos_integer(), integer()) ::
          {:ok, HeadSnapshot.t()} | {:error, :not_found}
  def snapshot(profile_id, chain_id, now_ms \\ System.system_time(:millisecond))
      when is_binary(profile_id) and profile_id != "" and is_integer(chain_id) and
             chain_id > 0 and is_integer(now_ms) do
    with %{generation: generation} = catalog <- Catalog.snapshot(),
         true <- generation == ConfigStore.route_generation(),
         {:ok, scope} <- scope_for(profile_id, chain_id, catalog),
         {:ok, result} <- Registry.get_head_snapshot(scope, generation, now_ms) do
      if Catalog.snapshot() == catalog and generation == ConfigStore.route_generation(),
        do: {:ok, result},
        else: {:error, :not_found}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "Refresh active profile scopes after one upstream publishes head evidence."
  @spec refresh_for_instance(pos_integer(), String.t()) :: :ok
  def refresh_for_instance(chain_id, instance_id)
      when is_integer(chain_id) and chain_id > 0 and is_binary(instance_id) do
    case Catalog.snapshot() do
      %{generation: generation} = catalog ->
        if generation == ConfigStore.route_generation() do
          now_ms = System.system_time(:millisecond)

          catalog
          |> Catalog.get_instance_refs(instance_id)
          |> Enum.uniq()
          |> Enum.each(fn profile_id ->
            with {:ok, scope} <- scope_for(profile_id, chain_id, catalog) do
              Registry.get_head_snapshot(scope, generation, now_ms)
            end
          end)
        end

      _unavailable ->
        :ok
    end

    :ok
  end

  defp scope_for(profile_id, chain_id, catalog) do
    with {:ok, chain} <- ConfigStore.get_chain(profile_id, chain_id) do
      instance_ids =
        catalog
        |> Catalog.get_profile_providers(profile_id, chain_id)
        |> Enum.map(& &1.instance_id)

      {:ok, HeadScope.new(profile_id, chain_id, instance_ids, policy(chain.block_time_ms))}
    end
  end

  defp policy(block_time_ms) do
    block_time_ms =
      if is_integer(block_time_ms) and block_time_ms > 0,
        do: block_time_ms,
        else: @default_block_time_ms

    %HeadComparison.Policy{
      block_time_ms: block_time_ms,
      reference_freshness_ms:
        max(@default_freshness_ms, min(block_time_ms * 4, @max_freshness_ms)),
      agreement_window_ms: @agreement_window_ms
    }
  end
end
