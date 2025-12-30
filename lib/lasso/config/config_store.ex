defmodule Lasso.Config.ConfigStore do
  @moduledoc """
  Profile-aware configuration store that caches chain and provider configurations
  in ETS tables for fast, hot-path access.

  ## Multi-Profile Architecture

  Profiles are the top-level isolation boundary. Each profile contains its own
  set of chains and providers with independent configuration. The ETS table
  (owned by Application process) uses the following key structure:

  - `{:profile, slug, :meta}` -> Profile metadata
  - `{:profile, slug, :chains}` -> `%{chain_name => ChainConfig.t()}`
  - `{:profile_list}` -> List of all profile slugs
  - `{:chain_profiles, chain}` -> List of profiles containing this chain
  - `{:all_chains}` -> Union of all chain names across all profiles
  - `{:global_providers, chain}` -> `[{profile, provider_id}, ...]`

  ## Backward Compatibility

  Single-argument functions like `get_chain/1` continue to work by using the
  "default" profile. New code should use the two-argument versions.

  ## Configuration Backend

  Configuration is loaded via the Backend behaviour. The default is
  `Lasso.Config.Backend.File` which loads profiles from YAML files.
  """

  use GenServer
  require Logger

  alias Lasso.Config.Backend
  alias Lasso.Config.ChainConfig
  alias Lasso.Config.ChainConfig.Provider

  @config_table :lasso_config_store
  @default_profile "default"

  # Legacy keys for backward compatibility
  @legacy_chains_key :chains
  @legacy_chain_ids_key :chain_ids

  ## Profile Metadata Type

  @type profile_meta :: %{
          slug: String.t(),
          name: String.t(),
          type: :free | :standard | :premium | :byok,
          default_rps_limit: pos_integer(),
          default_burst_limit: pos_integer()
        }

  ## Public API - Profile Operations

  @doc """
  Starts the ConfigStore GenServer.

  The GenServer manages configuration state but does NOT create the ETS table
  (that's owned by Application). Profile loading happens after supervision tree
  starts via `load_all_profiles/0`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads all profiles from the configured backend.

  This should be called AFTER the supervision tree is started to avoid
  circular dependencies. Returns the list of loaded profile slugs.
  """
  @spec load_all_profiles() :: {:ok, [String.t()]} | {:error, term()}
  def load_all_profiles do
    GenServer.call(__MODULE__, :load_all_profiles, :infinity)
  end

  @doc """
  Lists all loaded profile slugs.
  """
  @spec list_profiles() :: [String.t()]
  def list_profiles do
    case :ets.lookup(@config_table, {:profile_list}) do
      [{{:profile_list}, profiles}] -> profiles
      [] -> []
    end
  end

  @doc """
  Gets profile metadata by slug.
  """
  @spec get_profile(String.t()) :: {:ok, profile_meta()} | {:error, :not_found}
  def get_profile(slug) do
    case :ets.lookup(@config_table, {:profile, slug, :meta}) do
      [{{:profile, ^slug, :meta}, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets chain configuration for a specific profile and chain.
  """
  @spec get_chain(String.t(), String.t()) :: {:ok, ChainConfig.t()} | {:error, :not_found}
  def get_chain(profile, chain_name) do
    case :ets.lookup(@config_table, {:profile, profile, :chains}) do
      [{{:profile, ^profile, :chains}, chains}] ->
        case Map.get(chains, chain_name) do
          nil -> {:error, :not_found}
          chain_config -> {:ok, chain_config}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets chain configuration using the default profile (backward compatibility).
  """
  @spec get_chain(String.t()) :: {:ok, ChainConfig.t()} | {:error, :not_found}
  def get_chain(chain_name) do
    # Try profile-based lookup first, fall back to legacy
    case get_chain(@default_profile, chain_name) do
      {:ok, _} = result ->
        result

      {:error, :not_found} ->
        # Legacy fallback for backward compatibility
        case :ets.lookup(@config_table, @legacy_chains_key) do
          [{@legacy_chains_key, chains}] ->
            case Map.get(chains, chain_name) do
              nil -> {:error, :not_found}
              chain_config -> {:ok, chain_config}
            end

          [] ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Lists all chains for a specific profile.
  """
  @spec list_chains_for_profile(String.t()) :: [String.t()]
  def list_chains_for_profile(profile) do
    case :ets.lookup(@config_table, {:profile, profile, :chains}) do
      [{{:profile, ^profile, :chains}, chains}] -> Map.keys(chains)
      [] -> []
    end
  end

  @doc """
  Lists all chain names (union across all profiles).
  """
  @spec list_chains() :: [String.t()]
  def list_chains do
    case :ets.lookup(@config_table, {:all_chains}) do
      [{{:all_chains}, chains}] ->
        chains

      [] ->
        # Legacy fallback
        case :ets.lookup(@config_table, @legacy_chains_key) do
          [{@legacy_chains_key, chains}] -> Map.keys(chains)
          [] -> []
        end
    end
  end

  @doc """
  Lists profiles that contain a specific chain.
  """
  @spec list_profiles_for_chain(String.t()) :: [String.t()]
  def list_profiles_for_chain(chain_name) do
    case :ets.lookup(@config_table, {:chain_profiles, chain_name}) do
      [{{:chain_profiles, ^chain_name}, profiles}] -> profiles
      [] -> []
    end
  end

  @doc """
  Gets all chains for a profile as a map.
  """
  @spec get_profile_chains(String.t()) :: {:ok, %{String.t() => ChainConfig.t()}} | {:error, :not_found}
  def get_profile_chains(profile) do
    case :ets.lookup(@config_table, {:profile, profile, :chains}) do
      [{{:profile, ^profile, :chains}, chains}] -> {:ok, chains}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets all chains as a map (union, backward compatibility).
  """
  @spec get_all_chains() :: %{String.t() => ChainConfig.t()}
  def get_all_chains do
    # Try to return default profile's chains first
    case get_profile_chains(@default_profile) do
      {:ok, chains} ->
        chains

      {:error, :not_found} ->
        # Legacy fallback
        case :ets.lookup(@config_table, @legacy_chains_key) do
          [{@legacy_chains_key, chains}] -> chains
          [] -> %{}
        end
    end
  end

  @doc """
  Gets provider configuration for a specific profile, chain, and provider.
  """
  @spec get_provider(String.t(), String.t(), String.t()) ::
          {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(profile, chain_name, provider_id) do
    with {:ok, chain_config} <- get_chain(profile, chain_name) do
      case Enum.find(chain_config.providers, &(&1.id == provider_id)) do
        nil -> {:error, :not_found}
        provider -> {:ok, provider}
      end
    end
  end

  @doc """
  Gets provider configuration (backward compatibility).
  """
  @spec get_provider(String.t(), String.t()) ::
          {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(chain_name, provider_id) do
    get_provider(@default_profile, chain_name, provider_id)
  end

  @doc """
  Gets all providers for a specific chain (backward compatibility).
  """
  @spec get_providers(String.t()) :: {:ok, [Provider.t()]} | {:error, :not_found}
  def get_providers(chain_name) do
    case get_chain(chain_name) do
      {:ok, chain_config} -> {:ok, chain_config.providers}
      error -> error
    end
  end

  @doc """
  Gets all provider IDs for a profile and chain.
  """
  @spec get_provider_ids(String.t(), String.t()) :: [String.t()]
  def get_provider_ids(profile, chain_name) do
    case get_chain(profile, chain_name) do
      {:ok, chain_config} -> Enum.map(chain_config.providers, & &1.id)
      {:error, :not_found} -> []
    end
  end

  @doc """
  Lists all global provider keys for a chain (across all profiles).

  Returns list of `{profile, provider_id}` tuples for use in global components
  like BlockSync and HealthProbe.
  """
  @spec list_global_providers(String.t()) :: [{String.t(), String.t()}]
  def list_global_providers(chain_name) do
    case :ets.lookup(@config_table, {:global_providers, chain_name}) do
      [{{:global_providers, ^chain_name}, providers}] -> providers
      [] -> []
    end
  end

  @doc """
  Gets a chain configuration by chain name or chain ID (backward compatibility).
  """
  @spec get_chain_by_name_or_id(String.t() | integer()) ::
          {:ok, {String.t(), ChainConfig.t()}} | {:error, :not_found | :invalid_format}
  def get_chain_by_name_or_id(chain_id) when is_integer(chain_id) do
    find_chain_by_id(chain_id)
  end

  def get_chain_by_name_or_id(chain_name) when is_binary(chain_name) do
    case get_chain(chain_name) do
      {:ok, chain_config} ->
        {:ok, {chain_name, chain_config}}

      {:error, :not_found} ->
        # Try parsing as numeric chain ID
        case Integer.parse(chain_name) do
          {chain_id, ""} -> find_chain_by_id(chain_id)
          _ -> {:error, :invalid_format}
        end
    end
  end

  ## Public API - Runtime Registration (for tests)

  @doc """
  Registers a chain configuration in-memory (runtime only, not persisted).
  """
  @spec register_chain_runtime(String.t(), map()) :: :ok | {:error, term()}
  def register_chain_runtime(chain_name, chain_attrs) do
    GenServer.call(__MODULE__, {:register_chain_runtime, chain_name, chain_attrs})
  end

  @doc """
  Unregisters a chain from in-memory configuration (runtime only).
  """
  @spec unregister_chain_runtime(String.t()) :: :ok | {:error, term()}
  def unregister_chain_runtime(chain_name) do
    GenServer.call(__MODULE__, {:unregister_chain_runtime, chain_name})
  end

  @doc """
  Registers a provider configuration in-memory (runtime only).
  """
  @spec register_provider_runtime(String.t(), map()) :: :ok | {:error, term()}
  def register_provider_runtime(chain_name, provider_attrs) do
    GenServer.call(__MODULE__, {:register_provider_runtime, chain_name, provider_attrs})
  end

  @doc """
  Unregisters a provider from in-memory configuration (runtime only).
  """
  @spec unregister_provider_runtime(String.t(), String.t()) :: :ok | {:error, term()}
  def unregister_provider_runtime(chain_name, provider_id) do
    GenServer.call(__MODULE__, {:unregister_provider_runtime, chain_name, provider_id})
  end

  @doc """
  Reloads configuration from the configured backend.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload, :infinity)
  end

  @doc """
  Gets the current configuration status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    # ETS table is owned by Application - we just use it
    # Note: We don't load profiles here to avoid circular dependencies
    # Profile loading happens via load_all_profiles/0 after supervision tree starts

    # Parse options - support both legacy path and new config
    {backend_module, backend_config} = parse_backend_opts(opts)

    state = %{
      backend_module: backend_module,
      backend_config: backend_config,
      backend_state: nil,
      last_loaded: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:load_all_profiles, _from, state) do
    case do_load_all_profiles(state) do
      {:ok, profiles, new_state} ->
        {:reply, {:ok, profiles}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case do_load_all_profiles(state) do
      {:ok, _profiles, new_state} ->
        Logger.info("Configuration reloaded successfully")
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to reload configuration: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:register_chain_runtime, chain_name, chain_attrs}, _from, state) do
    # Register in default profile for backward compatibility
    with {:error, :not_found} <- get_chain(@default_profile, chain_name),
         chain_config <- normalize_chain_config(chain_name, chain_attrs) do
      # Store in legacy format for backward compat
      store_chain_legacy(chain_name, chain_config)
      # Also store in profile format
      add_chain_to_profile(@default_profile, chain_name, chain_config)
      Logger.debug("Registered chain #{chain_name} in ConfigStore (runtime)")
      {:reply, :ok, state}
    else
      {:ok, _existing} -> {:reply, {:error, :already_exists}, state}
    end
  end

  @impl true
  def handle_call({:unregister_chain_runtime, chain_name}, _from, state) do
    with {:ok, chain_config} <- get_chain(chain_name) do
      remove_chain_legacy(chain_name, chain_config)
      remove_chain_from_profile(@default_profile, chain_name)
      Logger.debug("Unregistered chain #{chain_name} from ConfigStore (runtime)")
      {:reply, :ok, state}
    else
      {:error, :not_found} -> {:reply, {:error, :chain_not_found}, state}
    end
  end

  @impl true
  def handle_call({:register_provider_runtime, chain_name, provider_attrs}, _from, state) do
    with {:ok, chain_config} <- get_chain(chain_name),
         provider_config <- normalize_provider_config(provider_attrs),
         :ok <- validate_provider_not_exists(chain_config, provider_config.id) do
      updated_chain = add_provider_to_chain(chain_config, provider_config)
      update_chain_in_ets(chain_name, updated_chain)
      Logger.debug("Registered provider #{provider_config.id} for #{chain_name} (runtime)")
      {:reply, :ok, state}
    else
      {:error, :not_found} -> {:reply, {:error, :chain_not_found}, state}
      {:error, :already_exists} -> {:reply, {:error, :already_exists}, state}
    end
  end

  @impl true
  def handle_call({:unregister_provider_runtime, chain_name, provider_id}, _from, state) do
    with {:ok, chain_config} <- get_chain(chain_name),
         {:ok, updated_chain} <- remove_provider_from_chain(chain_config, provider_id) do
      update_chain_in_ets(chain_name, updated_chain)
      Logger.debug("Unregistered provider #{provider_id} from #{chain_name} (runtime)")
      {:reply, :ok, state}
    else
      {:error, :not_found} -> {:reply, {:error, :chain_not_found}, state}
      {:error, :provider_not_found} -> {:reply, {:error, :provider_not_found}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    profiles = list_profiles()
    chains = list_chains()

    total_providers =
      profiles
      |> Enum.flat_map(&list_chains_for_profile/1)
      |> Enum.map(fn chain ->
        case get_chain(chain) do
          {:ok, config} -> length(config.providers)
          _ -> 0
        end
      end)
      |> Enum.sum()

    status = %{
      profiles_loaded: length(profiles),
      chains_loaded: length(chains),
      total_providers: total_providers,
      last_loaded: state.last_loaded,
      backend: state.backend_module
    }

    {:reply, status, state}
  end

  ## Private Functions

  defp parse_backend_opts(opts) when is_binary(opts) do
    # Legacy: single path string means use file backend with legacy chains.yml
    {Lasso.Config.Backend.File,
     [
       profiles_dir: "config/profiles",
       legacy_config_path: opts
     ]}
  end

  defp parse_backend_opts(opts) when is_list(opts) do
    backend_module = Keyword.get(opts, :backend, Backend.backend_module())
    backend_config = Keyword.get(opts, :config, Backend.backend_config())
    {backend_module, backend_config}
  end

  defp parse_backend_opts(_opts) do
    {Backend.backend_module(), Backend.backend_config()}
  end

  defp do_load_all_profiles(state) do
    backend_module = state.backend_module
    backend_config = state.backend_config

    with {:ok, backend_state} <- backend_module.init(backend_config),
         {:ok, profile_specs} <- backend_module.load_all(backend_state) do
      # Clear existing profile data
      clear_profile_data()

      # Store each profile
      profile_slugs =
        Enum.map(profile_specs, fn spec ->
          store_profile(spec)
          spec.slug
        end)

      # Build indices
      build_indices(profile_specs)

      # Also populate legacy format for backward compatibility
      populate_legacy_format(profile_specs)

      new_state = %{
        state
        | backend_state: backend_state,
          last_loaded: DateTime.utc_now()
      }

      Logger.info("Loaded #{length(profile_slugs)} profiles: #{Enum.join(profile_slugs, ", ")}")
      {:ok, profile_slugs, new_state}
    end
  end

  defp clear_profile_data do
    # Clear profile-related keys
    :ets.match_delete(@config_table, {{:profile, :_, :_}, :_})
    :ets.delete(@config_table, {:profile_list})
    :ets.delete(@config_table, {:all_chains})
    :ets.match_delete(@config_table, {{:chain_profiles, :_}, :_})
    :ets.match_delete(@config_table, {{:global_providers, :_}, :_})
  end

  defp store_profile(spec) do
    meta = %{
      slug: spec.slug,
      name: spec.name,
      type: spec.type,
      default_rps_limit: spec.default_rps_limit,
      default_burst_limit: spec.default_burst_limit
    }

    :ets.insert(@config_table, {{:profile, spec.slug, :meta}, meta})
    :ets.insert(@config_table, {{:profile, spec.slug, :chains}, spec.chains})
  end

  defp build_indices(profile_specs) do
    # Build profile list
    profile_slugs = Enum.map(profile_specs, & &1.slug)
    :ets.insert(@config_table, {{:profile_list}, profile_slugs})

    # Build chain -> profiles index and all_chains list
    chain_profiles_map =
      profile_specs
      |> Enum.flat_map(fn spec ->
        Enum.map(Map.keys(spec.chains), fn chain -> {chain, spec.slug} end)
      end)
      |> Enum.group_by(fn {chain, _} -> chain end, fn {_, profile} -> profile end)

    all_chains = Map.keys(chain_profiles_map)
    :ets.insert(@config_table, {{:all_chains}, all_chains})

    Enum.each(chain_profiles_map, fn {chain, profiles} ->
      :ets.insert(@config_table, {{:chain_profiles, chain}, profiles})
    end)

    # Build global providers index
    global_providers_map =
      profile_specs
      |> Enum.flat_map(fn spec ->
        Enum.flat_map(spec.chains, fn {chain_name, chain_config} ->
          Enum.map(chain_config.providers, fn provider ->
            {chain_name, {spec.slug, provider.id}}
          end)
        end)
      end)
      |> Enum.group_by(fn {chain, _} -> chain end, fn {_, provider} -> provider end)

    Enum.each(global_providers_map, fn {chain, providers} ->
      :ets.insert(@config_table, {{:global_providers, chain}, providers})
    end)
  end

  defp populate_legacy_format(profile_specs) do
    # Find default profile or use first profile
    default_spec =
      Enum.find(profile_specs, fn s -> s.slug == @default_profile end) ||
        List.first(profile_specs)

    if default_spec do
      # Store in legacy format
      :ets.insert(@config_table, {@legacy_chains_key, default_spec.chains})

      # Build chain_id index
      chain_id_index =
        Enum.reduce(default_spec.chains, %{}, fn {chain_name, chain_config}, acc ->
          if chain_config.chain_id do
            Map.put(acc, chain_config.chain_id, chain_name)
          else
            acc
          end
        end)

      :ets.insert(@config_table, {@legacy_chain_ids_key, chain_id_index})
    end
  end

  defp find_chain_by_id(chain_id) do
    case :ets.lookup(@config_table, @legacy_chain_ids_key) do
      [{@legacy_chain_ids_key, id_index}] ->
        case Map.get(id_index, chain_id) do
          nil ->
            {:error, :not_found}

          chain_name ->
            case get_chain(chain_name) do
              {:ok, chain_config} -> {:ok, {chain_name, chain_config}}
              error -> error
            end
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp add_chain_to_profile(profile, chain_name, chain_config) do
    chains =
      case :ets.lookup(@config_table, {:profile, profile, :chains}) do
        [{{:profile, ^profile, :chains}, existing}] -> existing
        [] -> %{}
      end

    updated_chains = Map.put(chains, chain_name, chain_config)
    :ets.insert(@config_table, {{:profile, profile, :chains}, updated_chains})

    # Update indices
    update_chain_profiles_index(chain_name, profile)
    update_all_chains_index(chain_name)
  end

  defp remove_chain_from_profile(profile, chain_name) do
    case :ets.lookup(@config_table, {:profile, profile, :chains}) do
      [{{:profile, ^profile, :chains}, chains}] ->
        updated_chains = Map.delete(chains, chain_name)
        :ets.insert(@config_table, {{:profile, profile, :chains}, updated_chains})

      [] ->
        :ok
    end
  end

  defp update_chain_profiles_index(chain_name, profile) do
    current =
      case :ets.lookup(@config_table, {:chain_profiles, chain_name}) do
        [{{:chain_profiles, ^chain_name}, profiles}] -> profiles
        [] -> []
      end

    if profile not in current do
      :ets.insert(@config_table, {{:chain_profiles, chain_name}, [profile | current]})
    end
  end

  defp update_all_chains_index(chain_name) do
    current =
      case :ets.lookup(@config_table, {:all_chains}) do
        [{{:all_chains}, chains}] -> chains
        [] -> []
      end

    if chain_name not in current do
      :ets.insert(@config_table, {{:all_chains}, [chain_name | current]})
    end
  end

  # Legacy storage helpers

  defp store_chain_legacy(chain_name, chain_config) do
    chains =
      case :ets.lookup(@config_table, @legacy_chains_key) do
        [{@legacy_chains_key, existing}] -> existing
        [] -> %{}
      end

    updated_chains = Map.put(chains, chain_name, chain_config)
    :ets.insert(@config_table, {@legacy_chains_key, updated_chains})

    if chain_config.chain_id do
      id_index =
        case :ets.lookup(@config_table, @legacy_chain_ids_key) do
          [{@legacy_chain_ids_key, existing}] -> existing
          [] -> %{}
        end

      updated_index = Map.put(id_index, chain_config.chain_id, chain_name)
      :ets.insert(@config_table, {@legacy_chain_ids_key, updated_index})
    end
  end

  defp remove_chain_legacy(chain_name, chain_config) do
    chains =
      case :ets.lookup(@config_table, @legacy_chains_key) do
        [{@legacy_chains_key, existing}] -> existing
        [] -> %{}
      end

    updated_chains = Map.delete(chains, chain_name)
    :ets.insert(@config_table, {@legacy_chains_key, updated_chains})

    if chain_config.chain_id do
      id_index =
        case :ets.lookup(@config_table, @legacy_chain_ids_key) do
          [{@legacy_chain_ids_key, existing}] -> existing
          [] -> %{}
        end

      updated_index = Map.delete(id_index, chain_config.chain_id)
      :ets.insert(@config_table, {@legacy_chain_ids_key, updated_index})
    end
  end

  defp update_chain_in_ets(chain_name, chain_config) do
    # Update legacy format
    chains =
      case :ets.lookup(@config_table, @legacy_chains_key) do
        [{@legacy_chains_key, existing}] -> existing
        [] -> %{}
      end

    updated_chains = Map.put(chains, chain_name, chain_config)
    :ets.insert(@config_table, {@legacy_chains_key, updated_chains})

    # Update profile format
    case :ets.lookup(@config_table, {:profile, @default_profile, :chains}) do
      [{{:profile, @default_profile, :chains}, profile_chains}] ->
        updated_profile_chains = Map.put(profile_chains, chain_name, chain_config)
        :ets.insert(@config_table, {{:profile, @default_profile, :chains}, updated_profile_chains})

      [] ->
        :ok
    end
  end

  # Normalization helpers

  defp normalize_chain_config(chain_name, attrs) when is_map(attrs) do
    connection_attrs = Map.get(attrs, :connection) || Map.get(attrs, "connection") || %{}
    failover_attrs = Map.get(attrs, :failover) || Map.get(attrs, "failover") || %{}
    selection_attrs = Map.get(attrs, :selection) || Map.get(attrs, "selection")
    monitoring_attrs = Map.get(attrs, :monitoring) || Map.get(attrs, "monitoring") || %{}
    providers_attrs = Map.get(attrs, :providers) || Map.get(attrs, "providers") || []

    %ChainConfig{
      chain_id: Map.get(attrs, :chain_id) || Map.get(attrs, "chain_id"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name") || chain_name,
      providers: Enum.map(providers_attrs, &normalize_provider_config/1),
      connection: normalize_connection_config(connection_attrs),
      failover: normalize_failover_config(failover_attrs),
      selection: normalize_selection_config(selection_attrs),
      monitoring: normalize_monitoring_config(monitoring_attrs)
    }
  end

  defp normalize_connection_config(attrs) when is_map(attrs) do
    %ChainConfig.Connection{
      heartbeat_interval:
        Map.get(attrs, :heartbeat_interval) || Map.get(attrs, "heartbeat_interval") || 30_000,
      reconnect_interval:
        Map.get(attrs, :reconnect_interval) || Map.get(attrs, "reconnect_interval") || 5_000,
      max_reconnect_attempts:
        Map.get(attrs, :max_reconnect_attempts) || Map.get(attrs, "max_reconnect_attempts") || 5
    }
  end

  defp normalize_failover_config(attrs) when is_map(attrs) do
    %ChainConfig.Failover{
      max_backfill_blocks:
        Map.get(attrs, :max_backfill_blocks) || Map.get(attrs, "max_backfill_blocks") || 100,
      backfill_timeout:
        Map.get(attrs, :backfill_timeout) || Map.get(attrs, "backfill_timeout") || 30_000,
      enabled: Map.get(attrs, :enabled) || Map.get(attrs, "enabled") || true
    }
  end

  defp normalize_selection_config(nil), do: nil

  defp normalize_selection_config(attrs) when is_map(attrs) do
    %ChainConfig.Selection{
      max_lag_blocks: Map.get(attrs, :max_lag_blocks) || Map.get(attrs, "max_lag_blocks")
    }
  end

  defp normalize_monitoring_config(attrs) when is_map(attrs) do
    %ChainConfig.Monitoring{
      probe_interval_ms:
        Map.get(attrs, :probe_interval_ms) || Map.get(attrs, "probe_interval_ms") || 12_000,
      lag_threshold_blocks:
        Map.get(attrs, :lag_threshold_blocks) || Map.get(attrs, "lag_threshold_blocks") || 3,
      new_heads_staleness_threshold_ms:
        Map.get(attrs, :new_heads_staleness_threshold_ms) ||
          Map.get(attrs, "new_heads_staleness_threshold_ms") ||
          42_000
    }
  end

  defp normalize_provider_config(attrs) when is_map(attrs) do
    %Provider{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      url: Map.get(attrs, :url) || Map.get(attrs, "url"),
      ws_url: Map.get(attrs, :ws_url) || Map.get(attrs, "ws_url"),
      type: Map.get(attrs, :type) || Map.get(attrs, "type") || "public",
      priority: Map.get(attrs, :priority) || Map.get(attrs, "priority") || 100,
      api_key_required:
        Map.get(attrs, :api_key_required) || Map.get(attrs, "api_key_required") || false,
      region: Map.get(attrs, :region) || Map.get(attrs, "region") || "global",
      adapter_config: Map.get(attrs, :adapter_config) || Map.get(attrs, "adapter_config"),
      __mock__: Map.get(attrs, :__mock__)
    }
  end

  defp validate_provider_not_exists(chain_config, provider_id) do
    if Enum.any?(chain_config.providers, &(&1.id == provider_id)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp add_provider_to_chain(chain_config, provider_config) do
    %{chain_config | providers: chain_config.providers ++ [provider_config]}
  end

  defp remove_provider_from_chain(chain_config, provider_id) do
    updated_providers = Enum.reject(chain_config.providers, &(&1.id == provider_id))

    if length(updated_providers) == length(chain_config.providers) do
      {:error, :provider_not_found}
    else
      {:ok, %{chain_config | providers: updated_providers}}
    end
  end
end
