defmodule Lasso.Providers.Catalog do
  @moduledoc """
  Provider instance catalog that maps profiles to shared upstream instances.

  Reads all profiles from ConfigStore, computes instance_ids via `InstanceId.derive/3`,
  and populates an ETS table referenced via persistent_term for atomic swap.

  ## ETS Key Structure

      {:instance, instance_id}                                -> %{chain, url, ws_url, archival, canonical_config}
      {:profile_providers, profile, chain}                    -> [%{instance_id, provider_id, priority, capabilities, archival}]
      {:instance_refs, instance_id}                           -> [profile]
      {:provider_instance_id, profile, chain, provider_id}    -> instance_id (reverse index for O(1) lookup)
      {:chain_instances, chain}                               -> [instance_id] (all instances for a chain)

  ## Concurrency

  `build_from_config/0` builds a fresh ETS table and atomically swaps the
  persistent_term reference. Concurrent readers always see a consistent snapshot.
  The old table is deleted after a grace period to cover in-flight reads.
  """

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.InstanceId

  @persistent_term_key :lasso_catalog_active
  @grace_period_ms 2_000

  @doc """
  Atomically rebuilds the catalog from ConfigStore.

  Creates a fresh ETS table, populates it fully, swaps the persistent_term
  reference, and schedules deletion of the old table after a grace period.
  """
  @spec build_from_config() :: :ok
  def build_from_config do
    new_table =
      :ets.new(:lasso_provider_catalog, [
        :public,
        :set,
        read_concurrency: true
      ])

    profiles = ConfigStore.list_profiles()

    chain_instances_acc =
      Enum.reduce(profiles, %{}, fn profile, acc ->
        chains = ConfigStore.list_chains_for_profile(profile)

        Enum.reduce(chains, acc, fn chain, chain_acc ->
          case ConfigStore.get_chain(profile, chain) do
            {:ok, chain_config} ->
              build_chain_entries(new_table, profile, chain, chain_config, chain_acc)

            {:error, _} ->
              chain_acc
          end
        end)
      end)

    Enum.each(chain_instances_acc, fn {chain, instance_ids} ->
      :ets.insert(new_table, {{:chain_instances, chain}, Enum.uniq(instance_ids)})
    end)

    old_table =
      try do
        :persistent_term.get(@persistent_term_key)
      rescue
        ArgumentError -> nil
      end

    :persistent_term.put(@persistent_term_key, new_table)

    if old_table do
      schedule_table_deletion(old_table)
    end

    :ok
  end

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
  @spec get_profile_providers(String.t(), String.t()) :: [map()]
  def get_profile_providers(profile, chain) do
    case safe_lookup({:profile_providers, profile, chain}) do
      [{_, providers}] -> providers
      _ -> []
    end
  end

  @doc """
  Resolves (profile, chain, provider_id) to an instance_id via O(1) ETS lookup.
  """
  @spec lookup_instance_id(String.t(), String.t(), String.t()) :: String.t() | nil
  def lookup_instance_id(profile, chain, provider_id) do
    case safe_lookup({:provider_instance_id, profile, chain, provider_id}) do
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
  @spec list_instances_for_chain(String.t()) :: [String.t()]
  def list_instances_for_chain(chain) do
    case safe_lookup({:chain_instances, chain}) do
      [{_, ids}] -> ids
      _ -> []
    end
  end

  @doc """
  Given (profile, chain, instance_id), returns the provider_id for that profile.
  """
  @spec reverse_lookup_provider_id(String.t(), String.t(), String.t()) :: String.t() | nil
  def reverse_lookup_provider_id(profile, chain, instance_id) do
    profile
    |> get_profile_providers(chain)
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

  defp build_chain_entries(ets_table, profile, chain, chain_config, chain_instances_acc) do
    provider_entries =
      Enum.map(chain_config.providers, fn provider ->
        instance_id =
          InstanceId.derive(chain, provider,
            profile: profile,
            sharing_mode: provider.sharing_mode
          )

        :ets.insert(ets_table, {
          {:instance, instance_id},
          %{
            chain: chain,
            url: provider.url,
            ws_url: provider.ws_url,
            archival: provider.archival,
            canonical_config: %{
              id: provider.id,
              name: provider.name,
              url: provider.url,
              ws_url: provider.ws_url
            }
          }
        })

        update_instance_refs(ets_table, instance_id, profile)

        :ets.insert(
          ets_table,
          {{:provider_instance_id, profile, chain, provider.id}, instance_id}
        )

        %{
          instance_id: instance_id,
          provider_id: provider.id,
          priority: provider.priority,
          capabilities: provider.capabilities,
          archival: provider.archival
        }
      end)

    :ets.insert(ets_table, {{:profile_providers, profile, chain}, provider_entries})

    instance_ids = Enum.map(provider_entries, & &1.instance_id)
    Map.update(chain_instances_acc, chain, instance_ids, &(&1 ++ instance_ids))
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

  defp schedule_table_deletion(old_table) do
    Task.start(fn ->
      Process.sleep(@grace_period_ms)

      try do
        :ets.delete(old_table)
      rescue
        ArgumentError -> :ok
      end
    end)
  end
end
