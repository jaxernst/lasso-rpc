defmodule Lasso.RPC.ProviderPool do
  @moduledoc """
  Manages health monitoring, failover, and load balancing for RPC providers.

  This GenServer tracks the health of all providers for a chain and determines
  which providers should be active based on:
  - Connection health and latency
  - Provider priority and reliability scores
  - Rate limiting and error rates
  - Automatic failover on provider failures

  """

  use GenServer
  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Events.Provider
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{ChainState, RateLimitState}

  @type t :: %__MODULE__{
          profile: profile(),
          chain_name: chain_name(),
          providers: %{provider_id() => __MODULE__.ProviderState.t()},
          active_providers: [provider_id()],
          total_requests: non_neg_integer(),
          failed_requests: non_neg_integer(),
          circuit_states: circuit_states(),
          recovery_times: recovery_times(),
          rate_limit_states: rate_limit_states()
        }

  @type circuit_states :: %{provider_id() => %{http: circuit_state(), ws: circuit_state()}}
  @type circuit_state :: :closed | :open | :half_open
  @type recovery_times :: %{
          provider_id() => %{http: non_neg_integer() | nil, ws: non_neg_integer() | nil}
        }
  @type circuit_errors :: %{
          provider_id() => %{http: map() | nil, ws: map() | nil}
        }
  @type rate_limit_states :: %{provider_id() => RateLimitState.t()}

  defstruct [
    :profile,
    :chain_name,
    :providers,
    :active_providers,
    # ETS table for sync state and lag tracking
    :table,
    total_requests: 0,
    failed_requests: 0,
    # Circuit breaker state per provider and transport: %{provider_id => %{http: state, ws: state}}
    circuit_states: %{},
    # Cached recovery times per provider: %{provider_id => %{http: ms | nil, ws: ms | nil}}
    # Updated when circuit states change to avoid N sequential GenServer calls
    recovery_times: %{},
    # Errors that caused circuits to open: %{provider_id => %{http: error_map | nil, ws: error_map | nil}}
    # Cleared when circuit closes, used for dashboard display
    circuit_errors: %{},
    # Rate limit state per provider (time-based, independent of circuit breaker)
    rate_limit_states: %{}
  ]

  defmodule ProviderState do
    @moduledoc """
    Runtime state for a single provider within a chain's pool.

    Health status is tracked directly on this struct. Circuit breaker
    handles transport-specific routing decisions (rate limiting, failures).
    """

    @type t :: %__MODULE__{
            id: Lasso.RPC.ProviderPool.provider_id(),
            config: map(),
            pid: pid() | nil,
            status: health_status(),
            http_status: health_status() | nil,
            ws_status: health_status() | nil,
            last_health_check: integer(),
            consecutive_failures: non_neg_integer(),
            consecutive_successes: non_neg_integer(),
            last_error: term() | nil,
            reconnect_attempts: non_neg_integer(),
            reconnect_grace_until: integer() | nil
          }

    # Note: :rate_limited is NOT a health status - rate limits are tracked via RateLimitState
    @type health_status ::
            :healthy
            | :unhealthy
            | :connecting
            | :disconnected
            | :degraded

    @derive Jason.Encoder
    defstruct [
      :id,
      :config,
      :pid,
      # Health status of the provider (aggregate of transports)
      :status,
      # Transport-specific status (if configured)
      :http_status,
      :ws_status,
      :last_health_check,
      :consecutive_failures,
      :consecutive_successes,
      :last_error,
      # WebSocket reconnection tracking
      reconnect_attempts: 0,
      reconnect_grace_until: nil
    ]
  end

  @type profile :: String.t()
  @type chain_name :: String.t()
  @type provider_id :: String.t()
  @type strategy :: :priority | :round_robin | :fastest | :cheapest | :latency_weighted
  # Note: :rate_limited is NOT a health status - rate limits are tracked via RateLimitState
  @type health_status ::
          :healthy
          | :unhealthy
          | :connecting
          | :disconnected
          | :degraded

  # Default timeout for ProviderPool GenServer calls (5 seconds)
  # ProviderPool operations are generally fast but can be delayed under high load
  @call_timeout 5_000

  # Failure threshold for marking provider as unhealthy
  @failure_threshold 3

  @doc """
  Starts the ProviderPool for a profile/chain pair.

  Accepts either `{profile, chain_name, chain_config}` (profile-aware) or
  `{chain_name, chain_config}` (backward compatible, uses "default" profile).
  """
  @spec start_link({profile, chain_name, map()} | {chain_name, map()}) :: GenServer.on_start()
  def start_link({profile, chain_name, chain_config}) when is_binary(profile) do
    GenServer.start_link(__MODULE__, {profile, chain_name, chain_config},
      name: via_name(profile, chain_name)
    )
  end

  def start_link({chain_name, chain_config}) do
    start_link({"default", chain_name, chain_config})
  end

  @doc """
  Registers a provider's configuration with the pool (no pid).
  """
  @spec register_provider(profile, chain_name, provider_id, map()) :: :ok
  def register_provider(profile, chain_name, provider_id, provider_config) do
    GenServer.call(
      via_name(profile, chain_name),
      {:register_provider, provider_id, provider_config}
    )
  end

  @doc """
  Attaches a WebSocket connection pid to an already-registered provider.
  The pid will be monitored.
  """
  @spec attach_ws_connection(profile, chain_name, provider_id, pid()) :: :ok | {:error, term()}
  def attach_ws_connection(profile, chain_name, provider_id, pid) do
    GenServer.call(via_name(profile, chain_name), {:attach_ws_connection, provider_id, pid})
  end

  @doc """
  Gets all currently active providers.

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use get_active_providers(profile, chain_name) instead with explicit profile parameter"
  @spec get_active_providers(chain_name) :: [provider_id]
  def get_active_providers(chain_name) do
    IO.warn(
      "ProviderPool.get_active_providers/1 defaults to 'default' profile. Pass profile explicitly."
    )

    get_active_providers("default", chain_name)
  end

  @spec get_active_providers(profile, chain_name) :: [provider_id]
  def get_active_providers(profile, chain_name) do
    GenServer.call(via_name(profile, chain_name), :get_active_providers)
  end

  @doc """
  Gets the health status of all providers.

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use get_status(profile, chain_name) instead with explicit profile parameter"
  @spec get_status(chain_name) :: {:ok, map()} | {:error, term()}
  def get_status(chain_name) do
    IO.warn("ProviderPool.get_status/1 defaults to 'default' profile. Pass profile explicitly.")
    get_status("default", chain_name)
  end

  @spec get_status(profile, chain_name) :: {:ok, map()} | {:error, term()}
  def get_status(profile, chain_name) do
    GenServer.call(via_name(profile, chain_name), :get_status, @call_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout getting status for chain #{chain_name}")
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :not_found}
  end

  @doc """
  Lists provider candidates enriched with policy-derived availability for selection.

  Supported filters:
  - protocol: :http | :ws | :both
  - exclude: [provider_id]
  - include_half_open: boolean (default false) - include providers with half-open circuits
  - max_lag_blocks: integer (optional) - exclude providers lagging more than N blocks behind best known height

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use list_candidates(profile, chain_name, filters) instead with explicit profile parameter"
  @spec list_candidates(chain_name, map()) :: [map()]
  def list_candidates(chain_name, filters \\ %{}) when is_map(filters) do
    IO.warn(
      "ProviderPool.list_candidates/2 defaults to 'default' profile. Pass profile explicitly."
    )

    list_candidates("default", chain_name, filters)
  end

  @spec list_candidates(profile, chain_name, map()) :: [map()]
  def list_candidates(profile, chain_name, filters) when is_binary(profile) and is_map(filters) do
    GenServer.call(via_name(profile, chain_name), {:list_candidates, filters}, @call_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout listing candidates for chain #{chain_name}")
      # Return empty list on timeout (fail closed)
      []

    :exit, {:noproc, _} ->
      []
  end

  @doc """
  Reports a successful operation (no latency needed; performance is tracked elsewhere).
  If transport is provided, updates the corresponding transport policy/status.

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use report_success(profile, chain_name, provider_id, transport) instead with explicit profile parameter"
  @spec report_success(chain_name, provider_id) :: :ok
  def report_success(chain_name, provider_id) do
    IO.warn(
      "ProviderPool.report_success/2 defaults to 'default' profile. Pass profile explicitly."
    )

    report_success("default", chain_name, provider_id, nil)
  end

  @deprecated "Use report_success(profile, chain_name, provider_id, transport) instead with explicit profile parameter"
  @spec report_success(chain_name, provider_id, :http | :ws | nil) :: :ok
  def report_success(chain_name, provider_id, transport) when transport in [:http, :ws, nil] do
    IO.warn(
      "ProviderPool.report_success/3 defaults to 'default' profile. Pass profile explicitly."
    )

    report_success("default", chain_name, provider_id, transport)
  end

  @spec report_success(profile, chain_name, provider_id, :http | :ws | nil) :: :ok
  def report_success(profile, chain_name, provider_id, transport)
      when is_binary(profile) and transport in [:http, :ws, nil] do
    GenServer.cast(via_name(profile, chain_name), {:report_success, provider_id, transport})
  end

  @doc """
  Reports a failure for error rate tracking. If transport is provided, updates that transport.

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use report_failure(profile, chain_name, provider_id, error, transport) instead with explicit profile parameter"
  @spec report_failure(chain_name, provider_id, term()) :: :ok
  def report_failure(chain_name, provider_id, error) do
    IO.warn(
      "ProviderPool.report_failure/3 defaults to 'default' profile. Pass profile explicitly."
    )

    report_failure("default", chain_name, provider_id, error, nil)
  end

  @deprecated "Use report_failure(profile, chain_name, provider_id, error, transport) instead with explicit profile parameter"
  @spec report_failure(chain_name, provider_id, term(), :http | :ws | nil) :: :ok
  def report_failure(chain_name, provider_id, error, transport)
      when transport in [:http, :ws, nil] do
    IO.warn(
      "ProviderPool.report_failure/4 defaults to 'default' profile. Pass profile explicitly."
    )

    report_failure("default", chain_name, provider_id, error, transport)
  end

  @spec report_failure(profile, chain_name, provider_id, term(), :http | :ws | nil) :: :ok
  def report_failure(profile, chain_name, provider_id, error, transport)
      when is_binary(profile) and transport in [:http, :ws, nil] do
    GenServer.cast(
      via_name(profile, chain_name),
      {:report_failure, provider_id, error, transport}
    )
  end

  @doc """
  Unregisters a provider from the pool (for test cleanup).

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use unregister_provider(profile, chain_name, provider_id) instead with explicit profile parameter"
  @spec unregister_provider(chain_name, provider_id) :: :ok
  def unregister_provider(chain_name, provider_id) do
    IO.warn(
      "ProviderPool.unregister_provider/2 defaults to 'default' profile. Pass profile explicitly."
    )

    unregister_provider("default", chain_name, provider_id)
  end

  @spec unregister_provider(profile, chain_name, provider_id) :: :ok
  def unregister_provider(profile, chain_name, provider_id) do
    GenServer.call(via_name(profile, chain_name), {:unregister_provider, provider_id})
  end

  @doc """
  Gets the WebSocket PID for a provider (for chaos testing).

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use get_provider_ws_pid(profile, chain_name, provider_id) instead with explicit profile parameter"
  @spec get_provider_ws_pid(chain_name, provider_id) :: {:ok, pid()} | {:error, :not_found}
  def get_provider_ws_pid(chain_name, provider_id) do
    IO.warn(
      "ProviderPool.get_provider_ws_pid/2 defaults to 'default' profile. Pass profile explicitly."
    )

    get_provider_ws_pid("default", chain_name, provider_id)
  end

  @spec get_provider_ws_pid(profile, chain_name, provider_id) ::
          {:ok, pid()} | {:error, :not_found}
  def get_provider_ws_pid(profile, chain_name, provider_id) do
    GenServer.call(via_name(profile, chain_name), {:get_provider_ws_pid, provider_id})
  end

  @doc """
  Gets recovery times for all open circuit breakers in the pool.

  Returns a map of provider_id => %{http: ms | nil, ws: ms | nil} where:
  - ms is milliseconds until circuit breaker will attempt recovery
  - nil means circuit is not open or recovery time unavailable

  This is cached in ProviderPool state and updated when circuit states change,
  avoiding expensive GenServer calls to each CircuitBreaker.

  ## Options
  - `:transport` - Filter by :http, :ws, or :both (default: :both)
  - `:only_open` - Only return entries for open circuits (default: true)

  Accepts optional profile as first argument (defaults to "default").

  ## Examples

      iex> ProviderPool.get_recovery_times("ethereum")
      {:ok, %{
        "alchemy_ethereum" => %{http: nil, ws: 30_000},
        "quicknode_ethereum" => %{http: 15_000, ws: nil}
      }}
  """
  @deprecated "Use get_recovery_times(profile, chain_name, opts) instead with explicit profile parameter"
  @spec get_recovery_times(chain_name, keyword()) ::
          {:ok, %{provider_id => %{http: non_neg_integer() | nil, ws: non_neg_integer() | nil}}}
          | {:error, term()}
  def get_recovery_times(chain_name, opts \\ []) do
    IO.warn(
      "ProviderPool.get_recovery_times/2 defaults to 'default' profile. Pass profile explicitly."
    )

    get_recovery_times("default", chain_name, opts)
  end

  @spec get_recovery_times(profile, chain_name, keyword()) ::
          {:ok, %{provider_id => %{http: non_neg_integer() | nil, ws: non_neg_integer() | nil}}}
          | {:error, term()}
  def get_recovery_times(profile, chain_name, opts) when is_binary(profile) do
    timeout = Keyword.get(opts, :timeout, 5000)

    try do
      GenServer.call(via_name(profile, chain_name), {:get_recovery_times, opts}, timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("Timeout getting recovery times for chain #{chain_name}")
        {:error, :timeout}

      :exit, {:noproc, _} ->
        Logger.warning("ProviderPool not found for chain #{chain_name}")
        {:error, :not_found}
    end
  end

  @doc """
  Gets the minimum recovery time across all open circuits for a chain.

  This is a convenience function that calls get_recovery_times/2 and returns
  the minimum value, or nil if no recovery times available.

  ## Options
  - `:transport` - Filter by :http, :ws, or :both (default: :both)
  - `:timeout` - GenServer call timeout in ms (default: 5000)

  Accepts optional profile as first argument (defaults to "default").

  ## Examples

      iex> ProviderPool.get_min_recovery_time("ethereum", transport: :http)
      {:ok, 15_000}

      iex> ProviderPool.get_min_recovery_time("ethereum")
      {:ok, nil}  # No open circuits
  """
  @deprecated "Use get_min_recovery_time(profile, chain_name, opts) instead with explicit profile parameter"
  @spec get_min_recovery_time(chain_name, keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def get_min_recovery_time(chain_name, opts \\ []) do
    IO.warn(
      "ProviderPool.get_min_recovery_time/2 defaults to 'default' profile. Pass profile explicitly."
    )

    get_min_recovery_time("default", chain_name, opts)
  end

  @spec get_min_recovery_time(profile, chain_name, keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def get_min_recovery_time(profile, chain_name, opts) when is_binary(profile) do
    transport_filter = Keyword.get(opts, :transport, :both)

    case get_recovery_times(profile, chain_name, opts) do
      {:ok, times_map} ->
        min_time =
          times_map
          |> Enum.flat_map(fn {_provider_id, transports} ->
            case transport_filter do
              :http -> [Map.get(transports, :http)]
              :ws -> [Map.get(transports, :ws)]
              :both -> [Map.get(transports, :http), Map.get(transports, :ws)]
              _ -> [Map.get(transports, :http), Map.get(transports, :ws)]
            end
          end)
          |> Enum.filter(&(is_integer(&1) and &1 > 0))
          |> case do
            [] -> nil
            times -> Enum.min(times)
          end

        {:ok, min_time}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Reports probe results from ProviderProbe (called by ProviderProbe).
  Results are processed in batch to maintain consistency.

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use report_probe_results(profile, chain_name, results) instead with explicit profile parameter"
  @spec report_probe_results(chain_name, [map()]) :: :ok
  def report_probe_results(chain_name, results) when is_list(results) do
    IO.warn(
      "ProviderPool.report_probe_results/2 defaults to 'default' profile. Pass profile explicitly."
    )

    report_probe_results("default", chain_name, results)
  end

  @spec report_probe_results(profile, chain_name, [map()]) :: :ok
  def report_probe_results(profile, chain_name, results)
      when is_binary(profile) and is_list(results) do
    GenServer.cast(via_name(profile, chain_name), {:probe_results, results})
  end

  @doc """
  Reports a newHeads update from WebSocket subscription (future use).

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use report_newheads(profile, chain_name, provider_id, block_height) instead with explicit profile parameter"
  @spec report_newheads(chain_name, provider_id, non_neg_integer()) :: :ok
  def report_newheads(chain_name, provider_id, block_height) do
    IO.warn(
      "ProviderPool.report_newheads/3 defaults to 'default' profile. Pass profile explicitly."
    )

    report_newheads("default", chain_name, provider_id, block_height)
  end

  @spec report_newheads(profile, chain_name, provider_id, non_neg_integer()) :: :ok
  def report_newheads(profile, chain_name, provider_id, block_height) when is_binary(profile) do
    GenServer.cast(via_name(profile, chain_name), {:newheads, provider_id, block_height})
  end

  @doc """
  Gets the ETS table name for a chain.
  Used by ChainState for consensus calculations.

  Note: ETS tables are chain-scoped (not profile-scoped) since sync data is global.
  """
  @spec table_name(chain_name) :: atom()
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  def table_name(chain_name), do: :"provider_pool_#{chain_name}"

  # GenServer callbacks

  @impl true
  def init({profile, chain_name, chain_config}) do
    # Subscribe to global circuit events and profile-scoped WS connection events
    Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events:#{profile}:#{chain_name}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{profile}:#{chain_name}")

    # Subscribe to profile-scoped block sync and health probe events
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:#{profile}:#{chain_name}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "health_probe:#{profile}:#{chain_name}")

    # Also subscribe to legacy topics for backward compatibility during migration
    Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain_name}")

    # Create ETS table for sync state and lag tracking
    # ETS table is chain-scoped (shared across profiles) since sync data is global
    table =
      case :ets.whereis(table_name(chain_name)) do
        :undefined ->
          :ets.new(table_name(chain_name), [
            :set,
            :public,
            :named_table,
            read_concurrency: true
          ])

        existing ->
          existing
      end

    # Pre-populate providers from chain_config to survive restarts
    # This ensures providers are immediately available even if async Task fails
    initial_providers =
      (chain_config.providers || [])
      |> Enum.map(fn provider ->
        {provider.id,
         %ProviderState{
           id: provider.id,
           config: provider,
           pid: nil,
           status: :connecting,
           http_status: if(is_binary(Map.get(provider, :url)), do: :connecting, else: nil),
           ws_status: if(is_binary(Map.get(provider, :ws_url)), do: :connecting, else: nil),
           last_health_check: System.system_time(:millisecond),
           consecutive_failures: 0,
           consecutive_successes: 0,
           last_error: nil
         }}
      end)
      |> Enum.into(%{})

    state = %__MODULE__{
      profile: profile,
      chain_name: chain_name,
      table: table,
      providers: initial_providers,
      active_providers: Map.keys(initial_providers),
      total_requests: 0,
      failed_requests: 0,
      circuit_states: %{},
      recovery_times: %{}
    }

    if map_size(initial_providers) > 0 do
      Logger.info(
        "ProviderPool initialized for #{profile}/#{chain_name} with #{map_size(initial_providers)} providers"
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:register_provider, provider_id, provider_config}, _from, state) do
    existing = Map.get(state.providers, provider_id)

    provider_state =
      case existing do
        nil ->
          %ProviderState{
            id: provider_id,
            config: provider_config,
            pid: nil,
            status: :connecting,
            http_status:
              if(is_binary(Map.get(provider_config, :url)), do: :connecting, else: nil),
            ws_status:
              if(is_binary(Map.get(provider_config, :ws_url)), do: :connecting, else: nil),
            last_health_check: System.system_time(:millisecond),
            consecutive_failures: 0,
            consecutive_successes: 0,
            last_error: nil
          }

        %ProviderState{} = prev ->
          # Preserve pid and all metrics; refresh config only
          %{prev | config: provider_config}
      end

    new_state =
      state
      |> Map.update!(:providers, &Map.put(&1, provider_id, provider_state))
      |> update_active_providers()

    Logger.info("Registered provider #{provider_id} for #{state.chain_name}")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:attach_ws_connection, provider_id, pid}, _from, state) when is_pid(pid) do
    case Map.get(state.providers, provider_id) do
      %ProviderState{} = prev ->
        updated =
          prev
          |> Map.put(:pid, pid)
          |> Map.put(:ws_status, prev.ws_status || :connecting)
          |> Map.put(:status, derive_aggregate_status(prev))

        new_state =
          state
          |> Map.update!(:providers, &Map.put(&1, provider_id, updated))
          |> update_active_providers()

        Logger.info(
          "Attached WS pid to provider #{provider_id} for #{state.chain_name}: #{inspect(pid)}"
        )

        {:reply, :ok, new_state}

      nil ->
        {:reply, {:error, :not_registered}, state}
    end
  end

  @impl true
  def handle_call(:get_active_providers, _from, state) do
    {:reply, state.active_providers, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    providers =
      Enum.map(state.providers, fn {id, provider} ->
        # Normalize circuit_state format - ensure map structure
        circuit_state_normalized =
          normalize_circuit_state(Map.get(state.circuit_states, id, :closed))

        http_cb_state = get_cb_state(state.circuit_states, id, :http)
        ws_cb_state = get_cb_state(state.circuit_states, id, :ws)

        # Get circuit errors (error that caused circuit to open)
        circuit_errors = Map.get(state.circuit_errors, id, %{http: nil, ws: nil})
        http_cb_error = Map.get(circuit_errors, :http)
        ws_cb_error = Map.get(circuit_errors, :ws)

        # Get recovery times from cached state (avoids GenServer call cascade)
        recovery_times = Map.get(state.recovery_times, id, %{http: nil, ws: nil})
        http_recovery = Map.get(recovery_times, :http)
        ws_recovery = Map.get(recovery_times, :ws)

        # Get rate limit state from RateLimitState (independent of circuit breaker)
        rate_limit_state = Map.get(state.rate_limit_states, id)
        now_ms = System.monotonic_time(:millisecond)

        http_rate_limited =
          rate_limit_state != nil and
            RateLimitState.rate_limited?(rate_limit_state, :http, now_ms)

        ws_rate_limited =
          rate_limit_state != nil and RateLimitState.rate_limited?(rate_limit_state, :ws, now_ms)

        # Rate limit time remaining (for dashboard display)
        rate_limit_remaining =
          if rate_limit_state do
            http_remaining = RateLimitState.time_remaining(rate_limit_state, :http, now_ms)
            ws_remaining = RateLimitState.time_remaining(rate_limit_state, :ws, now_ms)
            %{http: http_remaining, ws: ws_remaining}
          else
            %{http: nil, ws: nil}
          end

        # For backwards compatibility, is_in_cooldown is true if any transport is rate limited
        is_in_cooldown = http_rate_limited or ws_rate_limited

        # Cooldown until is the max rate limit expiry time
        cooldown_until =
          case {rate_limit_remaining.http, rate_limit_remaining.ws} do
            {nil, nil} -> nil
            {http, nil} -> now_ms + http
            {nil, ws} -> now_ms + ws
            {http, ws} -> now_ms + max(http, ws)
          end

        # Derive availability from status (single source of truth)
        availability = status_to_availability(provider.status)
        http_availability = status_to_availability(provider.http_status)
        ws_availability = status_to_availability(provider.ws_status)

        %{
          id: id,
          name: Map.get(provider.config, :name, id),
          config: provider.config,
          status: provider.status,
          http_status: provider.http_status,
          ws_status: provider.ws_status,
          # Derived availability (from status)
          availability: availability,
          http_availability: http_availability,
          ws_availability: ws_availability,
          # Rate limit state (from RateLimitState, independent of circuit breaker)
          http_rate_limited: http_rate_limited,
          ws_rate_limited: ws_rate_limited,
          rate_limit_remaining: rate_limit_remaining,
          # Legacy cooldown fields (for backwards compatibility)
          is_in_cooldown: is_in_cooldown,
          cooldown_until: cooldown_until,
          # Circuit breaker state (normalized to map format)
          circuit_state: circuit_state_normalized,
          http_cb_state: http_cb_state,
          ws_cb_state: ws_cb_state,
          # Circuit breaker errors (error that caused circuit to open)
          http_cb_error: http_cb_error,
          ws_cb_error: ws_cb_error,
          # Circuit breaker recovery times
          http_recovery: http_recovery,
          ws_recovery: ws_recovery,
          # Provider metrics
          consecutive_failures: provider.consecutive_failures,
          consecutive_successes: provider.consecutive_successes,
          last_health_check: provider.last_health_check,
          last_error: provider.last_error
        }
      end)

    healthy_count = Enum.count(providers, &(&1.status == :healthy))

    status = %{
      chain_name: state.chain_name,
      total_providers: map_size(state.providers),
      healthy_providers: healthy_count,
      active_providers: length(state.active_providers),
      total_requests: state.total_requests,
      failed_requests: state.failed_requests,
      providers: providers,
      circuit_states: state.circuit_states
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:list_candidates, filters}, _from, state) do
    candidates =
      state
      |> candidates_ready(filters)
      |> Enum.map(fn p ->
        %{
          id: p.id,
          config: p.config,
          availability: status_to_availability(p.status),
          # Include circuit state per transport for selection tiering
          circuit_state: %{
            http: get_cb_state(state.circuit_states, p.id, :http),
            ws: get_cb_state(state.circuit_states, p.id, :ws)
          },
          # Include rate limit state per transport (independent of circuit breaker)
          rate_limited: get_rate_limit_state(state, p.id)
        }
      end)

    {:reply, candidates, state}
  end

  @impl true
  def handle_call({:unregister_provider, provider_id}, _from, state) do
    new_providers = Map.delete(state.providers, provider_id)
    new_state = %{state | providers: new_providers}
    new_state = update_active_providers(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_provider_ws_pid, provider_id}, _from, state) do
    case Map.get(state.providers, provider_id) do
      %{pid: pid} when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_recovery_times, opts}, _from, state) do
    transport_filter = Keyword.get(opts, :transport, :both)
    only_open = Keyword.get(opts, :only_open, true)

    result =
      state.recovery_times
      |> Enum.filter(fn {provider_id, _times} ->
        if only_open do
          # Only include if at least one circuit is open for the requested transport(s)
          http_state = get_cb_state(state.circuit_states, provider_id, :http)
          ws_state = get_cb_state(state.circuit_states, provider_id, :ws)

          case transport_filter do
            :http -> http_state == :open
            :ws -> ws_state == :open
            :both -> http_state == :open or ws_state == :open
            _ -> http_state == :open or ws_state == :open
          end
        else
          true
        end
      end)
      |> Enum.into(%{})

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_cast({:report_success, provider_id}, state) do
    new_state = update_provider_success(state, provider_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_failure, provider_id, error}, state) do
    new_state = update_provider_failure(state, provider_id, error)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_success, provider_id, :http}, state),
    do: {:noreply, update_provider_success_http(state, provider_id)}

  def handle_cast({:report_success, provider_id, :ws}, state),
    do: {:noreply, update_provider_success_ws(state, provider_id)}

  def handle_cast({:report_success, provider_id, nil}, state),
    do: {:noreply, update_provider_success(state, provider_id)}

  @impl true
  def handle_cast({:probe_results, results}, state) do
    # Process ALL results in batch (avoid race conditions)
    state = apply_probe_batch(state, results)
    {:noreply, state}
  end

  # Handle newHeads update from WebSocket subscriptions (via BlockHeightMonitor)
  @impl true
  def handle_cast({:newheads, provider_id, block_height}, state) do
    timestamp = System.system_time(:millisecond)
    sequence = get_current_sequence(state)

    # Store sync state (same format as probe results)
    :ets.insert(
      state.table,
      {{:provider_sync, state.chain_name, provider_id}, {block_height, timestamp, sequence}}
    )

    # Calculate and store lag, broadcast update (mirrors HTTP probe behavior)
    case ChainState.consensus_height(state.chain_name) do
      {:ok, consensus_height} ->
        lag = block_height - consensus_height

        # Store lag for fallback path in ChainState.provider_lag
        :ets.insert(
          state.table,
          {{:provider_lag, state.chain_name, provider_id}, lag}
        )

        # Broadcast sync update for dashboard live updates
        Phoenix.PubSub.broadcast(Lasso.PubSub, "sync:updates", %{
          chain: state.chain_name,
          provider_id: provider_id,
          block_height: block_height,
          consensus_height: consensus_height,
          lag: lag
        })

      {:error, _reason} ->
        # No consensus available - can't calculate lag yet
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:report_failure, provider_id, error, :http}, state),
    do: {:noreply, update_provider_failure_http(state, provider_id, error)}

  def handle_cast({:report_failure, provider_id, error, :ws}, state),
    do: {:noreply, update_provider_failure_ws(state, provider_id, error)}

  def handle_cast({:report_failure, provider_id, error, nil}, state),
    do: {:noreply, update_provider_failure(state, provider_id, error)}

  # Async recovery time update from background Task (spawned in update_recovery_time_for_circuit)
  @impl true
  def handle_cast({:update_recovery_time_async, provider_id, transport, recovery_time}, state) do
    # Only update if circuit is still open (avoid stale data from async race)
    circuit_state = get_cb_state(state.circuit_states, provider_id, transport)

    new_state =
      if circuit_state in [:open, :half_open] do
        provider_times = Map.get(state.recovery_times, provider_id, %{http: nil, ws: nil})
        updated_times = Map.put(provider_times, transport, recovery_time)
        new_recovery_times = Map.put(state.recovery_times, provider_id, updated_times)
        %{state | recovery_times: new_recovery_times}
      else
        state
      end

    {:noreply, new_state}
  end

  # WebSocket connection established
  @impl true
  def handle_info({:ws_connected, provider_id, _connection_id}, state) do
    handle_ws_connected(provider_id, state)
  end

  @impl true
  def handle_info({:ws_closed, provider_id, code, %_{} = jerr}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated =
          provider
          |> Map.put(:ws_status, :disconnected)
          |> Map.put(:status, derive_aggregate_status(provider))
          |> Map.put(:consecutive_failures, provider.consecutive_failures + 1)
          |> Map.put(:last_error, jerr)
          |> Map.put(:last_health_check, System.system_time(:millisecond))

        event_details = %{code: code, reason: jerr.message}
        publish_provider_event(state.chain_name, provider_id, :ws_closed, event_details)

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:ws_disconnected, provider_id, %_{} = jerr}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated =
          provider
          |> Map.put(:ws_status, :disconnected)
          |> Map.put(:status, derive_aggregate_status(provider))
          |> Map.put(:consecutive_failures, provider.consecutive_failures + 1)
          |> Map.put(:last_error, jerr)
          |> Map.put(:last_health_check, System.system_time(:millisecond))

        event_details = %{reason: jerr.message}
        publish_provider_event(state.chain_name, provider_id, :ws_closed, event_details)

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:ws_reconnecting, provider_id, attempt}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated =
          provider
          |> Map.put(:reconnect_attempts, attempt)
          |> Map.put(:ws_status, :connecting)
          |> Map.put(:status, derive_aggregate_status(provider))

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:clear_reconnect_grace, provider_id}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        # Only clear if grace period has actually expired
        now = System.monotonic_time(:millisecond)
        grace_until = provider.reconnect_grace_until

        if grace_until && now >= grace_until do
          updated =
            provider
            |> Map.put(:reconnect_attempts, 0)
            |> Map.put(:reconnect_grace_until, nil)
            |> Map.put(:status, derive_aggregate_status(provider))

          new_state = put_provider_and_refresh(state, provider_id, updated)
          {:noreply, new_state}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:connection_error, provider_id, %_{} = jerr}, state) do
    # Treat connection error as a failure signal; reuse existing failure path
    new_state = update_provider_failure(state, provider_id, jerr)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {:circuit_breaker_event,
         %{chain: event_chain, provider_id: provider_id, transport: transport, from: from, to: to} =
           event_data},
        state
      )
      when is_binary(provider_id) and from in [:closed, :open, :half_open] and
             to in [:closed, :open, :half_open] do
    # Only handle circuit breaker events for THIS chain
    if event_chain == state.chain_name or is_nil(event_chain) do
      Logger.info(
        "ProviderPool[#{state.chain_name}]: CB event #{provider_id}:#{transport} #{from} -> #{to}"
      )

      # Update circuit states
      new_circuit_states = update_circuit_state(state.circuit_states, provider_id, transport, to)

      # Update recovery times cache when circuit opens or transitions
      new_recovery_times =
        if to in [:open, :half_open] do
          update_recovery_time_for_circuit(
            state.recovery_times,
            provider_id,
            transport,
            state.profile,
            state.chain_name
          )
        else
          # Circuit closed, clear recovery time
          clear_recovery_time(state.recovery_times, provider_id, transport)
        end

      # Update circuit errors - store error when opening, clear when closing
      new_circuit_errors =
        if to == :open do
          # Extract error from event (added by circuit breaker when opening)
          error_info = Map.get(event_data, :error)
          update_circuit_error(state.circuit_errors, provider_id, transport, error_info)
        else
          if to == :closed do
            # Clear error when circuit closes
            clear_circuit_error(state.circuit_errors, provider_id, transport)
          else
            # half_open: keep existing error
            state.circuit_errors
          end
        end

      # Note: Rate limits are now managed independently via RateLimitState
      # They auto-expire based on Retry-After timing, not circuit breaker state

      {:noreply,
       %{
         state
         | circuit_states: new_circuit_states,
           recovery_times: new_recovery_times,
           circuit_errors: new_circuit_errors
       }}
    else
      # Ignore events from other chains
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(%Provider.Healthy{provider_id: provider_id, ts: ts}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :healthy,
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            last_health_check: ts
        }

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(%Provider.Unhealthy{provider_id: provider_id, ts: ts, reason: reason}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :unhealthy,
            consecutive_failures: provider.consecutive_failures + 1,
            last_error: reason,
            last_health_check: ts
        }

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(%Provider.WSConnected{provider_id: provider_id, ts: ts}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :healthy,
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            last_health_check: ts
        }

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(%Provider.WSClosed{provider_id: provider_id, ts: ts, reason: reason}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :disconnected,
            consecutive_failures: provider.consecutive_failures + 1,
            last_error: {:ws_closed, reason},
            last_health_check: ts
        }

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(
        %Provider.WSDisconnected{provider_id: provider_id, ts: ts, reason: reason},
        state
      ) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :disconnected,
            consecutive_failures: provider.consecutive_failures + 1,
            last_error: {:ws_disconnected, reason},
            last_health_check: ts
        }

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find the provider that went down
    case Enum.find(state.providers, fn {_id, provider} -> provider.pid == pid end) do
      {provider_id, provider} ->
        case reason do
          {exception, stacktrace} when is_list(stacktrace) ->
            formatted = Exception.format(:error, exception, stacktrace)
            Logger.error("Provider #{provider_id} process crashed\n" <> formatted)

          other ->
            Logger.warning("Provider #{provider_id} process died: #{inspect(other)}")
        end

        new_provider = %{
          provider
          | status: :disconnected,
            consecutive_failures: provider.consecutive_failures + 1
        }

        new_providers = Map.put(state.providers, provider_id, new_provider)
        new_state = %{state | providers: new_providers}
        new_state = update_active_providers(new_state)
        {:noreply, new_state}

      nil ->
        Logger.debug("Unknown process died: #{inspect(pid)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:block_height_update, {_profile, provider_id}, height, source, timestamp},
        state
      ) do
    # Update ETS height tracking
    sequence = get_current_sequence(state)

    :ets.insert(
      state.table,
      {{:provider_sync, state.chain_name, provider_id}, {height, timestamp, sequence}}
    )

    # Calculate and broadcast lag if consensus height is available
    case ChainState.consensus_height(state.chain_name) do
      {:ok, consensus_height} ->
        lag = height - consensus_height
        :ets.insert(state.table, {{:provider_lag, state.chain_name, provider_id}, lag})

        Phoenix.PubSub.broadcast(Lasso.PubSub, "sync:updates", %{
          chain: state.chain_name,
          provider_id: provider_id,
          block_height: height,
          consensus_height: consensus_height,
          lag: lag,
          source: source
        })

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:health_probe_recovery, {_profile, provider_id}, transport, old_state, _new_state, _ts},
        state
      ) do
    Logger.debug("ProviderPool received health probe recovery",
      provider_id: provider_id,
      transport: transport,
      after_failures: old_state.consecutive_failures
    )

    {:noreply, state}
  end

  # Handler for ws_connected events (extracted to avoid clause ordering warning)
  defp handle_ws_connected(provider_id, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        # Set grace period: keep reconnect_attempts for 30s after reconnection
        # This allows dashboard to show "Reconnecting" status while provider stabilizes
        grace_period_ms = 30_000
        grace_until = System.monotonic_time(:millisecond) + grace_period_ms

        updated =
          provider
          |> Map.put(:ws_status, :healthy)
          |> Map.put(:status, derive_aggregate_status(provider))
          |> Map.put(:consecutive_successes, provider.consecutive_successes + 1)
          |> Map.put(:consecutive_failures, 0)
          |> Map.put(:last_health_check, System.system_time(:millisecond))
          |> Map.put(:reconnect_grace_until, grace_until)

        # Schedule grace period cleanup
        Process.send_after(self(), {:clear_reconnect_grace, provider_id}, grace_period_ms)

        publish_provider_event(state.chain_name, provider_id, :ws_connected, %{})
        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  # Private functions

  @spec candidates_ready(t(), map()) :: [ProviderState.t()]
  defp candidates_ready(state, filters) do
    max_lag_blocks = Map.get(filters, :max_lag_blocks)
    current_time = System.monotonic_time(:millisecond)
    protocol = Map.get(filters, :protocol)

    state.active_providers
    |> Enum.map(&Map.get(state.providers, &1))
    |> Enum.filter(&provider_passes_filters?(&1, state, filters, protocol, current_time))
    |> filter_by_lag(state.chain_name, max_lag_blocks)
    |> filter_excluded(filters)
  end

  defp provider_passes_filters?(provider, state, filters, protocol, current_time) do
    transport_ready?(provider, protocol, current_time) and
      circuit_breaker_ready?(provider, state.circuit_states, protocol, filters) and
      rate_limit_ok?(provider, state, protocol, current_time, filters)
  end

  defp transport_ready?(provider, protocol, current_time) do
    case protocol do
      :http ->
        transport_available?(provider, :http, current_time)

      :ws ->
        transport_available?(provider, :ws, current_time) and
          is_pid(ws_connection_pid(provider.id))

      :both ->
        transport_available?(provider, :http, current_time) or
          (transport_available?(provider, :ws, current_time) and
             is_pid(ws_connection_pid(provider.id)))

      _ ->
        transport_available?(provider, :http, current_time) or
          transport_available?(provider, :ws, current_time)
    end
  end

  defp circuit_breaker_ready?(provider, circuit_states, protocol, filters) do
    include_half_open = Map.get(filters, :include_half_open, false)

    case protocol do
      :http ->
        cb_ready?(get_cb_state(circuit_states, provider.id, :http), include_half_open)

      :ws ->
        cb_ready?(get_cb_state(circuit_states, provider.id, :ws), include_half_open)

      _ ->
        check_any_transport_cb_ready(provider, circuit_states, include_half_open)
    end
  end

  defp cb_ready?(cb_state, include_half_open) do
    if include_half_open, do: cb_state != :open, else: cb_state == :closed
  end

  defp check_any_transport_cb_ready(provider, circuit_states, include_half_open) do
    # For :both or nil protocol, include provider if it has at least one viable transport
    # A transport is viable if: 1) it's configured, 2) CB is not open (or half-open allowed)
    http_state = get_cb_state(circuit_states, provider.id, :http)
    ws_state = get_cb_state(circuit_states, provider.id, :ws)
    has_http = is_binary(Map.get(provider.config, :url))
    has_ws = is_binary(Map.get(provider.config, :ws_url))

    if include_half_open do
      # Include if at least one configured transport is not fully open
      (has_http and http_state != :open) or (has_ws and ws_state != :open)
    else
      # Include if at least one configured transport has closed CB
      (has_http and http_state == :closed) or (has_ws and ws_state == :closed)
    end
  end

  defp rate_limit_ok?(provider, state, protocol, current_time, filters) do
    if Map.get(filters, :exclude_rate_limited, false) do
      case protocol do
        :http ->
          not transport_rate_limited?(state, provider.id, :http, current_time)

        :ws ->
          not transport_rate_limited?(state, provider.id, :ws, current_time)

        :both ->
          not transport_rate_limited?(state, provider.id, :http, current_time) and
            not transport_rate_limited?(state, provider.id, :ws, current_time)

        _ ->
          # For nil protocol, include if at least one transport is not rate limited
          not transport_rate_limited?(state, provider.id, :http, current_time) or
            not transport_rate_limited?(state, provider.id, :ws, current_time)
      end
    else
      # By default, include rate-limited providers (selection tiering handles preference)
      true
    end
  end

  defp filter_excluded(providers, filters) do
    case Map.get(filters, :exclude) do
      nil ->
        providers

      exclude_list when is_list(exclude_list) ->
        Enum.filter(providers, &(&1.id not in exclude_list))

      _ ->
        providers
    end
  end

  defp ws_connection_pid(provider_id) when is_binary(provider_id) do
    GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, provider_id}}})
  end

  @spec get_cb_state(circuit_states(), provider_id(), :http | :ws) :: circuit_state()
  defp get_cb_state(circuit_states, provider_id, transport) do
    case Map.get(circuit_states, provider_id) do
      %{} = m -> Map.get(m, transport, :closed)
      other when other in [:open, :closed, :half_open] -> other
      _ -> :closed
    end
  end

  @doc false
  @spec normalize_circuit_state(circuit_state() | %{http: circuit_state(), ws: circuit_state()}) ::
          %{http: circuit_state(), ws: circuit_state()}
  defp normalize_circuit_state(%{http: _, ws: _} = map_format), do: map_format

  defp normalize_circuit_state(atom_state) when atom_state in [:open, :closed, :half_open] do
    %{http: atom_state, ws: atom_state}
  end

  defp normalize_circuit_state(_), do: %{http: :closed, ws: :closed}

  # Lag-based filtering: Excludes providers that are too far behind best known block height
  # Implements fail-open behavior: if lag data unavailable, include the provider
  defp filter_by_lag(providers, _chain, nil), do: providers

  defp filter_by_lag(providers, chain, max_lag_blocks) when is_integer(max_lag_blocks) do
    filtered =
      Enum.reduce(providers, [], fn provider, included ->
        case ChainState.provider_lag(chain, provider.id) do
          {:ok, lag} when lag >= -max_lag_blocks ->
            # Provider is within acceptable lag threshold (negative lag = blocks behind)
            # lag >= -max_lag_blocks means provider is at most max_lag_blocks behind
            [provider | included]

          {:ok, lag} ->
            # Provider is lagging beyond threshold - exclude it
            Logger.debug(
              "Excluded provider #{provider.id} from selection: lag=#{lag} blocks (threshold: -#{max_lag_blocks})"
            )

            included

          {:error, _reason} ->
            # Lag data unavailable - fail open (include provider)
            [provider | included]
        end
      end)

    filtered = Enum.reverse(filtered)

    # Warn if ALL providers were excluded due to lag
    if providers != [] and filtered == [] do
      Logger.warning(
        "All #{length(providers)} providers for #{chain} excluded due to lag (threshold: -#{max_lag_blocks} blocks)"
      )
    end

    filtered
  end

  # Check if transport is configured (circuit breaker handles availability)
  defp transport_available?(provider, :http, _now_ms) do
    is_binary(Map.get(provider.config, :url))
  end

  defp transport_available?(provider, :ws, _now_ms) do
    is_binary(Map.get(provider.config, :ws_url))
  end

  # Check if a provider's transport is currently rate limited
  defp transport_rate_limited?(state, provider_id, transport, now_ms) do
    case Map.get(state.rate_limit_states, provider_id) do
      nil -> false
      rate_limit_state -> RateLimitState.rate_limited?(rate_limit_state, transport, now_ms)
    end
  end

  # Get rate limit state for a provider (for candidate response)
  defp get_rate_limit_state(state, provider_id) do
    case Map.get(state.rate_limit_states, provider_id) do
      nil ->
        %{http: false, ws: false}

      rate_limit_state ->
        now = System.monotonic_time(:millisecond)

        %{
          http: RateLimitState.rate_limited?(rate_limit_state, :http, now),
          ws: RateLimitState.rate_limited?(rate_limit_state, :ws, now)
        }
    end
  end

  defp put_provider_and_refresh(state, provider_id, updated) do
    new_providers = Map.put(state.providers, provider_id, updated)
    new_state = %{state | providers: new_providers}
    update_active_providers(new_state)
  end

  defp update_active_providers(state) do
    # Use runtime provider state instead of ConfigStore
    # This allows dynamically registered providers (mocks, tests) to participate
    viable_providers =
      state.providers
      |> Enum.filter(fn {_id, provider} ->
        provider.status in [:healthy, :connecting, :degraded]
      end)
      |> Enum.map(fn {id, _provider} -> id end)

    %{state | active_providers: viable_providers}
  end

  defp update_provider_success(state, provider_id) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        updated_provider =
          provider
          |> Map.merge(%{
            status: derive_aggregate_status(provider),
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            last_health_check: System.system_time(:millisecond)
          })

        state = maybe_emit_became_healthy(state, provider_id, provider)

        state
        |> put_provider_and_refresh(provider_id, updated_provider)
        |> clear_rate_limit_for_provider(provider_id, :http)
        |> clear_rate_limit_for_provider(provider_id, :ws)
        |> Map.update!(:total_requests, &(&1 + 1))
    end
  end

  defp update_provider_success_http(state, provider_id) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        # Report success to circuit breaker
        cb_id = {state.profile, state.chain_name, provider_id, :http}
        CircuitBreaker.signal_recovery(cb_id)

        updated =
          provider
          |> Map.put(:http_status, :healthy)
          |> then(&Map.put(&1, :status, derive_aggregate_status(&1)))
          |> Map.put(:consecutive_successes, provider.consecutive_successes + 1)
          |> Map.put(:consecutive_failures, 0)
          |> Map.put(:last_health_check, System.system_time(:millisecond))

        state
        |> put_provider_and_refresh(provider_id, updated)
        |> clear_rate_limit_for_provider(provider_id, :http)
    end
  end

  defp update_provider_success_ws(state, provider_id) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        # Report success to circuit breaker
        cb_id = {state.profile, state.chain_name, provider_id, :ws}
        CircuitBreaker.signal_recovery(cb_id)

        updated =
          provider
          |> Map.put(:ws_status, :healthy)
          |> then(&Map.put(&1, :status, derive_aggregate_status(&1)))
          |> Map.put(:consecutive_successes, provider.consecutive_successes + 1)
          |> Map.put(:consecutive_failures, 0)
          |> Map.put(:last_health_check, System.system_time(:millisecond))

        state
        |> put_provider_and_refresh(provider_id, updated)
        |> clear_rate_limit_for_provider(provider_id, :ws)
    end
  end

  defp update_provider_failure_http(state, provider_id, error) do
    update_provider_failure_with_transport(state, provider_id, error, :http)
  end

  defp update_provider_failure_ws(state, provider_id, error) do
    update_provider_failure_with_transport(state, provider_id, error, :ws)
  end

  defp update_provider_failure_with_transport(state, provider_id, error, transport) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        {jerr, _context} = normalize_error_for_pool(error, provider_id)
        status_field = if transport == :http, do: :http_status, else: :ws_status

        cond do
          jerr.category == :rate_limit ->
            # Rate limits are temporary backpressure, not provider health issues
            # Provider stays healthy - RateLimitState is the authoritative source for rate limit status
            retry_after_ms = RateLimitState.extract_retry_after(jerr.data)

            # Report to circuit breaker (rate limit threshold is lower than other errors)
            cb_id = {state.profile, state.chain_name, provider_id, transport}
            CircuitBreaker.record_failure(cb_id, jerr)

            # Only update last_error for debugging - don't change health status
            updated =
              provider
              |> Map.put(:last_error, jerr)
              |> Map.put(:last_health_check, System.system_time(:millisecond))

            state
            |> put_provider_and_refresh(provider_id, updated)
            |> record_rate_limit_for_provider(provider_id, transport, retry_after_ms)

          jerr.category == :client_error ->
            # Client errors don't affect provider health status
            updated =
              provider
              |> Map.put(:last_error, jerr)
              |> Map.put(:last_health_check, System.system_time(:millisecond))

            state |> put_provider_and_refresh(provider_id, updated) |> increment_failure_stats()

          true ->
            new_failures = provider.consecutive_failures + 1
            new_status = derive_failure_status(new_failures)

            # Report to circuit breaker
            cb_id = {state.profile, state.chain_name, provider_id, transport}
            CircuitBreaker.record_failure(cb_id, jerr)

            updated =
              provider
              |> Map.put(status_field, new_status)
              |> then(&Map.put(&1, :status, derive_aggregate_status(&1)))
              |> Map.put(:consecutive_failures, new_failures)
              |> Map.put(:consecutive_successes, 0)
              |> Map.put(:last_error, jerr)
              |> Map.put(:last_health_check, System.system_time(:millisecond))

            state
            |> put_provider_and_refresh(provider_id, updated)
            |> increment_failure_stats()
        end
    end
  end

  defp maybe_emit_became_healthy(state, provider_id, provider) do
    if provider.status != :healthy do
      publish_provider_event(state.chain_name, provider_id, :healthy, %{})
      state
    else
      state
    end
  end

  defp update_provider_failure(state, provider_id, error) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        {jerr, context} = normalize_error_for_pool(error, provider_id)

        cond do
          jerr.category == :rate_limit ->
            # Rate limits are temporary backpressure, not provider health issues
            # Provider stays healthy - RateLimitState is the authoritative source for rate limit status
            retry_after_ms = RateLimitState.extract_retry_after(jerr.data)
            transport = jerr.transport || :http

            # Only update last_error for debugging - don't change health status
            updated_provider =
              provider
              |> Map.merge(%{
                last_error: jerr,
                last_health_check: System.system_time(:millisecond)
              })

            state
            |> put_provider_and_refresh(provider_id, updated_provider)
            |> record_rate_limit_for_provider(provider_id, transport, retry_after_ms)

          jerr.category == :client_error and context == :live_traffic ->
            # Client errors from live traffic don't affect provider health status
            updated_provider =
              provider
              |> Map.merge(%{
                last_error: jerr,
                last_health_check: System.system_time(:millisecond)
              })

            state
            |> put_provider_and_refresh(provider_id, updated_provider)
            |> increment_failure_stats()

          true ->
            new_consecutive_failures = provider.consecutive_failures + 1
            new_status = derive_failure_status(new_consecutive_failures)

            updated_provider =
              provider
              |> Map.merge(%{
                status: new_status,
                consecutive_failures: new_consecutive_failures,
                consecutive_successes: 0,
                last_error: jerr,
                last_health_check: System.system_time(:millisecond)
              })

            new_state =
              state
              |> put_provider_and_refresh(provider_id, updated_provider)
              |> increment_failure_stats()

            if updated_provider.status == :unhealthy and provider.status != :unhealthy do
              Logger.warning(
                "Provider #{provider_id} marked as unhealthy after #{updated_provider.consecutive_failures} failures"
              )

              publish_provider_event(state.chain_name, provider_id, :unhealthy, %{})

              :telemetry.execute([:lasso, :provider, :status], %{count: 1}, %{
                chain: state.chain_name,
                provider_id: provider_id,
                status: :unhealthy
              })
            end

            new_state
        end
    end
  end

  defp normalize_error_for_pool({:health_check, %JError{} = jerr}, _provider_id),
    do: {jerr, :health_check}

  defp normalize_error_for_pool({:health_check, other}, provider_id),
    do: {JError.from(other, provider_id: provider_id), :health_check}

  defp normalize_error_for_pool(%JError{} = jerr, _provider_id),
    do: {jerr, :live_traffic}

  defp normalize_error_for_pool(other, provider_id),
    do: {JError.from(other, provider_id: provider_id), :live_traffic}

  # Derives failure status from consecutive failures (without :misconfigured)
  # Note: :misconfigured status removed - use planned "break off" mechanism for persistent failures
  defp derive_failure_status(consecutive_failures) do
    if consecutive_failures >= @failure_threshold, do: :unhealthy, else: :degraded
  end

  # Maps provider health status to availability for dashboard/API compatibility
  # Note: rate limits are tracked separately via RateLimitState, not health status
  defp status_to_availability(nil), do: :up
  defp status_to_availability(:healthy), do: :up
  defp status_to_availability(:connecting), do: :up
  defp status_to_availability(:degraded), do: :limited
  defp status_to_availability(:unhealthy), do: :down
  defp status_to_availability(:disconnected), do: :down
  defp status_to_availability(_), do: :up

  defp increment_failure_stats(state) do
    state
    |> Map.update!(:total_requests, &(&1 + 1))
    |> Map.update!(:failed_requests, &(&1 + 1))
  end

  # Derives aggregate health status from transport statuses
  # Note: rate limits are tracked via RateLimitState, not health status
  defp derive_aggregate_status(provider) do
    http = Map.get(provider, :http_status)
    ws = Map.get(provider, :ws_status)

    cond do
      # Any transport healthy = provider healthy
      http == :healthy or ws == :healthy ->
        :healthy

      # Connecting state takes precedence during startup
      http == :connecting or ws == :connecting ->
        :connecting

      # All transports unhealthy/disconnected = provider unhealthy
      (http in [:unhealthy, :disconnected] or is_nil(http)) and
          (ws in [:unhealthy, :disconnected] or is_nil(ws)) ->
        :unhealthy

      true ->
        :degraded
    end
  end

  # Record rate limit to RateLimitState (time-based, independent of circuit breaker)
  defp record_rate_limit_for_provider(state, provider_id, transport, retry_after_ms) do
    current_rate_limit_state =
      Map.get(state.rate_limit_states, provider_id) || RateLimitState.new()

    updated_rate_limit_state =
      RateLimitState.record_rate_limit(current_rate_limit_state, transport, retry_after_ms)

    %{
      state
      | rate_limit_states: Map.put(state.rate_limit_states, provider_id, updated_rate_limit_state)
    }
  end

  # Clear rate limit for a specific transport (called on success)
  defp clear_rate_limit_for_provider(state, provider_id, transport) do
    case Map.get(state.rate_limit_states, provider_id) do
      nil ->
        state

      rate_limit_state ->
        updated = RateLimitState.clear_rate_limit(rate_limit_state, transport)
        %{state | rate_limit_states: Map.put(state.rate_limit_states, provider_id, updated)}
    end
  end

  defp publish_provider_event(chain_name, provider_id, event, details) do
    ts = System.system_time(:millisecond)

    typed =
      case event do
        :healthy ->
          %Provider.Healthy{ts: ts, chain: chain_name, provider_id: provider_id}

        :unhealthy ->
          %Provider.Unhealthy{
            ts: ts,
            chain: chain_name,
            provider_id: provider_id,
            reason: Map.get(details, :reason) || Map.get(details, "reason")
          }

        :ws_connected ->
          %Provider.WSConnected{ts: ts, chain: chain_name, provider_id: provider_id}

        :ws_closed ->
          %Provider.WSClosed{
            ts: ts,
            chain: chain_name,
            provider_id: provider_id,
            code: Map.get(details, :code) || Map.get(details, "code"),
            reason: Map.get(details, :reason) || Map.get(details, "reason")
          }
      end

    Phoenix.PubSub.broadcast(Lasso.PubSub, Provider.topic(chain_name), typed)
  end

  # Updates circuit state for a specific provider and transport
  defp update_circuit_state(circuit_states, provider_id, transport, new_state) do
    current_states = Map.get(circuit_states, provider_id, %{})

    updated_states =
      case current_states do
        state when state in [:closed, :open, :half_open] ->
          # Legacy format: single state for provider
          # Upgrade to new format with per-transport states
          %{http: state, ws: state}

        %{} = states_map ->
          states_map
      end
      |> Map.put(transport, new_state)

    Map.put(circuit_states, provider_id, updated_states)
  end

  # Updates recovery time for a specific circuit by querying CircuitBreaker asynchronously.
  # This spawns a Task to avoid blocking the ProviderPool GenServer on CircuitBreaker calls,
  # which was causing GenServer call cascades and 2+ second delays during circuit thrashing.
  defp update_recovery_time_for_circuit(recovery_times, provider_id, transport, profile, chain) do
    # Circuit breaker ID includes profile for isolation
    breaker_id = {profile, chain, provider_id, transport}

    # Spawn async task to query recovery time - don't block ProviderPool
    Task.start(fn ->
      recovery_time =
        try do
          case CircuitBreaker.get_recovery_time_remaining(breaker_id) do
            time when is_integer(time) and time > 0 -> time
            _ -> nil
          end
        catch
          :exit, _ -> nil
        end

      # Send result back to ProviderPool as cast (non-blocking)
      if recovery_time do
        GenServer.cast(
          via_name(profile, chain),
          {:update_recovery_time_async, provider_id, transport, recovery_time}
        )
      end
    end)

    # Return existing recovery times immediately without blocking
    recovery_times
  end

  # Clears recovery time for a specific circuit (when it closes)
  defp clear_recovery_time(recovery_times, provider_id, transport) do
    provider_times = Map.get(recovery_times, provider_id, %{http: nil, ws: nil})
    updated_times = Map.put(provider_times, transport, nil)
    Map.put(recovery_times, provider_id, updated_times)
  end

  # Updates circuit error for a specific provider and transport (when circuit opens)
  defp update_circuit_error(circuit_errors, provider_id, transport, error_info) do
    provider_errors = Map.get(circuit_errors, provider_id, %{http: nil, ws: nil})
    updated_errors = Map.put(provider_errors, transport, error_info)
    Map.put(circuit_errors, provider_id, updated_errors)
  end

  # Clears circuit error for a specific circuit (when it closes)
  defp clear_circuit_error(circuit_errors, provider_id, transport) do
    provider_errors = Map.get(circuit_errors, provider_id, %{http: nil, ws: nil})
    updated_errors = Map.put(provider_errors, transport, nil)
    Map.put(circuit_errors, provider_id, updated_errors)
  end

  # Processes a batch of probe results
  defp apply_probe_batch(state, results) do
    # First pass: Update sync state for all successful probes
    state =
      Enum.reduce(results, state, fn result, acc_state ->
        if result.success? do
          # Store: height, timestamp, sequence number
          :ets.insert(
            acc_state.table,
            {{:provider_sync, acc_state.chain_name, result.provider_id},
             {result.block_height, result.timestamp, result.sequence}}
          )

          # Update HTTP transport availability for health policy (probe uses HTTP)
          update_provider_success_http(acc_state, result.provider_id)
        else
          # Tag failures as coming from health_check context for policy handling
          update_provider_failure_http(
            acc_state,
            result.provider_id,
            {:health_check, result.error}
          )
        end
      end)

    # Second pass: Calculate lag for successful providers only
    # NOTE: Consensus is calculated lazily by ChainState
    update_provider_lags(state, results)

    state
  end

  defp update_provider_lags(state, probe_results) do
    # Get consensus height (lazy calculation from ChainState)
    case ChainState.consensus_height(state.chain_name) do
      {:ok, consensus_height} ->
        # Calculate lag only for successful probes
        Enum.each(probe_results, fn result ->
          if result.success? do
            lag = result.block_height - consensus_height

            # Store lag
            :ets.insert(
              state.table,
              {{:provider_lag, state.chain_name, result.provider_id}, lag}
            )

            # Broadcast sync update for dashboard live updates
            Phoenix.PubSub.broadcast(Lasso.PubSub, "sync:updates", %{
              chain: state.chain_name,
              provider_id: result.provider_id,
              block_height: result.block_height,
              consensus_height: consensus_height,
              lag: lag
            })

            # Emit telemetry when lagging beyond threshold
            threshold = get_lag_threshold_for_chain(state.profile, state.chain_name)

            if lag < -threshold do
              emit_lag_telemetry(state.chain_name, result.provider_id, lag)
            end
          end
        end)

      {:error, _reason} ->
        # No consensus available - don't calculate lag
        :ok
    end
  end

  defp get_current_sequence(_state) do
    # For newHeads, use timestamp-based pseudo-sequence
    # In the future, could maintain a sequence counter
    div(System.system_time(:millisecond), 1000)
  end

  defp get_lag_threshold_for_chain(profile, chain) do
    # Get lag threshold from chain configuration (chains.yml)
    # Falls back to application config if chain not found
    case Lasso.Config.ConfigStore.get_chain(profile, chain) do
      {:ok, chain_config} ->
        chain_config.monitoring.lag_threshold_blocks

      {:error, _} ->
        # Fallback to application config for backwards compatibility
        thresholds =
          Application.get_env(:lasso, :provider_probe, [])
          |> Keyword.get(:lag_threshold_by_chain, %{})

        Map.get(thresholds, chain) ||
          Application.get_env(:lasso, :provider_probe, [])
          |> Keyword.get(:default_lag_threshold, 10)
    end
  end

  defp emit_lag_telemetry(chain, provider_id, lag) do
    :telemetry.execute(
      [:lasso, :provider_probe, :lag_detected],
      %{lag_blocks: lag},
      %{chain: chain, provider_id: provider_id}
    )
  end

  @doc """
  Returns the via tuple for the ProviderPool GenServer.

  Accepts optional profile as first argument (defaults to "default").
  """
  @deprecated "Use via_name(profile, chain_name) instead with explicit profile parameter"
  @spec via_name(String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via_name(chain_name) when is_binary(chain_name) do
    IO.warn("ProviderPool.via_name/1 defaults to 'default' profile. Pass profile explicitly.")
    via_name("default", chain_name)
  end

  @spec via_name(String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via_name(profile, chain_name) when is_binary(profile) and is_binary(chain_name) do
    {:via, Registry, {Lasso.Registry, {:provider_pool, profile, chain_name}}}
  end
end
