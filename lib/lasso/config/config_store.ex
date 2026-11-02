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
  - `{:route_generation}` -> Monotonic generation of the published configuration snapshot

  ## Configuration Backend

  Configuration is loaded via the Backend behaviour. The default is
  `Lasso.Config.Backend.File` which loads profiles from YAML files.
  """

  use GenServer
  require Logger

  alias Lasso.Config.Backend
  alias Lasso.Config.{ChainAlias, ChainConfig}
  alias Lasso.Config.ChainConfig.Provider
  alias Lasso.Config.ConfigStore.Owner
  alias Lasso.Config.ProfileMeta
  alias Lasso.Core.Streaming.InstanceEventBus
  alias Lasso.Core.Support.DynamicSupervisorCall
  alias Lasso.Providers.{Catalog, ProviderHeaders}
  alias Lasso.RPC.ChainSupervisor

  @persistent_term_key :lasso_config_store_active
  @pending_cleanup_table :lasso_runtime_provider_cleanup
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
  @runtime_reconcile_retry_ms 1_000
  @runtime_supervisors [
    Lasso.BlockSync.DynamicSupervisor,
    Lasso.Providers.InstanceDynamicSupervisor,
    Lasso.Providers.ProbeSupervisor,
    Lasso.ProfileChainSupervisor
  ]

  ## Types

  @type profile_id :: String.t()
  @type scope :: :system
  @type profile_meta :: ProfileMeta.t()

  defp table do
    case :persistent_term.get(@persistent_term_key) do
      {table, generation} when is_integer(generation) and generation >= 0 -> table
      table -> table
    end
  end

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

  @doc "Returns the generation of the currently published routing configuration."
  @spec route_generation() :: non_neg_integer()
  def route_generation do
    case :persistent_term.get(@persistent_term_key, :unavailable) do
      {_table, generation} when is_integer(generation) and generation >= 0 -> generation
      :unavailable -> 0
      table -> route_generation_from_table(table)
    end
  end

  defp route_generation_from_table(table) do
    case :ets.lookup(table, {:route_generation}) do
      [{{:route_generation}, generation}] when is_integer(generation) and generation >= 0 ->
        generation

      _other ->
        0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Returns one provider and the generation atomically published with its route data."
  @spec get_provider_with_route_generation(profile_id(), pos_integer(), String.t()) ::
          {:ok, Provider.t(), non_neg_integer()} | {:error, :not_found}
  def get_provider_with_route_generation(profile_id, chain_id, provider_id) do
    rows =
      :ets.select(table(), [
        {{{:profile, profile_id, :chains}, :"$1"}, [], [{{:chains, :"$1"}}]},
        {{{:route_generation}, :"$1"}, [], [{{:generation, :"$1"}}]}
      ])

    with {:chains, chains} <- List.keyfind(rows, :chains, 0),
         {:generation, generation} <- List.keyfind(rows, :generation, 0),
         %{providers: providers} <- Map.get(chains, chain_id),
         %Provider{} = provider <- Enum.find(providers, &(&1.id == provider_id)) do
      {:ok, provider, generation}
    else
      _ -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
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
  Returns a configured URL alias for a numeric chain ID.

  The public profile is preferred for compatibility with the legacy global
  chain-ID index. Other loaded profiles are consulted when the chain is not in
  public.
  """
  @spec find_chain_name_by_id(integer()) :: {:ok, String.t()} | {:error, :not_found}
  def find_chain_name_by_id(chain_id) when is_integer(chain_id) and chain_id > 0 do
    profiles = list_profiles()

    profiles =
      if "public" in profiles, do: ["public" | List.delete(profiles, "public")], else: profiles

    Enum.find_value(profiles, {:error, :not_found}, fn profile_id ->
      case get_chain(profile_id, chain_id) do
        {:ok, chain_config} ->
          {:ok, ChainAlias.canonical_slug(chain_id, chain_config.url_aliases)}

        {:error, :not_found} ->
          false
      end
    end)
  end

  def find_chain_name_by_id(_chain_id), do: {:error, :not_found}

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

  def register_chain_runtime(profile_id, legacy_alias, %{chain_id: chain_id} = chain_attrs)
      when is_binary(profile_id) and is_binary(legacy_alias) and is_integer(chain_id) and
             chain_id > 0 do
    aliases = Map.get(chain_attrs, :url_aliases, [])
    chain_attrs = Map.put(chain_attrs, :url_aliases, Enum.uniq([legacy_alias | aliases]))
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
      {:register_provider_runtime, profile_id, chain_id, provider_attrs},
      15_000
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
      {:unregister_provider_runtime, profile_id, chain_id, provider_id},
      :infinity
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

  @doc "Warms profiles in one validated publication and repairs scoped runtime dependencies."
  @spec ensure_profiles([map()]) :: :ok | {:error, term()}
  def ensure_profiles(specs) when is_list(specs),
    do: GenServer.call(__MODULE__, {:ensure_profiles, specs}, :infinity)

  @doc "Checks exact published profile content without changing runtime state."
  @spec profile_content_published?(map()) :: boolean()
  def profile_content_published?(spec) do
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

    integer_chains = Map.new(spec.chains, fn {_alias, chain} -> {chain.chain_id, chain} end)

    safe_lookup({:profile, spec.profile_id, :meta}) == [
      {{:profile, spec.profile_id, :meta}, meta}
    ] and
      safe_lookup({:profile, spec.profile_id, :chains}) == [
        {{:profile, spec.profile_id, :chains}, integer_chains}
      ] and
      safe_lookup({:resolve, spec.scope, spec.slug}) == [
        {{:resolve, spec.scope, spec.slug}, spec.profile_id}
      ]
  rescue
    _ -> false
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
  Updates an existing profile through a validated config/catalog publication.

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
      runtime_dirty_profiles: MapSet.new(),
      last_good_specs: snapshot_profile_specs(),
      runtime_reconcile_timer: nil,
      runtime_reconcile_attempt: 0,
      runtime_supervisor_monitors: monitor_runtime_supervisors(%{})
    }

    if :ets.first(@pending_cleanup_table) != :"$end_of_table" do
      send(self(), {:runtime_reconcile_needed, :pending_provider_cleanup})
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:load_all_profiles, _from, state) do
    case do_load_all_profiles(state) do
      {:ok, profiles, new_state} ->
        {:reply, {:ok, profiles},
         %{new_state | db_degraded: false, runtime_dirty_profiles: MapSet.new()}}

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
    old_runtime = catalog_runtime_snapshot()

    case do_load_all_profiles(state, preserve_current_ets_on_degraded?: true) do
      {:ok, profiles, new_state} ->
        Logger.info("Configuration reloaded successfully")
        publication = rebuild_shared_infrastructure(old_chain_ids, {:published, old_runtime})
        chain_results = sync_chain_supervisors(old_pairs)
        reconcile_transport_channels_all(old_endpoints)
        Enum.each(profiles, &broadcast_profile_updated/1)

        {:reply, runtime_reconcile_status([publication | chain_results]),
         %{new_state | db_degraded: false, runtime_dirty_profiles: MapSet.new()}}

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
  def handle_call({:ensure_profiles, specs}, _from, state) do
    specs = Enum.uniq_by(specs, & &1.profile_id)
    result = do_ensure_profiles(specs)

    state =
      Enum.reduce(specs, state, fn spec, acc ->
        if profile_content_published?(spec),
          do: mark_runtime_dirty(acc, spec.profile_id, :ok),
          else: acc
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:inject_profile, profile_spec}, _from, state) do
    reply = do_inject_profile(profile_spec)
    {:reply, reply, mark_runtime_dirty(state, profile_spec.profile_id, reply)}
  end

  @impl true
  def handle_call({:resolve_or_load, scope, slug}, _from, state) do
    {reply, new_state} = do_resolve_or_load(scope, slug, state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:update_profile, profile_spec}, _from, state) do
    reply = do_update_profile(profile_spec)
    {:reply, reply, mark_runtime_dirty(state, profile_spec.profile_id, reply)}
  end

  @impl true
  def handle_call({:remove_profile, profile_id}, _from, state) do
    reply = do_remove_profile(profile_id)
    {:reply, reply, mark_runtime_dirty(state, profile_id, reply)}
  end

  @impl true
  def handle_call({:register_chain_runtime, profile_id, chain_id, chain_attrs}, _from, state) do
    case get_chain(profile_id, chain_id) do
      {:ok, _existing} ->
        {:reply, {:error, :already_exists}, state}

      {:error, :not_found} ->
        chain_config = normalize_chain_config(chain_id, chain_attrs)

        validation =
          with :ok <- ChainConfig.validate_no_unresolved_placeholders(chain_config) do
            validate_provider_headers(chain_config.providers)
          end

        case validation do
          :ok ->
            ensure_profile_in_list(profile_id)
            add_chain_to_profile(profile_id, chain_id, chain_config)
            Logger.debug("Registered chain #{chain_id} in profile #{profile_id} (runtime)")
            {:reply, :ok, mark_runtime_dirty(state, profile_id, :ok)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:unregister_chain_runtime, profile_id, chain_id}, _from, state) do
    case get_chain(profile_id, chain_id) do
      {:ok, _chain_config} ->
        remove_chain_from_profile(profile_id, chain_id)
        maybe_remove_profile_from_list(profile_id)
        Logger.debug("Unregistered chain #{chain_id} from profile #{profile_id} (runtime)")
        {:reply, :ok, mark_runtime_dirty(state, profile_id, :ok)}

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
         :ok <- validate_provider_not_exists(chain_config, provider_config.id),
         :ok <- ProviderHeaders.validate(provider_config),
         updated_chain <- add_provider_to_chain(chain_config, provider_config),
         :ok <- ChainConfig.validate_no_unresolved_placeholders(updated_chain) do
      update_chain_in_profile(profile_id, chain_id, updated_chain)

      Logger.debug(
        "Registered provider #{provider_config.id} for chain #{chain_id} in profile #{profile_id} (runtime)"
      )

      {:reply, :ok, mark_runtime_dirty(state, profile_id, :ok)}
    else
      {:error, :not_found} -> {:reply, {:error, :chain_not_found}, state}
      {:error, :already_exists} -> {:reply, {:error, :already_exists}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
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
      instance_id = Lasso.Providers.Catalog.lookup_instance_id(profile_id, chain_id, provider_id)
      cleanup_key = {profile_id, chain_id, provider_id}
      old_generation = route_generation()
      :ets.insert(@pending_cleanup_table, {cleanup_key, {instance_id, old_generation}})
      update_chain_in_profile(profile_id, chain_id, updated_chain)

      publication = rebuild_shared_infrastructure(list_chain_ids())
      runtime_provider_removal_barrier()
      cleanup = reconcile_provider_cleanup(cleanup_key, {instance_id, old_generation})

      Logger.debug(
        "Unregistered provider #{provider_id} from chain #{chain_id} in profile #{profile_id} (runtime)"
      )

      result = runtime_reconcile_status([publication, cleanup])
      {:reply, result, mark_runtime_dirty(state, profile_id, result)}
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
      backend: state.backend_module,
      runtime_reconcile_pending: not is_nil(state.runtime_reconcile_timer)
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
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
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

          snapshot = current_profile_fingerprints()

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
        case apply_retry_deltas(specs, snapshot, state.runtime_dirty_profiles) do
          :ok ->
            Logger.info("ConfigStore: retry succeeded, exiting degraded mode")

          {:error, _} ->
            Logger.warning("ConfigStore: backend recovered; runtime reconciliation pending")
        end

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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.runtime_supervisor_monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {supervisor, monitors} ->
        send(self(), {:runtime_reconcile_needed, {:supervisor_down, supervisor}})
        {:noreply, %{state | runtime_supervisor_monitors: monitors}}
    end
  end

  @impl true
  def handle_info({:runtime_reconcile_needed, operation}, %{runtime_reconcile_timer: nil} = state) do
    emit_runtime_reconcile_telemetry(:scheduled, operation)

    timer =
      Process.send_after(
        self(),
        :retry_runtime_reconcile,
        runtime_retry_delay(state.runtime_reconcile_attempt)
      )

    {:noreply,
     %{
       state
       | runtime_reconcile_timer: timer,
         runtime_reconcile_attempt: state.runtime_reconcile_attempt + 1
     }}
  end

  def handle_info({:runtime_reconcile_needed, _operation}, state), do: {:noreply, state}

  @impl true
  def handle_info(:retry_runtime_reconcile, state) do
    emit_runtime_reconcile_telemetry(:attempted, :all)

    monitors = monitor_runtime_supervisors(state.runtime_supervisor_monitors)
    publication = rebuild_shared_infrastructure(list_chain_ids())
    cleanup = reconcile_pending_provider_cleanup()
    chain_results = ensure_all_profile_chain_supervisors()
    result = runtime_reconcile_status([publication, cleanup | chain_results])
    attempt = if result == :ok, do: 0, else: state.runtime_reconcile_attempt

    {:noreply,
     %{
       state
       | runtime_reconcile_timer: nil,
         runtime_reconcile_attempt: attempt,
         runtime_supervisor_monitors: monitors
     }}
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

  defp do_ensure_profiles(specs) do
    changed = Enum.reject(specs, &profile_content_published?/1)
    {accepted, failures} = accepted_profile_changes(changed)

    # Once the config/catalog commit succeeds, runtime reconciliation is
    # background convergence. Verify global infrastructure and each profile's
    # workers below instead of letting one post-commit failure gate the census.
    runtime_specs = Enum.reject(specs, &Map.has_key?(failures, &1.profile_id))

    with :ok <- census_publication_result(publish_changed_profiles(accepted)),
         {:ok, runtime_failures} <- verify_profile_runtime(runtime_specs) do
      failures = Map.merge(failures, runtime_failures)

      if map_size(failures) == 0,
        do: :ok,
        else: {:error, {:profile_publication_failed, failures}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {:runtime_unavailable, {kind, normalize_failure(reason)}}}
  end

  defp census_publication_result(:ok), do: :ok
  defp census_publication_result({:error, {:runtime_reconcile_pending, _}}), do: :ok
  defp census_publication_result(error), do: error

  defp accepted_profile_changes([]), do: {[], %{}}

  defp accepted_profile_changes(specs) do
    # Structural failures never trigger a full catalog validation for each
    # valid neighbour. Only shared catalog invariants need isolation.
    {valid, structural_failures} =
      Enum.reduce(specs, {[], %{}}, fn spec, {valid, failures} ->
        case validate_profile_spec(spec) do
          :ok -> {[spec | valid], failures}
          {:error, reason} -> {valid, Map.put(failures, spec.profile_id, reason)}
        end
      end)

    valid = Enum.reverse(valid)

    validation = if valid == [], do: :ok, else: Catalog.validate_profile_batch(valid)

    case validation do
      :ok ->
        {valid, structural_failures}

      {:error, _} ->
        Enum.reduce(valid, {[], structural_failures}, fn spec, {accepted, failures} ->
          case Catalog.validate_profile_batch(accepted ++ [spec]) do
            :ok ->
              {accepted ++ [spec], failures}

            {:error, reason} ->
              Logger.error("Profile runtime publication rejected", profile_id: spec.profile_id)
              {accepted, Map.put(failures, spec.profile_id, reason)}
          end
        end)
    end
  end

  defp publish_changed_profiles([]), do: :ok

  defp publish_changed_profiles(specs) do
    old_pairs = collect_profile_chain_pairs()
    old_chain_ids = list_chain_ids()

    old_configs =
      Map.new(specs, fn spec ->
        {spec.profile_id,
         snapshot_profile_chain_configs(spec.profile_id, list_chains_for_profile(spec.profile_id))}
      end)

    old_runtime = catalog_runtime_snapshot()
    publish_profiles_upsert(specs, &Catalog.build_from_config/0)

    publication = rebuild_shared_infrastructure(old_chain_ids, {:published, old_runtime})
    chains = sync_chain_supervisors(old_pairs)

    Enum.each(specs, fn spec ->
      reconcile_transport_channels(spec.profile_id, old_configs[spec.profile_id], spec)
      broadcast_profile_updated(spec.profile_id)
    end)

    notify_inject()
    runtime_reconcile_status([publication | chains])
  end

  defp catalog_coherent? do
    case Catalog.snapshot() do
      %{table: table, generation: generation} ->
        Catalog.ready?() and generation == route_generation() and
          Lasso.RPC.AttemptProjection.routes_ready?(
            generation,
            Catalog.routing_control_routes(table)
          )

      nil ->
        false
    end
  end

  defp verify_profile_runtime(specs) do
    # Require a coherent global catalog before inspecting per-profile workers.
    rebuild =
      if catalog_coherent?(),
        do: :ok,
        else: rebuild_shared_infrastructure(list_chain_ids())

    with :ok <- rebuild,
         true <- Enum.all?(@runtime_supervisors, &is_pid(Process.whereis(&1))),
         true <- catalog_coherent?() do
      runtimes = Map.new(specs, &{&1.profile_id, profile_runtime([&1])})

      # Shared physical workers can appear in many tenant profiles. Attempt each
      # dependency once per census, including failures, then attribute that same
      # result to every referencing profile instead of repeating bounded timeouts.
      repairs =
        runtimes
        |> Map.values()
        |> Enum.flat_map(&runtime_dependencies/1)
        |> Enum.uniq()
        |> Map.new(&{&1, repair_runtime_dependency(&1)})

      failures =
        Map.new(
          Enum.flat_map(runtimes, fn {id, runtime} ->
            repaired = Enum.map(runtime_dependencies(runtime), &Map.fetch!(repairs, &1))

            if runtime_reconcile_status(repaired) == :ok and profile_runtime_ready?(runtime),
              do: [],
              else: [{id, :profile_runtime_unavailable}]
          end)
        )

      # Transport cleanup records background convergence; it is not a worker proof.
      runtimes
      |> Map.values()
      |> Enum.flat_map(& &1.profile_chains)
      |> Enum.uniq()
      |> reconcile_profile_channels()

      if catalog_coherent?(),
        do: {:ok, failures},
        else: {:error, :profile_runtime_unavailable}
    else
      _ -> {:error, :profile_runtime_unavailable}
    end
  end

  defp profile_runtime(specs) do
    pairs =
      for spec <- specs, {_alias, chain} <- spec.chains, do: {spec.profile_id, chain.chain_id}

    profile_chains = Enum.uniq(pairs)

    instances =
      for {profile, chain} <- profile_chains,
          provider <- Catalog.get_profile_providers(profile, chain),
          instance <- [provider.instance_id],
          do: {chain, instance}

    %{
      profile_chains: profile_chains,
      chain_ids: pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      instances: Enum.uniq(instances)
    }
  end

  defp profile_runtime_ready?(runtime) do
    Enum.all?(runtime.profile_chains, fn {profile, chain} ->
      match?({:ok, _}, Catalog.get_routing_plan(Catalog.snapshot(), profile, chain)) and
        Lasso.ProfileChainSupervisor.running?(profile, chain)
    end) and
      Enum.all?(runtime.chain_ids, fn chain ->
        is_pid(GenServer.whereis(Lasso.Providers.ProbeCoordinator.via_name(chain)))
      end) and
      Enum.all?(runtime.instances, fn {_chain, instance} ->
        is_pid(GenServer.whereis(Lasso.Providers.InstanceSupervisor.via_name(instance)))
      end)
  end

  # Runtime-only recovery never retires instances or republishes persistent_term.
  # A fault outside the warmed profiles is not part of this readiness decision.
  defp runtime_dependencies(runtime) do
    Enum.map(runtime.profile_chains, &{:profile_chain, &1}) ++
      Enum.map(runtime.chain_ids, &{:probe, &1}) ++
      Enum.map(runtime.instances, fn {_chain, instance} -> {:instance, instance} end)
  end

  defp repair_runtime_dependency(dependency) do
    do_repair_runtime_dependency(dependency)
  rescue
    _error -> {:error, :profile_runtime_unavailable}
  catch
    _kind, _reason -> {:error, :profile_runtime_unavailable}
  end

  defp do_repair_runtime_dependency({:profile_chain, {profile, chain}}) do
    if Lasso.ProfileChainSupervisor.running?(profile, chain) do
      :ok
    else
      with {:ok, config} <- get_chain(profile, chain) do
        Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain, config)
      end
    end
  end

  defp do_repair_runtime_dependency({:instance, instance}) do
    ensure_runtime_child(
      Lasso.Providers.InstanceSupervisor.via_name(instance),
      Lasso.Providers.InstanceDynamicSupervisor,
      {Lasso.Providers.InstanceSupervisor, instance}
    )
  end

  defp do_repair_runtime_dependency({:probe, chain}) do
    ensure_runtime_child(
      Lasso.Providers.ProbeCoordinator.via_name(chain),
      Lasso.Providers.ProbeSupervisor,
      {Lasso.Providers.ProbeCoordinator, chain}
    )
  end

  defp ensure_runtime_child(name, supervisor, spec) do
    if is_pid(GenServer.whereis(name)),
      do: :ok,
      else: DynamicSupervisorCall.start_child(supervisor, spec)
  end

  defp do_inject_profile(profile_spec) do
    validate_and_publish_profile(profile_spec)
  end

  defp do_update_profile(profile_spec) do
    case get_profile(profile_spec.profile_id) do
      {:error, :not_found} -> {:error, :profile_not_found}
      {:ok, _meta} -> validate_and_publish_profile(profile_spec)
    end
  end

  defp validate_and_publish_profile(profile_spec) do
    with :ok <- validate_profile_spec(profile_spec),
         :ok <- Catalog.validate_profile_batch([profile_spec]) do
      publish_changed_profiles([profile_spec])
    end
  catch
    kind, reason -> {:error, {:profile_publication_failed, {kind, normalize_failure(reason)}}}
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

        old_runtime = catalog_runtime_snapshot()
        publish_profile_removal(profile_id, meta)

        publication = rebuild_shared_infrastructure(old_chain_ids, {:published, old_runtime})
        chain_results = sync_chain_supervisors(old_pairs)
        notify_inject()
        broadcast_profile_updated(profile_id)

        runtime_reconcile_status([publication | chain_results])
    end
  rescue
    e ->
      Logger.error("Failed to remove profile: #{inspect(e)}")
      {:error, e}
  catch
    kind, reason -> {:error, {:profile_publication_failed, {kind, normalize_failure(reason)}}}
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
  defp apply_retry_deltas(loaded_specs, spawn_snapshot, runtime_dirty_profiles) do
    spawn_snapshot = spawn_snapshot || %{}
    spawn_ids = MapSet.new(Map.keys(spawn_snapshot))
    loaded_by_id = Map.new(loaded_specs, &{&1.profile_id, &1})
    loaded_ids = MapSet.new(Map.keys(loaded_by_id))

    current_ids = current_file_profile_ids()
    current_fingerprints = current_profile_fingerprints()

    to_remove =
      spawn_ids
      |> MapSet.intersection(current_ids)
      |> MapSet.difference(loaded_ids)
      |> Enum.filter(fn profile_id ->
        not MapSet.member?(runtime_dirty_profiles, profile_id) and
          Map.get(current_fingerprints, profile_id) == Map.get(spawn_snapshot, profile_id)
      end)

    old_pairs = collect_profile_chain_pairs()
    old_chain_ids = list_chain_ids()

    changed =
      Enum.filter(loaded_specs, fn spec ->
        not MapSet.member?(runtime_dirty_profiles, spec.profile_id) and
          (not MapSet.member?(current_ids, spec.profile_id) or
             Map.get(current_fingerprints, spec.profile_id) ==
               Map.get(spawn_snapshot, spec.profile_id)) and
          not profile_content_published?(spec)
      end)

    {accepted, failures} = accepted_profile_changes(changed)
    changed_ids = Enum.map(accepted, & &1.profile_id) ++ to_remove

    if changed_ids != [] do
      old_runtime = catalog_runtime_snapshot()
      replacements = Map.new(accepted, &{&1.profile_id, &1})

      specs =
        snapshot_profile_specs()
        |> Enum.reject(&(&1.profile_id in to_remove or Map.has_key?(replacements, &1.profile_id)))
        |> Kernel.++(accepted)

      populate_ets(specs)
      publication = rebuild_shared_infrastructure(old_chain_ids, {:published, old_runtime})
      chain_results = sync_chain_supervisors(old_pairs)
      notify_inject()
      Enum.each(changed_ids, &broadcast_profile_updated/1)
      runtime_reconcile_status([publication | chain_results])
    else
      if map_size(failures) == 0,
        do: :ok,
        else: {:error, {:profile_publication_failed, failures}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {:profile_publication_failed, {kind, normalize_failure(reason)}}}
  end

  # Set of file-backed profile IDs currently in ETS.
  defp current_file_profile_ids, do: list_profiles() |> MapSet.new()

  defp current_profile_fingerprints do
    case snapshot_profile_specs() do
      specs when is_list(specs) ->
        Map.new(specs, fn spec -> {spec.profile_id, :erlang.phash2(spec)} end)

      _ ->
        %{}
    end
  end

  # Resolution order: keyword option -> app env -> default.
  defp retry_opt(opts, _key, app_key, default) when is_binary(opts) do
    Application.get_env(:lasso, app_key, default)
  end

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
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {:profile_publication_failed, {kind, normalize_failure(reason)}}}
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

  @doc "Validate loaded profile specs before an operator applies them to the active store."
  @spec validate_profile_specs([map()]) :: :ok | {:error, term()}
  def validate_profile_specs(profile_specs) when is_list(profile_specs) do
    with :ok <- validate_unique_profile_ids(profile_specs) do
      Enum.reduce_while(profile_specs, :ok, fn spec, :ok ->
        case validate_profile_spec(spec) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def validate_profile_specs(_), do: {:error, :invalid_profile_specs}

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

      Enum.any?(chains, fn {_, chain} ->
        not Lasso.RPC.HeadPolicy.valid_mode?(Map.get(chain, :head_policy, "off"))
      end) ->
        {:error, :invalid_head_policy}

      Enum.any?(chains, fn {_, chain} -> Map.get(chain, :head_policy) == "global" end) and
          not Lasso.BlockPublication.Runtime.configured?() ->
        {:error, :global_publication_unconfigured}

      true ->
        with :ok <- validate_chain_aliases(chains, MapSet.new(ids)),
             :ok <- validate_profile_transactions(chains),
             :ok <- validate_profile_provider_placeholders(chains) do
          validate_profile_provider_headers(chains)
        end
    end
  end

  defp validate_profile_spec(_), do: {:error, :invalid_profile_spec}

  defp validate_profile_transactions(chains) do
    Enum.reduce_while(chains, :ok, fn {_, chain}, :ok ->
      case ChainConfig.Transactions.validate(chain.transactions, chain.providers) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_profile_provider_placeholders(chains) do
    Enum.reduce_while(chains, :ok, fn {chain_name, chain}, :ok ->
      case ChainConfig.validate_no_unresolved_placeholders(chain) do
        :ok ->
          {:cont, :ok}

        {:error, {:unresolved_env_vars, providers}} ->
          {:halt, {:error, {:unresolved_env_vars, [{chain_name, providers}]}}}
      end
    end)
  end

  defp validate_profile_provider_headers(chains) do
    Enum.reduce_while(chains, :ok, fn {chain_name, chain}, :ok ->
      case Enum.find(chain.providers, &(ProviderHeaders.validate(&1) != :ok)) do
        nil -> {:cont, :ok}
        provider -> {:halt, {:error, {:invalid_provider_headers, chain_name, provider.id}}}
      end
    end)
  end

  defp validate_provider_headers(providers) do
    case Enum.find(providers, &(ProviderHeaders.validate(&1) != :ok)) do
      nil -> :ok
      _ -> {:error, :invalid_provider_headers}
    end
  end

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
    route_generation = next_route_generation()

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

    :ets.insert(new_table, {{:route_generation}, route_generation})
    build_indices(profile_specs, new_table)

    old_table = active_table(nil)

    commit =
      if Process.whereis(Lasso.Providers.Catalog.Owner),
        do: &Catalog.build_from_config/0,
        else: fn -> :ok end

    commit_snapshot(new_table, route_generation, old_table, commit)
  end

  defp safe_lookup(key) do
    :ets.lookup(table(), key)
  rescue
    ArgumentError -> []
  end

  defp active_table(default) do
    case :persistent_term.get(@persistent_term_key, default) do
      {table, generation} when is_integer(generation) and generation >= 0 -> table
      table -> table
    end
  end

  defp publish_snapshot(table, generation)
       when is_integer(generation) and generation >= 0 do
    :persistent_term.put(@persistent_term_key, {table, generation})
  end

  defp next_route_generation, do: route_generation() + 1

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

  defp mark_runtime_dirty(state, profile_id, reply) do
    if reply == :ok or match?({:error, {:runtime_reconcile_pending, _}}, reply) do
      state = refresh_last_good_specs(state, :ok)
      %{state | runtime_dirty_profiles: MapSet.put(state.runtime_dirty_profiles, profile_id)}
    else
      state
    end
  end

  defp refresh_last_good_specs(state, :ok),
    do: %{state | last_good_specs: snapshot_profile_specs()}

  defp resolve_with_meta(scope, slug) do
    with {:ok, profile_id} <- resolve(scope, slug),
         {:ok, meta} <- get_profile(profile_id) do
      {:ok, profile_id, meta}
    end
  end

  defp publish_profiles_upsert(specs, commit) do
    profile_ids = MapSet.new(specs, & &1.profile_id)
    old_table = table()
    route_generation = next_route_generation()

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
      {{:profile, profile_id, :meta}, _} -> MapSet.member?(profile_ids, profile_id)
      {{:profile, profile_id, :chains}, _} -> MapSet.member?(profile_ids, profile_id)
      {{:resolve, _scope, _slug}, profile_id} -> MapSet.member?(profile_ids, profile_id)
      {{:profile_list}, _} -> true
      {{:chain_profiles, _chain_id}, _} -> true
      {{:all_chain_ids}, _} -> true
      _ -> false
    end)
    |> then(&:ets.insert(new_table, &1))

    Enum.each(specs, &store_profile(&1, new_table))
    :ets.insert(new_table, {{:route_generation}, route_generation})
    rebuild_indices_from_table(new_table)

    commit_snapshot(new_table, route_generation, old_table, commit)
    :ok
  end

  defp commit_snapshot(new_table, generation, old_table, commit) do
    old_generation = route_generation()
    publish_snapshot(new_table, generation)

    try do
      :ok = commit.()
      if old_table, do: Owner.schedule_delete(old_table, @grace_period_ms)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        publish_snapshot(old_table, old_generation)
        Owner.schedule_delete(new_table, @grace_period_ms)
        restore_catalog_controls()
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp restore_catalog_controls do
    case Catalog.snapshot() do
      %{table: table, generation: generation} ->
        if :ets.info(table, :size) != :undefined do
          Lasso.RPC.AttemptProjection.reconcile_routes(
            generation,
            Catalog.routing_control_routes(table)
          )
        end

      nil ->
        :ok
    end
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

  defp publish_profile_removal(profile_id, %ProfileMeta{} = meta) do
    old_table = table()
    route_generation = next_route_generation()

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
    :ets.insert(new_table, {{:route_generation}, route_generation})
    rebuild_indices_from_table(new_table)

    commit_snapshot(new_table, route_generation, old_table, &Catalog.build_from_config/0)

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
    table = table()

    chains =
      case :ets.lookup(table, {:profile, profile_id, :chains}) do
        [{{:profile, ^profile_id, :chains}, existing}] -> existing
        [] -> %{}
      end

    updated_chains = Map.put(chains, chain_id, chain_config)
    generation = next_route_generation()

    :ets.insert(table, [
      {{:profile, profile_id, :chains}, updated_chains},
      {{:route_generation}, generation}
    ])

    update_indices_for_chain_add(profile_id, chain_id)
    publish_snapshot(table, generation)
  end

  defp remove_chain_from_profile(profile_id, chain_id) do
    table = table()

    case :ets.lookup(table, {:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] ->
        updated_chains = Map.delete(chains, chain_id)
        generation = next_route_generation()

        :ets.insert(table, [
          {{:profile, profile_id, :chains}, updated_chains},
          {{:route_generation}, generation}
        ])

        update_indices_for_chain_remove(profile_id, chain_id)
        publish_snapshot(table, generation)

      [] ->
        :ok
    end
  end

  defp update_chain_in_profile(profile_id, chain_id, chain_config) do
    table = table()

    case :ets.lookup(table, {:profile, profile_id, :chains}) do
      [{{:profile, ^profile_id, :chains}, chains}] ->
        updated_chains = Map.put(chains, chain_id, chain_config)
        generation = next_route_generation()

        :ets.insert(table, [
          {{:profile, profile_id, :chains}, updated_chains},
          {{:route_generation}, generation}
        ])

        publish_snapshot(table, generation)

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

    display_name =
      Map.get(attrs, :display_name) || Map.get(attrs, "display_name") ||
        Map.get(attrs, :name) || Map.get(attrs, "name")

    %ChainConfig{
      chain_id: chain_id,
      head_policy: Map.get(attrs, :head_policy, Map.get(attrs, "head_policy", "off")),
      block_time_ms: Map.get(attrs, :block_time_ms, Map.get(attrs, "block_time_ms")),
      name: display_name,
      display_name: display_name,
      url_aliases:
        attrs
        |> Map.get(:url_aliases, Map.get(attrs, "url_aliases"))
        |> normalize_url_aliases(),
      providers: Enum.map(providers_attrs, &normalize_provider_config/1),
      websocket: normalize_websocket_config(websocket_attrs),
      transactions:
        ChainConfig.Transactions.parse(
          Map.get(attrs, :transactions, Map.get(attrs, "transactions"))
        ),
      selection: normalize_selection_config(selection_attrs),
      monitoring: normalize_monitoring_config(monitoring_attrs)
    }
  end

  defp normalize_url_aliases(aliases) when is_list(aliases) do
    Enum.filter(aliases, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp normalize_url_aliases(_aliases), do: []

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
      max_lag_blocks: Map.get(attrs, :max_lag_blocks) || Map.get(attrs, "max_lag_blocks"),
      archival_threshold:
        Map.get(attrs, :archival_threshold) || Map.get(attrs, "archival_threshold") ||
          ChainConfig.Selection.default_archival_threshold()
    }
  end

  defp normalize_monitoring_config(attrs) when is_map(attrs) do
    Lasso.Config.ObservationConfig.monitoring(attrs, %ChainConfig.Monitoring{
      probe_interval_ms:
        Map.get(attrs, :probe_interval_ms) || Map.get(attrs, "probe_interval_ms") || 15_000,
      lag_alert_threshold_blocks:
        Map.get(attrs, :lag_alert_threshold_blocks) ||
          Map.get(attrs, "lag_alert_threshold_blocks") ||
          Map.get(attrs, :lag_threshold_blocks) || Map.get(attrs, "lag_threshold_blocks") || 3
    })
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
      background_observations:
        Map.get(attrs, :background_observations, Map.get(attrs, "background_observations", true)),
      observation_overrides:
        Map.get(attrs, :observation_overrides, Map.get(attrs, "observation_overrides")),
      chain_identity_interval_ms:
        Map.get(attrs, :chain_identity_interval_ms, Map.get(attrs, "chain_identity_interval_ms")),
      block_poll_interval_ms:
        Map.get(attrs, :block_poll_interval_ms, Map.get(attrs, "block_poll_interval_ms")),
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
          profile_id
          |> Lasso.ProfileChainSupervisor.start_profile_chain(chain_id, chain_config)
          |> track_runtime_reconcile_result(:profile_chain_start)

        _ ->
          :ok
      end
    end
  rescue
    e ->
      [track_runtime_reconcile_result({:error, e}, :profile_chain_start)]
  end

  defp collect_profile_chain_pairs do
    for profile_id <- list_profiles(),
        chain_id <- list_chains_for_profile(profile_id),
        do: {profile_id, chain_id}
  end

  defp sync_chain_supervisors(old_pairs) do
    new_pairs = collect_profile_chain_pairs()

    starts =
      for {profile_id, chain_id} <- new_pairs do
        case get_chain(profile_id, chain_id) do
          {:ok, config} ->
            profile_id
            |> Lasso.ProfileChainSupervisor.start_profile_chain(chain_id, config)
            |> track_runtime_reconcile_result(:profile_chain_start)

          _ ->
            :ok
        end
      end

    stops =
      for {profile_id, chain_id} <- old_pairs -- new_pairs do
        profile_id
        |> Lasso.ProfileChainSupervisor.stop_profile_chain(chain_id)
        |> track_runtime_reconcile_result(:profile_chain_stop)
      end

    starts ++ stops
  rescue
    e ->
      [track_runtime_reconcile_result({:error, e}, :profile_chain_sync)]
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
  defp catalog_runtime_snapshot do
    instances = Catalog.list_all_instance_ids()
    {instances, snapshot_instance_chain_ids(instances)}
  end

  defp rebuild_shared_infrastructure(old_chain_ids, publication \\ :rebuild) do
    {old_instances, old_instance_chain_ids} =
      case publication do
        {:published, previous} -> previous
        :rebuild -> catalog_runtime_snapshot()
      end

    if publication == :rebuild, do: Catalog.build_from_config()

    new_instances = Catalog.list_all_instance_ids()
    new_chain_ids = list_chain_ids()
    removed_instances = old_instances -- new_instances

    Enum.each(removed_instances, fn instance_id ->
      if chain_id = Map.get(old_instance_chain_ids, instance_id) do
        InstanceEventBus.broadcast(
          Lasso.Topics.instance_sub_manager_restarted(chain_id),
          {:instance_sub_manager_restarted, instance_id}
        )
      end
    end)

    probe_chain_ids =
      Enum.filter(new_chain_ids, fn chain_id ->
        Catalog.list_instances_for_chain(chain_id) != []
      end)

    {instance_starts, instance_stops} =
      reconcile_instance_supervisors(new_instances, removed_instances)

    {probe_starts, probe_stops} =
      reconcile_probe_coordinators(old_chain_ids, probe_chain_ids)

    block_sync = reconcile_block_sync_workers(old_instances, old_instance_chain_ids)

    runtime_reconcile_status(
      instance_starts ++ instance_stops ++ probe_starts ++ probe_stops ++ block_sync
    )
  rescue
    error ->
      track_runtime_reconcile_result({:error, error}, :shared_infrastructure)
      {:error, {:runtime_reconcile_pending, error}}
  catch
    :exit, reason ->
      track_runtime_reconcile_result({:error, reason}, :shared_infrastructure)
      {:error, {:runtime_reconcile_pending, reason}}
  end

  defp reconcile_instance_supervisors(new_instances, removed_instances) do
    alias Lasso.Providers.InstanceSupervisor

    case DynamicSupervisorCall.children(Lasso.Providers.InstanceDynamicSupervisor) do
      {:ok, children} ->
        running_instances =
          for {_, pid, _, _} <- children,
              is_pid(pid),
              {:instance_supervisor, instance_id} <- Registry.keys(Lasso.Registry, pid),
              do: instance_id

        stale_instances = Enum.uniq(removed_instances ++ (running_instances -- new_instances))

        starts =
          bounded_reconcile(new_instances, fn instance_id ->
            case DynamicSupervisorCall.start_child(
                   Lasso.Providers.InstanceDynamicSupervisor,
                   {InstanceSupervisor, instance_id}
                 ) do
              {:ok, _} -> :ok
              :ignore -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, _} = error -> track_runtime_reconcile_result(error, :instance_start)
            end
          end)

        stops =
          if Enum.any?(starts, &match?({:error, _}, &1)) do
            []
          else
            bounded_reconcile(stale_instances, fn instance_id ->
              result =
                case GenServer.whereis(InstanceSupervisor.via_name(instance_id)) do
                  nil ->
                    :ok

                  pid ->
                    DynamicSupervisorCall.terminate_child(
                      Lasso.Providers.InstanceDynamicSupervisor,
                      pid
                    )
                    |> track_runtime_reconcile_result(:instance_stop)
                end

              Lasso.Providers.InstanceState.clear(instance_id)
              result
            end)
          end

        {starts, stops}

      {:error, _} = error ->
        {[track_runtime_reconcile_result(error, :instance_supervisor)], []}
    end
  end

  defp reconcile_probe_coordinators(old_chain_ids, desired_chain_ids) do
    alias Lasso.Providers.ProbeCoordinator

    case DynamicSupervisorCall.children(Lasso.Providers.ProbeSupervisor) do
      {:ok, children} ->
        running_chains =
          for {_, pid, _, _} <- children,
              is_pid(pid),
              {:probe_coordinator, chain_id} <- Registry.keys(Lasso.Registry, pid),
              do: chain_id

        stale_chains =
          Enum.uniq((old_chain_ids -- desired_chain_ids) ++ (running_chains -- desired_chain_ids))

        starts =
          bounded_reconcile(desired_chain_ids, fn chain_id ->
            case DynamicSupervisorCall.start_child(
                   Lasso.Providers.ProbeSupervisor,
                   {ProbeCoordinator, chain_id}
                 ) do
              {:ok, _} -> :ok
              {:error, {:already_started, _}} -> ProbeCoordinator.reload_instances(chain_id)
              {:error, _} = error -> track_runtime_reconcile_result(error, :probe_start)
              _ -> :ok
            end
          end)

        stops =
          if Enum.any?(starts, &match?({:error, _}, &1)) do
            []
          else
            bounded_reconcile(stale_chains, &stop_stale_probe_coordinator/1)
          end

        {starts, stops}

      {:error, _} = error ->
        {[track_runtime_reconcile_result(error, :probe_supervisor)], []}
    end
  end

  defp stop_stale_probe_coordinator(chain_id) do
    alias Lasso.Providers.ProbeCoordinator

    result =
      case GenServer.whereis(ProbeCoordinator.via_name(chain_id)) do
        nil ->
          :ok

        pid ->
          case DynamicSupervisorCall.terminate_child(Lasso.Providers.ProbeSupervisor, pid) do
            {:error, :not_found} -> :ok
            result -> track_runtime_reconcile_result(result, :probe_stop)
          end
      end

    Lasso.Providers.RestartCounter.clear({:probe_coord, chain_id})
    result
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
    case Lasso.BlockSync.Supervisor.list_worker_keys() do
      {:ok, running_keys} ->
        reconcile_block_sync_workers(old_instances, old_instance_chain_ids, running_keys)

      {:error, _} = error ->
        [track_runtime_reconcile_result(error, :block_sync_list)]
    end
  end

  defp reconcile_block_sync_workers(old_instances, old_instance_chain_ids, running_keys) do
    alias Lasso.Providers.Catalog

    new_instances = Catalog.list_all_instance_ids()
    added = new_instances -- old_instances
    retained = new_instances -- added

    desired =
      for instance_id <- new_instances,
          {:ok, %{chain_id: chain_id}} <- [Catalog.get_instance(instance_id)],
          do: {chain_id, instance_id}

    removed_from_catalog =
      for instance_id <- old_instances -- new_instances,
          chain_id = Map.get(old_instance_chain_ids, instance_id),
          is_integer(chain_id),
          do: {chain_id, instance_id}

    removed = Enum.uniq((running_keys -- desired) ++ removed_from_catalog)

    # Reap dropped instances before spawning new ones to enforce the
    # probe-intensity contract: no window where two workers for the same
    # provider URL run concurrently (auth rotation scenario).
    stops =
      for {chain_id, instance_id} <- removed do
        result =
          chain_id
          |> Lasso.BlockSync.Supervisor.stop_worker(instance_id)
          |> track_runtime_reconcile_result(:block_sync_stop)

        Lasso.BlockSync.Registry.remove_instance(chain_id, instance_id)
        Lasso.Providers.RestartCounter.clear({:block_sync, instance_id})
        result
      end

    starts =
      for {chain_id, instance_id} <- desired do
        chain_id
        |> Lasso.BlockSync.Supervisor.start_worker(instance_id)
        |> track_runtime_reconcile_result(:block_sync_start)
      end

    # Single signal: retained instances whose ref set or config may have
    # changed pick up the new config via :instance_config_updated. Added
    # workers load fresh config in handle_continue; removed are gone.
    broadcasts = broadcast_instance_config_changes(retained)

    if added != [] or removed != [] do
      Logger.info("Reconciled BlockSync workers: +#{length(added)} -#{length(removed)}")
    end

    stops ++ starts ++ broadcasts
  end

  defp broadcast_instance_config_changes(instance_ids) do
    for instance_id <- instance_ids do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.instance_config_updated(instance_id),
        :instance_config_updated
      )
      |> track_runtime_reconcile_result(:instance_config_broadcast)
    end
  end

  defp ensure_all_profile_chain_supervisors do
    Enum.flat_map(list_profiles(), &start_profile_chain_supervisors/1)
  end

  defp monitor_runtime_supervisors(monitors) do
    monitored = Map.values(monitors)

    Enum.reduce(@runtime_supervisors -- monitored, monitors, fn supervisor, acc ->
      case Process.whereis(supervisor) do
        pid when is_pid(pid) -> Map.put(acc, Process.monitor(pid), supervisor)
        nil -> acc
      end
    end)
  end

  defp track_runtime_reconcile_result({:error, reason} = error, operation) do
    Logger.warning("Runtime reconciliation pending",
      operation: operation,
      reason: inspect(reason)
    )

    send(self(), {:runtime_reconcile_needed, operation})
    error
  end

  defp track_runtime_reconcile_result(result, _operation), do: result

  defp reconcile_profile_channels(profile_chains) do
    pairs = MapSet.new(profile_chains)

    @pending_cleanup_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {{profile, chain, _provider} = key, pending} ->
      if MapSet.member?(pairs, {profile, chain}),
        do: [reconcile_provider_cleanup(key, pending)],
        else: []
    end)
    |> runtime_reconcile_status()
  end

  defp reconcile_pending_provider_cleanup do
    @pending_cleanup_table
    |> :ets.tab2list()
    |> Enum.map(fn {key, pending} -> reconcile_provider_cleanup(key, pending) end)
    |> runtime_reconcile_status()
  end

  defp reconcile_provider_cleanup(
         {profile_id, chain_id, provider_id} = key,
         {instance_id, generation}
       ) do
    with :ok <- notify_removed_provider_alias(key, instance_id),
         :ok <-
           ChainSupervisor.remove_provider(
             profile_id,
             chain_id,
             provider_id,
             instance_id,
             generation
           ) do
      complete_provider_cleanup(:ok, key)
    else
      {:error, _reason} = error -> complete_provider_cleanup(error, key)
    end
  end

  defp notify_removed_provider_alias({profile_id, chain_id, provider_id}, old_instance_id) do
    current_instance_id =
      Lasso.Providers.Catalog.lookup_instance_id(profile_id, chain_id, provider_id)

    case {get_provider(profile_id, chain_id, provider_id), current_instance_id} do
      {{:error, :not_found}, nil} ->
        broadcast_removed_provider_alias(profile_id, chain_id, provider_id, old_instance_id)

      {{:ok, _provider}, instance_id} when is_binary(instance_id) ->
        if instance_id == old_instance_id do
          :ok
        else
          broadcast_removed_provider_alias(profile_id, chain_id, provider_id, old_instance_id)
        end

      _ ->
        {:error, {:provider_alias_publication_pending, profile_id, chain_id, provider_id}}
    end
  end

  defp broadcast_removed_provider_alias(profile_id, chain_id, provider_id, instance_id) do
    InstanceEventBus.broadcast(
      Lasso.Topics.instance_sub_manager_restarted(chain_id),
      {:runtime_provider_removed, profile_id, provider_id, instance_id}
    )

    :ok
  end

  defp runtime_provider_removal_barrier do
    case Application.get_env(:lasso, :runtime_provider_removal_barrier) do
      {observer, ref} when is_pid(observer) and is_reference(ref) ->
        send(observer, {:runtime_provider_removal_published, self(), ref})

        receive do
          {:runtime_provider_removal_continue, ^ref} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp complete_provider_cleanup(:ok, key) do
    :ets.delete(@pending_cleanup_table, key)
    :ok
  end

  defp complete_provider_cleanup({:error, _reason} = error, _key) do
    track_runtime_reconcile_result(error, :provider_channel_cleanup)
  end

  defp bounded_reconcile(items, operation) do
    items
    |> Enum.reduce_while([], fn item, results ->
      result = operation.(item)

      if match?({:error, _}, result) do
        {:halt, [result | results]}
      else
        {:cont, [result | results]}
      end
    end)
    |> Enum.reverse()
  end

  defp runtime_reconcile_status(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, {:runtime_reconcile_pending, _}} = pending -> pending
      {:error, reason} -> {:error, {:runtime_reconcile_pending, reason}}
      nil -> :ok
    end
  end

  defp runtime_retry_delay(attempt) do
    base = min(@runtime_reconcile_retry_ms * Integer.pow(2, min(attempt, 5)), 30_000)
    base + jitter(base)
  end

  defp emit_runtime_reconcile_telemetry(event, operation) do
    :telemetry.execute(
      [:lasso, :config, :runtime_reconcile, event],
      %{count: 1},
      %{operation: operation}
    )
  end
end
