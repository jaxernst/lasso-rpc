defmodule Lasso.Core.Support.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for RPC provider fault tolerance.

  Implements the circuit breaker pattern to prevent cascade failures
  when providers are experiencing issues. Provides automatic recovery
  and configurable failure thresholds.
  """

  use GenServer
  require Logger
  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  defstruct [
    :profile,
    :chain,
    :provider_id,
    :transport,
    :failure_threshold,
    :recovery_timeout,
    :success_threshold,
    # Category-specific failure thresholds
    :category_thresholds,
    # :closed, :open, :half_open
    :state,
    :failure_count,
    :last_failure_time,
    :success_count,
    :config,
    # Number of in-flight attempts currently admitted while half-open
    inflight_count: 0,
    # Max parallel attempts allowed during half-open (default: 3)
    # This prevents thundering herd while allowing reasonable probe traffic
    half_open_max_inflight: 3,
    # Error category that caused circuit to open (for category-specific recovery)
    # Rate limits have known recovery times, so 1 success is sufficient
    opened_by_category: nil,
    # Timer reference for proactive recovery (automatically transitions open -> half_open)
    # Ensures circuits don't stay open forever when excluded from selection
    recovery_timer_ref: nil,
    # The error that caused the circuit to open (for dashboard display)
    # Stored as a map with :code, :category, :message keys
    last_open_error: nil
  ]

  @type profile :: String.t()
  @type chain :: String.t()
  @type provider_id :: String.t()
  @type transport :: :http | :ws
  @type breaker_id :: {profile, chain, provider_id, transport}
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
  Attempts to execute a function guarded by the circuit breaker.

  Returns an explicit execution envelope that separates circuit breaker
  concerns from function results:

  - `{:executed, fun_result}` - Function was executed. `fun_result` is whatever
    the wrapped function returned (which could itself be an error tuple).

  - `{:rejected, reason}` - Circuit breaker prevented execution.

  ## Rejection Reasons

  - `:circuit_open` - Circuit is open due to failures
  - `:half_open_busy` - Circuit is half-open but at max inflight capacity
  - `:admission_timeout` - Admission check timed out
  - `:not_found` - Circuit breaker process not found

  ## Exception Handling

  If the wrapped function raises an exception, it's returned as:
  `{:executed, {:exception, {kind, error, stacktrace}}}`

  This treats exceptions as "executed but failed" rather than "rejected".

  ## Flow

  1. Fast admission check (GenServer.call {:admit, now_ms})
  2. Execute fun in the caller process with timeout
  3. Report result asynchronously (GenServer.cast {:report, token, result})
  """
  # Timeout for admission check (reduced from 2000ms to 500ms to fail faster under load)
  # Under normal conditions admission is <10ms, but during GenServer queue backlog this limits
  # worst-case blocking per channel attempt to 500ms instead of 2 seconds.
  @admit_timeout 500

  @typedoc "Reasons why the circuit breaker rejected execution"
  @type rejection_reason :: :circuit_open | :half_open_busy | :admission_timeout | :not_found

  @typedoc "Result of a circuit breaker call - separates execution status from function result"
  @type call_result(result) :: {:executed, result} | {:rejected, rejection_reason()}

  @spec call(breaker_id, (-> result), non_neg_integer()) :: call_result(result)
        when result: term()
  def call({profile, chain, provider_id, transport} = id, fun, timeout \\ 30_000) do
    now_ms = System.monotonic_time(:millisecond)
    admit_start_us = System.monotonic_time(:microsecond)

    decision =
      try do
        GenServer.call(via_name(id), {:admit, now_ms}, @admit_timeout)
      catch
        :exit, {:timeout, _} ->
          Logger.warning("Circuit breaker admission timeout",
            profile: profile,
            chain: chain,
            provider_id: provider_id,
            transport: transport
          )

          {:deny, :admission_timeout}

        :exit, {:noproc, _} ->
          Logger.warning("Circuit breaker not found",
            profile: profile,
            chain: chain,
            provider_id: provider_id,
            transport: transport
          )

          {:deny, :not_found}
      end

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
      %{
        profile: profile,
        chain: chain,
        provider_id: provider_id,
        transport: transport,
        decision: decision_tag
      }
    )

    case decision do
      {:allow, token} ->
        execute_with_token(id, token, fun, timeout, profile, chain, provider_id, transport)

      {:deny, :open} ->
        {:rejected, :circuit_open}

      {:deny, :half_open_busy} ->
        {:rejected, :half_open_busy}

      {:deny, :admission_timeout} ->
        {:rejected, :admission_timeout}

      {:deny, :not_found} ->
        {:rejected, :not_found}
    end
  end

  # Executes the function with timeout enforcement and reports result to CB
  @spec execute_with_token(
          breaker_id(),
          term(),
          (-> result),
          timeout(),
          profile(),
          chain(),
          provider_id(),
          transport()
        ) ::
          {:executed, result}
        when result: term()
  defp execute_with_token(id, token, fun, timeout, profile, chain, provider_id, transport) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          kind, error ->
            {:__exception__, {kind, error, __STACKTRACE__}}
        end
      end)

    result =
      case Task.yield(task, timeout) do
        {:ok, {:__exception__, exception_info}} ->
          # Function threw an exception - treat as executed but failed
          {:exception, exception_info}

        {:ok, fun_result} ->
          # Function completed normally - pass through its result unchanged
          fun_result

        nil ->
          # Timeout occurred - kill the task
          Task.shutdown(task, :brutal_kill)

          Logger.error("Request timeout in circuit breaker",
            profile: profile,
            chain: chain,
            provider_id: provider_id,
            transport: transport,
            timeout_ms: timeout
          )

          :telemetry.execute(
            [:lasso, :circuit_breaker, :timeout],
            %{timeout_ms: timeout},
            %{profile: profile, chain: chain, provider_id: provider_id, transport: transport}
          )

          # Return timeout error with io_ms for latency tracking
          {:error,
           JError.new(-32_000, "Request timeout after #{timeout}ms",
             category: :timeout,
             retriable?: true,
             breaker_penalty?: true
           ), timeout}
      end

    # Report to circuit breaker for state tracking
    report_result =
      case result do
        {:exception, {kind, error, _stacktrace}} -> {:error, {kind, error}}
        other -> other
      end

    GenServer.cast(via_name(id), {:report, token, report_result})

    # Always wrap in {:executed, _} - the CB executed the function
    {:executed, result}
  end

  # Timeout for state queries
  @state_timeout 2_000

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec get_state(breaker_id) ::
          %{
            chain: chain | nil,
            provider_id: provider_id,
            transport: transport,
            state: breaker_state,
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            last_failure_time: integer() | nil
          }
          | {:error, term()}
  def get_state(id) do
    GenServer.call(via_name(id), :get_state, @state_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout getting circuit breaker state for #{inspect(id)}")
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :not_found}
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

  @doc """
  Gets the time remaining until circuit recovery attempt (in milliseconds).
  Returns nil if circuit is not open or if recovery should be attempted immediately.

  Used for providing retry-after hints in error responses.
  """
  @spec get_recovery_time_remaining(breaker_id) :: non_neg_integer() | nil
  def get_recovery_time_remaining(breaker_id) do
    case get_state(breaker_id) do
      %{state: :open, last_failure_time: last_failure} when not is_nil(last_failure) ->
        # Get recovery timeout from state
        try do
          case GenServer.call(via_name(breaker_id), :get_recovery_timeout, @state_timeout) do
            {:ok, recovery_timeout} ->
              current_time = System.monotonic_time(:millisecond)
              time_remaining = last_failure + recovery_timeout - current_time
              max(0, time_remaining)

            _ ->
              nil
          end
        catch
          :exit, _ -> nil
        end

      {:error, _reason} ->
        nil

      _ ->
        nil
    end
  end

  # GenServer callbacks

  @impl true
  def init({{profile, chain, provider_id, transport}, config})
      when is_binary(profile) and is_binary(chain) do
    do_init(profile, chain, provider_id, transport, config)
  end

  defp do_init(profile, chain, provider_id, transport, config) do
    # Default category-specific thresholds
    # Rate limits should open circuit quickly (2 failures)
    # Server errors are more tolerant (5 failures) as they may be transient
    default_category_thresholds = %{
      rate_limit: 2,
      server_error: 5,
      network_error: 3,
      timeout: 2,
      auth_error: 2
    }

    category_thresholds =
      Map.get(config, :category_thresholds, %{})
      |> Map.merge(default_category_thresholds, fn _k, v1, _v2 -> v1 end)

    # Half-open admission limit: allow 3 concurrent requests during recovery by default
    # This prevents thundering herd while still allowing reasonable probe traffic
    half_open_max_inflight = Map.get(config, :half_open_max_inflight, 3)

    state = %__MODULE__{
      profile: profile,
      chain: chain,
      provider_id: provider_id,
      transport: transport,
      failure_threshold: Map.get(config, :failure_threshold, 5),
      recovery_timeout: Map.get(config, :recovery_timeout, 60_000),
      success_threshold: Map.get(config, :success_threshold, 2),
      category_thresholds: category_thresholds,
      half_open_max_inflight: half_open_max_inflight,
      inflight_count: 0,
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
          # Cancel proactive recovery timer since we're transitioning via traffic
          cancel_recovery_timer(state.recovery_timer_ref)

          :telemetry.execute([:lasso, :circuit_breaker, :half_open], %{count: 1}, %{
            chain: state.chain,
            provider_id: state.provider_id,
            transport: state.transport,
            from_state: :open,
            to_state: :half_open,
            reason: :attempt_recovery
          })

          publish_circuit_event(
            state.profile,
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
              inflight_count: 1,
              recovery_timer_ref: nil
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
      last_failure_time: state.last_failure_time,
      last_open_error: state.last_open_error
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_recovery_timeout, _from, state) do
    {:reply, {:ok, state.recovery_timeout}, state}
  end

  @impl true
  def handle_call({:report_external_sync, outcome}, _from, state) do
    new_state = classify_and_update_state_for_report(outcome, state)
    {:reply, new_state.state, new_state}
  end

  @impl true
  def handle_cast({:report, _token, result}, state) do
    # Normalize transport 3-tuples to 2-tuples at the boundary
    # Circuit breaker only needs success/failure, not I/O timing
    normalized = normalize_transport_result(result)

    # Update state based on attempt result; do not block caller
    new_state = classify_and_update_state_for_report(normalized, state)

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
    :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
      chain: state.chain,
      provider_id: state.provider_id,
      transport: state.transport,
      from_state: state.state,
      to_state: :open,
      reason: :manual_open
    })

    publish_circuit_event(
      state.profile,
      state.provider_id,
      state.state,
      :open,
      :manual_open,
      state.transport,
      state.chain
    )

    # Cancel any existing timer and schedule new one
    cancel_recovery_timer(state.recovery_timer_ref)
    timer_ref = schedule_recovery_timer(state.recovery_timeout)

    new_state = %{
      state
      | state: :open,
        last_failure_time: System.monotonic_time(:millisecond),
        recovery_timer_ref: timer_ref
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:close, state) do
    :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
      chain: state.chain,
      provider_id: state.provider_id,
      transport: state.transport,
      from_state: state.state,
      to_state: :closed,
      reason: :manual_close
    })

    publish_circuit_event(
      state.profile,
      state.provider_id,
      state.state,
      :closed,
      :manual_close,
      state.transport,
      state.chain
    )

    # Cancel any pending recovery timer
    cancel_recovery_timer(state.recovery_timer_ref)

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_time: nil,
        opened_by_category: nil,
        recovery_timer_ref: nil,
        last_open_error: nil
    }

    {:noreply, new_state}
  end

  # Proactive recovery: automatically transition open -> half_open after recovery_timeout
  # This ensures circuits don't stay open forever when excluded from selection
  @impl true
  def handle_info(:attempt_proactive_recovery, state) do
    case state.state do
      :open ->
        :telemetry.execute([:lasso, :circuit_breaker, :proactive_recovery], %{count: 1}, %{
          chain: state.chain,
          provider_id: state.provider_id,
          transport: state.transport,
          from_state: :open,
          to_state: :half_open,
          reason: :proactive_recovery
        })

        publish_circuit_event(
          state.profile,
          state.provider_id,
          :open,
          :half_open,
          :proactive_recovery,
          state.transport,
          state.chain
        )

        new_state = %{
          state
          | state: :half_open,
            success_count: 0,
            inflight_count: 0,
            recovery_timer_ref: nil
        }

        {:noreply, new_state}

      other_state ->
        # Circuit already recovered or closed (e.g., via probe success or manual intervention)
        Logger.debug(
          "Circuit breaker #{state.provider_id} (#{state.transport}) proactive recovery skipped, " <>
            "already in #{other_state} state"
        )

        {:noreply, %{state | recovery_timer_ref: nil}}
    end
  end

  # Private functions

  # Normalizes results to 2-tuples at the boundary.
  # Circuit breaker only cares about success/failure for state management.
  #
  # Handles:
  # - Transport 3-tuples: {:ok, value, io_ms} -> {:ok, value}
  # - Transport 3-tuples: {:error, reason, io_ms} -> {:error, reason}
  # - Standard 2-tuples: pass through unchanged
  # - Plain :ok atom: common GenServer/simple success -> {:ok, :ok}
  # - Other values: pass through (will hit defensive catch-all)
  defp normalize_transport_result({:ok, value, _io_ms}), do: {:ok, value}
  defp normalize_transport_result({:error, reason, _io_ms}), do: {:error, reason}
  defp normalize_transport_result({:ok, _value} = ok_tuple), do: ok_tuple
  defp normalize_transport_result({:error, _reason} = error_tuple), do: error_tuple
  defp normalize_transport_result(:ok), do: {:ok, :ok}
  defp normalize_transport_result(other), do: other

  defp classify_and_handle_result(result, state) do
    # Expects 2-tuples only (normalized at boundary)
    case result do
      {:ok, value} ->
        handle_success(value, state)

      {:error, %JError{retriable?: true, breaker_penalty?: true} = reason} ->
        handle_failure(reason, state)

      # Retriable but no breaker penalty (e.g., capability_violation)
      {:error, %JError{retriable?: true, breaker_penalty?: false} = reason} ->
        handle_non_breaker_error({:error, reason}, state)

      {:error, %JError{retriable?: false} = reason} ->
        # User/client errors don't affect circuit breaker state
        handle_non_breaker_error({:error, reason}, state)

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
        # DEFENSIVE: Unknown shapes should not happen after normalization
        # Log as error and treat conservatively (as failure, not success)
        Logger.error("Circuit breaker received unexpected result shape after normalization",
          shape: inspect(other),
          provider_id: state.provider_id,
          transport: state.transport,
          chain: state.chain
        )

        jerr =
          JError.new(-32_000, "Internal error: unexpected circuit breaker result shape",
            category: :internal_error,
            retriable?: false
          )

        handle_failure(jerr, state)
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
    # Use category-specific success threshold for recovery
    # Rate limits have known recovery times, so 1 success is sufficient
    effective_threshold = effective_success_threshold(state)

    case state.state do
      :closed ->
        # Reset failure count on success
        new_state = %{state | failure_count: 0}
        {:reply, {:ok, result}, new_state}

      :open ->
        # Received a success while open (e.g., external report). Transition to half_open
        # Cancel proactive recovery timer since we're transitioning out of open
        cancel_recovery_timer(state.recovery_timer_ref)

        :telemetry.execute([:lasso, :circuit_breaker, :half_open], %{count: 1}, %{
          chain: state.chain,
          provider_id: state.provider_id,
          transport: state.transport,
          from_state: :open,
          to_state: :half_open,
          reason: :recovery_attempt
        })

        publish_circuit_event(
          state.profile,
          state.provider_id,
          :open,
          :half_open,
          :recovery_attempt,
          state.transport,
          state.chain
        )

        new_success_count = 1

        if new_success_count >= effective_threshold do
          :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
            chain: state.chain,
            provider_id: state.provider_id,
            transport: state.transport,
            from_state: :open,
            to_state: :closed,
            reason: :recovered
          })

          publish_circuit_event(
            state.profile,
            state.provider_id,
            :open,
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
              last_failure_time: nil,
              opened_by_category: nil,
              recovery_timer_ref: nil,
              last_open_error: nil
          }

          {:reply, {:ok, result}, new_state}
        else
          new_state = %{
            state
            | state: :half_open,
              success_count: new_success_count,
              failure_count: 0,
              recovery_timer_ref: nil
          }

          {:reply, {:ok, result}, new_state}
        end

      :half_open ->
        # Increment success count
        new_success_count = state.success_count + 1

        if new_success_count >= effective_threshold do
          :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
            chain: state.chain,
            provider_id: state.provider_id,
            transport: state.transport,
            from_state: :half_open,
            to_state: :closed,
            reason: :recovered
          })

          publish_circuit_event(
            state.profile,
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
              last_failure_time: nil,
              opened_by_category: nil,
              last_open_error: nil
          }

          {:reply, {:ok, result}, new_state}
        else
          new_state = %{state | success_count: new_success_count}
          {:reply, {:ok, result}, new_state}
        end
    end
  end

  # Rate limits have known recovery times (retry-after), so 1 success is sufficient
  # Other errors need more confidence before closing (default success_threshold)
  defp effective_success_threshold(%{opened_by_category: :rate_limit}), do: 1
  defp effective_success_threshold(state), do: state.success_threshold

  defp handle_failure(error, state) do
    new_failure_count = state.failure_count + 1
    current_time = System.monotonic_time(:millisecond)

    # Determine the appropriate threshold based on error category
    error_category = if is_struct(error, JError), do: error.category, else: :unknown_error
    threshold = Map.get(state.category_thresholds, error_category, state.failure_threshold)

    # For rate limit errors, extract retry-after to adjust recovery timeout
    adjusted_recovery_timeout =
      if error_category == :rate_limit and is_struct(error, JError) do
        extract_retry_after(error) || state.recovery_timeout
      else
        state.recovery_timeout
      end

    # Format error summary for logging (only used in specific cases below)
    error_summary =
      if is_struct(error, JError) do
        "#{error.code} (#{error.category})"
      else
        inspect(error)
      end

    # Emit telemetry for all failures (metrics capture)
    :telemetry.execute(
      [:lasso, :circuit_breaker, :failure],
      %{count: 1},
      %{
        chain: state.chain,
        provider_id: state.provider_id,
        transport: state.transport,
        error_category: error_category,
        circuit_state: state.state
      }
    )

    case state.state do
      :closed ->
        # Log first failure at debug level (useful for debugging, filtered in production)
        if new_failure_count == 1 do
          Logger.debug(
            "Circuit breaker #{state.provider_id} (#{state.transport}) first failure: #{error_summary}"
          )
        end

        if new_failure_count >= threshold do
          :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
            chain: state.chain,
            provider_id: state.provider_id,
            transport: state.transport,
            from_state: :closed,
            to_state: :open,
            reason: :failure_threshold_exceeded,
            error_category: error_category,
            failure_count: new_failure_count,
            recovery_timeout_ms: adjusted_recovery_timeout
          })

          publish_circuit_event(
            state.profile,
            state.provider_id,
            :closed,
            :open,
            :failure_threshold_exceeded,
            state.transport,
            state.chain,
            error
          )

          # Schedule proactive recovery timer
          timer_ref = schedule_recovery_timer(adjusted_recovery_timeout)

          new_state = %{
            state
            | state: :open,
              failure_count: new_failure_count,
              last_failure_time: current_time,
              recovery_timeout: adjusted_recovery_timeout,
              opened_by_category: error_category,
              recovery_timer_ref: timer_ref,
              last_open_error: extract_error_info(error)
          }

          {:reply, {:error, :circuit_opening}, new_state}
        else
          new_state = %{state | failure_count: new_failure_count, last_failure_time: current_time}
          {:reply, {:error, error}, new_state}
        end

      :half_open ->
        :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
          chain: state.chain,
          provider_id: state.provider_id,
          transport: state.transport,
          from_state: :half_open,
          to_state: :open,
          reason: :reopen_due_to_failure,
          error_category: error_category,
          failure_count: new_failure_count,
          recovery_timeout_ms: state.recovery_timeout
        })

        publish_circuit_event(
          state.profile,
          state.provider_id,
          :half_open,
          :open,
          :reopen_due_to_failure,
          state.transport,
          state.chain,
          error
        )

        # Schedule proactive recovery timer for the re-opened circuit
        timer_ref = schedule_recovery_timer(state.recovery_timeout)

        new_state = %{
          state
          | state: :open,
            failure_count: new_failure_count,
            last_failure_time: current_time,
            success_count: 0,
            recovery_timer_ref: timer_ref,
            last_open_error: extract_error_info(error)
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

  # Schedule proactive recovery timer with jitter to prevent thundering herd
  # Returns the timer reference for later cancellation
  defp schedule_recovery_timer(recovery_timeout) do
    # Add 5% jitter to prevent synchronized recovery attempts across multiple circuits
    jitter_ms = :rand.uniform(max(1, div(recovery_timeout, 20)))
    delay_ms = recovery_timeout + jitter_ms
    Process.send_after(self(), :attempt_proactive_recovery, delay_ms)
  end

  # Cancel an existing recovery timer (safe to call with nil)
  defp cancel_recovery_timer(nil), do: :ok

  defp cancel_recovery_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp publish_circuit_event(
         profile,
         provider_id,
         from,
         to,
         reason,
         transport,
         chain,
         error \\ nil
       ) do
    # Extract error details for dashboard display
    error_info =
      case error do
        %JError{code: code, category: category, message: msg} ->
          %{
            error_code: code,
            error_category: category,
            error_message: truncate_error_message(msg)
          }

        _ ->
          nil
      end

    event =
      {:circuit_breaker_event,
       %{
         ts: System.system_time(:millisecond),
         profile: profile,
         chain: chain,
         provider_id: provider_id,
         transport: transport,
         from: from,
         to: to,
         reason: reason,
         error: error_info,
         source_node_id: Lasso.Cluster.Topology.get_self_node_id(),
         source_node: node()
       }}

    Phoenix.PubSub.broadcast(Lasso.PubSub, "circuit:events:#{profile}:#{chain}", event)
  end

  # Truncate long error messages for dashboard display
  defp truncate_error_message(msg) when is_binary(msg) do
    if String.length(msg) > 100 do
      String.slice(msg, 0, 97) <> "..."
    else
      msg
    end
  end

  defp truncate_error_message(other), do: inspect(other) |> truncate_error_message()

  @doc """
  Signals that external health monitoring has detected the provider is reachable.

  This is used by health probes and other external monitors to indicate that a
  provider appears to be responding. The circuit breaker uses this signal to
  attempt recovery when appropriate.

  ## Behavior by Circuit State

  - **Open**: Triggers transition to half-open state (recovery attempt)
  - **Half-open**: Counts toward success threshold for closing circuit
  - **Closed**: No-op (circuit doesn't need recovery signals)

  ## Important

  This is NOT for recording live traffic outcomes. Live traffic goes through
  `call/3` which reports results internally. This function is specifically for
  external monitoring systems to signal "provider appears healthy, consider recovery."

  ## Returns

  - `:ok` - Signal was processed (or ignored if circuit is closed)
  - `{:error, :not_found}` - Circuit breaker not found
  """
  @spec signal_recovery(breaker_id()) :: :ok | {:error, :not_found}
  def signal_recovery(id) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        # Only signal recovery when circuit needs it (open/half-open)
        # Closed circuits don't need recovery signals from external monitors
        case get_state(id) do
          %{state: state} when state in [:open, :half_open] ->
            GenServer.cast(via_name(id), {:report_external, {:ok, :success}})
            :ok

          _ ->
            :ok
        end
    end
  end

  @doc """
  Record a successful operation for the circuit breaker.

  **Deprecated**: Use `signal_recovery/1` instead. This function has been renamed
  to better reflect its purpose - signaling recovery readiness to open/half-open
  circuits, not recording live traffic successes.
  """
  @deprecated "Use signal_recovery/1 instead"
  @spec record_success(breaker_id()) :: :ok | {:error, :not_found}
  def record_success(id), do: signal_recovery(id)

  @doc """
  Record a failed operation for the circuit breaker (async).

  Optionally accepts the error reason for proper classification and logging.
  If no reason is provided, defaults to a generic failure.
  """
  @spec record_failure(tuple(), term()) :: :ok | {:error, :not_found}
  def record_failure(id, reason \\ :failure) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        GenServer.cast(via_name(id), {:report_external, {:error, reason}})
        :ok
    end
  end

  @doc """
  Record a failed operation for the circuit breaker (synchronous).

  Returns the circuit state after recording the failure (:closed, :open, or :half_open).
  Use this when you need to know the circuit state immediately after recording.
  """
  @spec record_failure_sync(tuple(), term(), timeout()) ::
          {:ok, :closed | :open | :half_open} | {:error, :not_found | :timeout}
  def record_failure_sync(id, reason \\ :failure, timeout \\ 5_000) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        try do
          state = GenServer.call(via_name(id), {:report_external_sync, {:error, reason}}, timeout)
          {:ok, state}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end
    end
  end

  # Extract retry-after hint from normalized JError (populated by ErrorNormalizer)
  # Circuit breaker only reads structured data, no message parsing
  defp extract_retry_after(%JError{data: data}) when is_map(data) do
    Map.get(data, :retry_after_ms) || Map.get(data, "retry_after_ms")
  end

  defp extract_retry_after(_), do: nil

  # Extract error info for storage in state (for dashboard display)
  defp extract_error_info(%JError{code: code, category: category, message: msg}) do
    %{
      code: code,
      category: category,
      message: truncate_error_message(msg)
    }
  end

  defp extract_error_info(_), do: nil

  defp via_name({profile, chain, provider_id, transport})
       when is_binary(profile) and is_binary(chain) do
    key = "#{profile}:#{chain}:#{provider_id}:#{transport}"
    {:via, Registry, {Lasso.Registry, {:circuit_breaker, key}}}
  end
end
