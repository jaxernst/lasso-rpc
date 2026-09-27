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

  @default_block_time_ms 12_000
  @default_freshness_ms 30_000
  @max_freshness_ms 60_000
  @agreement_window_ms 2_000

  @spec snapshot(String.t(), pos_integer(), integer()) ::
          {:ok, HeadSnapshot.t()} | {:error, :not_found}
  def snapshot(profile_id, chain_id, now_ms \\ System.system_time(:millisecond))
      when is_binary(profile_id) and profile_id != "" and is_integer(chain_id) and
             chain_id > 0 and is_integer(now_ms) do
    with {:ok, chain} <- ConfigStore.get_chain(profile_id, chain_id),
         %{generation: generation} = catalog <- Catalog.snapshot() do
      instance_ids =
        catalog
        |> Catalog.get_profile_providers(profile_id, chain_id)
        |> Enum.map(& &1.instance_id)

      scope = HeadScope.new(profile_id, chain_id, instance_ids, policy(chain.block_time_ms))

      observations =
        Enum.flat_map(scope.instance_ids, fn instance_id ->
          Registry.get_observations(chain_id, instance_id)
        end)

      {:ok, HeadComparison.derive(scope, observations, now_ms, generation)}
    else
      _missing -> {:error, :not_found}
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
