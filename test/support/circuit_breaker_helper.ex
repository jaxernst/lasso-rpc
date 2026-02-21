defmodule Lasso.Test.CircuitBreakerHelper do
  @moduledoc """
  Test helpers for managing circuit breaker lifecycle and state.

  Circuit breakers are keyed by `{instance_id, transport}` where instance_id
  is a binary string. The Registry key is `{:circuit_breaker, "instance_id:transport"}`.
  """

  alias Lasso.Core.Support.CircuitBreaker
  require Logger

  @spec setup_clean_circuit_breakers() :: :ok
  def setup_clean_circuit_breakers do
    existing_cbs = list_all_circuit_breakers()

    Enum.each(existing_cbs, fn {_key, pid} ->
      reset_circuit_breaker(pid)
    end)

    ExUnit.Callbacks.on_exit(fn ->
      cleanup_circuit_breakers(existing_cbs)
    end)

    :ok
  end

  @spec ensure_circuit_breaker_started(String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure_circuit_breaker_started(instance_id, transport, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    config = Keyword.get(opts, :config, %{})
    breaker_id = {instance_id, transport}
    deadline = System.monotonic_time(:millisecond) + timeout

    ensure_cb_started_loop(breaker_id, config, deadline)
  end

  defp ensure_cb_started_loop(breaker_id, config, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case get_circuit_breaker_state(breaker_id) do
        {:ok, state} ->
          {:ok, state}

        {:error, :not_found} ->
          _ = start_circuit_breaker(breaker_id, config)
          Process.sleep(50)
          ensure_cb_started_loop(breaker_id, config, deadline)

        {:error, :timeout} ->
          Process.sleep(50)
          ensure_cb_started_loop(breaker_id, config, deadline)
      end
    end
  end

  @spec get_circuit_breaker_state(CircuitBreaker.breaker_id()) ::
          {:ok, map()} | {:error, :not_found}
  def get_circuit_breaker_state(breaker_id) do
    resolved = resolve_breaker_id(breaker_id, 250)

    try do
      case CircuitBreaker.get_state(resolved) do
        %{state: _} = state -> {:ok, state}
        {:error, :not_found} -> {:error, :not_found}
        {:error, :timeout} -> {:error, :timeout}
        _ -> {:error, :not_found}
      end
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @spec wait_for_circuit_breaker_state(
          CircuitBreaker.breaker_id(),
          (map() -> boolean()),
          keyword()
        ) :: {:ok, map()} | {:error, :timeout}
  def wait_for_circuit_breaker_state(breaker_id, condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval)
  end

  defp wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case get_circuit_breaker_state(breaker_id) do
        {:ok, state} ->
          if condition_fn.(state) do
            {:ok, state}
          else
            Process.sleep(interval)
            wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval)
          end

        {:error, :not_found} ->
          Process.sleep(interval)
          wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval)
      end
    end
  end

  @spec reset_to_closed(CircuitBreaker.breaker_id()) :: :ok
  def reset_to_closed(breaker_id) do
    try do
      CircuitBreaker.close(resolve_breaker_id(breaker_id, 1_000))
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  @spec force_open(CircuitBreaker.breaker_id()) :: :ok
  def force_open(breaker_id) do
    try do
      CircuitBreaker.open(resolve_breaker_id(breaker_id, 1_000))
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  @spec assert_circuit_breaker_state(CircuitBreaker.breaker_id(), atom()) :: :ok
  def assert_circuit_breaker_state(breaker_id, expected_state) do
    case get_circuit_breaker_state(breaker_id) do
      {:ok, %{state: ^expected_state}} ->
        :ok

      {:ok, %{state: actual_state}} ->
        raise ExUnit.AssertionError,
          message: """
          Circuit breaker state mismatch for #{inspect(breaker_id)}
          Expected: #{expected_state}
          Got: #{actual_state}
          """

      {:error, :not_found} ->
        raise ExUnit.AssertionError,
          message: "Circuit breaker not found: #{inspect(breaker_id)}"
    end
  end

  # Private helpers

  defp list_all_circuit_breakers do
    try do
      Registry.select(Lasso.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.filter(fn
        {{:circuit_breaker, key}, _pid} when is_binary(key) -> true
        _ -> false
      end)
    catch
      :exit, _ -> []
    end
  end

  defp reset_circuit_breaker(pid) when is_pid(pid) do
    try do
      state = :sys.get_state(pid)
      breaker_id = {state.instance_id, state.transport}
      CircuitBreaker.close(breaker_id)
    catch
      :exit, _ -> :ok
    end
  end

  defp cleanup_circuit_breakers(existing_cbs) do
    current_cbs = list_all_circuit_breakers()
    new_cbs = current_cbs -- existing_cbs

    Enum.each(new_cbs, fn {_key, pid} ->
      if Process.alive?(pid) do
        try do
          state = :sys.get_state(pid)
          reset_to_closed({state.instance_id, state.transport})
        catch
          _ -> :ok
        end
      end
    end)

    Enum.each(existing_cbs, fn {_key, pid} ->
      if Process.alive?(pid) do
        reset_circuit_breaker(pid)
      end
    end)

    :ok
  end

  defp start_circuit_breaker(breaker_id, config) do
    try do
      CircuitBreaker.start_link({resolve_breaker_id(breaker_id, 500), config})
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp resolve_breaker_id(breaker_id, timeout_ms) when timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    resolve_breaker_id_until(breaker_id, deadline)
  end

  defp resolve_breaker_id(breaker_id, _timeout_ms), do: resolve_breaker_id(breaker_id)

  defp resolve_breaker_id_until(breaker_id, deadline) do
    resolved = resolve_breaker_id(breaker_id)

    if unresolved_shorthand?(breaker_id, resolved) and
         System.monotonic_time(:millisecond) < deadline do
      Process.sleep(25)
      resolve_breaker_id_until(breaker_id, deadline)
    else
      resolved
    end
  end

  defp unresolved_shorthand?({chain_provider, _transport} = original, resolved)
       when is_binary(chain_provider) do
    String.contains?(chain_provider, ":") and resolved == original
  end

  defp unresolved_shorthand?(_, _), do: false

  defp resolve_breaker_id({chain_provider, transport}) when is_binary(chain_provider) do
    case String.split(chain_provider, ":", parts: 2) do
      [chain, provider_id] ->
        instance_id =
          Lasso.Config.ConfigStore.list_profiles()
          |> Enum.find_value(fn profile ->
            Lasso.Providers.Catalog.lookup_instance_id(profile, chain, provider_id)
          end)

        {instance_id || chain_provider, transport}

      _ ->
        {chain_provider, transport}
    end
  end

  defp resolve_breaker_id(other), do: other
end
