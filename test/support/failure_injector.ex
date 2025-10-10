defmodule TestSupport.FailureInjector do
  @moduledoc """
  Test-only failure injection for MockWSClient.

  This module allows tests to configure connection failure behavior
  without using Application environment globals. Each test gets isolated
  failure configuration via start_supervised/1.

  ## Usage

      # In test setup or test body
      {:ok, _} = start_supervised(TestSupport.FailureInjector)

      # Configure failure behavior for specific connection
      TestSupport.FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt > 0, do: {:error, :connection_refused}, else: :ok
      end)

  ## Examples

      # Fail all attempts after the first successful connection
      FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt > 0, do: {:error, :connection_refused}, else: :ok
      end)

      # Fail attempts 2 and 3, then succeed
      FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt in [1, 2], do: {:error, :econnrefused}, else: :ok
      end)

      # Alternate success and failure
      FailureInjector.configure(endpoint.id, fn attempt ->
        if rem(attempt, 2) == 1, do: {:error, :timeout}, else: :ok
      end)
  """

  use Agent

  @type connection_id :: String.t()
  @type attempt :: non_neg_integer()
  @type failure_result :: :ok | {:error, term()} | {:delay, non_neg_integer()} | {:hang}
  @type failure_fn :: (attempt -> failure_result)

  @doc """
  Starts the FailureInjector agent.

  This should be called via start_supervised/1 in tests to ensure
  proper cleanup after each test.
  """
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Configure failure behavior for a specific connection identifier.

  The failure function receives the current attempt number (starting at 0)
  and returns one of:
  - :ok - connection succeeds
  - {:error, reason} - connection fails with the given reason
  - {:delay, ms} - connection succeeds after delay
  - {:hang} - connection hangs indefinitely (no response, no close)

  ## Examples

      # Fail after initial connection
      FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt > 0, do: {:error, :connection_refused}, else: :ok
      end)

      # Fail specific attempts
      FailureInjector.configure(endpoint.id, fn attempt ->
        case attempt do
          1 -> {:error, :timeout}
          2 -> {:error, :econnrefused}
          _ -> :ok
        end
      end)

      # Simulate slow connection
      FailureInjector.configure(endpoint.id, fn attempt ->
        if attempt == 0, do: {:delay, 5_000}, else: :ok
      end)

      # Simulate hanging connection
      FailureInjector.configure(endpoint.id, fn _attempt ->
        {:hang}
      end)
  """
  def configure(connection_id, failure_fn) when is_function(failure_fn, 1) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, connection_id, %{
        failure_fn: failure_fn,
        attempt_count: 0
      })
    end)
  end

  @doc """
  Check if a connection attempt should fail.

  Returns the failure_fn result for the current attempt number,
  then increments the attempt counter.

  If FailureInjector is not started (production mode) or no configuration
  exists for the connection_id, returns :ok (connection succeeds).
  """
  def check_failure(connection_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, connection_id) do
        nil ->
          # No failure configuration - succeed
          {:ok, state}

        config ->
          result = config.failure_fn.(config.attempt_count)
          new_config = %{config | attempt_count: config.attempt_count + 1}
          new_state = Map.put(state, connection_id, new_config)
          {result, new_state}
      end
    end)
  rescue
    # FailureInjector not started - production mode
    ArgumentError -> :ok
  end

  @doc """
  Check if FailureInjector is available (test mode).

  Returns true if the FailureInjector agent is running, false otherwise.
  """
  def available? do
    Process.whereis(__MODULE__) != nil
  end

  @doc """
  Get current attempt count for a connection identifier.

  Useful for debugging test behavior. Returns 0 if no configuration exists.
  """
  def get_attempt_count(connection_id) do
    if available?() do
      Agent.get(__MODULE__, fn state ->
        case Map.get(state, connection_id) do
          nil -> 0
          config -> config.attempt_count
        end
      end)
    else
      0
    end
  end

  @doc """
  Clear failure configuration for a specific connection identifier.

  This is rarely needed as start_supervised/1 handles cleanup automatically,
  but can be useful for tests that want to change behavior mid-test.
  """
  def clear(connection_id) do
    if available?() do
      Agent.update(__MODULE__, fn state ->
        Map.delete(state, connection_id)
      end)
    end
  end

  @doc """
  Clear all failure configurations.

  This is rarely needed as start_supervised/1 handles cleanup automatically.
  """
  def clear_all do
    if available?() do
      Agent.update(__MODULE__, fn _state -> %{} end)
    end
  end
end
