defmodule Lasso.Providers.ObservationPolicy do
  @moduledoc "Resolves file-profile observation demand before coalescing physical provider work."

  alias Lasso.Config.{ChainConfig, ConfigStore, ObservationConfig}
  alias Lasso.Providers.Catalog

  @type policy :: %{
          background_observations: boolean(),
          http_heads_interval_ms: non_neg_integer(),
          http_backup_interval_ms: non_neg_integer(),
          chain_identity_interval_ms: non_neg_integer(),
          evidence_freshness_ms: pos_integer(),
          subscribe_new_heads: boolean()
        }

  @spec references(String.t(), pos_integer()) :: [{String.t(), ChainConfig.t(), policy()}]
  def references(instance_id, chain_id) do
    instance_id
    |> Catalog.get_instance_refs()
    |> Enum.flat_map(fn profile ->
      case ConfigStore.get_chain(profile, chain_id) do
        {:ok, chain} ->
          policies_for_reference(profile, chain_id, instance_id, chain)
          |> Enum.map(&{profile, chain, &1})

        _ ->
          []
      end
    end)
  end

  @doc "Resolves every provider entry in one profile that shares a physical instance."
  @spec policies_for_reference(String.t(), pos_integer(), String.t(), ChainConfig.t()) :: [
          policy()
        ]
  def policies_for_reference(profile, chain_id, instance_id, chain) do
    provider_ids =
      Catalog.get_profile_providers(profile, chain_id)
      |> Enum.filter(&(&1.instance_id == instance_id))
      |> Enum.map(& &1.provider_id)

    chain.providers
    |> Enum.filter(&(&1.id in provider_ids))
    |> Enum.map(&ObservationConfig.resolve(chain, &1))
  end

  @spec effective(String.t(), pos_integer(), boolean()) :: map()
  def effective(instance_id, chain_id, has_ws) do
    instance_id
    |> references(chain_id)
    |> Enum.map(&elem(&1, 2))
    |> coalesce(has_ws)
  end

  @spec current_interval([policy()], boolean(), keyword()) :: non_neg_integer()
  def current_interval(policies, has_ws, opts \\ []) do
    age = Keyword.get(opts, :ws_age_ms)

    policies
    |> Enum.filter(& &1.background_observations)
    |> Enum.map(fn policy ->
      healthy? =
        Keyword.get(opts, :ws_healthy?, false) and
          (is_nil(age) or age <= policy.evidence_freshness_ms)

      cond do
        policy.http_heads_interval_ms == 0 -> 0
        has_ws and policy.subscribe_new_heads and healthy? -> policy.http_backup_interval_ms
        true -> policy.http_heads_interval_ms
      end
    end)
    |> minimum()
  end

  @doc "Coalesces per-reference demand; zero means no periodic work."
  @spec coalesce([policy()], boolean()) :: map()
  def coalesce(policies, has_ws) do
    enabled = Enum.filter(policies, & &1.background_observations)

    %{
      enabled?: enabled != [],
      poll_interval_ms: minimum(Enum.map(enabled, & &1.http_heads_interval_ms)),
      ws_active_poll_interval_ms:
        minimum(
          Enum.map(enabled, fn policy ->
            cond do
              policy.http_heads_interval_ms == 0 -> 0
              has_ws and policy.subscribe_new_heads -> policy.http_backup_interval_ms
              true -> policy.http_heads_interval_ms
            end
          end)
        ),
      chain_identity_interval_ms: minimum(Enum.map(enabled, & &1.chain_identity_interval_ms)),
      subscribe_new_heads: has_ws and Enum.any?(enabled, & &1.subscribe_new_heads),
      evidence_freshness_ms: minimum(Enum.map(policies, & &1.evidence_freshness_ms), 60_000)
    }
  end

  defp minimum(values, fallback \\ 0) do
    values |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.min(fn -> fallback end)
  end
end
