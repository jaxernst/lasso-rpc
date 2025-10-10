defmodule Lasso.RPC.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for RPC provider fault tolerance.

  Implements the circuit breaker pattern to prevent cascade failures
  when providers are experiencing issues. Provides automatic recovery
  and configurable failure thresholds.
  """

  use GenServer
  require Logger
  alias Lasso.RPC.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  defstruct [
    :chain,
    :provider_id,
    :transport,
    :failure_threshold,
    :recovery_timeout,
    :success_threshold,
    # :closed, :open, :half_open
    :state,
    :failure_count,
    :last_failure_time,
    :success_count,
    :config,
    # Number of in-flight attempts currently admitted while half-open
    inflight_count: 0,
    # Max parallel attempts allowed during half-open (conservative default: 1)
    half_open_max_inflight: 1
  ]

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type transport :: :http | :ws
  @type breaker_id :: {chain, provider_id, transport}
  @type breaker_state :: :closed | :open | :half_open
  @type state_t :: %__MODULE__{
          chain: chain,
          provider_id: provider_id,
          failure_threshold: non_neg_integer(),
          recovery_timeout: non_neg_integer(),
          success_threshold: non_neg_integer(),
          state: breaker_state,
          failure_count: non_neg_integer(),
          last_failure_time: integer() | nil,
          success_count: non_neg_integer(),
          config: map()
        }

  @doc """
  Starts a circuit breaker for a provider.
  """
  @spec start_link({breaker_id, map()}) :: GenServer.on_start()
  def start_link({id, config}) do
    GenServer.start_link(__MODULE__, {id, config}, name: via_name(id))
  end

  @doc """
  Attempts to execute a function guarded by the circuit breaker without
  executing the function inside the GenServer.

  Flow:
  - Fast admission check (GenServer.call {:admit, now_ms})
  - Execute fun in the caller process
  - Report result asynchronously (GenServer.cast {:report, token, result})
  """
  @spec call(breaker_id, (-> any()), non_neg_integer()) ::
          {:ok, any()} | {:error, term()}
  def call({chain, provider_id, transport} = id, fun, _timeout \\ 30_000) do
    now_ms = System.monotonic_time(:millisecond)
    admit_start_us = System.monotonic_time(:microsecond)

    decision = GenServer.call(via_name(id), {:admit, now_ms})
    admit_call_ms = div(System.monotonic_time(:microsecond) - admit_start_us, 1000)

    decision_tag =
      case decision do
        {:allow, _} -> :allow
        {:deny, reason} -> reason
        other -> other
      end

    :telemetry.execute(
      [:lasso, :circuit_breaker, :admit],
      %{admit_call_ms: admit_call_ms},
      %{chain: chain, provider_id: provider_id, transport: transport, decision: decision_tag}
    )

    case decision do
      {:allow, token} ->
        result =
          try do
            fun.()
          catch
            kind, error -> {:__trap__, {kind, error}}
          end

        GenServer.cast(via_name(id), {:report, token, result})

        case result do
          {:__trap__, {kind, error}} ->
            # Mirror previous semantics: treat as error; normalization happens in breaker
            {:error, {kind, error}}

          {:ok, _} ->
            result

          {:error, _} ->
            result

          other ->
            {:ok, other}
        end

      {:deny, :open} ->
        {:error, :circuit_open}

      {:deny, :half_open_busy} ->
        {:error, :circuit_open}
    end
  end

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec get_state(breaker_id) :: %{
          chain: chain | nil,
          provider_id: provider_id,
          transport: transport,
          state: breaker_state,
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          last_failure_time: integer() | nil
        }
  def get_state(id) do
    GenServer.call(via_name(id), :get_state)
  end

  @doc """
  Manually opens the circuit breaker.
  """
  @spec open(breaker_id) :: :ok
  def open(breaker_id) do
    GenServer.cast(via_name(breaker_id), :open)
  end

  @doc """
  Manually closes the circuit breaker.
  """
  @spec close(breaker_id) :: :ok
  def close(breaker_id) do
    GenServer.cast(via_name(breaker_id), :close)
  end

  # GenServer callbacks

  @impl true
  def init({{chain, provider_id, transport}, config}) do
    state = %__MODULE__{
      chain: chain,
      provider_id: provider_id,
      transport: transport,
      failure_threshold: Map.get(config, :failure_threshold, 5),
      recovery_timeout: Map.get(config, :recovery_timeout, 60_000),
      success_threshold: Map.get(config, :success_threshold, 2),
      state: :closed,
      failure_count: 0,
      last_failure_time: nil,
      success_count: 0,
      config: config
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:admit, now_ms}, _from, state) do
    case state.state do
      :closed ->
        {:reply, {:allow, :closed}, state}

      :open ->
        if should_attempt_recovery?(state) do
          Logger.info("Circuit breaker #{state.provider_id} attempting recovery")

          :telemetry.execute([:lasso, :circuit_breaker, :half_open], %{count: 1}, %{
            provider_id: state.provider_id
          })

          publish_circuit_event(
            state.provider_id,
            :open,
            :half_open,
            :attempt_recovery,
            state.transport,
            state.chain
          )

          new_state = %{
            state
            | state: :half_open,
              last_failure_time: state.last_failure_time || now_ms,
              inflight_count: 1
          }

          {:reply, {:allow, :half_open}, new_state}
        else
          {:reply, {:deny, :open}, state}
        end

      :half_open ->
        if state.inflight_count < state.half_open_max_inflight do
          {:reply, {:allow, :half_open}, %{state | inflight_count: state.inflight_count + 1}}
        else
          {:reply, {:deny, :half_open_busy}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    status = %{
      chain: state.chain,
      provider_id: state.provider_id,
      transport: state.transport,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      last_failure_time: state.last_failure_time
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:report, _token, result}, state) do
    # Update state based on attempt result; do not block caller
    new_state = classify_and_update_state_for_report(result, state)

    # Decrement inflight counter if half-open
    final_state =
      case new_state.state do
        :half_open -> %{new_state | inflight_count: max(new_state.inflight_count - 1, 0)}
        _ -> new_state
      end

    {:noreply, final_state}
  end

  @impl true
  def handle_cast({:report_external, outcome}, state) do
    new_state = classify_and_update_state_for_report(outcome, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:open, state) do
    Logger.warning("Circuit breaker #{state.provider_id} (#{state.transport}) manually opened")

    :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
      provider_id: state.provider_id
    })

    publish_circuit_event(
      state.provider_id,
      state.state,
      :open,
      :manual_open,
      state.transport,
      state.chain
    )

    new_state = %{state | state: :open, last_failure_time: System.monotonic_time(:millisecond)}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:close, state) do
    Logger.info("Circuit breaker #{state.provider_id} (#{state.transport}) manually closed")

    :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
      provider_id: state.provider_id
    })

    publish_circuit_event(
      state.provider_id,
      state.state,
      :closed,
      :manual_close,
      state.transport,
      state.chain
    )

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_time: nil
    }

    {:noreply, new_state}
  end

  # Private functions

  defp classify_and_handle_result(result, state) do
    # Logger.debug("Classifying and handling result: #{inspect(result)}")

    case result do
      {:ok, value} ->
        handle_success(value, state)

      {:error, %JError{retriable?: true, breaker_penalty?: true} = reason} ->
        handle_failure(reason, state)

      # Retriable but no breaker penalty (e.g., capability_violation)
      {:error, %JError{retriable?: true, breaker_penalty?: false} = reason} ->
        handle_non_breaker_error({:error, reason}, state)

      {:error, %JError{retriable?: false}} ->
        # User/client errors don't affect circuit breaker state
        handle_non_breaker_error(result, state)

      {:error, reason} ->
        # Normalize unknown error shapes to JError for consistent handling
        jerr =
          ErrorNormalizer.normalize(reason,
            provider_id: state.provider_id,
            transport: state.transport
          )

        if jerr.retriable? and jerr.breaker_penalty? do
          handle_failure(jerr, state)
        else
          handle_non_breaker_error({:error, jerr}, state)
        end

      other ->
        # Any other return value is treated as success for backwards compatibility
        handle_success(other, state)
    end
  end

  defp classify_and_update_state_for_report(result, state) do
    case classify_and_handle_result(result, state) do
      {:reply, _reply, new_state} -> new_state
    end
  end

  defp handle_non_breaker_error(error_result, state) do
    # User errors don't change circuit breaker state
    case state.state do
      :closed ->
        {:reply, error_result, state}

      :half_open ->
        # In half_open, user errors are "neutral" - don't count as success or failure
        {:reply, error_result, state}

      :open ->
        # This shouldn't happen since we check circuit state before calling execute_call
        {:reply, {:error, :circuit_open}, state}
    end
  end

  defp handle_success(result, state) do
    case state.state do
      :closed ->
        # Reset failure count on success
        new_state = %{state | failure_count: 0}
        {:reply, {:ok, result}, new_state}

      :half_open ->
        # Increment success count
        new_success_count = state.success_count + 1

        if new_success_count >= state.success_threshold do
          Logger.info(
            "Circuit breaker #{state.provider_id} (#{state.transport}) recovered, closing"
          )

          :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
            provider_id: state.provider_id
          })

          publish_circuit_event(
            state.provider_id,
            :half_open,
            :closed,
            :recovered,
            state.transport,
            state.chain
          )

          new_state = %{
            state
            | state: :closed,
              failure_count: 0,
              success_count: 0,
              last_failure_time: nil
          }

          {:reply, {:ok, result}, new_state}
        else
          new_state = %{state | success_count: new_success_count}
          {:reply, {:ok, result}, new_state}
        end
    end
  end

  defp handle_failure(error, state) do
    new_failure_count = state.failure_count + 1
    current_time = System.monotonic_time(:millisecond)

    Logger.warning(
      "Circuit breaker #{state.provider_id} (#{state.transport}) failure #{new_failure_count}/#{state.failure_threshold}: #{inspect(error)}"
    )

    case state.state do
      :closed ->
        if new_failure_count >= state.failure_threshold do
          Logger.error(
            "Circuit breaker #{state.provider_id} (#{state.transport}) opening after #{new_failure_count} failures"
          )

          :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
            provider_id: state.provider_id
          })

          publish_circuit_event(
            state.provider_id,
            :closed,
            :open,
            :failure_threshold_exceeded,
            state.transport,
            state.chain
          )

          new_state = %{
            state
            | state: :open,
              failure_count: new_failure_count,
              last_failure_time: current_time
          }

          {:reply, {:error, :circuit_opening}, new_state}
        else
          new_state = %{state | failure_count: new_failure_count, last_failure_time: current_time}
          {:reply, {:error, error}, new_state}
        end

      :half_open ->
        # Half-open state fails, go back to open
        Logger.error(
          "Circuit breaker #{state.provider_id} (#{state.transport}) re-opening after recovery attempt failed"
        )

        :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
          provider_id: state.provider_id
        })

        publish_circuit_event(
          state.provider_id,
          :half_open,
          :open,
          :reopen_due_to_failure,
          state.transport,
          state.chain
        )

        new_state = %{
          state
          | state: :open,
            failure_count: new_failure_count,
            last_failure_time: current_time,
            success_count: 0
        }

        {:reply, {:error, :circuit_reopening}, new_state}

      :open ->
        # Circuit already open, ignore additional failures
        # Just update the failure time to keep the recovery timeout fresh
        new_state = %{
          state
          | failure_count: new_failure_count,
            last_failure_time: current_time
        }

        {:reply, {:error, :circuit_open}, new_state}
    end
  end

  defp should_attempt_recovery?(state) do
    case state.last_failure_time do
      nil ->
        true

      last_failure ->
        current_time = System.monotonic_time(:millisecond)
        current_time - last_failure >= state.recovery_timeout
    end
  end

  defp publish_circuit_event(provider_id, from, to, reason, transport, chain) do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "circuit:events",
      {:circuit_breaker_event,
       %{
         ts: System.system_time(:millisecond),
         chain: chain,
         provider_id: provider_id,
         transport: transport,
         from: from,
         to: to,
         reason: reason
       }}
    )
  end

  @doc """
  Record a successful operation for the circuit breaker.
  """
  def record_success(id) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        GenServer.cast(via_name(id), {:report_external, {:ok, :success}})
        :ok
    end
  end

  @doc """
  Record a failed operation for the circuit breaker.
  """
  def record_failure(id) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        GenServer.cast(via_name(id), {:report_external, {:error, :failure}})
        :ok
    end
  end

  defp via_name({chain, provider_id, transport}) do
    key = "#{chain}:#{provider_id}:#{transport}"
    {:via, Registry, {Lasso.Registry, {:circuit_breaker, key}}}
  end
end
