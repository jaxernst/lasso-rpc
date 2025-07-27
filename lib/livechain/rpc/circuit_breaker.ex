defmodule Livechain.RPC.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for RPC provider fault tolerance.

  Implements the circuit breaker pattern to prevent cascade failures
  when providers are experiencing issues. Provides automatic recovery
  and configurable failure thresholds.
  """

  use GenServer
  require Logger

  defstruct [
    :provider_id,
    :failure_threshold,
    :recovery_timeout,
    :success_threshold,
    # :closed, :open, :half_open
    :state,
    :failure_count,
    :last_failure_time,
    :success_count,
    :config
  ]

  @doc """
  Starts a circuit breaker for a provider.
  """
  def start_link({provider_id, config}) do
    GenServer.start_link(__MODULE__, {provider_id, config}, name: via_name(provider_id))
  end

  @doc """
  Attempts to execute a function through the circuit breaker.
  """
  def call(provider_id, fun, timeout \\ 30_000) do
    GenServer.call(via_name(provider_id), {:call, fun}, timeout)
  end

  @doc """
  Gets the current state of the circuit breaker.
  """
  def get_state(provider_id) do
    GenServer.call(via_name(provider_id), :get_state)
  end

  @doc """
  Manually opens the circuit breaker.
  """
  def open(provider_id) do
    GenServer.cast(via_name(provider_id), :open)
  end

  @doc """
  Manually closes the circuit breaker.
  """
  def close(provider_id) do
    GenServer.cast(via_name(provider_id), :close)
  end

  # GenServer callbacks

  @impl true
  def init({provider_id, config}) do
    Logger.info("Starting circuit breaker for #{provider_id}")

    state = %__MODULE__{
      provider_id: provider_id,
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
  def handle_call({:call, fun}, _from, state) do
    case state.state do
      :closed ->
        execute_call(fun, state)

      :open ->
        if should_attempt_recovery?(state) do
          Logger.info("Circuit breaker #{state.provider_id} attempting recovery")
          new_state = %{state | state: :half_open}
          execute_call(fun, new_state)
        else
          {:reply, {:error, :circuit_open}, state}
        end

      :half_open ->
        execute_call(fun, state)
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    status = %{
      provider_id: state.provider_id,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      last_failure_time: state.last_failure_time
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:open, state) do
    Logger.warning("Circuit breaker #{state.provider_id} manually opened")
    new_state = %{state | state: :open, last_failure_time: System.monotonic_time(:millisecond)}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:close, state) do
    Logger.info("Circuit breaker #{state.provider_id} manually closed")

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

  defp execute_call(fun, state) do
    try do
      result = fun.()
      handle_success(result, state)
    catch
      kind, error ->
        handle_failure({kind, error}, state)
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
          Logger.info("Circuit breaker #{state.provider_id} recovered, closing")

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
      "Circuit breaker #{state.provider_id} failure #{new_failure_count}/#{state.failure_threshold}: #{inspect(error)}"
    )

    case state.state do
      :closed ->
        if new_failure_count >= state.failure_threshold do
          Logger.error(
            "Circuit breaker #{state.provider_id} opening after #{new_failure_count} failures"
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
          "Circuit breaker #{state.provider_id} re-opening after recovery attempt failed"
        )

        new_state = %{
          state
          | state: :open,
            failure_count: new_failure_count,
            last_failure_time: current_time,
            success_count: 0
        }

        {:reply, {:error, :circuit_reopening}, new_state}
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

  defp via_name(provider_id) do
    {:via, :global, {:circuit_breaker, provider_id}}
  end
end
