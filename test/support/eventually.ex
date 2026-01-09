defmodule Lasso.Test.Eventually do
  @moduledoc """
  Polling-based assertions for asynchronous test scenarios.

  This module provides a simpler alternative to telemetry-based synchronization
  for cases where:
  - Telemetry events are not available
  - Simple state polling is sufficient
  - Quick iteration during test development

  For production tests, prefer `TelemetrySync` for deterministic event-driven waiting.

  ## Usage

      # Wait for a circuit breaker to open
      assert_eventually(fn ->
        CircuitBreaker.get_state(provider).state == :open
      end)

      # Wait with custom timeout and interval
      assert_eventually(
        fn -> Provider.healthy?(provider_id) end,
        timeout: 10_000,
        interval: 100
      )

      # Use refute variant
      refute_eventually(fn ->
        Process.whereis(some_process) != nil
      end)
  """

  @default_timeout 5_000
  @default_interval 50

  @doc """
  Asserts that a condition becomes true within a timeout period.

  Polls the condition function at regular intervals until it returns true
  or the timeout is exceeded.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 5000)
  - `:interval` - Polling interval in milliseconds (default: 50)
  - `:message` - Custom failure message

  ## Examples

      # Wait for process to start
      assert_eventually(fn ->
        Process.whereis(MyWorker) != nil
      end)

      # Wait with custom message
      assert_eventually(
        fn -> balance > 0 end,
        message: "Balance should become positive"
      )

  ## Returns

  Returns `:ok` on success, raises `ExUnit.AssertionError` on timeout.
  """
  @spec assert_eventually((-> boolean()), keyword()) :: :ok
  def assert_eventually(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    message = Keyword.get(opts, :message)

    deadline = System.monotonic_time(:millisecond) + timeout

    case poll_until_true(condition_fn, deadline, interval) do
      :ok ->
        :ok

      {:error, :timeout, last_value} ->
        error_message =
          message ||
            """
            Assertion failed within #{timeout}ms timeout.
            Last value: #{inspect(last_value)}
            Condition: #{inspect(condition_fn)}
            """

        raise ExUnit.AssertionError, message: error_message
    end
  end

  @doc """
  Asserts that a condition remains false within a timeout period.

  The inverse of `assert_eventually/2`. Useful for ensuring something
  does NOT happen within a time window.

  ## Examples

      # Ensure process doesn't restart
      refute_eventually(fn ->
        Process.whereis(CrashedWorker) != nil
      end)

      # Ensure circuit breaker doesn't open prematurely
      refute_eventually(
        fn -> CircuitBreaker.get_state(id).state == :open end,
        timeout: 1000
      )
  """
  @spec refute_eventually((-> boolean()), keyword()) :: :ok
  def refute_eventually(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    message = Keyword.get(opts, :message)

    deadline = System.monotonic_time(:millisecond) + timeout

    case poll_until_true(condition_fn, deadline, interval) do
      :ok ->
        error_message =
          message ||
            """
            Refutation failed: condition became true within #{timeout}ms.
            Condition: #{inspect(condition_fn)}
            """

        raise ExUnit.AssertionError, message: error_message

      {:error, :timeout, _last_value} ->
        # Success - condition never became true
        :ok
    end
  end

  @doc """
  Waits until a condition becomes true and returns the result.

  Similar to `assert_eventually/2` but returns the value instead of
  raising on timeout.

  ## Returns

  - `{:ok, value}` when condition becomes true
  - `{:error, :timeout}` if timeout exceeded

  ## Examples

      case wait_until(fn -> get_user(id) end) do
        {:ok, user} -> assert user.name == "Alice"
        {:error, :timeout} -> flunk("User not found")
      end
  """
  @spec wait_until((-> any()), keyword()) :: {:ok, any()} | {:error, :timeout}
  def wait_until(value_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)

    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until_value(value_fn, deadline, interval)
  end

  @doc """
  Waits for a value to match a pattern.

  Polls a function until its return value matches the given pattern.

  ## Examples

      # Wait for specific state
      {:ok, %{status: :ready}} = wait_for_value(
        fn -> get_status(worker) end,
        match: %{status: :ready}
      )

      # Wait for non-nil value
      {:ok, user} = wait_for_value(
        fn -> Repo.get(User, id) end,
        match_non_nil: true
      )
  """
  @spec wait_for_value((-> any()), keyword()) :: {:ok, any()} | {:error, :timeout}
  def wait_for_value(value_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    match_pattern = Keyword.get(opts, :match)
    match_non_nil = Keyword.get(opts, :match_non_nil, false)

    condition_fn = fn ->
      value = value_fn.()

      cond do
        match_non_nil and not is_nil(value) -> {true, value}
        match_pattern != nil and matches_pattern?(value, match_pattern) -> {true, value}
        match_pattern == nil and match_non_nil == false and value != nil -> {true, value}
        true -> {false, value}
      end
    end

    deadline = System.monotonic_time(:millisecond) + timeout

    case poll_with_value(condition_fn, deadline, interval) do
      {:ok, value} -> {:ok, value}
      {:error, :timeout, _last_value} -> {:error, :timeout}
    end
  end

  @doc """
  Repeatedly executes a function until it succeeds or times out.

  Useful for operations that may fail transiently (network calls, etc.).

  ## Options

  - `:timeout` - Maximum time to retry (default: 5000ms)
  - `:interval` - Delay between retries (default: 100ms)
  - `:retry_on` - List of error atoms to retry on (default: retry all errors)

  ## Examples

      # Retry network call
      {:ok, response} = retry_until_success(fn ->
        HTTPClient.get(url)
      end)

      # Retry specific errors only
      {:ok, result} = retry_until_success(
        fn -> risky_operation() end,
        retry_on: [:timeout, :connection_refused]
      )
  """
  @spec retry_until_success((-> {:ok, any()} | {:error, any()}), keyword()) ::
          {:ok, any()} | {:error, :timeout, any()}
  def retry_until_success(operation_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, 100)
    retry_on = Keyword.get(opts, :retry_on)

    deadline = System.monotonic_time(:millisecond) + timeout

    retry_loop(operation_fn, deadline, interval, retry_on, nil)
  end

  # Private helpers

  defp poll_until_true(condition_fn, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout, try_condition(condition_fn)}
    else
      case try_condition(condition_fn) do
        true ->
          :ok

        false ->
          Process.sleep(interval)
          poll_until_true(condition_fn, deadline, interval)

        _other ->
          Process.sleep(interval)
          poll_until_true(condition_fn, deadline, interval)
      end
    end
  end

  defp poll_until_value(value_fn, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case try_value(value_fn) do
        {:ok, value} when not is_nil(value) ->
          {:ok, value}

        {:ok, nil} ->
          Process.sleep(interval)
          poll_until_value(value_fn, deadline, interval)

        {:error, _} ->
          Process.sleep(interval)
          poll_until_value(value_fn, deadline, interval)
      end
    end
  end

  defp poll_with_value(condition_fn, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      case try_condition_with_value(condition_fn) do
        {_matches, value} -> {:error, :timeout, value}
        _other -> {:error, :timeout, nil}
      end
    else
      case try_condition_with_value(condition_fn) do
        {true, value} ->
          {:ok, value}

        {false, _value} ->
          Process.sleep(interval)
          poll_with_value(condition_fn, deadline, interval)
      end
    end
  end

  defp retry_loop(operation_fn, deadline, interval, retry_on, last_error) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout, last_error}
    else
      case operation_fn.() do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = error ->
          if should_retry?(reason, retry_on) do
            Process.sleep(interval)
            retry_loop(operation_fn, deadline, interval, retry_on, error)
          else
            error
          end
      end
    end
  end

  defp try_condition(condition_fn) do
    try do
      condition_fn.()
    rescue
      _ -> false
    catch
      _ -> false
    end
  end

  defp try_value(value_fn) do
    try do
      {:ok, value_fn.()}
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      thrown -> {:error, {:throw, thrown}}
    end
  end

  defp try_condition_with_value(condition_fn) do
    try do
      condition_fn.()
    rescue
      _ -> {false, nil}
    catch
      _ -> {false, nil}
    end
  end

  defp should_retry?(_reason, nil), do: true
  defp should_retry?(reason, retry_on) when is_list(retry_on), do: reason in retry_on

  defp matches_pattern?(value, pattern) when is_map(pattern) and is_map(value) do
    Enum.all?(pattern, fn {key, expected} ->
      Map.get(value, key) == expected
    end)
  end

  defp matches_pattern?(value, pattern), do: value == pattern
end
