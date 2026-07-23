defmodule Lasso.Providers.Catalog do
  @moduledoc """
  Provider instance catalog that maps profiles to shared upstream instances.

  Reads all profiles from ConfigStore, computes instance_ids via `InstanceId.derive/3`,
  and populates an ETS table referenced via persistent_term for atomic swap.

  ## ETS Key Structure

      {:instance, instance_id}                                   -> %{chain_id, url, ws_url, canonical_config}
      {:profile_providers, profile, chain_id}                    -> [%{instance_id, provider_id, priority, capabilities, archival, subscribe_new_heads}]

  Capabilities (archival, subscribe_new_heads, etc.) are profile-scoped and
  live only on `{:profile_providers, p, chain_id}`. The same upstream URL can be
  classified differently by different profiles, so capabilities must never
  be read from the shared `{:instance, id}` entry.
      {:instance_refs, instance_id}                              -> [profile]
      {:provider_instance_id, profile, chain_id, provider_id}   -> instance_id (reverse index for O(1) lookup)
      {:chain_instances, chain_id}                               -> [instance_id] (all instances for a chain)

  All chain keys use `chain_id :: pos_integer()` (EIP-155 integer). Instance identity
  is derived from the normalized HTTP URL, normalized WS URL, chain_id, and auth scope;
  catalog writes refuse to overwrite an existing instance row with divergent endpoint
  URLs for the same derived ID.

  ## Concurrency

  `build_from_config/0` builds a fresh ETS table and atomically swaps the
  persistent_term reference. Concurrent readers always see a consistent snapshot.
  The old table is deleted after a grace period to cover in-flight reads.
  """

  require Logger

  alias Lasso.Config.{ChainConfig, ConfigStore}
  alias Lasso.Providers.{InstanceId, ProviderHeaders}

  @persistent_term_key :lasso_catalog_active

  @doc """
  Atomically rebuilds the catalog from ConfigStore.

  Creates a fresh ETS table, populates it fully, swaps the persistent_term
  reference, and schedules deletion of the old table after a grace period.
  """
  @spec build_from_config() :: :ok
  def build_from_config do
    Lasso.Providers.Catalog.Owner.rebuild()
  end

  @doc """
  Populates a freshly-created ETS table with catalog entries derived
  from current `ConfigStore` state.

  Called by `Lasso.Providers.Catalog.Owner` from inside the owner
  GenServer so the table belongs to a long-lived process. External
  callers should use `build_from_config/0`.
  """
  @spec populate(:ets.tid()) :: :ok
  def populate(new_table) do
    profiles = ConfigStore.list_profiles()

    chain_instances_acc =
      Enum.reduce(profiles, %{}, fn profile, acc ->
        chain_ids = ConfigStore.list_chains_for_profile(profile)

        Enum.reduce(chain_ids, acc, fn chain_id, chain_acc ->
          case ConfigStore.get_chain(profile, chain_id) do
            {:ok, chain_config} ->
              build_chain_entries(
                new_table,
                profile,
                chain_id,
                chain_config,
                chain_acc
              )

            {:error, _} ->
              chain_acc
          end
        end)
      end)

    Enum.each(chain_instances_acc, fn {chain_id, instance_ids} ->
      :ets.insert(new_table, {{:chain_instances, chain_id}, Enum.uniq(instance_ids)})
    end)

    :ok
  end

  @doc false
  # The `:persistent_term` key under which the active catalog ETS table
  # reference is published. Public so `Catalog.Owner` can swap it; not
  # part of the external API.
  @spec persistent_term_key() :: atom()
  def persistent_term_key, do: @persistent_term_key

  @doc """
  Gets instance config by instance_id.
  """
  @spec get_instance(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_instance(instance_id) do
    case safe_lookup({:instance, instance_id}) do
      [{_, config}] -> {:ok, config}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Gets the list of profiles that reference an instance.
  """
  @spec get_instance_refs(String.t()) :: [String.t()]
  def get_instance_refs(instance_id) do
    case safe_lookup({:instance_refs, instance_id}) do
      [{_, refs}] -> refs
      _ -> []
    end
  end

  @doc """
  Gets the provider list for a profile+chain with instance_id cross-references.
  """
  @spec get_profile_providers(String.t(), pos_integer()) :: [map()]
  def get_profile_providers(profile, chain_id) do
    case safe_lookup({:profile_providers, profile, chain_id}) do
      [{_, providers}] -> providers
      _ -> []
    end
  end

  @doc """
  Resolves (profile, chain_id, provider_id) to an instance_id via O(1) ETS lookup.
  """
  @spec lookup_instance_id(String.t(), pos_integer(), String.t()) :: String.t() | nil
  def lookup_instance_id(profile, chain_id, provider_id) do
    case safe_lookup({:provider_instance_id, profile, chain_id, provider_id}) do
      [{_, instance_id}] -> instance_id
      _ -> nil
    end
  end

  @doc """
  Lists all unique instance_ids in the catalog.
  """
  @spec list_all_instance_ids() :: [String.t()]
  def list_all_instance_ids do
    case table() do
      nil -> []
      t -> :ets.match(t, {{:instance, :"$1"}, :_}) |> List.flatten()
    end
  end

  @doc """
  Returns all instance_ids for a given chain.
  """
  @spec list_instances_for_chain(pos_integer()) :: [String.t()]
  def list_instances_for_chain(chain_id) do
    case safe_lookup({:chain_instances, chain_id}) do
      [{_, ids}] -> ids
      _ -> []
    end
  end

  @doc """
  Given (profile, chain_id, instance_id), returns the provider_id for that profile.
  """
  @spec reverse_lookup_provider_id(String.t(), pos_integer(), String.t()) :: String.t() | nil
  def reverse_lookup_provider_id(profile, chain_id, instance_id) do
    profile
    |> get_profile_providers(chain_id)
    |> Enum.find_value(fn
      %{instance_id: ^instance_id, provider_id: pid} -> pid
      _ -> nil
    end)
  end

  @doc """
  Returns the count of unique provider instances.
  """
  @spec instance_count() :: non_neg_integer()
  def instance_count do
    list_all_instance_ids() |> length()
  end

  @doc """
  Returns the active ETS table reference.

  Returns nil if no catalog has been built yet (e.g., during early startup).
  """
  @spec table() :: :ets.tid() | nil
  def table do
    :persistent_term.get(@persistent_term_key, nil)
  end

  # Private

  defp safe_lookup(key) do
    case table() do
      nil -> []
      t -> :ets.lookup(t, key)
    end
  rescue
    ArgumentError -> []
  end

  defp build_chain_entries(
         ets_table,
         profile,
         chain_id,
         chain_config,
         chain_instances_acc
       ) do
    provider_entries =
      Enum.map(chain_config.providers, fn provider ->
        subscribe_new_heads =
          ChainConfig.should_subscribe_new_heads?(chain_config, provider)

        instance_id =
          InstanceId.derive(chain_id, provider,
            profile_id: profile,
            sharing_mode: provider.sharing_mode
          )

        insert_instance_config(ets_table, instance_id, profile, chain_id, chain_config, provider)

        update_instance_refs(ets_table, instance_id, profile)

        :ets.insert(
          ets_table,
          {{:provider_instance_id, profile, chain_id, provider.id}, instance_id}
        )

        %{
          instance_id: instance_id,
          provider_id: provider.id,
          name: provider.name,
          priority: provider.priority,
          capabilities: provider.capabilities,
          archival: provider.archival,
          subscribe_new_heads: subscribe_new_heads
        }
      end)

    :ets.insert(ets_table, {{:profile_providers, profile, chain_id}, provider_entries})

    instance_ids = Enum.map(provider_entries, & &1.instance_id)
    Map.update(chain_instances_acc, chain_id, instance_ids, &(&1 ++ instance_ids))
  end

  defp insert_instance_config(ets_table, instance_id, profile, chain_id, chain_config, provider) do
    config = %{
      chain_id: chain_id,
      block_time_ms: chain_config.block_time_ms,
      url: provider.url,
      ws_url: provider.ws_url,
      headers: ProviderHeaders.build(provider),
      mock?: provider.__mock__ == true,
      canonical_config: %{
        id: provider.id,
        name: provider.name,
        url: provider.url,
        ws_url: provider.ws_url
      }
    }

    case :ets.lookup(ets_table, {:instance, instance_id}) do
      [] ->
        :ets.insert(ets_table, {{:instance, instance_id}, config})

      [{_, existing}] ->
        if endpoint_identity_match?(existing, config) do
          :ok
        else
          emit_identity_collision(instance_id, profile, chain_id, provider, existing, config)
        end
    end
  end

  defp endpoint_identity_match?(existing, new) do
    normalize_endpoint_url(existing.url) == normalize_endpoint_url(new.url) and
      normalize_endpoint_url(Map.get(existing, :ws_url)) ==
        normalize_endpoint_url(Map.get(new, :ws_url))
  end

  defp normalize_endpoint_url(url), do: InstanceId.optional_normalize_url(url)

  defp emit_identity_collision(instance_id, profile, chain_id, provider, existing, new) do
    Logger.error("Provider instance identity collision; keeping existing catalog entry",
      instance_id: instance_id,
      profile: profile,
      chain_id: chain_id,
      provider_id: provider.id,
      existing_url: Lasso.URLMask.mask(existing.url),
      existing_ws_url: Lasso.URLMask.mask(Map.get(existing, :ws_url)),
      new_url: Lasso.URLMask.mask(new.url),
      new_ws_url: Lasso.URLMask.mask(Map.get(new, :ws_url))
    )

    :telemetry.execute(
      [:lasso, :provider_catalog, :identity_collision],
      %{count: 1},
      %{
        instance_id: instance_id,
        chain_id: chain_id,
        profile: profile,
        provider_id: provider.id
      }
    )

    :ok
  end

  defp update_instance_refs(ets_table, instance_id, profile) do
    current_refs =
      case :ets.lookup(ets_table, {:instance_refs, instance_id}) do
        [{_, refs}] -> refs
        [] -> []
      end

    unless profile in current_refs do
      :ets.insert(ets_table, {{:instance_refs, instance_id}, [profile | current_refs]})
    end
  end
end
