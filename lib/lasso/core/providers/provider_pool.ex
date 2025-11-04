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

  alias Lasso.Events.Provider
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Caching.BlockchainMetadataCache
  alias Lasso.RPC.CircuitBreaker
  alias Lasso.RPC.HealthPolicy

  @type t :: %__MODULE__{
          chain_name: chain_name(),
          providers: %{provider_id() => __MODULE__.ProviderState.t()},
          active_providers: [provider_id()],
          total_requests: non_neg_integer(),
          failed_requests: non_neg_integer(),
          circuit_states: circuit_states(),
          recovery_times: recovery_times()
        }

  @type circuit_states :: %{provider_id() => %{http: circuit_state(), ws: circuit_state()}}
  @type circuit_state :: :closed | :open | :half_open
  @type recovery_times :: %{
          provider_id() => %{http: non_neg_integer() | nil, ws: non_neg_integer() | nil}
        }

  defstruct [
    :chain_name,
    :providers,
    :active_providers,
    total_requests: 0,
    failed_requests: 0,
    # Circuit breaker state per provider and transport: %{provider_id => %{http: state, ws: state}}
    circuit_states: %{},
    # Cached recovery times per provider: %{provider_id => %{http: ms | nil, ws: ms | nil}}
    # Updated when circuit states change to avoid N sequential GenServer calls
    recovery_times: %{}
  ]

  defmodule ProviderState do
    @moduledoc """
    Runtime state for a single provider within a chain's pool.

    Health and availability are centralized in policy structs to provide
    a single source of truth for routing decisions.
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
            reconnect_grace_until: integer() | nil,
            policy: Lasso.RPC.HealthPolicy.t(),
            http_policy: Lasso.RPC.HealthPolicy.t(),
            ws_policy: Lasso.RPC.HealthPolicy.t()
          }

    @type health_status ::
            :healthy
            | :unhealthy
            | :connecting
            | :disconnected
            | :rate_limited
            | :misconfigured
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
      # Centralized health policy state (availability + signals)
      :policy,
      # Transport-specific health policies
      :http_policy,
      :ws_policy,
      # WebSocket reconnection tracking
      reconnect_attempts: 0,
      reconnect_grace_until: nil
    ]
  end

  @type chain_name :: String.t()
  @type provider_id :: String.t()
  @type strategy :: :priority | :round_robin | :fastest | :cheapest | :latency_weighted
  @type health_status ::
          :healthy
          | :unhealthy
          | :connecting
          | :disconnected
          | :rate_limited
          | :misconfigured
          | :degraded

  # Default timeout for ProviderPool GenServer calls (5 seconds)
  # ProviderPool operations are generally fast but can be delayed under high load
  @call_timeout 5_000

  @doc """
  Starts the ProviderPool for a chain.
  """
  @spec start_link({chain_name, map()}) :: GenServer.on_start()
  def start_link({chain_name, chain_config}) do
    GenServer.start_link(__MODULE__, {chain_name, chain_config}, name: via_name(chain_name))
  end

  @doc """
  Registers a provider's configuration with the pool (no pid).
  """
  @spec register_provider(chain_name, provider_id, map()) :: :ok
  def register_provider(chain_name, provider_id, provider_config) do
    GenServer.call(via_name(chain_name), {:register_provider, provider_id, provider_config})
  end

  @doc """
  Attaches a WebSocket connection pid to an already-registered provider.
  The pid will be monitored
  """
  @spec attach_ws_connection(chain_name, provider_id, pid()) :: :ok | {:error, term()}
  def attach_ws_connection(chain_name, provider_id, pid) do
    GenServer.call(via_name(chain_name), {:attach_ws_connection, provider_id, pid})
  end

  @doc """
  Gets all currently active providers.
  """
  @spec get_active_providers(chain_name) :: [provider_id]
  def get_active_providers(chain_name) do
    GenServer.call(via_name(chain_name), :get_active_providers)
  end

  @doc """
  Gets the health status of all providers.
  """
  @spec get_status(chain_name) :: {:ok, map()} | {:error, term()}
  def get_status(chain_name) do
    try do
      GenServer.call(via_name(chain_name), :get_status, @call_timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("Timeout getting status for chain #{chain_name}")
        {:error, :timeout}

      :exit, {:noproc, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists provider candidates enriched with policy-derived availability for selection.

  Supported filters:
  - protocol: :http | :ws | :both
  - exclude: [provider_id]
  - include_half_open: boolean (default false) - include providers with half-open circuits
  - max_lag_blocks: integer (optional) - exclude providers lagging more than N blocks behind best known height
  """
  @spec list_candidates(chain_name, map()) :: [map()]
  def list_candidates(chain_name, filters \\ %{}) when is_map(filters) do
    try do
      GenServer.call(via_name(chain_name), {:list_candidates, filters}, @call_timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("Timeout listing candidates for chain #{chain_name}")
        # Return empty list on timeout (fail closed)
        []

      :exit, {:noproc, _} ->
        []
    end
  end

  @doc """
  Reports a successful operation (no latency needed; performance is tracked elsewhere).
  If transport is provided, updates the corresponding transport policy/status.
  """
  @spec report_success(chain_name, provider_id) :: :ok
  def report_success(chain_name, provider_id) do
    GenServer.cast(via_name(chain_name), {:report_success, provider_id})
  end

  @spec report_success(chain_name, provider_id, :http | :ws | nil) :: :ok
  def report_success(chain_name, provider_id, transport) when transport in [:http, :ws, nil] do
    GenServer.cast(via_name(chain_name), {:report_success, provider_id, transport})
  end

  @doc """
  Reports a failure for error rate tracking. If transport is provided, updates that transport.
  """
  @spec report_failure(chain_name, provider_id, term()) :: :ok
  def report_failure(chain_name, provider_id, error) do
    GenServer.cast(via_name(chain_name), {:report_failure, provider_id, error})
  end

  @spec report_failure(chain_name, provider_id, term(), :http | :ws | nil) :: :ok
  def report_failure(chain_name, provider_id, error, transport)
      when transport in [:http, :ws, nil] do
    GenServer.cast(via_name(chain_name), {:report_failure, provider_id, error, transport})
  end

  @doc """
  Unregisters a provider from the pool (for test cleanup).
  """
  @spec unregister_provider(chain_name, provider_id) :: :ok
  def unregister_provider(chain_name, provider_id) do
    GenServer.call(via_name(chain_name), {:unregister_provider, provider_id})
  end

  @doc """
  Gets the WebSocket PID for a provider (for chaos testing).
  """
  @spec get_provider_ws_pid(chain_name, provider_id) :: {:ok, pid()} | {:error, :not_found}
  def get_provider_ws_pid(chain_name, provider_id) do
    GenServer.call(via_name(chain_name), {:get_provider_ws_pid, provider_id})
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

  ## Examples

      iex> ProviderPool.get_recovery_times("ethereum")
      {:ok, %{
        "alchemy_ethereum" => %{http: nil, ws: 30_000},
        "quicknode_ethereum" => %{http: 15_000, ws: nil}
      }}
  """
  @spec get_recovery_times(chain_name, keyword()) ::
          {:ok, %{provider_id => %{http: non_neg_integer() | nil, ws: non_neg_integer() | nil}}}
          | {:error, term()}
  def get_recovery_times(chain_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    try do
      GenServer.call(via_name(chain_name), {:get_recovery_times, opts}, timeout)
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

  ## Examples

      iex> ProviderPool.get_min_recovery_time("ethereum", transport: :http)
      {:ok, 15_000}

      iex> ProviderPool.get_min_recovery_time("ethereum")
      {:ok, nil}  # No open circuits
  """
  @spec get_min_recovery_time(chain_name, keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def get_min_recovery_time(chain_name, opts \\ []) do
    transport_filter = Keyword.get(opts, :transport, :both)

    case get_recovery_times(chain_name, opts) do
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

  # GenServer callbacks

  @impl true
  def init({chain_name, chain_config}) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain_name}")

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
           last_error: nil,
           policy: HealthPolicy.new(),
           http_policy: HealthPolicy.new(),
           ws_policy: HealthPolicy.new()
         }}
      end)
      |> Enum.into(%{})

    state = %__MODULE__{
      chain_name: chain_name,
      providers: initial_providers,
      active_providers: Map.keys(initial_providers),
      total_requests: 0,
      failed_requests: 0,
      circuit_states: %{},
      recovery_times: %{}
    }

    if map_size(initial_providers) > 0 do
      Logger.info(
        "ProviderPool initialized for #{chain_name} with #{map_size(initial_providers)} providers"
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
            last_error: nil,
            policy: HealthPolicy.new(),
            http_policy: HealthPolicy.new(),
            ws_policy: HealthPolicy.new()
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
    current_time = System.monotonic_time(:millisecond)

    providers =
      Enum.map(state.providers, fn {id, provider} ->
        # Normalize circuit_state format - ensure map structure
        circuit_state_normalized =
          normalize_circuit_state(Map.get(state.circuit_states, id, :closed))

        http_cb_state = get_cb_state(state.circuit_states, id, :http)
        ws_cb_state = get_cb_state(state.circuit_states, id, :ws)

        # Compute derived fields from policy (single source of truth)
        cooldown_until = provider.policy.cooldown_until
        is_in_cooldown = HealthPolicy.cooldown?(provider.policy, current_time)
        availability = HealthPolicy.availability(provider.policy)

        http_availability = HealthPolicy.availability(provider.http_policy)
        ws_availability = HealthPolicy.availability(provider.ws_policy)

        %{
          id: id,
          name: Map.get(provider.config, :name, id),
          config: provider.config,
          status: provider.status,
          http_status: provider.http_status,
          ws_status: provider.ws_status,
          # Derived fields (computed from policy)
          availability: availability,
          http_availability: http_availability,
          ws_availability: ws_availability,
          cooldown_until: cooldown_until,
          is_in_cooldown: is_in_cooldown,
          # Circuit breaker state (normalized to map format)
          circuit_state: circuit_state_normalized,
          http_cb_state: http_cb_state,
          ws_cb_state: ws_cb_state,
          # Provider metrics
          consecutive_failures: provider.consecutive_failures,
          consecutive_successes: provider.consecutive_successes,
          last_health_check: provider.last_health_check,
          last_error: provider.last_error,
          # Policy (source of truth)
          policy: provider.policy
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
        availability =
          case Map.get(p, :policy) do
            %HealthPolicy{} = pol -> HealthPolicy.availability(pol)
            _ -> :up
          end

        %{
          id: p.id,
          config: p.config,
          availability: availability,
          policy: Map.get(p, :policy)
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

  # Typed WS connection events
  @impl true
  def handle_info({:ws_connected, provider_id}, state) do
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
         %{chain: event_chain, provider_id: provider_id, transport: transport, from: from, to: to}},
        state
      )
      when is_binary(provider_id) and from in [:closed, :open, :half_open] and
             to in [:closed, :open, :half_open] do
    # Only handle circuit breaker events for THIS chain
    if event_chain == state.chain_name or is_nil(event_chain) do
      start_time = System.monotonic_time(:millisecond)

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
            state.chain_name
          )
        else
          # Circuit closed, clear recovery time
          clear_recovery_time(state.recovery_times, provider_id, transport)
        end

      # Instrumentation: log slow circuit event processing (>100ms indicates blocking)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      if duration_ms > 100 do
        Logger.warning("SLOW circuit event processing",
          duration_ms: duration_ms,
          provider: provider_id,
          transport: transport,
          chain: state.chain_name,
          transition: "#{from} -> #{to}"
        )
      end

      {:noreply,
       %{state | circuit_states: new_circuit_states, recovery_times: new_recovery_times}}
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
  def handle_info(%Provider.CooldownStart{provider_id: provider_id, until: _until_ts}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :rate_limited
        }

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(%Provider.CooldownEnd{provider_id: provider_id}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = provider
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

  # Private functions

  @spec candidates_ready(t(), map()) :: [ProviderState.t()]
  defp candidates_ready(state, filters) do
    max_lag_blocks = Map.get(filters, :max_lag_blocks)
    current_time = System.monotonic_time(:millisecond)

    state.active_providers
    |> Enum.map(&Map.get(state.providers, &1))
    |> Enum.filter(fn p ->
      # Check transport availability
      transport_ok =
        case Map.get(filters, :protocol) do
          :http ->
            transport_available?(p, :http, current_time)

          :ws ->
            transport_available?(p, :ws, current_time) and is_pid(ws_connection_pid(p.id))

          :both ->
            transport_available?(p, :http, current_time) and
              transport_available?(p, :ws, current_time)

          _ ->
            transport_available?(p, :http, current_time) or
              transport_available?(p, :ws, current_time)
        end

      # Check circuit breaker state
      include_half_open = Map.get(filters, :include_half_open, false)

      circuit_ok =
        case Map.get(filters, :protocol) do
          :http ->
            cb_state = get_cb_state(state.circuit_states, p.id, :http)

            if include_half_open do
              cb_state != :open
            else
              cb_state == :closed
            end

          :ws ->
            cb_state = get_cb_state(state.circuit_states, p.id, :ws)

            if include_half_open do
              cb_state != :open
            else
              cb_state == :closed
            end

          _ ->
            http_state = get_cb_state(state.circuit_states, p.id, :http)
            ws_state = get_cb_state(state.circuit_states, p.id, :ws)

            if include_half_open do
              # Include if at least one transport is not fully open
              not (http_state == :open and ws_state == :open)
            else
              # Only include if at least one transport is closed
              http_state == :closed or ws_state == :closed
            end
        end

      transport_ok and circuit_ok
    end)
    |> filter_by_lag(state.chain_name, max_lag_blocks)
    |> Enum.filter(fn provider ->
      case Map.get(filters, :exclude) do
        nil -> true
        exclude_list when is_list(exclude_list) -> provider.id not in exclude_list
        _ -> true
      end
    end)
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
    # Track providers with missing lag data to detect if filtering is completely broken
    {filtered, missing_lag_data} =
      Enum.reduce(providers, {[], []}, fn provider, {included, missing} ->
        case BlockchainMetadataCache.get_provider_lag(chain, provider.id) do
          {:ok, lag} when lag >= -max_lag_blocks ->
            # Provider is within acceptable lag threshold (negative lag = blocks behind)
            # lag >= -max_lag_blocks means provider is at most max_lag_blocks behind
            {[provider | included], missing}

          {:ok, lag} ->
            # Provider is lagging beyond threshold - exclude it
            telemetry_lag_excluded(chain, provider.id, lag, max_lag_blocks)

            Logger.debug(
              "Excluded provider #{provider.id} from selection: lag=#{lag} blocks (threshold: -#{max_lag_blocks})"
            )

            {included, missing}

          {:error, reason} ->
            # Lag data unavailable - fail open (include provider but track it)
            telemetry_lag_data_unavailable(chain, provider.id, reason)

            Logger.debug(
              "Lag data unavailable for provider #{provider.id}, including in candidates (reason: #{inspect(reason)})"
            )

            {[provider | included], [provider.id | missing]}
        end
      end)

    # Alert if ALL providers have missing lag data (lag filtering completely disabled)
    if providers != [] and length(missing_lag_data) == length(providers) do
      telemetry_lag_filtering_disabled(chain, length(providers))

      Logger.warning(
        "Lag filtering disabled for #{chain}: no lag data for any of #{length(providers)} providers. " <>
          "Check BlockchainMetadataMonitor health."
      )
    end

    filtered = Enum.reverse(filtered)

    # Emit telemetry if ALL providers were excluded due to lag
    if providers != [] and filtered == [] do
      telemetry_all_providers_lagging(chain, length(providers), max_lag_blocks)

      Logger.warning(
        "All #{length(providers)} providers for #{chain} excluded due to lag (threshold: -#{max_lag_blocks} blocks)"
      )
    end

    filtered
  end

  defp transport_available?(provider, :http, now_ms) do
    has_http = is_binary(Map.get(provider.config, :url))

    if has_http,
      do: not in_cooldown?(Map.get(provider, :http_policy), provider, now_ms),
      else: false
  end

  defp transport_available?(provider, :ws, now_ms) do
    has_ws = is_binary(Map.get(provider.config, :ws_url))

    if has_ws,
      do: not in_cooldown?(Map.get(provider, :ws_policy), provider, now_ms),
      else: false
  end

  defp in_cooldown?(%HealthPolicy{} = pol, _provider, now_ms),
    do: HealthPolicy.cooldown?(pol, now_ms)

  defp put_provider_and_refresh(state, provider_id, updated) do
    new_providers = Map.put(state.providers, provider_id, updated)
    new_state = %{state | providers: new_providers}
    update_active_providers(new_state)
  end

  defp update_active_providers(state) do
    # Use runtime provider state instead of ConfigStore
    # This allows dynamically registered providers (battle tests, mocks) to participate
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
        policy = provider.policy || HealthPolicy.new()
        new_policy = HealthPolicy.apply_event(policy, {:success, 0, nil})

        updated_provider =
          provider
          |> Map.merge(%{
            status: derive_aggregate_status(provider),
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            last_health_check: System.system_time(:millisecond),
            policy: new_policy
          })

        state = maybe_emit_cooldown_end(state, provider_id, provider)
        state = maybe_emit_became_healthy(state, provider_id, provider)

        state
        |> put_provider_and_refresh(provider_id, updated_provider)
        |> Map.update!(:total_requests, &(&1 + 1))
    end
  end

  defp update_provider_success_http(state, provider_id) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        pol = provider.http_policy || HealthPolicy.new()
        new_pol = HealthPolicy.apply_event(pol, {:success, 0, nil})

        updated =
          provider
          |> Map.put(:http_policy, new_pol)
          |> Map.put(:http_status, :healthy)
          |> then(&Map.put(&1, :status, derive_aggregate_status(&1)))
          |> Map.put(:consecutive_successes, provider.consecutive_successes + 1)
          |> Map.put(:consecutive_failures, 0)
          |> Map.put(:last_health_check, System.system_time(:millisecond))

        state
        |> put_provider_and_refresh(provider_id, updated)
    end
  end

  defp update_provider_success_ws(state, provider_id) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        pol = provider.ws_policy || HealthPolicy.new()
        new_pol = HealthPolicy.apply_event(pol, {:success, 0, nil})

        updated =
          provider
          |> Map.put(:ws_policy, new_pol)
          |> Map.put(:ws_status, :healthy)
          |> then(&Map.put(&1, :status, derive_aggregate_status(&1)))
          |> Map.put(:consecutive_successes, provider.consecutive_successes + 1)
          |> Map.put(:consecutive_failures, 0)
          |> Map.put(:last_health_check, System.system_time(:millisecond))

        state
        |> put_provider_and_refresh(provider_id, updated)
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
        {jerr, context} = normalize_error_for_pool(error, provider_id)
        now_ms = System.monotonic_time(:millisecond)

        pol =
          case transport do
            :http -> provider.http_policy || HealthPolicy.new()
            :ws -> provider.ws_policy || HealthPolicy.new()
          end

        new_pol = HealthPolicy.apply_event(pol, {:failure, jerr, context, nil, now_ms})

        cond do
          jerr.category == :rate_limit ->
            cooldown_until = new_pol.cooldown_until

            updated =
              provider
              |> Map.put((transport == :http && :http_policy) || :ws_policy, new_pol)
              |> Map.put((transport == :http && :http_status) || :ws_status, :rate_limited)
              |> then(&Map.put(&1, :status, derive_aggregate_status(&1)))
              |> Map.put(:last_error, jerr)
              |> Map.put(:last_health_check, System.system_time(:millisecond))

            publish_provider_event(state.chain_name, provider_id, :cooldown_start, %{
              until: cooldown_until
            })

            state
            |> put_provider_and_refresh(provider_id, updated)
            |> increment_failure_stats()

          jerr.category == :client_error and context == :live_traffic ->
            updated =
              provider
              |> Map.put(:last_error, jerr)
              |> Map.put(:last_health_check, System.system_time(:millisecond))

            state |> put_provider_and_refresh(provider_id, updated) |> increment_failure_stats()

          true ->
            new_failures = provider.consecutive_failures + 1
            failure_threshold = new_pol.config.failure_threshold

            new_status =
              HealthPolicy.decide_failure_status(jerr, context, new_failures, failure_threshold)

            updated =
              provider
              |> Map.put((transport == :http && :http_policy) || :ws_policy, new_pol)
              |> Map.put((transport == :http && :http_status) || :ws_status, new_status)
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

  defp maybe_emit_cooldown_end(state, provider_id, provider) do
    prev_cooldown = provider.policy.cooldown_until

    if prev_cooldown do
      publish_provider_event(state.chain_name, provider_id, :cooldown_end, %{})

      :telemetry.execute([:lasso, :provider, :cooldown, :end], %{count: 1}, %{
        chain: state.chain_name,
        provider_id: provider_id
      })

      state
    else
      state
    end
  end

  defp maybe_emit_became_healthy(state, provider_id, provider) do
    if provider.status != :healthy do
      publish_provider_event(state.chain_name, provider_id, :healthy, %{})

      :telemetry.execute([:lasso, :provider, :status], %{count: 1}, %{
        chain: state.chain_name,
        provider_id: provider_id,
        status: :healthy
      })

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
        now_ms = System.monotonic_time(:millisecond)
        policy = provider.policy || HealthPolicy.new()

        new_policy =
          HealthPolicy.apply_event(policy, {:failure, jerr, context, nil, now_ms})

        cond do
          jerr.category == :rate_limit ->
            cooldown_until = new_policy.cooldown_until

            Logger.warning(
              "Provider #{provider_id} rate limited, cooling down until #{inspect(cooldown_until)}"
            )

            updated_provider =
              provider
              |> Map.merge(%{
                status: :rate_limited,
                last_error: jerr,
                last_health_check: System.system_time(:millisecond),
                policy: new_policy
              })

            publish_provider_event(state.chain_name, provider_id, :cooldown_start, %{
              until: cooldown_until
            })

            :telemetry.execute([:lasso, :provider, :cooldown, :start], %{count: 1}, %{
              chain: state.chain_name,
              provider_id: provider_id,
              cooldown_ms: if(cooldown_until, do: max(cooldown_until - now_ms, 0), else: 0)
            })

            state
            |> put_provider_and_refresh(provider_id, updated_provider)
            |> increment_failure_stats()

          jerr.category == :client_error and context == :live_traffic ->
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
            failure_threshold = new_policy.config.failure_threshold

            new_status =
              HealthPolicy.decide_failure_status(
                jerr,
                context,
                new_consecutive_failures,
                failure_threshold
              )

            updated_provider =
              provider
              |> Map.merge(%{
                status: new_status,
                consecutive_failures: new_consecutive_failures,
                consecutive_successes: 0,
                last_error: jerr,
                last_health_check: System.system_time(:millisecond),
                policy: new_policy
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

  # defp start_rate_limit_cooldown/2: superseded by HealthPolicy cooldown handling

  # Failure status decision logic centralized in HealthPolicy

  defp increment_failure_stats(state) do
    state
    |> Map.update!(:total_requests, &(&1 + 1))
    |> Map.update!(:failed_requests, &(&1 + 1))
  end

  defp derive_aggregate_status(provider) do
    http = Map.get(provider, :http_status)
    ws = Map.get(provider, :ws_status)

    cond do
      http == :healthy or ws == :healthy ->
        :healthy

      http == :connecting or ws == :connecting ->
        :connecting

      (http in [:unhealthy, :disconnected, :rate_limited] or is_nil(http)) and
          (ws in [:unhealthy, :disconnected, :rate_limited] or is_nil(ws)) ->
        :unhealthy

      true ->
        :degraded
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

        :cooldown_start ->
          %Provider.CooldownStart{
            ts: ts,
            chain: chain_name,
            provider_id: provider_id,
            until:
              Map.get(details, :until) || Map.get(details, "until") ||
                System.monotonic_time(:millisecond)
          }

        :cooldown_end ->
          %Provider.CooldownEnd{ts: ts, chain: chain_name, provider_id: provider_id}

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
  defp update_recovery_time_for_circuit(recovery_times, provider_id, transport, chain) do
    breaker_id = {chain, provider_id, transport}

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
          via_name(chain),
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

  # Telemetry: emit event when provider excluded due to lag
  defp telemetry_lag_excluded(chain, provider_id, lag, max_lag_blocks) do
    :telemetry.execute(
      [:lasso, :selection, :lag_excluded],
      %{count: 1, lag_blocks: abs(lag)},
      %{
        chain: chain,
        provider_id: provider_id,
        lag: lag,
        threshold: -max_lag_blocks
      }
    )
  end

  # Telemetry: emit event when ALL providers excluded due to lag
  defp telemetry_all_providers_lagging(chain, provider_count, max_lag_blocks) do
    :telemetry.execute(
      [:lasso, :selection, :all_providers_lagging],
      %{count: 1, provider_count: provider_count},
      %{
        chain: chain,
        threshold: -max_lag_blocks
      }
    )
  end

  # Telemetry: emit event when individual provider has no lag data
  defp telemetry_lag_data_unavailable(chain, provider_id, reason) do
    :telemetry.execute(
      [:lasso, :selection, :lag_data_unavailable],
      %{count: 1},
      %{
        chain: chain,
        provider_id: provider_id,
        reason: reason
      }
    )
  end

  # Telemetry: emit event when lag filtering is completely disabled (all providers missing lag data)
  defp telemetry_lag_filtering_disabled(chain, provider_count) do
    :telemetry.execute(
      [:lasso, :selection, :lag_filtering_disabled],
      %{count: 1, provider_count: provider_count},
      %{
        chain: chain
      }
    )
  end

  def via_name(chain_name) do
    {:via, Registry, {Lasso.Registry, {:provider_pool, chain_name}}}
  end
end
