defmodule Lasso.Config.ConfigStore do
  @moduledoc """
  Profile-aware configuration store that caches chain and provider configurations
  in ETS tables for fast, hot-path access.

  ## Multi-Profile Architecture

  Profiles are the top-level isolation boundary. Each profile is keyed
  internally by an opaque `profile_id`. File-backed system profiles use their
  slug itself (for example, `"public"`). Scope is retained only for Backend
  compatibility and is always `:system` in OSS.

  The ETS table (owned by Application process) uses the following key
  structure:

  - `{:profile, profile_id, :meta}` -> Profile metadata
  - `{:profile, profile_id, :chains}` -> `%{chain_id :: pos_integer() => ChainConfig.t()}`
  - `{:resolve, scope, slug}` -> profile_id (resolution index — same table,
    same atomic swap, never observed independently)
  - `{:profile_list}` -> List of all profile_ids
  - `{:chain_profiles, chain_id}` -> List of profile_ids containing this chain
  - `{:all_chain_ids}` -> Union of all chain_ids (integers) across all profiles

  ## Configuration Backend

  Configuration is loaded via the Backend behaviour. The default is
  `Lasso.Config.Backend.File` which loads profiles from YAML files.
  """

  use GenServer
  require Logger

  alias Lasso.Config.Backend
  alias Lasso.Config.ChainConfig
  alias Lasso.Config.ChainConfig.Provider
  alias Lasso.Config.ConfigStore.Owner
  alias Lasso.Config.ProfileMeta

  @persistent_term_key :lasso_config_store_active
  @default_profile Lasso.Config.ProfileValidator.default_profile()

  # CONCURRENCY-2: how long the OLD ETS table sticks around after the
  # persistent_term swap. Any request that captured the old table
  # reference BEFORE the swap (via `table/0`) and then runs `:ets.lookup`
  # AFTER the delete fires raises ArgumentError; `safe_lookup/1`
  # silently rescues to `[]`, which downstream is "chain not found".
  #
  # The grace window must comfortably exceed the longest in-flight
  # `:ets.lookup` chain on the request path. Lookups are O(1), but
  # the time between `table/0` capture and the actual lookup includes
  # any work the request does in between (Plug pipeline, JSON-RPC parse,
  # provider selection iteration). Under load with bursts of reloads,
  # 2s left a measurable spurious-not-found tail.
  #
  # 30s is well past any realistic request lifecycle. The cost is
  # holding the old ETS table in memory for an extra 28s — bounded
  # by the reload rate and table size (current scale: ~80 instances
  # × ~100 profiles, sub-megabyte).
  @grace_period_ms 30_000
  @resolve_or_load_timeout_ms 5_000

  ## Types

  @type profile_id :: String.t()
  @type scope :: :system
  @type profile_meta :: ProfileMeta.t()

  defp table, do: :persistent_term.get(@persistent_term_key)

  ## Public API - Profile Operations

  @doc """
  Starts the ConfigStore GenServer.

  The GenServer manages configuration state but does NOT create the ETS table
  (that's owned by Application). Profile loading happens after supervision tree
  starts via `load_all_profiles/0`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads all profiles from the configured backend.

  This should be called AFTER the supervision tree is started to avoid
  circular dependencies. Returns the list of loaded profile_ids.
  """
  @spec load_all_profiles() :: {:ok, [profile_id()]} | {:error, term()}
  def load_all_profiles do
    GenServer.call(__MODULE__, :load_all_profiles, :infinity)
  end

  @doc """
  Lists all loaded profile_ids.

  For file-backed profiles `profile_id == slug`. Use
  `list_profile_summaries/1` for display data.
  """
  @spec list_profiles() :: [profile_id()]
  def list_profiles do
    case safe_lookup({:profile_list}) do
      [{{:profile_list}, profiles}] -> profiles
      _ -> []
    end
  end

  @doc """
  Resolves `(scope, slug)` to an opaque `profile_id`.

  This is the single resolution boundary: callers that hold a
  user-facing slug pair it with the request's scope here, then thread
  the returned `profile_id` through the rest of the system.
  """
  @spec resolve(scope(), String.t()) :: {:ok, profile_id()} | {:error, :not_found}
  def resolve(:system, slug) when is_binary(slug) do
    case safe_lookup({:resolve, :system, slug}) do
      [{{:resolve, :system, ^slug}, profile_id}] -> {:ok, profile_id}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Resolves a slug for an OSS request. The optional first argument is retained
  as a compatibility façade and is ignored because YAML profiles have one
  system scope.
  """
  @spec resolve_for_request(term(), String.t()) :: {:ok, profile_id()} | {:error, :not_found}
  def resolve_for_request(_context, slug) when is_binary(slug), do: resolve(:system, slug)

  @doc """
  Resolves `(scope, slug)` and loads it from the configured backend on a miss.

  `ConfigStore` is the runtime cache; the configured backend is authoritative
  for profiles that are not yet present in the local ETS table. This helper is
  intentionally scope-based so callers do not need to know how the file
  backend is configured.
  """
  @spec resolve_or_load(scope(), String.t()) ::
          {:ok, profile_id(), profile_meta()}
          | {:error, :not_found | {:load_failed, term()} | {:inject_failed, term()}}
  def resolve_or_load(:system, slug) when is_binary(slug) do
    case resolve_with_meta(:system, slug) do
      {:ok, _profile_id, _meta} = ok ->
        ok

      {:error, :not_found} ->
        timeout =
          Application.get_env(
            :lasso,
            :config_store_resolve_or_load_timeout_ms,
            @resolve_or_load_timeout_ms
          )

        try do
          GenServer.call(__MODULE__, {:resolve_or_load, :system, slug}, timeout)
        catch
          :exit, {:timeout, _} -> {:error, {:load_failed, :timeout}}
          :exit, reason -> {:error, {:load_failed, reason}}
        end
    end
  end

  @doc """
  Gets profile metadata by `profile_id`.
  """
  @spec get_profile(profile_id()) :: {:ok, profile_meta()} | {:error, :not_found}
  def get_profile(profile_id) do
    case safe_lookup({:profile, profile_id, :meta}) do
      [{{:profile, ^profile_id, :meta}, meta}] -> {:ok, meta}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Gets chain configuration for a specific `profile_id` and chain.

  Accepts either a `pos_integer()` chain_id (primary path) or a binary
  identifier (resolved via `lookup_chain_id_in_profile/2` for the
  rehydrate/migration window only).
  """
  @spec get_chain(profile_id(), pos_integer() | String.t()) ::
          {:ok, ChainConfig.t()} | {:error, :not_found}
  def get_chain(profile_id, chain_id)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    case safe_lookup({:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] ->
        case Map.get(chains, chain_id) do
          nil -> {:error, :not_found}
          chain_config -> {:ok, chain_config}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def get_chain(profile_id, chain_identifier)
      when is_binary(profile_id) and is_binary(chain_identifier) do
    case lookup_chain_id_in_profile(profile_id, chain_identifier) do
      {:ok, chain_id} -> get_chain(profile_id, chain_id)
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Resolves a chain slug or decimal string to a `chain_id` for a profile.

  Parses exact decimal chain IDs before matching aliases from the loaded profile
  configuration. Returns `{:ok, chain_id}` or `:not_found`.
  """
  @spec lookup_chain_id_in_profile(profile_id(), String.t()) ::
          {:ok, pos_integer()} | :not_found
  def lookup_chain_id_in_profile(profile_id, chain_identifier)
      when is_binary(profile_id) and is_binary(chain_identifier) do
    case safe_lookup({:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] ->
        resolve_chain_identifier(chains, chain_identifier)

      _ ->
        :not_found
    end
  end

  @doc """
  Returns true when the profile contains a chain with the given `chain_id`.
  """
  @spec profile_has_chain?(profile_id(), pos_integer()) :: boolean()
  def profile_has_chain?(profile_id, chain_id)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    case safe_lookup({:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] -> Map.has_key?(chains, chain_id)
      _ -> false
    end
  end

  defp resolve_chain_identifier(chains, identifier) do
    case Integer.parse(identifier) do
      {id, ""} when is_map_key(chains, id) ->
        {:ok, id}

      _ ->
        case Enum.find(chains, fn {_chain_id, cc} ->
               identifier in Map.get(cc, :url_aliases, [])
             end) do
          {chain_id, _cc} -> {:ok, chain_id}
          nil -> :not_found
        end
    end
  end

  @doc """
  Lists all profile IDs in the file-backed `:system` scope.
  """
  @spec list_profile_ids_for_scope(scope()) :: [profile_id()]
  def list_profile_ids_for_scope(:system) do
    scope = :system

    case table() do
      nil ->
        []

      t ->
        try do
          :ets.match(t, {{:resolve, scope, :"$1"}, :"$2"})
          |> Enum.map(fn [_slug, profile_id] -> profile_id end)
        rescue
          ArgumentError -> []
        end
    end
  end

  @doc """
  Returns display-ready profile summaries for the given scope.

  Each summary carries `profile_id` (machine identity) plus the
  user-facing `slug`, `name`, `logo`, and `unlisted` fields — sufficient
  for dashboards and selectors without forcing them to translate
  `profile_id` back to a slug.
  """
  @spec list_profile_summaries(scope()) :: [
          %{
            profile_id: profile_id(),
            slug: String.t(),
            name: String.t(),
            logo: String.t() | nil,
            unlisted: boolean()
          }
        ]
  def list_profile_summaries(:system) do
    scope = :system

    scope
    |> list_profile_ids_for_scope()
    |> Enum.flat_map(fn profile_id ->
      case get_profile(profile_id) do
        {:ok, meta} ->
          [
            %{
              profile_id: profile_id,
              slug: meta.slug,
              name: meta.name,
              logo: meta.logo,
              unlisted: meta.unlisted
            }
          ]

        {:error, :not_found} ->
          []
      end
    end)
  end

  @doc """
  Lists all chain_ids for a specific `profile_id`.
  """
  @spec list_chains_for_profile(profile_id()) :: [pos_integer()]
  def list_chains_for_profile(profile_id) do
    case safe_lookup({:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] -> Map.keys(chains)
      _ -> []
    end
  end

  @doc """
  Lists all chain_ids (union across all profiles).
  """
  @spec list_chain_ids() :: [pos_integer()]
  def list_chain_ids do
    case safe_lookup({:all_chain_ids}) do
      [{{:all_chain_ids}, chain_ids}] -> chain_ids
      _ -> []
    end
  end

  @doc "Compatibility alias for callers that predate integer chain runtime keys."
  @spec list_chains() :: [pos_integer()]
  def list_chains, do: list_chain_ids()

  @doc """
  Lists profile_ids that contain a specific chain.
  """
  @spec list_profiles_for_chain(pos_integer()) :: [profile_id()]
  def list_profiles_for_chain(chain_id) when is_integer(chain_id) and chain_id > 0 do
    case safe_lookup({:chain_profiles, chain_id}) do
      [{{:chain_profiles, ^chain_id}, profiles}] -> profiles
      _ -> []
    end
  end

  @doc """
  Gets all chains for a `profile_id` as a map keyed by `chain_id`.
  """
  @spec get_profile_chains(profile_id()) ::
          {:ok, %{pos_integer() => ChainConfig.t()}} | {:error, :not_found}
  def get_profile_chains(profile_id) do
    case safe_lookup({:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] -> {:ok, chains}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Gets all chains for the default profile as a map keyed by `chain_id`.

  Used for cross-profile operations like chain ID lookups.
  """
  @spec get_all_chains() :: %{pos_integer() => ChainConfig.t()}
  def get_all_chains do
    case get_profile_chains(@default_profile) do
      {:ok, chains} -> chains
      {:error, :not_found} -> %{}
    end
  end

  @doc """
  Gets provider configuration for a specific `profile_id`, chain, and provider.
  """
  @spec get_provider(profile_id(), pos_integer(), String.t()) ::
          {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(profile_id, chain_id, provider_id)
      when is_binary(profile_id) and is_integer(chain_id) and is_binary(provider_id) do
    with {:ok, chain_config} <- get_chain(profile_id, chain_id) do
      case Enum.find(chain_config.providers, &(&1.id == provider_id)) do
        nil -> {:error, :not_found}
        provider -> {:ok, provider}
      end
    end
  end

  @doc """
  Gets all providers for a specific `profile_id` and chain.
  """
  @spec get_providers(profile_id(), pos_integer()) :: {:ok, [Provider.t()]} | {:error, :not_found}
  def get_providers(profile_id, chain_id)
      when is_binary(profile_id) and is_integer(chain_id) do
    case get_chain(profile_id, chain_id) do
      {:ok, chain_config} -> {:ok, chain_config.providers}
      error -> error
    end
  end

  def get_providers(profile_id, chain_identifier)
      when is_binary(profile_id) and is_binary(chain_identifier) do
    case lookup_chain_id_in_profile(profile_id, chain_identifier) do
      {:ok, chain_id} -> get_providers(profile_id, chain_id)
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Gets all provider IDs for a `profile_id` and chain.
  """
  @spec get_provider_ids(profile_id(), pos_integer()) :: [String.t()]
  def get_provider_ids(profile_id, chain_id) when is_integer(chain_id) do
    case get_chain(profile_id, chain_id) do
      {:ok, chain_config} -> Enum.map(chain_config.providers, & &1.id)
      {:error, :not_found} -> []
    end
  end

  ## Public API - Runtime Registration (for tests)

  @doc """
  Registers a chain configuration in-memory for a `profile_id` (runtime only, not persisted).
  """
  @spec register_chain_runtime(profile_id(), pos_integer(), map()) :: :ok | {:error, term()}
  def register_chain_runtime(profile_id, chain_id, chain_attrs)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(__MODULE__, {:register_chain_runtime, profile_id, chain_id, chain_attrs})
  end

  def register_chain_runtime(profile_id, _legacy_alias, %{chain_id: chain_id} = chain_attrs)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    register_chain_runtime(profile_id, chain_id, chain_attrs)
  end

  @doc """
  Unregisters a chain from in-memory configuration for a `profile_id` (runtime only).
  """
  @spec unregister_chain_runtime(profile_id(), pos_integer()) :: :ok | {:error, term()}
  def unregister_chain_runtime(profile_id, chain_id)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(__MODULE__, {:unregister_chain_runtime, profile_id, chain_id})
  end

  def unregister_chain_runtime(profile_id, legacy_alias)
      when is_binary(profile_id) and is_binary(legacy_alias) do
    case lookup_chain_id_in_profile(profile_id, legacy_alias) do
      {:ok, chain_id} -> unregister_chain_runtime(profile_id, chain_id)
      :not_found -> {:error, :chain_not_found}
    end
  end

  @doc """
  Registers a provider configuration in-memory for a `profile_id` (runtime only).
  """
  @spec register_provider_runtime(profile_id(), pos_integer(), map()) :: :ok | {:error, term()}
  def register_provider_runtime(profile_id, chain_id, provider_attrs)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(
      __MODULE__,
      {:register_provider_runtime, profile_id, chain_id, provider_attrs}
    )
  end

  def register_provider_runtime(profile_id, legacy_alias, provider_attrs)
      when is_binary(profile_id) and is_binary(legacy_alias) do
    case lookup_chain_id_in_profile(profile_id, legacy_alias) do
      {:ok, chain_id} -> register_provider_runtime(profile_id, chain_id, provider_attrs)
      :not_found -> {:error, :chain_not_found}
    end
  end

  @doc """
  Unregisters a provider from in-memory configuration for a `profile_id` (runtime only).
  """
  @spec unregister_provider_runtime(profile_id(), pos_integer(), String.t()) ::
          :ok | {:error, term()}
  def unregister_provider_runtime(profile_id, chain_id, provider_id)
      when is_binary(profile_id) and is_integer(chain_id) and is_binary(provider_id) do
    GenServer.call(
      __MODULE__,
      {:unregister_provider_runtime, profile_id, chain_id, provider_id}
    )
  end

  def unregister_provider_runtime(profile_id, legacy_alias, provider_id)
      when is_binary(profile_id) and is_binary(legacy_alias) and is_binary(provider_id) do
    case lookup_chain_id_in_profile(profile_id, legacy_alias) do
      {:ok, chain_id} -> unregister_provider_runtime(profile_id, chain_id, provider_id)
      :not_found -> {:error, :chain_not_found}
    end
  end

  @doc """
  Reloads configuration from the configured backend.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload, :infinity)
  end

  @doc """
  Injects a single profile into ConfigStore with full infrastructure setup.

  Writes to ETS, rebuilds Catalog, starts InstanceSupervisors and
  ProbeCoordinators for the new profile. Used for immediate activation
  after a runtime configuration update.
  """
  @spec inject_profile(map()) :: :ok | {:error, term()}
  def inject_profile(profile_spec) do
    GenServer.call(__MODULE__, {:inject_profile, profile_spec}, :infinity)
  end

  @doc """
  Updates an existing profile in ConfigStore with targeted ETS update.

  Overwrites profile data, rebuilds indices for changed chains, and
  reconciles shared infrastructure (Catalog, InstanceSupervisors,
  ProbeCoordinators, BlockSync workers).
  """
  @spec update_profile(map()) :: :ok | {:error, term()}
  def update_profile(profile_spec) do
    GenServer.call(__MODULE__, {:update_profile, profile_spec}, :infinity)
  end

  @doc """
  Removes a profile from ConfigStore and tears down its infrastructure.

  Rebuilds Catalog before deleting ConfigStore entries so the routing
  layer stops seeing the profile's providers before the profile itself
  disappears from resolution.

  Takes `profile_id`. Callers that hold a slug must call `resolve/2`
  first.
  """
  @spec remove_profile(profile_id()) :: :ok | {:error, term()}
  def remove_profile(profile_id) when is_binary(profile_id) do
    GenServer.call(__MODULE__, {:remove_profile, profile_id}, :infinity)
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
    # Profile loading happens after init; this process only tracks retry state.
    {backend_module, backend_config} = parse_backend_opts(opts)

    state = %{
      backend_module: backend_module,
      backend_config: backend_config,
      backend_state: nil,
      last_loaded: nil,
      retry_interval_ms:
        retry_opt(opts, :retry_interval_ms, :config_store_retry_interval_ms, 30_000),
      retry_timer: nil,
      retry_task_ref: nil,
      retry_task_snapshot: nil,
      db_degraded: false,
      last_good_specs: snapshot_profile_specs()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:load_all_profiles, _from, state) do
    case do_load_all_profiles(state) do
      {:ok, profiles, new_state} ->
        {:reply, {:ok, profiles}, %{new_state | db_degraded: false}}

      {:degraded, profiles, new_state} ->
        Logger.warning("Initial configuration load was degraded; scheduling retry")

        {:reply, {:ok, profiles}, schedule_retry(%{new_state | db_degraded: true})}

      {:error, reason} ->
        # Keep retrying boot-time load errors.
        Logger.error("Initial load failed: #{inspect(reason)}; scheduling retry")
        {:reply, {:error, reason}, schedule_retry(%{state | db_degraded: true})}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    # Capture prior chain state so removed chains are reconciled correctly.
    old_pairs = collect_profile_chain_pairs()
    old_chain_ids = list_chain_ids()
    old_endpoints = snapshot_all_chain_endpoints()

    case do_load_all_profiles(state, preserve_current_ets_on_degraded?: true) do
      {:ok, profiles, new_state} ->
        Logger.info("Configuration reloaded successfully")
        rebuild_shared_infrastructure(old_chain_ids)
        sync_chain_supervisors(old_pairs)
        reconcile_transport_channels_all(old_endpoints)
        Enum.each(profiles, &broadcast_profile_updated/1)
        {:reply, :ok, %{new_state | db_degraded: false}}

      {:degraded, _profiles, new_state} ->
        # Keep serving the last good snapshot and retry in the background.
        Logger.warning("Skipping degraded reload; preserving cached profiles")

        {:reply, {:error, :degraded}, schedule_retry(%{new_state | db_degraded: true})}

      {:error, reason} ->
        Logger.error("Failed to reload configuration: #{inspect(reason)}")
        {:reply, {:error, reason}, schedule_retry(%{state | db_degraded: true})}
    end
  end

  @impl true
  def handle_call({:inject_profile, profile_spec}, _from, state) do
    reply = do_inject_profile(profile_spec)
    {:reply, reply, refresh_last_good_specs(state, reply)}
  end

  @impl true
  def handle_call({:resolve_or_load, scope, slug}, _from, state) do
    {reply, new_state} = do_resolve_or_load(scope, slug, state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:update_profile, profile_spec}, _from, state) do
    reply = do_update_profile(profile_spec)
    {:reply, reply, refresh_last_good_specs(state, reply)}
  end

  @impl true
  def handle_call({:remove_profile, profile_id}, _from, state) do
    reply = do_remove_profile(profile_id)
    {:reply, reply, refresh_last_good_specs(state, reply)}
  end

  @impl true
  def handle_call({:register_chain_runtime, profile_id, chain_id, chain_attrs}, _from, state) do
    case get_chain(profile_id, chain_id) do
      {:ok, _existing} ->
        {:reply, {:error, :already_exists}, state}

      {:error, :not_found} ->
        ensure_profile_in_list(profile_id)
        chain_config = normalize_chain_config(chain_id, chain_attrs)
        add_chain_to_profile(profile_id, chain_id, chain_config)
        Logger.debug("Registered chain #{chain_id} in profile #{profile_id} (runtime)")
        {:reply, :ok, refresh_last_good_specs(state, :ok)}
    end
  end

  @impl true
  def handle_call({:unregister_chain_runtime, profile_id, chain_id}, _from, state) do
    case get_chain(profile_id, chain_id) do
      {:ok, _chain_config} ->
        remove_chain_from_profile(profile_id, chain_id)
        maybe_remove_profile_from_list(profile_id)
        Logger.debug("Unregistered chain #{chain_id} from profile #{profile_id} (runtime)")
        {:reply, :ok, refresh_last_good_specs(state, :ok)}

      {:error, :not_found} ->
        {:reply, {:error, :chain_not_found}, state}
    end
  end

  @impl true
  def handle_call(
        {:register_provider_runtime, profile_id, chain_id, provider_attrs},
        _from,
        state
      ) do
    with {:ok, chain_config} <- get_chain(profile_id, chain_id),
         provider_config <- normalize_provider_config(provider_attrs),
         :ok <- validate_provider_not_exists(chain_config, provider_config.id) do
      updated_chain = add_provider_to_chain(chain_config, provider_config)
      update_chain_in_profile(profile_id, chain_id, updated_chain)

      Logger.debug(
        "Registered provider #{provider_config.id} for chain #{chain_id} in profile #{profile_id} (runtime)"
      )

      {:reply, :ok, refresh_last_good_specs(state, :ok)}
    else
      {:error, :not_found} -> {:reply, {:error, :chain_not_found}, state}
      {:error, :already_exists} -> {:reply, {:error, :already_exists}, state}
    end
  end

  @impl true
  def handle_call(
        {:unregister_provider_runtime, profile_id, chain_id, provider_id},
        _from,
        state
      ) do
    with {:ok, chain_config} <- get_chain(profile_id, chain_id),
         {:ok, updated_chain} <- remove_provider_from_chain(chain_config, provider_id) do
      update_chain_in_profile(profile_id, chain_id, updated_chain)

      Logger.debug(
        "Unregistered provider #{provider_id} from chain #{chain_id} in profile #{profile_id} (runtime)"
      )

      {:reply, :ok, refresh_last_good_specs(state, :ok)}
    else
      {:error, :not_found} -> {:reply, {:error, :chain_not_found}, state}
      {:error, :provider_not_found} -> {:reply, {:error, :provider_not_found}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    profiles = list_profiles()
    chain_ids = list_chain_ids()

    total_providers =
      profiles
      |> Enum.flat_map(fn profile_id ->
        list_chains_for_profile(profile_id)
        |> Enum.map(fn chain_id -> {profile_id, chain_id} end)
      end)
      |> Enum.map(fn {profile_id, chain_id} ->
        case get_chain(profile_id, chain_id) do
          {:ok, config} -> length(config.providers)
          _ -> 0
        end
      end)
      |> Enum.sum()

    status = %{
      profiles_loaded: length(profiles),
      chains_loaded: length(chain_ids),
      total_providers: total_providers,
      last_loaded: state.last_loaded,
      backend: state.backend_module
    }

    {:reply, status, state}
  end

  # Old ETS tables published via persistent_term are deleted from inside
  # the GenServer — `:ets.delete/1` requires the calling process to be
  # the table owner, which only this process is.
  @impl true
  def handle_info({:config_store_owner_restarted, _owner}, state) do
    case state.last_good_specs do
      specs when is_list(specs) ->
        populate_ets(specs)
        Logger.info("ConfigStore republished its last good snapshot after Owner restart")

      nil ->
        Logger.warning(
          "ConfigStore Owner restarted before a configuration snapshot was available"
        )
    end

    {:noreply, state}
  rescue
    e ->
      Logger.error("ConfigStore could not republish snapshot after Owner restart: #{inspect(e)}")
      {:noreply, state}
  end

  @impl true
  def handle_info({:delete_old_table, table}, state) do
    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  # Degraded-mode recovery runs backend load in a Task so the GenServer mailbox
  # stays responsive. Snapshot bounds removals to avoid evicting profiles that
  # were injected while the Task was running.
  @impl true
  def handle_info(:retry_eager_load, state) do
    state = %{state | retry_timer: nil}

    if state.retry_task_ref do
      # A prior retry task is still in flight; defer.
      Logger.debug("ConfigStore retry: prior retry task still running, re-scheduling")
      {:noreply, schedule_retry(state)}
    else
      case ensure_backend_initialized(state) do
        {:ok, backend_state} ->
          backend_module = state.backend_module

          task =
            Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
              backend_module.load_all(backend_state)
            end)

          snapshot = current_file_profile_ids()

          {:noreply,
           %{
             state
             | backend_state: backend_state,
               retry_task_ref: task.ref,
               retry_task_snapshot: snapshot
           }}

        {:error, reason} ->
          Logger.warning("ConfigStore retry: backend init failed, will retry: #{inspect(reason)}")
          {:noreply, schedule_retry(%{state | db_degraded: true})}
      end
    end
  end

  # Apply retry-task results as deltas against current ETS state.
  @impl true
  def handle_info({ref, result}, state) when ref == state.retry_task_ref do
    Process.demonitor(ref, [:flush])
    snapshot = state.retry_task_snapshot
    state = %{state | retry_task_ref: nil, retry_task_snapshot: nil}

    case result do
      {:ok, specs} ->
        Logger.info("ConfigStore: retry succeeded, exiting degraded mode")
        apply_retry_deltas(specs, snapshot)
        {:noreply, %{state | db_degraded: false, last_loaded: DateTime.utc_now()}}

      {:degraded, _specs} ->
        Logger.debug("ConfigStore: retry still degraded, will retry")
        {:noreply, schedule_retry(state)}

      {:error, reason} ->
        Logger.warning("ConfigStore retry: backend error, will retry: #{inspect(reason)}")
        {:noreply, schedule_retry(state)}
    end
  end

  # Retry task crashed before completing; re-arm timer.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when ref == state.retry_task_ref do
    Logger.warning("ConfigStore retry task crashed: #{inspect(reason)}")
    {:noreply, schedule_retry(%{state | retry_task_ref: nil, retry_task_snapshot: nil})}
  end

  ## Private Functions

  # Inject a profile end-to-end.
  defp do_resolve_or_load(scope, slug, state) do
    case resolve_with_meta(scope, slug) do
      {:ok, _profile_id, _meta} = ok ->
        {ok, state}

      {:error, :not_found} ->
        case ensure_backend_initialized(state) do
          {:ok, backend_state} ->
            state = %{state | backend_state: backend_state}

            reply =
              case safe_backend_load(state.backend_module, backend_state, scope, slug) do
                {:ok, profile_spec} ->
                  case do_inject_profile(profile_spec) do
                    :ok -> resolve_with_meta(scope, slug)
                    {:error, reason} -> {:error, {:inject_failed, normalize_failure(reason)}}
                  end

                {:error, :not_found} ->
                  {:error, :not_found}

                {:error, {:load_failed, reason}} ->
                  {:error, {:load_failed, reason}}

                {:error, reason} ->
                  {:error, {:load_failed, normalize_failure(reason)}}
              end

            {reply, state}

          {:error, reason} ->
            {{:error, {:load_failed, reason}}, state}
        end
    end
  end

  defp safe_backend_load(backend_module, backend_state, _scope, slug) do
    backend_module.load(backend_state, slug)
  rescue
    e -> {:error, {:load_failed, normalize_failure(e)}}
  catch
    kind, reason -> {:error, {:load_failed, {kind, normalize_failure(reason)}}}
  end

  defp normalize_failure(reason) when is_atom(reason), do: reason
  defp normalize_failure(reason) when is_binary(reason), do: reason

  defp normalize_failure(%{__struct__: module} = reason) do
    if is_exception(reason) do
      {module, Exception.message(reason)}
    else
      inspect(reason)
    end
  end

  defp normalize_failure(reason), do: inspect(reason)

  defp do_inject_profile(profile_spec) do
    with :ok <- validate_profile_spec(profile_spec) do
      do_inject_profile_validated(profile_spec)
    end
  end

  defp do_inject_profile_validated(profile_spec) do
    profile_id = profile_spec.profile_id

    Logger.info(
      "Injecting profile into ConfigStore",
      Lasso.Logging.profile_metadata(profile_spec)
    )

    store_profile(profile_spec)

    update_indices_for_inject(profile_spec)

    # Inject path uses post-mutation chain_ids.
    rebuild_shared_infrastructure(list_chain_ids())

    start_profile_chain_supervisors(profile_id)

    notify_inject()
    broadcast_profile_updated(profile_id)

    :ok
  rescue
    e ->
      Logger.error("Failed to inject profile: #{inspect(e)}")
      {:error, e}
  end

  defp do_update_profile(profile_spec) do
    with :ok <- validate_profile_spec(profile_spec) do
      do_update_profile_validated(profile_spec)
    end
  end

  defp do_update_profile_validated(profile_spec) do
    profile_id = profile_spec.profile_id

    case get_profile(profile_id) do
      {:error, :not_found} ->
        {:error, :profile_not_found}

      {:ok, old_meta} ->
        Logger.info(
          "Updating profile in ConfigStore",
          Lasso.Logging.profile_metadata(profile_spec)
        )

        old_pairs = collect_profile_chain_pairs()
        old_chain_ids = list_chain_ids()
        old_profile_chains = list_chains_for_profile(profile_id)
        old_chain_configs = snapshot_profile_chain_configs(profile_id, old_profile_chains)

        store_profile(profile_spec)
        delete_stale_resolve_entry(old_meta, profile_spec)
        rebuild_indices_for_profile(profile_id, old_profile_chains, profile_spec)
        rebuild_shared_infrastructure(old_chain_ids)
        sync_chain_supervisors(old_pairs)
        reconcile_transport_channels(profile_id, old_chain_configs, profile_spec)
        notify_inject()
        broadcast_profile_updated(profile_id)

        :ok
    end
  rescue
    e ->
      Logger.error("Failed to update profile: #{inspect(e)}")
      {:error, e}
  end

  defp do_remove_profile(profile_id) do
    case get_profile(profile_id) do
      {:error, :not_found} ->
        {:error, :profile_not_found}

      {:ok, meta} ->
        Logger.info(
          "Removing profile from ConfigStore",
          Lasso.Logging.profile_metadata(meta)
        )

        old_pairs = collect_profile_chain_pairs()
        old_chain_ids = list_chain_ids()

        publish_profile_removal(profile_id, meta)

        rebuild_shared_infrastructure(old_chain_ids)
        sync_chain_supervisors(old_pairs)
        notify_inject()
        broadcast_profile_updated(profile_id)

        :ok
    end
  rescue
    e ->
      Logger.error("Failed to remove profile: #{inspect(e)}")
      {:error, e}
  end

  # Schedule eager-load retry and spread retries across nodes with jitter.
  defp schedule_retry(%{retry_timer: prior, retry_interval_ms: ms} = state) do
    if prior, do: Process.cancel_timer(prior)
    delay = ms + jitter(ms)
    timer = Process.send_after(self(), :retry_eager_load, delay)
    %{state | retry_timer: timer}
  end

  defp jitter(ms) do
    span = max(div(ms, 7), 1)
    :rand.uniform(2 * span) - span
  end

  # Apply a completed retry as deltas. Snapshot bounds removals so runtime
  # updates made while the backend read was running are preserved.
  defp apply_retry_deltas(loaded_specs, spawn_snapshot) do
    spawn_snapshot = spawn_snapshot || MapSet.new()
    loaded_by_id = Map.new(loaded_specs, &{&1.profile_id, &1})
    loaded_ids = MapSet.new(Map.keys(loaded_by_id))

    current_ids = current_file_profile_ids()

    to_remove =
      spawn_snapshot
      |> MapSet.intersection(current_ids)
      |> MapSet.difference(loaded_ids)

    old_pairs = collect_profile_chain_pairs()
    old_chain_ids = list_chain_ids()

    changed_profile_ids =
      Enum.flat_map(loaded_specs, fn spec ->
        result =
          if MapSet.member?(current_ids, spec.profile_id) do
            do_update_profile_without_rebuild(spec)
          else
            do_inject_profile_without_rebuild(spec)
          end

        case result do
          :ok -> [spec.profile_id]
          _ -> []
        end
      end)

    removed_profile_ids =
      Enum.flat_map(to_remove, fn profile_id ->
        case do_remove_profile_without_rebuild(profile_id) do
          :ok -> [profile_id]
          _ -> []
        end
      end)

    changed_ids = changed_profile_ids ++ removed_profile_ids

    if changed_ids != [] do
      rebuild_shared_infrastructure(old_chain_ids)
      sync_chain_supervisors(old_pairs)
      notify_inject()
      Enum.each(changed_ids, &broadcast_profile_updated/1)
    end

    :ok
  end

  defp do_inject_profile_without_rebuild(profile_spec) do
    Logger.info(
      "Injecting profile into ConfigStore",
      Lasso.Logging.profile_metadata(profile_spec)
    )

    store_profile(profile_spec)
    update_indices_for_inject(profile_spec)

    :ok
  rescue
    e ->
      Logger.error("Failed to inject profile: #{inspect(e)}")
      {:error, e}
  end

  defp do_update_profile_without_rebuild(profile_spec) do
    profile_id = profile_spec.profile_id

    case get_profile(profile_id) do
      {:error, :not_found} ->
        {:error, :profile_not_found}

      {:ok, old_meta} ->
        Logger.info(
          "Updating profile in ConfigStore",
          Lasso.Logging.profile_metadata(profile_spec)
        )

        old_profile_chains = list_chains_for_profile(profile_id)

        store_profile(profile_spec)
        delete_stale_resolve_entry(old_meta, profile_spec)
        rebuild_indices_for_profile(profile_id, old_profile_chains, profile_spec)

        :ok
    end
  rescue
    e ->
      Logger.error("Failed to update profile: #{inspect(e)}")
      {:error, e}
  end

  defp do_remove_profile_without_rebuild(profile_id) do
    case get_profile(profile_id) do
      {:error, :not_found} ->
        {:error, :profile_not_found}

      {:ok, meta} ->
        Logger.info(
          "Removing profile from ConfigStore",
          Lasso.Logging.profile_metadata(meta)
        )

        publish_profile_removal(profile_id, meta)

        :ok
    end
  rescue
    e ->
      Logger.error("Failed to remove profile: #{inspect(e)}")
      {:error, e}
  end

  # Set of file-backed profile IDs currently in ETS.
  defp current_file_profile_ids, do: list_profiles() |> MapSet.new()

  # Resolution order: keyword option -> app env -> default.
  defp retry_opt(opts, key, app_key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:lasso, app_key, default)
    end
  end

  defp parse_backend_opts(opts) when is_binary(opts) do
    # Legacy: single path string means use file backend
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

  defp do_load_all_profiles(state, opts \\ []) do
    preserve_current_ets_on_degraded? =
      Keyword.get(opts, :preserve_current_ets_on_degraded?, false)

    with {:ok, backend_state} <- ensure_backend_initialized(state) do
      case safe_backend_load_all(state.backend_module, backend_state) do
        {:ok, specs} ->
          finalize_validated_load(specs, state, backend_state, :ok)

        {:degraded, _specs} when preserve_current_ets_on_degraded? ->
          {:degraded, list_profiles(), %{state | backend_state: backend_state}}

        {:degraded, specs} ->
          finalize_validated_load(specs, state, backend_state, :degraded)

        {:error, _} = error ->
          error
      end
    end
  end

  defp finalize_validated_load(profile_specs, state, backend_state, result) do
    case validate_profile_specs(profile_specs) do
      :ok ->
        {profile_ids, new_state} = finalize_load(profile_specs, state, backend_state)
        {result, profile_ids, new_state}

      {:error, _} = error ->
        error
    end
  end

  defp finalize_load(profile_specs, state, backend_state) do
    populate_ets(profile_specs)

    new_state = %{
      state
      | backend_state: backend_state,
        last_loaded: DateTime.utc_now(),
        last_good_specs: profile_specs
    }

    profile_ids = Enum.map(profile_specs, & &1.profile_id)
    Logger.info("Loaded #{length(profile_ids)} profiles: #{Enum.join(profile_ids, ", ")}")

    {profile_ids, new_state}
  end

  defp validate_profile_specs(profile_specs) when is_list(profile_specs) do
    with :ok <- validate_unique_profile_ids(profile_specs) do
      Enum.reduce_while(profile_specs, :ok, fn spec, :ok ->
        case validate_profile_spec(spec) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_profile_specs(_), do: {:error, :invalid_profile_specs}

  defp validate_unique_profile_ids(profile_specs) do
    ids = Enum.map(profile_specs, &Map.get(&1, :profile_id))

    if Enum.all?(ids, &is_binary/1) and length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :invalid_or_duplicate_profile_id}
    end
  end

  defp validate_profile_spec(%{
         scope: :system,
         profile_id: profile_id,
         slug: slug,
         chains: chains
       })
       when is_binary(profile_id) and is_binary(slug) and is_map(chains) do
    ids = Enum.map(chains, fn {_name, chain} -> Map.get(chain, :chain_id) end)

    cond do
      not Enum.all?(ids, &(is_integer(&1) and &1 > 0)) ->
        {:error, :invalid_chain_id}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_chain_id}

      true ->
        validate_chain_aliases(chains, MapSet.new(ids))
    end
  end

  defp validate_profile_spec(_), do: {:error, :invalid_profile_spec}

  defp validate_chain_aliases(chains, chain_ids) do
    aliases =
      for {chain_name, chain} <- chains,
          alias_name <- Map.get(chain, :url_aliases, [chain_name]),
          do: {Map.get(chain, :chain_id), alias_name}

    with :ok <- validate_alias_values(aliases),
         :ok <- validate_unique_aliases(aliases) do
      validate_decimal_alias_collisions(aliases, chain_ids)
    end
  end

  defp validate_alias_values(aliases) do
    case Enum.find(aliases, fn {_chain_id, alias_name} ->
           not (is_binary(alias_name) and String.trim(alias_name) != "")
         end) do
      nil -> :ok
      {chain_id, alias_name} -> {:error, {:invalid_chain_alias, chain_id, alias_name}}
    end
  end

  defp validate_unique_aliases(aliases) do
    case aliases
         |> Enum.group_by(fn {_chain_id, alias_name} -> alias_name end)
         |> Enum.find(fn {_alias_name, values} -> length(values) > 1 end) do
      nil -> :ok
      {alias_name, _values} -> {:error, {:duplicate_chain_alias, alias_name}}
    end
  end

  defp validate_decimal_alias_collisions(aliases, chain_ids) do
    case Enum.find(aliases, fn {chain_id, alias_name} ->
           case Integer.parse(alias_name) do
             {decimal_id, ""} -> decimal_id != chain_id and MapSet.member?(chain_ids, decimal_id)
             _ -> false
           end
         end) do
      nil ->
        :ok

      {chain_id, alias_name} ->
        {:error, {:chain_alias_collides_with_chain_id, chain_id, alias_name}}
    end
  end

  defp safe_backend_load_all(backend_module, backend_state) do
    backend_module.load_all(backend_state)
  rescue
    e -> {:error, {:load_failed, normalize_failure(e)}}
  catch
    kind, reason -> {:error, {:load_failed, {kind, normalize_failure(reason)}}}
  end

  defp ensure_backend_initialized(%{backend_state: nil} = state) do
    state.backend_module.init(state.backend_config)
  end

  defp ensure_backend_initialized(%{backend_state: backend_state}) do
    {:ok, backend_state}
  end

  defp populate_ets(profile_specs) do
    new_table =
      :ets.new(:lasso_config_store, [
        :public,
        :set,
        {:heir, Process.whereis(Owner), :config_store},
        read_concurrency: true
      ])

    Enum.each(profile_specs, fn spec ->
      store_profile(spec, new_table)
    end)

    build_indices(profile_specs, new_table)

    old_table = :persistent_term.get(@persistent_term_key, nil)
    :persistent_term.put(@persistent_term_key, new_table)

    if old_table do
      Owner.schedule_delete(old_table, @grace_period_ms)
    end
  end

  defp safe_lookup(key) do
    :ets.lookup(table(), key)
  rescue
    ArgumentError -> []
  end

  defp snapshot_profile_specs do
    for profile_id <- list_profiles(),
        {:ok, meta} = get_profile(profile_id),
        {:ok, chains} = get_profile_chains(profile_id),
        into: [] do
      %{
        scope: :system,
        profile_id: meta.profile_id,
        slug: meta.slug,
        name: meta.name,
        logo: meta.logo,
        rps_limit: meta.rps_limit,
        burst_limit: meta.burst_limit,
        unlisted: meta.unlisted,
        chains:
          Map.new(chains, fn {chain_id, chain} ->
            {chain.display_name || Integer.to_string(chain_id), chain}
          end)
      }
    end
  rescue
    ArgumentError -> nil
  end

  defp refresh_last_good_specs(state, :ok),
    do: %{state | last_good_specs: snapshot_profile_specs()}

  defp refresh_last_good_specs(state, _reply), do: state

  defp resolve_with_meta(scope, slug) do
    with {:ok, profile_id} <- resolve(scope, slug),
         {:ok, meta} <- get_profile(profile_id) do
      {:ok, profile_id, meta}
    end
  end

  defp store_profile(spec), do: publish_profile_upsert(spec)

  defp publish_profile_upsert(spec) do
    old_table = table()

    new_table =
      :ets.new(:lasso_config_store, [
        :public,
        :set,
        {:heir, Process.whereis(Owner), :config_store},
        read_concurrency: true
      ])

    old_table
    |> :ets.tab2list()
    |> Enum.reject(fn
      {{:profile, profile_id, :meta}, _} -> profile_id == spec.profile_id
      {{:profile, profile_id, :chains}, _} -> profile_id == spec.profile_id
      {{:resolve, _scope, _slug}, profile_id} -> profile_id == spec.profile_id
      {{:profile_list}, _} -> true
      {{:chain_profiles, _chain_id}, _} -> true
      {{:all_chain_ids}, _} -> true
      _ -> false
    end)
    |> then(&:ets.insert(new_table, &1))

    store_profile(spec, new_table)
    rebuild_indices_from_table(new_table)

    :persistent_term.put(@persistent_term_key, new_table)
    Owner.schedule_delete(old_table, @grace_period_ms)

    :ok
  end

  defp store_profile(spec, t) do
    meta = %ProfileMeta{
      profile_id: spec.profile_id,
      scope: spec.scope,
      slug: spec.slug,
      name: spec.name,
      logo: Map.get(spec, :logo),
      rps_limit: spec.rps_limit,
      burst_limit: spec.burst_limit,
      unlisted: Map.get(spec, :unlisted, false)
    }

    # Profile validation runs before every publication, so this conversion
    # cannot silently drop an invalid chain or overwrite a duplicate ID.
    :ok = validate_profile_spec(spec)

    integer_chains = Map.new(spec.chains, fn {_chain_name, cc} -> {cc.chain_id, cc} end)

    # The three rows for one profile are inserted as a single :ets.insert/2
    # call with a list — :ets.insert/2 is atomic on a :set table, so a
    # concurrent reader cannot observe meta+chains without the resolution
    # index entry (the partial-snapshot case the redesign forbids).
    # Resolution index lives in the same table as the profile data so an
    # atomic-swap reload (populate_ets) never exposes one without the other.
    :ets.insert(t, [
      {{:profile, spec.profile_id, :meta}, meta},
      {{:profile, spec.profile_id, :chains}, integer_chains},
      {{:resolve, spec.scope, spec.slug}, spec.profile_id}
    ])
  end

  # When `update_profile` reshapes a profile under a new scope or slug,
  # `store_profile/2` writes the new `{:resolve, scope, slug}` entry but
  # leaves the prior one pointing at the same `profile_id`. That stale
  # entry would let `resolve(old_scope, old_slug)` keep returning the
  # profile after rename. Drop it.
  defp publish_profile_removal(profile_id, %ProfileMeta{} = meta) do
    old_table = table()

    new_table =
      :ets.new(:lasso_config_store, [
        :public,
        :set,
        {:heir, Process.whereis(Owner), :config_store},
        read_concurrency: true
      ])

    retained_rows =
      old_table
      |> :ets.tab2list()
      |> Enum.reject(fn
        {{:profile, ^profile_id, :meta}, _} -> true
        {{:profile, ^profile_id, :chains}, _} -> true
        {{:resolve, scope, slug}, ^profile_id} -> scope == meta.scope and slug == meta.slug
        {{:profile_list}, _} -> true
        {{:chain_profiles, _chain_id}, _} -> true
        {{:all_chain_ids}, _} -> true
        _ -> false
      end)

    :ets.insert(new_table, retained_rows)
    rebuild_indices_from_table(new_table)

    :persistent_term.put(@persistent_term_key, new_table)
    Owner.schedule_delete(old_table, @grace_period_ms)

    :ok
  end

  defp rebuild_indices_from_table(t) do
    profile_ids =
      t
      |> :ets.match({{:profile, :"$1", :meta}, :"$2"})
      |> Enum.map(fn [profile_id, _meta] -> profile_id end)

    :ets.insert(t, {{:profile_list}, profile_ids})

    chain_profiles_map =
      t
      |> :ets.match({{:profile, :"$1", :chains}, :"$2"})
      |> Enum.reduce(%{}, fn [profile_id, chains], acc ->
        Enum.reduce(Map.keys(chains), acc, fn chain_id, inner_acc ->
          Map.update(inner_acc, chain_id, [profile_id], &[profile_id | &1])
        end)
      end)

    all_chain_ids = Map.keys(chain_profiles_map)
    :ets.insert(t, {{:all_chain_ids}, all_chain_ids})

    Enum.each(chain_profiles_map, fn {chain_id, profile_ids} ->
      :ets.insert(t, {{:chain_profiles, chain_id}, Enum.uniq(profile_ids)})
    end)
  end

  defp delete_stale_resolve_entry(%ProfileMeta{}, _new_spec), do: :ok

  defp build_indices(profile_specs, t) do
    profile_ids = Enum.map(profile_specs, & &1.profile_id)
    :ets.insert(t, {{:profile_list}, profile_ids})

    # Chains are already integer-keyed after store_profile converts them.
    # Read back the integer-keyed chains from ETS to build the indices.
    chain_profiles_map =
      profile_ids
      |> Enum.flat_map(fn profile_id ->
        case :ets.lookup(t, {:profile, profile_id, :chains}) do
          [{{:profile, ^profile_id, :chains}, chains}] ->
            Enum.map(Map.keys(chains), fn chain_id -> {chain_id, profile_id} end)

          _ ->
            []
        end
      end)
      |> Enum.group_by(fn {chain_id, _} -> chain_id end, fn {_, pid} -> pid end)

    all_chain_ids = Map.keys(chain_profiles_map)
    :ets.insert(t, {{:all_chain_ids}, all_chain_ids})

    Enum.each(chain_profiles_map, fn {chain_id, pids} ->
      :ets.insert(t, {{:chain_profiles, chain_id}, pids})
    end)
  end

  defp ensure_profile_in_list(profile_id) do
    current = list_profiles()

    rows =
      if match?({:error, :not_found}, get_profile(profile_id)) do
        meta = %ProfileMeta{
          profile_id: profile_id,
          scope: :system,
          slug: profile_id,
          name: profile_id,
          rps_limit: 100,
          burst_limit: 500,
          unlisted: false
        }

        [
          {{:profile, profile_id, :meta}, meta},
          {{:resolve, :system, profile_id}, profile_id}
        ]
      else
        []
      end

    rows =
      if profile_id in current do
        rows
      else
        [{{:profile_list}, [profile_id | current]} | rows]
      end

    if rows != [], do: :ets.insert(table(), rows)
  end

  defp maybe_remove_profile_from_list(profile_id) do
    remaining_chains = list_chains_for_profile(profile_id)

    if remaining_chains == [] do
      current = list_profiles()
      :ets.insert(table(), {{:profile_list}, List.delete(current, profile_id)})
    end
  end

  defp add_chain_to_profile(profile_id, chain_id, chain_config) do
    chains =
      case :ets.lookup(table(), {:profile, profile_id, :chains}) do
        [{{:profile, ^profile_id, :chains}, existing}] -> existing
        [] -> %{}
      end

    updated_chains = Map.put(chains, chain_id, chain_config)
    :ets.insert(table(), {{:profile, profile_id, :chains}, updated_chains})

    update_indices_for_chain_add(profile_id, chain_id)
  end

  defp remove_chain_from_profile(profile_id, chain_id) do
    case :ets.lookup(table(), {:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] ->
        updated_chains = Map.delete(chains, chain_id)
        :ets.insert(table(), {{:profile, profile_id, :chains}, updated_chains})
        update_indices_for_chain_remove(profile_id, chain_id)

      [] ->
        :ok
    end
  end

  defp update_chain_in_profile(profile_id, chain_id, chain_config) do
    case :ets.lookup(table(), {:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] ->
        updated_chains = Map.put(chains, chain_id, chain_config)
        :ets.insert(table(), {{:profile, profile_id, :chains}, updated_chains})

      [] ->
        :ok
    end
  end

  defp update_chain_profiles_index(chain_id, profile_id) do
    current =
      case :ets.lookup(table(), {:chain_profiles, chain_id}) do
        [{{:chain_profiles, ^chain_id}, profiles}] -> profiles
        [] -> []
      end

    if profile_id not in current do
      :ets.insert(table(), {{:chain_profiles, chain_id}, [profile_id | current]})
    end
  end

  defp update_all_chain_ids_index(chain_id) do
    current =
      case :ets.lookup(table(), {:all_chain_ids}) do
        [{{:all_chain_ids}, ids}] -> ids
        [] -> []
      end

    if chain_id not in current do
      :ets.insert(table(), {{:all_chain_ids}, [chain_id | current]})
    end
  end

  defp update_indices_for_chain_add(profile_id, chain_id) do
    update_chain_profiles_index(chain_id, profile_id)
    update_all_chain_ids_index(chain_id)
  end

  defp update_indices_for_chain_remove(profile_id, chain_id) do
    remove_profile_from_chain_profiles(chain_id, profile_id)
    maybe_remove_chain_from_all_chain_ids(chain_id)
  end

  defp remove_profile_from_chain_profiles(chain_id, profile_id) do
    case :ets.lookup(table(), {:chain_profiles, chain_id}) do
      [{{:chain_profiles, ^chain_id}, profiles}] ->
        updated = List.delete(profiles, profile_id)

        if updated == [] do
          :ets.delete(table(), {:chain_profiles, chain_id})
        else
          :ets.insert(table(), {{:chain_profiles, chain_id}, updated})
        end

      [] ->
        :ok
    end
  end

  defp maybe_remove_chain_from_all_chain_ids(chain_id) do
    has_chain =
      :ets.match(table(), {{:profile, :"$1", :chains}, :"$2"})
      |> Enum.any?(fn [_, chains] -> Map.has_key?(chains, chain_id) end)

    if not has_chain do
      case :ets.lookup(table(), {:all_chain_ids}) do
        [{{:all_chain_ids}, ids}] ->
          :ets.insert(table(), {{:all_chain_ids}, List.delete(ids, chain_id)})

        [] ->
          :ok
      end
    end
  end

  # Profile publication rebuilds all indices in the unpublished snapshot.
  defp update_indices_for_inject(_spec), do: :ok

  defp notify_inject do
    case Application.get_env(:lasso, :profile_inject_listener) do
      nil -> :ok
      mod -> mod.record_inject()
    end
  end

  defp broadcast_profile_updated(profile_id) do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      Lasso.Topics.config_profile_updated(profile_id),
      {:profile_config_updated, profile_id}
    )
  rescue
    _ -> :ok
  end

  # Normalization helpers

  defp normalize_chain_config(chain_id, attrs) when is_integer(chain_id) and is_map(attrs) do
    websocket_attrs = Map.get(attrs, :websocket) || Map.get(attrs, "websocket") || %{}
    selection_attrs = Map.get(attrs, :selection) || Map.get(attrs, "selection")
    monitoring_attrs = Map.get(attrs, :monitoring) || Map.get(attrs, "monitoring") || %{}
    providers_attrs = Map.get(attrs, :providers) || Map.get(attrs, "providers") || []

    %ChainConfig{
      chain_id: chain_id,
      display_name:
        Map.get(attrs, :display_name) || Map.get(attrs, "display_name") ||
          Map.get(attrs, :name) || Map.get(attrs, "name"),
      url_aliases:
        attrs
        |> Map.get(:url_aliases, Map.get(attrs, "url_aliases"))
        |> normalize_url_aliases(Map.get(attrs, :name) || Map.get(attrs, "name")),
      providers: Enum.map(providers_attrs, &normalize_provider_config/1),
      websocket: normalize_websocket_config(websocket_attrs),
      selection: normalize_selection_config(selection_attrs),
      monitoring: normalize_monitoring_config(monitoring_attrs)
    }
  end

  defp normalize_url_aliases(aliases, _fallback) when is_list(aliases) do
    Enum.filter(aliases, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp normalize_url_aliases(_aliases, fallback) when is_binary(fallback), do: [fallback]
  defp normalize_url_aliases(_aliases, _fallback), do: []

  defp normalize_websocket_config(attrs) when is_map(attrs) do
    failover_attrs = Map.get(attrs, :failover) || Map.get(attrs, "failover") || %{}

    %ChainConfig.Websocket{
      subscribe_new_heads:
        Map.get(attrs, :subscribe_new_heads) || Map.get(attrs, "subscribe_new_heads") || true,
      new_heads_timeout_ms:
        Map.get(attrs, :new_heads_timeout_ms) || Map.get(attrs, "new_heads_timeout_ms") ||
          42_000,
      failover: normalize_websocket_failover_config(failover_attrs)
    }
  end

  defp normalize_websocket_failover_config(attrs) when is_map(attrs) do
    %ChainConfig.WebsocketFailover{
      max_backfill_blocks:
        Map.get(attrs, :max_backfill_blocks) || Map.get(attrs, "max_backfill_blocks") || 100,
      backfill_timeout_ms:
        Map.get(attrs, :backfill_timeout_ms) || Map.get(attrs, "backfill_timeout_ms") || 30_000
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
        Map.get(attrs, :probe_interval_ms) || Map.get(attrs, "probe_interval_ms") || 15_000,
      lag_alert_threshold_blocks:
        Map.get(attrs, :lag_alert_threshold_blocks) ||
          Map.get(attrs, "lag_alert_threshold_blocks") ||
          Map.get(attrs, :lag_threshold_blocks) || Map.get(attrs, "lag_threshold_blocks") || 3
    }
  end

  defp normalize_provider_config(attrs) when is_map(attrs) do
    sharing_mode =
      case Map.get(attrs, :sharing_mode) || Map.get(attrs, "sharing_mode") do
        :isolated -> :isolated
        "isolated" -> :isolated
        _ -> :auto
      end

    archival =
      case Map.get(attrs, :archival, Map.get(attrs, "archival")) do
        nil -> true
        val -> val
      end

    %Provider{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      url: Map.get(attrs, :url) || Map.get(attrs, "url"),
      ws_url: Map.get(attrs, :ws_url) || Map.get(attrs, "ws_url"),
      priority: Map.get(attrs, :priority) || Map.get(attrs, "priority") || 100,
      capabilities: Map.get(attrs, :capabilities) || Map.get(attrs, "capabilities"),
      archival: archival,
      subscribe_new_heads:
        Map.get(attrs, :subscribe_new_heads, Map.get(attrs, "subscribe_new_heads")),
      sharing_mode: sharing_mode,
      api_key: Map.get(attrs, :api_key) || Map.get(attrs, "api_key"),
      credentials: Map.get(attrs, :credentials) || Map.get(attrs, "credentials"),
      headers: Map.get(attrs, :headers) || Map.get(attrs, "headers"),
      auth_headers: Map.get(attrs, :auth_headers) || Map.get(attrs, "auth_headers"),
      __mock__: Map.get(attrs, :__mock__)
    }
  end

  defp start_profile_chain_supervisors(profile_id) do
    chain_ids = list_chains_for_profile(profile_id)

    for chain_id <- chain_ids do
      case get_chain(profile_id, chain_id) do
        {:ok, chain_config} ->
          Lasso.ProfileChainSupervisor.start_profile_chain(
            profile_id,
            chain_id,
            chain_config
          )

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("Failed to start chain supervisors for #{profile_id}: #{inspect(e)}")
  end

  defp collect_profile_chain_pairs do
    for profile_id <- list_profiles(),
        chain_id <- list_chains_for_profile(profile_id),
        do: {profile_id, chain_id}
  end

  defp sync_chain_supervisors(old_pairs) do
    new_pairs = collect_profile_chain_pairs()

    for {profile_id, chain_id} <- new_pairs -- old_pairs do
      case get_chain(profile_id, chain_id) do
        {:ok, config} ->
          Lasso.ProfileChainSupervisor.start_profile_chain(profile_id, chain_id, config)

        _ ->
          :ok
      end
    end

    for {profile_id, chain_id} <- old_pairs -- new_pairs do
      Lasso.ProfileChainSupervisor.stop_profile_chain(profile_id, chain_id)
    end
  rescue
    e ->
      Logger.warning("Failed to sync chain supervisors on reload: #{inspect(e)}")
  end

  defp snapshot_profile_chain_configs(profile_id, chain_ids) do
    Map.new(chain_ids, fn chain_id ->
      {chain_id, chain_provider_endpoints(profile_id, chain_id)}
    end)
  end

  defp reconcile_transport_channels(profile_id, old_chain_configs, profile_spec) do
    new_chain_ids = Map.keys(profile_spec.chains || %{})
    chain_ids = MapSet.union(MapSet.new(Map.keys(old_chain_configs)), MapSet.new(new_chain_ids))

    Enum.each(chain_ids, fn chain_id ->
      old_providers = Map.get(old_chain_configs, chain_id, %{})
      new_providers = chain_provider_endpoints(profile_id, chain_id)
      reset_changed_provider_channels(profile_id, chain_id, old_providers, new_providers)
    end)
  end

  # Reconciles transport channels for every (profile, chain) after a cluster
  # reload. Remote nodes apply config changes via reload/0 rather than
  # update_profile/1, so without this they keep serving from channels that
  # cache a now-stale endpoint URL.
  defp reconcile_transport_channels_all(old_endpoints) do
    new_pairs = collect_profile_chain_pairs()

    pairs =
      MapSet.union(MapSet.new(Map.keys(old_endpoints)), MapSet.new(new_pairs))

    Enum.each(pairs, fn {profile_id, chain_id} ->
      old_providers = Map.get(old_endpoints, {profile_id, chain_id}, %{})
      new_providers = chain_provider_endpoints(profile_id, chain_id)
      reset_changed_provider_channels(profile_id, chain_id, old_providers, new_providers)
    end)
  end

  # Closes transport channels for providers whose endpoint changed or that were
  # removed. Channels are keyed by provider_id and cache the URL captured at
  # creation, so an endpoint change under the same id leaves a stale channel
  # until it is explicitly closed. HTTP channels are recreated lazily from fresh
  # config on the next request; WS channels are recreated on the next
  # ws_connected event once the rebuilt instance reconnects. Only the affected
  # provider is touched, so unrelated traffic and live subscriptions on the same
  # chain keep running.
  defp reset_changed_provider_channels(profile_id, chain_id, old_providers, new_providers) do
    removed_provider_ids = Map.keys(old_providers) -- Map.keys(new_providers)

    changed_provider_ids =
      Enum.flat_map(new_providers, fn {provider_id, new_endpoints} ->
        case Map.fetch(old_providers, provider_id) do
          {:ok, old_endpoints} when old_endpoints != new_endpoints -> [provider_id]
          _ -> []
        end
      end)

    Enum.uniq(removed_provider_ids ++ changed_provider_ids)
    |> Enum.each(fn provider_id ->
      Lasso.RPC.TransportRegistry.close_channel_sync(profile_id, chain_id, provider_id, :http)
      Lasso.RPC.TransportRegistry.close_channel_sync(profile_id, chain_id, provider_id, :ws)
    end)
  end

  defp snapshot_all_chain_endpoints do
    Enum.reduce(collect_profile_chain_pairs(), %{}, fn {profile_id, chain_id}, acc ->
      Map.put(acc, {profile_id, chain_id}, chain_provider_endpoints(profile_id, chain_id))
    end)
  end

  defp chain_provider_endpoints(profile_id, chain_id) do
    case get_chain(profile_id, chain_id) do
      {:ok, %{providers: providers}} when is_list(providers) ->
        Map.new(providers, fn provider ->
          {provider.id, %{url: provider.url, ws_url: provider.ws_url}}
        end)

      _ ->
        %{}
    end
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

  # `publish_profile_upsert/1` atomically publishes the complete rebuilt index.
  defp rebuild_indices_for_profile(_profile_id, _old_chain_ids, _profile_spec), do: :ok

  # Reconciles Catalog + InstanceSupervisors + ProbeCoordinators + BlockSync
  # workers against current ConfigStore state.
  #
  # `old_chains` is the chain set captured BEFORE any mutations the caller
  # has made. Chains present in `old_chains` but absent from the new state
  # get their ProbeCoordinators torn down via `old_chains -- new_chains`.
  #
  # Caller contract:
  #   - Inject path (no chains removed): pass `list_chains()` (post-mutation
  #     list — equivalent to the pre-mutation set plus the just-added chains).
  #   - Update / remove / reload paths: pass the chain list captured BEFORE
  #     the mutation so removed chains tear down cleanly.
  defp rebuild_shared_infrastructure(old_chain_ids) do
    alias Lasso.Providers.{Catalog, InstanceSupervisor, ProbeCoordinator}

    old_instances = Catalog.list_all_instance_ids()
    old_instance_chain_ids = snapshot_instance_chain_ids(old_instances)

    Catalog.build_from_config()

    new_instances = Catalog.list_all_instance_ids()
    new_chain_ids = list_chain_ids()

    for instance_id <- new_instances do
      case DynamicSupervisor.start_child(
             Lasso.Providers.InstanceDynamicSupervisor,
             {InstanceSupervisor, instance_id}
           ) do
        {:ok, _} ->
          :ok

        :ignore ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to start InstanceSupervisor for #{instance_id}: #{inspect(reason)}"
          )
      end
    end

    for instance_id <- old_instances -- new_instances do
      case GenServer.whereis(InstanceSupervisor.via_name(instance_id)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Lasso.Providers.InstanceDynamicSupervisor, pid)
      end

      Lasso.Providers.InstanceState.clear(instance_id)
    end

    for chain_id <- new_chain_ids do
      case DynamicSupervisor.start_child(
             Lasso.Providers.ProbeSupervisor,
             {ProbeCoordinator, chain_id}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> ProbeCoordinator.reload_instances(chain_id)
        _ -> :ok
      end
    end

    for chain_id <- old_chain_ids -- new_chain_ids do
      case GenServer.whereis(ProbeCoordinator.via_name(chain_id)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Lasso.Providers.ProbeSupervisor, pid)
      end

      Lasso.Providers.RestartCounter.clear({:probe_coord, chain_id})
    end

    reconcile_block_sync_workers(old_instances, old_instance_chain_ids)
  rescue
    e ->
      Logger.warning("Failed to rebuild shared infrastructure: #{inspect(e)}")
  end

  defp snapshot_instance_chain_ids(instance_ids) do
    alias Lasso.Providers.Catalog

    Map.new(instance_ids, fn id ->
      case Catalog.get_instance(id) do
        {:ok, %{chain_id: chain_id}} -> {id, chain_id}
        _ -> {id, nil}
      end
    end)
  end

  defp reconcile_block_sync_workers(old_instances, old_instance_chain_ids) do
    alias Lasso.Providers.Catalog

    new_instances = Catalog.list_all_instance_ids()
    added = new_instances -- old_instances
    removed = old_instances -- new_instances
    retained = new_instances -- added

    # Reap dropped instances before spawning new ones to enforce the
    # probe-intensity contract: no window where two workers for the same
    # provider URL run concurrently (auth rotation scenario).
    for instance_id <- removed do
      case Map.get(old_instance_chain_ids, instance_id) do
        nil -> :ok
        chain_id -> Lasso.BlockSync.Supervisor.stop_worker(chain_id, instance_id)
      end

      Lasso.Providers.RestartCounter.clear({:block_sync, instance_id})
    end

    for instance_id <- added do
      case Catalog.get_instance(instance_id) do
        {:ok, %{chain_id: chain_id}} ->
          Lasso.BlockSync.Supervisor.start_worker(chain_id, instance_id)

        _ ->
          :ok
      end
    end

    # Single signal: retained instances whose ref set or config may have
    # changed pick up the new config via :instance_config_updated. Added
    # workers load fresh config in handle_continue; removed are gone.
    broadcast_instance_config_changes(retained)

    if added != [] or removed != [] do
      Logger.info("Reconciled BlockSync workers: +#{length(added)} -#{length(removed)}")
    end
  end

  defp broadcast_instance_config_changes(instance_ids) do
    for instance_id <- instance_ids do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.instance_config_updated(instance_id),
        :instance_config_updated
      )
    end
  end
end
