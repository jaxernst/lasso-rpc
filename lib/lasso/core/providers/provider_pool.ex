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
  alias Lasso.RPC.HealthPolicy

  defstruct [
    :chain_name,
    :providers,
    :active_providers,
    :stats,
    # Circuit breaker state per provider_id: :closed | :open | :half_open
    circuit_states: %{}
  ]

  defmodule ProviderState do
    @derive Jason.Encoder
    defstruct [
      :id,
      :config,
      :pid,
      # Health status of the provider:
      # :healthy | :unhealthy | :connecting | :disconnected | :rate_limited | :misconfigured | :degraded
      :status,
      # Policy-derived availability for routing: :up | :limited | :down | :misconfigured
      :availability,
      :last_health_check,
      :consecutive_failures,
      :consecutive_successes,
      :last_error,
      # Cooldown fields for rate limit handling
      :cooldown_until,
      # Centralized health policy state (availability + signals)
      :policy
    ]
  end

  defmodule PoolStats do
    @derive Jason.Encoder
    defstruct total_providers: 0,
              healthy_providers: 0,
              active_providers: 0,
              total_requests: 0,
              failed_requests: 0,
              avg_response_time: 0,
              last_failover: nil
  end

  @type chain_name :: String.t()
  @type provider_id :: String.t()
  @type strategy :: :priority | :round_robin | :fastest | :cheapest
  @type health_status ::
          :healthy
          | :unhealthy
          | :connecting
          | :disconnected
          | :rate_limited
          | :misconfigured
          | :degraded

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
  The pid will be monitored; HTTP-only providers should never call this.
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
    GenServer.call(via_name(chain_name), :get_status)
  end

  @doc """
  Lists provider candidates enriched with policy-derived availability for selection.

  Supported filters: %{protocol: :http | :ws | :both, exclude: [provider_id]}
  """
  @spec list_candidates(chain_name, map()) :: [map()]
  def list_candidates(chain_name, filters \\ %{}) when is_map(filters) do
    GenServer.call(via_name(chain_name), {:list_candidates, filters})
  end

  @doc """
  Reports a successful operation (no latency needed; performance is tracked elsewhere).
  """
  @spec report_success(chain_name, provider_id) :: :ok
  def report_success(chain_name, provider_id) do
    GenServer.cast(via_name(chain_name), {:report_success, provider_id})
  end

  @doc """
  Reports a failure for error rate tracking.
  """
  @spec report_failure(chain_name, provider_id, term()) :: :ok
  def report_failure(chain_name, provider_id, error) do
    GenServer.cast(via_name(chain_name), {:report_failure, provider_id, error})
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

  # GenServer callbacks

  @impl true
  def init({chain_name, _chain_config}) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{chain_name}")

    state = %__MODULE__{
      chain_name: chain_name,
      providers: %{},
      active_providers: [],
      stats: %PoolStats{},
      circuit_states: %{}
    }

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
            last_health_check: System.system_time(:millisecond),
            consecutive_failures: 0,
            consecutive_successes: 0,
            last_error: nil,
            cooldown_until: nil,
            policy: Lasso.RPC.HealthPolicy.new()
          }

        %ProviderState{} = prev ->
          # Preserve pid and all metrics; refresh config only
          %{prev | config: provider_config}
      end

    new_state =
      state
      |> Map.update!(:providers, &Map.put(&1, provider_id, provider_state))
      |> update_active_providers()

    Logger.info(
      "Registered provider #{provider_id} for #{state.chain_name} (status: #{provider_state.status}, active_providers: #{inspect(new_state.active_providers)})"
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:attach_ws_connection, provider_id, pid}, _from, state) when is_pid(pid) do
    case Map.get(state.providers, provider_id) do
      %ProviderState{} = prev ->
        updated = %{prev | pid: pid, status: prev.status || :connecting}

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
        circuit_state = Map.get(state.circuit_states, id, :closed)

        {cooldown_until, is_in_cooldown} =
          case Map.get(provider, :policy) do
            %Lasso.RPC.HealthPolicy{} = pol ->
              {pol.cooldown_until, Lasso.RPC.HealthPolicy.cooldown?(pol, current_time)}

            _ ->
              cuc = provider.cooldown_until
              {cuc, cuc && cuc > current_time}
          end

        availability =
          case Map.get(provider, :policy) do
            %Lasso.RPC.HealthPolicy{} = pol -> Lasso.RPC.HealthPolicy.availability(pol)
            _ -> Map.get(provider, :availability, :up)
          end

        %{
          id: id,
          name: Map.get(provider.config, :name, id),
          config: provider.config,
          status: provider.status,
          availability: availability,
          circuit_state: circuit_state,
          consecutive_failures: provider.consecutive_failures,
          consecutive_successes: provider.consecutive_successes,
          last_health_check: provider.last_health_check,
          last_error: provider.last_error,
          is_in_cooldown: is_in_cooldown,
          cooldown_until: cooldown_until,
          policy: Map.get(provider, :policy)
        }
      end)

    status = %{
      chain_name: state.chain_name,
      total_providers: map_size(state.providers),
      active_providers: length(state.active_providers),
      providers: providers,
      circuit_states: state.circuit_states,
      stats: state.stats
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:list_candidates, filters}, _from, state) do
    Logger.debug(
      "ProviderPool.list_candidates for #{state.chain_name}: active_providers=#{inspect(state.active_providers)}, circuit_states=#{inspect(state.circuit_states)}, filters=#{inspect(filters)}"
    )

    candidates =
      state
      |> candidates_ready(filters)
      |> Enum.map(fn p ->
        availability =
          case Map.get(p, :policy) do
            %Lasso.RPC.HealthPolicy{} = pol -> Lasso.RPC.HealthPolicy.availability(pol)
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
  def handle_cast({:report_success, provider_id}, state) do
    new_state = update_provider_success(state, provider_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_failure, provider_id, error}, state) do
    new_state = update_provider_failure(state, provider_id, error)
    {:noreply, new_state}
  end

  # Typed WS connection events
  @impl true
  def handle_info({:ws_connected, provider_id}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        updated = %{
          provider
          | status: :healthy,
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            last_health_check: System.system_time(:millisecond)
        }

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
        updated = %{
          provider
          | status: :disconnected,
            consecutive_failures: provider.consecutive_failures + 1,
            last_error: jerr,
            last_health_check: System.system_time(:millisecond)
        }

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
        updated = %{
          provider
          | status: :disconnected,
            consecutive_failures: provider.consecutive_failures + 1,
            last_error: jerr,
            last_health_check: System.system_time(:millisecond)
        }

        event_details = %{reason: jerr.message}
        publish_provider_event(state.chain_name, provider_id, :ws_closed, event_details)

        new_state = put_provider_and_refresh(state, provider_id, updated)
        {:noreply, new_state}
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
        {:circuit_breaker_event, %{provider_id: provider_id, from: from, to: to}},
        state
      )
      when is_binary(provider_id) and from in [:closed, :open, :half_open] and
             to in [:closed, :open, :half_open] do
    Logger.info("ProviderPool[#{state.chain_name}]: CB event #{provider_id} #{from} -> #{to}")
    new_states = Map.put(state.circuit_states, provider_id, to)
    {:noreply, %{state | circuit_states: new_states}}
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

  # NOTE: candidates_ready and supports_protocol? are used by list_candidates/2
  # Keep them private helpers for candidate construction.
  defp candidates_ready(state, filters) do
    current_time = System.monotonic_time(:millisecond)

    state.active_providers
    |> Enum.map(&Map.get(state.providers, &1))
    |> Enum.filter(fn p ->
      av =
        Map.get(p, :availability) ||
          case Map.get(p, :policy) do
            %Lasso.RPC.HealthPolicy{} = pol -> Lasso.RPC.HealthPolicy.availability(pol)
            _ -> :up
          end

      av in [:up, :limited]
    end)
    |> Enum.filter(fn p ->
      case Map.get(p, :policy) do
        %Lasso.RPC.HealthPolicy{} = pol ->
          not Lasso.RPC.HealthPolicy.cooldown?(pol, current_time)

        _ ->
          is_nil(p.cooldown_until) or p.cooldown_until <= current_time
      end
    end)
    |> Enum.filter(&supports_protocol?(&1.config, Map.get(filters, :protocol)))
    |> Enum.filter(fn provider ->
      case Map.get(filters, :protocol) do
        :ws ->
          provider.status == :healthy and is_pid(ws_connection_pid(provider.id))

        _ ->
          true
      end
    end)
    |> Enum.filter(fn provider ->
      case Map.get(state.circuit_states, provider.id) do
        :open -> false
        _ -> true
      end
    end)
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

  defp supports_protocol?(_provider_config, nil), do: true
  defp supports_protocol?(provider_config, :http), do: is_binary(Map.get(provider_config, :url))
  defp supports_protocol?(provider_config, :ws), do: is_binary(Map.get(provider_config, :ws_url))

  defp supports_protocol?(provider_config, :both),
    do: is_binary(Map.get(provider_config, :url)) and is_binary(Map.get(provider_config, :ws_url))

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
        provider.status in [:healthy, :connecting]
      end)
      |> Enum.map(fn {id, _provider} -> id end)

    %{state | active_providers: viable_providers}
  end

  defp update_provider_success(state, provider_id) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        policy = provider.policy || Lasso.RPC.HealthPolicy.new()
        new_policy = Lasso.RPC.HealthPolicy.apply_event(policy, {:success, 0, nil})

        updated_provider =
          provider
          |> Map.merge(%{
            status: :healthy,
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            last_health_check: System.system_time(:millisecond),
            policy: new_policy
          })

        state = maybe_emit_cooldown_end(state, provider_id, provider)
        state = maybe_emit_became_healthy(state, provider_id, provider)

        new_stats = %{state.stats | total_requests: state.stats.total_requests + 1}

        state
        |> put_provider_and_refresh(provider_id, updated_provider)
        |> Map.put(:stats, new_stats)
    end
  end

  defp maybe_emit_cooldown_end(state, provider_id, provider) do
    prev_cooldown =
      case provider.policy do
        %Lasso.RPC.HealthPolicy{cooldown_until: cu} -> cu
        _ -> provider.cooldown_until
      end

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
        policy = provider.policy || Lasso.RPC.HealthPolicy.new()

        new_policy =
          Lasso.RPC.HealthPolicy.apply_event(policy, {:failure, jerr, context, nil, now_ms})

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

  defp normalize_error_for_pool({:health_check, %Lasso.JSONRPC.Error{} = jerr}, _provider_id),
    do: {jerr, :health_check}

  defp normalize_error_for_pool({:health_check, other}, provider_id),
    do: {Lasso.JSONRPC.Error.from(other, provider_id: provider_id), :health_check}

  defp normalize_error_for_pool(%Lasso.JSONRPC.Error{} = jerr, _provider_id),
    do: {jerr, :live_traffic}

  defp normalize_error_for_pool(other, provider_id),
    do: {Lasso.JSONRPC.Error.from(other, provider_id: provider_id), :live_traffic}

  # defp start_rate_limit_cooldown/2: superseded by HealthPolicy cooldown handling

  # Failure status decision logic centralized in HealthPolicy

  defp increment_failure_stats(state) do
    new_stats = %{
      state.stats
      | total_requests: state.stats.total_requests + 1,
        failed_requests: state.stats.failed_requests + 1
    }

    %{state | stats: new_stats}
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

  def via_name(chain_name) do
    {:via, Registry, {Lasso.Registry, {:provider_pool, chain_name}}}
  end
end
