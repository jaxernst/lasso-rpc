defmodule Lasso.HealthProbe.BatchCoordinator do
  @moduledoc """
  Centralized health probe coordinator that cycles through all providers sequentially.

  Instead of spawning N individual GenServer workers (each with its own timer),
  this coordinator uses a single timer to probe one provider at a time in round-robin
  fashion. This reduces process count and smooths out load distribution.

  ## Performance Benefits

  - **Reduced process count**: 1 GenServer instead of N workers
  - **Reduced timer count**: 1 timer instead of N timers
  - **Smoother load**: Staggered probes instead of synchronized bursts
  - **Lower memory**: Single process state instead of N process heaps

  ## Probe Cycle

  With a 200ms tick interval and 46 providers:
  - Each provider is probed every 9.2 seconds (200ms × 46)
  - This is close to the recommended 10s health check interval
  - Load is distributed evenly across time

  ## Design

  The coordinator maintains per-provider state (consecutive failures, last probe time, etc.)
  in its own state map. It subscribes to PubSub events for WS connection stability and
  updates the relevant provider's state accordingly.
  """

  use GenServer
  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.RPC.Transport.WebSocket.Connection, as: WSConnection
  alias Lasso.RPC.{Channel, Response, TransportRegistry}

  @tick_interval_ms 200
  @default_timeout_ms 5_000
  @max_consecutive_failures_before_warn 3

  @type provider_state :: %{
          provider_id: String.t(),
          # HTTP probe state
          consecutive_failures: non_neg_integer(),
          consecutive_successes: non_neg_integer(),
          last_probe_time: integer() | nil,
          last_latency_ms: non_neg_integer() | nil,
          has_http: boolean(),
          # WS probe state
          ws_consecutive_failures: non_neg_integer(),
          ws_consecutive_successes: non_neg_integer(),
          ws_last_probe_time: integer() | nil,
          ws_last_latency_ms: non_neg_integer() | nil,
          has_ws: boolean(),
          ws_connection_stable: boolean()
        }

  @type t :: %__MODULE__{
          chain: String.t(),
          profile: String.t(),
          providers: %{String.t() => provider_state()},
          provider_ids: [String.t()],
          current_index: non_neg_integer(),
          timeout_ms: pos_integer(),
          timer_ref: reference() | nil,
          paused: boolean()
        }

  defstruct [
    :chain,
    :profile,
    :providers,
    :provider_ids,
    :current_index,
    :timeout_ms,
    :timer_ref,
    :paused
  ]

  ## Client API

  @spec start_link({String.t(), String.t(), [String.t()], keyword()}) :: GenServer.on_start()
  def start_link({profile, chain, provider_ids, opts}) when is_binary(profile) do
    GenServer.start_link(__MODULE__, {profile, chain, provider_ids, opts},
      name: via(profile, chain)
    )
  end

  @spec via(String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain) when is_binary(profile) do
    {:via, Registry, {Lasso.Registry, {:health_probe_coordinator, profile, chain}}}
  end

  @doc """
  Get the current status of the batch coordinator.
  """
  @spec get_status(String.t(), String.t()) :: map() | {:error, :not_running}
  def get_status(profile, chain) when is_binary(profile) do
    GenServer.call(via(profile, chain), :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Get status for a specific provider.
  """
  @spec get_provider_status(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_running}
  def get_provider_status(profile, chain, provider_id) when is_binary(profile) do
    GenServer.call(via(profile, chain), {:get_provider_status, provider_id})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Add a provider to the coordinator dynamically.
  """
  @spec add_provider(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_provider(profile, chain, provider_id) when is_binary(profile) do
    GenServer.call(via(profile, chain), {:add_provider, provider_id})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Remove a provider from the coordinator dynamically.
  """
  @spec remove_provider(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_provider(profile, chain, provider_id) when is_binary(profile) do
    GenServer.call(via(profile, chain), {:remove_provider, provider_id})
  catch
    :exit, _ -> {:error, :not_running}
  end

  ## GenServer Callbacks

  @impl true
  def init({profile, chain, provider_ids, opts}) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # Subscribe to WS connection events for this chain
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{profile}:#{chain}")

    # Initialize per-provider state
    providers =
      provider_ids
      |> Enum.map(fn provider_id ->
        {provider_id, init_provider_state(profile, chain, provider_id)}
      end)
      |> Map.new()

    state = %__MODULE__{
      chain: chain,
      profile: profile,
      providers: providers,
      provider_ids: provider_ids,
      current_index: 0,
      timeout_ms: timeout,
      timer_ref: nil,
      paused: false
    }

    # Schedule first tick after a short delay to let connections establish
    state = schedule_tick(state, 2_000)

    provider_count = length(provider_ids)
    cycle_time_s = Float.round(@tick_interval_ms * provider_count / 1000, 1)

    Logger.info("HealthProbe.BatchCoordinator started",
      chain: chain,
      profile: profile,
      provider_count: provider_count,
      tick_interval_ms: @tick_interval_ms,
      cycle_time_seconds: cycle_time_s
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      chain: state.chain,
      profile: state.profile,
      provider_count: length(state.provider_ids),
      current_index: state.current_index,
      tick_interval_ms: @tick_interval_ms,
      paused: state.paused,
      providers:
        Enum.map(state.provider_ids, fn id ->
          provider = Map.get(state.providers, id, %{})

          %{
            id: id,
            http_failures: Map.get(provider, :consecutive_failures, 0),
            http_successes: Map.get(provider, :consecutive_successes, 0),
            ws_failures: Map.get(provider, :ws_consecutive_failures, 0),
            ws_successes: Map.get(provider, :ws_consecutive_successes, 0)
          }
        end)
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:get_provider_status, provider_id}, _from, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      provider ->
        status = %{
          consecutive_failures: provider.consecutive_failures,
          consecutive_successes: provider.consecutive_successes,
          last_probe_time: provider.last_probe_time,
          last_latency_ms: provider.last_latency_ms,
          has_http: provider.has_http,
          ws_consecutive_failures: provider.ws_consecutive_failures,
          ws_consecutive_successes: provider.ws_consecutive_successes,
          ws_last_probe_time: provider.ws_last_probe_time,
          ws_last_latency_ms: provider.ws_last_latency_ms,
          has_ws: provider.has_ws,
          ws_connection_stable: provider.ws_connection_stable
        }

        {:reply, {:ok, status}, state}
    end
  end

  def handle_call({:add_provider, provider_id}, _from, state) do
    if Map.has_key?(state.providers, provider_id) do
      {:reply, {:error, :already_exists}, state}
    else
      provider_state = init_provider_state(state.profile, state.chain, provider_id)

      new_state = %{
        state
        | providers: Map.put(state.providers, provider_id, provider_state),
          provider_ids: state.provider_ids ++ [provider_id]
      }

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:remove_provider, provider_id}, _from, state) do
    if Map.has_key?(state.providers, provider_id) do
      new_provider_ids = Enum.reject(state.provider_ids, &(&1 == provider_id))

      # Adjust index if needed
      new_index =
        if state.current_index >= length(new_provider_ids) do
          0
        else
          state.current_index
        end

      new_state = %{
        state
        | providers: Map.delete(state.providers, provider_id),
          provider_ids: new_provider_ids,
          current_index: new_index
      }

      {:reply, :ok, new_state}
    else
      # Idempotent: removing non-existent provider is OK
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:probe_tick, state) do
    state = execute_current_probe(state)
    state = advance_index(state)
    state = schedule_tick(state, @tick_interval_ms)
    {:noreply, state}
  end

  # WS connection stability achieved - signal recovery to circuit breaker
  def handle_info({:ws_stable, provider_id}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        {:noreply, state}

      provider ->
        cb_id = {state.profile, state.chain, provider_id, :ws}
        CircuitBreaker.signal_recovery(cb_id)

        updated_provider = %{provider | ws_connection_stable: true}
        new_providers = Map.put(state.providers, provider_id, updated_provider)
        {:noreply, %{state | providers: new_providers}}
    end
  end

  # WS connected - stability not proven yet
  def handle_info({:ws_connected, provider_id, _conn_id}, state) do
    state = update_provider(state, provider_id, fn p -> %{p | ws_connection_stable: false} end)
    {:noreply, state}
  end

  # WS disconnected - reset stability
  def handle_info({:ws_disconnected, provider_id, _error}, state) do
    state = update_provider(state, provider_id, fn p -> %{p | ws_connection_stable: false} end)
    {:noreply, state}
  end

  # WS closed - reset stability
  def handle_info({:ws_closed, provider_id, _code, _error}, state) do
    state = update_provider(state, provider_id, fn p -> %{p | ws_connection_stable: false} end)
    {:noreply, state}
  end

  # Ignore unrelated messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp init_provider_state(profile, chain, provider_id) do
    has_http = has_http_capability?(profile, chain, provider_id)
    has_ws = has_ws_capability?(profile, chain, provider_id)
    ws_stable = get_initial_ws_stability(profile, chain, provider_id)

    %{
      provider_id: provider_id,
      consecutive_failures: 0,
      consecutive_successes: 0,
      last_probe_time: nil,
      last_latency_ms: nil,
      has_http: has_http,
      ws_consecutive_failures: 0,
      ws_consecutive_successes: 0,
      ws_last_probe_time: nil,
      ws_last_latency_ms: nil,
      has_ws: has_ws,
      ws_connection_stable: ws_stable
    }
  end

  defp schedule_tick(state, delay_ms) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :probe_tick, delay_ms)
    %{state | timer_ref: ref}
  end

  defp advance_index(state) do
    case state.provider_ids do
      [] ->
        state

      ids ->
        new_index = rem(state.current_index + 1, length(ids))
        %{state | current_index: new_index}
    end
  end

  defp update_provider(state, provider_id, update_fn) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        updated = update_fn.(provider)
        %{state | providers: Map.put(state.providers, provider_id, updated)}
    end
  end

  defp execute_current_probe(state) do
    if state.paused or state.provider_ids == [] do
      state
    else
      provider_id = Enum.at(state.provider_ids, state.current_index)

      case Map.get(state.providers, provider_id) do
        nil ->
          state

        provider ->
          updated_provider =
            provider
            |> execute_http_probe(state)
            |> execute_ws_probe(state)

          %{state | providers: Map.put(state.providers, provider_id, updated_provider)}
      end
    end
  end

  # HTTP probe execution
  defp execute_http_probe(%{has_http: false} = provider, _state), do: provider

  defp execute_http_probe(provider, state) do
    start_time = System.monotonic_time(:millisecond)

    result =
      do_http_probe(state.profile, state.chain, provider.provider_id, state.timeout_ms)

    latency_ms = System.monotonic_time(:millisecond) - start_time
    now = System.system_time(:millisecond)

    case result do
      {:ok, _chain_id} ->
        handle_http_probe_success(provider, state, latency_ms, now)

      {:error, reason} ->
        handle_http_probe_failure(provider, state, reason, latency_ms, now)
    end
  end

  # WS probe execution
  defp execute_ws_probe(%{has_ws: false} = provider, _state), do: provider

  defp execute_ws_probe(provider, state) do
    if ws_connected?(state.profile, state.chain, provider.provider_id) do
      start_time = System.monotonic_time(:millisecond)

      result =
        do_ws_probe(state.profile, state.chain, provider.provider_id, state.timeout_ms)

      latency_ms = System.monotonic_time(:millisecond) - start_time
      now = System.system_time(:millisecond)

      case result do
        {:ok, _chain_id} ->
          handle_ws_probe_success(provider, state, latency_ms, now)

        {:error, reason} ->
          handle_ws_probe_failure(provider, state, reason, latency_ms, now)
      end
    else
      provider
    end
  end

  # HTTP probe success/failure handlers

  defp handle_http_probe_success(provider, state, latency_ms, now) do
    cb_id = {state.profile, state.chain, provider.provider_id, :http}
    CircuitBreaker.signal_recovery(cb_id)

    new_consecutive_successes = provider.consecutive_successes + 1
    was_failing = provider.consecutive_failures >= @max_consecutive_failures_before_warn

    if was_failing do
      Logger.info("HealthProbe: HTTP recovered",
        chain: state.chain,
        provider_id: provider.provider_id,
        latency_ms: latency_ms,
        after_failures: provider.consecutive_failures
      )

      broadcast_recovery(state, provider, :http, provider.consecutive_failures)
    end

    %{
      provider
      | consecutive_failures: 0,
        consecutive_successes: new_consecutive_successes,
        last_probe_time: now,
        last_latency_ms: latency_ms
    }
  end

  defp handle_http_probe_failure(provider, state, reason, latency_ms, now) do
    cb_id = {state.profile, state.chain, provider.provider_id, :http}
    CircuitBreaker.record_failure(cb_id, reason)

    new_consecutive_failures = provider.consecutive_failures + 1

    if new_consecutive_failures == @max_consecutive_failures_before_warn do
      Logger.warning("HealthProbe: HTTP degraded",
        chain: state.chain,
        provider_id: provider.provider_id,
        consecutive_failures: new_consecutive_failures,
        reason: inspect(reason)
      )
    end

    %{
      provider
      | consecutive_failures: new_consecutive_failures,
        consecutive_successes: 0,
        last_probe_time: now,
        last_latency_ms: latency_ms
    }
  end

  # WS probe success/failure handlers

  defp handle_ws_probe_success(provider, state, latency_ms, now) do
    cb_id = {state.profile, state.chain, provider.provider_id, :ws}

    if provider.ws_connection_stable do
      CircuitBreaker.signal_recovery(cb_id)
    end

    new_consecutive_successes = provider.ws_consecutive_successes + 1
    was_failing = provider.ws_consecutive_failures >= @max_consecutive_failures_before_warn

    if was_failing do
      Logger.info("HealthProbe: WS recovered",
        chain: state.chain,
        provider_id: provider.provider_id,
        latency_ms: latency_ms,
        after_failures: provider.ws_consecutive_failures
      )

      broadcast_recovery(state, provider, :ws, provider.ws_consecutive_failures)
    end

    %{
      provider
      | ws_consecutive_failures: 0,
        ws_consecutive_successes: new_consecutive_successes,
        ws_last_probe_time: now,
        ws_last_latency_ms: latency_ms
    }
  end

  defp handle_ws_probe_failure(provider, state, reason, latency_ms, now) do
    cb_id = {state.profile, state.chain, provider.provider_id, :ws}
    CircuitBreaker.record_failure(cb_id, reason)

    new_consecutive_failures = provider.ws_consecutive_failures + 1

    if new_consecutive_failures == @max_consecutive_failures_before_warn do
      Logger.warning("HealthProbe: WS degraded",
        chain: state.chain,
        provider_id: provider.provider_id,
        consecutive_failures: new_consecutive_failures,
        reason: inspect(reason)
      )
    end

    %{
      provider
      | ws_consecutive_failures: new_consecutive_failures,
        ws_consecutive_successes: 0,
        ws_last_probe_time: now,
        ws_last_latency_ms: latency_ms
    }
  end

  defp broadcast_recovery(state, provider, transport, old_consecutive_failures) do
    provider_key = {state.profile, provider.provider_id}
    timestamp = System.system_time(:millisecond)

    old_state = %{consecutive_failures: old_consecutive_failures}

    new_state = %{
      consecutive_successes:
        if(transport == :http,
          do: provider.consecutive_successes + 1,
          else: provider.ws_consecutive_successes + 1
        ),
      status: :healthy
    }

    msg = {:health_probe_recovery, provider_key, transport, old_state, new_state, timestamp}

    Phoenix.PubSub.broadcast(Lasso.PubSub, "health_probe:#{state.profile}:#{state.chain}", msg)
  end

  # HTTP probe implementation

  defp do_http_probe(profile, chain, provider_id, timeout_ms) do
    case TransportRegistry.get_channel(profile, chain, provider_id, :http) do
      {:ok, channel} ->
        rpc_request = %{
          "jsonrpc" => "2.0",
          "method" => "eth_chainId",
          "params" => [],
          "id" => :rand.uniform(1_000_000)
        }

        case Channel.request(channel, rpc_request, timeout_ms) do
          {:ok, %Response.Success{} = response, _io_ms} ->
            case Response.Success.decode_result(response) do
              {:ok, "0x" <> hex} ->
                {:ok, String.to_integer(hex, 16)}

              {:ok, result} ->
                {:ok, result}

              {:error, reason} ->
                {:error, {:decode_failed, reason}}
            end

          {:ok, %Response.Error{error: jerror} = _error, _io_ms} ->
            if jerror.category == :rate_limit do
              {:error, jerror}
            else
              {:ok, :error_response}
            end

          {:error, reason, _io_ms} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:channel_unavailable, reason}}
    end
  rescue
    e ->
      Logger.error("HealthProbe crashed",
        chain: chain,
        provider_id: provider_id,
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, {:exception, Exception.message(e)}}
  end

  # WS probe implementation

  defp do_ws_probe(profile, chain, provider_id, timeout_ms) do
    case WSConnection.request({profile, chain, provider_id}, "eth_chainId", [], timeout_ms) do
      {:ok, %Response.Success{} = response} ->
        case Response.Success.decode_result(response) do
          {:ok, "0x" <> hex} ->
            {:ok, String.to_integer(hex, 16)}

          {:ok, result} ->
            {:ok, result}

          {:error, _} ->
            {:ok, :parse_error}
        end

      {:error, %{category: :rate_limit} = jerr} ->
        {:error, jerr}

      {:error, %{retriable?: true} = _jerr} ->
        {:ok, :error_response}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, {:ws_not_connected, chain, provider_id}}

    :exit, {:timeout, _} ->
      {:error, {:ws_request_timeout, timeout_ms}}

    kind, error ->
      Logger.error("WS HealthProbe crashed",
        chain: chain,
        provider_id: provider_id,
        error: Exception.format(kind, error, __STACKTRACE__)
      )

      {:error, {:exception, inspect({kind, error})}}
  end

  # Capability checks

  defp get_initial_ws_stability(profile, chain, provider_id) do
    case WSConnection.status(profile, chain, provider_id) do
      %{connection_stable: true} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp has_http_capability?(profile, chain, provider_id) do
    case TransportRegistry.get_channel(profile, chain, provider_id, :http) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp has_ws_capability?(profile, chain, provider_id) do
    case TransportRegistry.get_channel(profile, chain, provider_id, :ws) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp ws_connected?(profile, chain, provider_id) do
    case WSConnection.status(profile, chain, provider_id) do
      %{connected: true} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end
end
