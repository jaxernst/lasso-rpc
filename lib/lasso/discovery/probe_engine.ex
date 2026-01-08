defmodule Lasso.Discovery.ProbeEngine do
  @moduledoc """
  Concurrent probe execution engine for provider discovery.

  Provides a unified way to run multiple probes concurrently with
  timeout handling, progress tracking, and result aggregation.
  """

  require Logger

  @type probe_result :: {:ok, term()} | {:error, term()} | {:timeout, term()}

  @doc """
  Runs probe functions concurrently over a list of items.

  ## Options

    * `:concurrent` - Maximum concurrent probes (default: 5)
    * `:timeout` - Timeout per probe in milliseconds (default: 5000)
    * `:on_progress` - Optional callback `fn item, result -> :ok end` for progress

  ## Examples

      items = ["eth_blockNumber", "eth_chainId", "eth_gasPrice"]
      results = ProbeEngine.run(items, fn method ->
        probe_method(url, method)
      end, concurrent: 10, timeout: 3000)
  """
  @spec run(list(), (term() -> term()), keyword()) :: [probe_result()]
  def run(items, probe_fn, opts \\ []) when is_list(items) and is_function(probe_fn, 1) do
    concurrent = Keyword.get(opts, :concurrent, 5)
    timeout = Keyword.get(opts, :timeout, 5000)
    on_progress = Keyword.get(opts, :on_progress)

    items
    |> Task.async_stream(
      fn item ->
        result = safe_probe(probe_fn, item, timeout)

        if on_progress do
          on_progress.(item, result)
        end

        {item, result}
      end,
      max_concurrency: concurrent,
      timeout: timeout + 1000,
      on_timeout: :kill_task
    )
    |> Enum.map(&normalize_task_result/1)
  end

  @doc """
  Runs a single probe with timeout protection.

  Returns `{:ok, result}`, `{:error, reason}`, or `{:timeout, item}`.
  """
  @spec probe(term(), (term() -> term()), keyword()) :: probe_result()
  def probe(item, probe_fn, opts \\ []) when is_function(probe_fn, 1) do
    timeout = Keyword.get(opts, :timeout, 5000)
    safe_probe(probe_fn, item, timeout)
  end

  @doc """
  Groups probe results by status.

  Returns a map with `:ok`, `:error`, and `:timeout` keys.
  """
  @spec group_by_status([{term(), probe_result()}]) :: %{
          ok: [{term(), term()}],
          error: [{term(), term()}],
          timeout: [term()]
        }
  def group_by_status(results) do
    results
    |> Enum.reduce(%{ok: [], error: [], timeout: []}, fn
      {item, {:ok, value}}, acc ->
        %{acc | ok: [{item, value} | acc.ok]}

      {item, {:error, reason}}, acc ->
        %{acc | error: [{item, reason} | acc.error]}

      {item, {:timeout, _}}, acc ->
        %{acc | timeout: [item | acc.timeout]}
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  @doc """
  Counts results by status.
  """
  @spec count_results([{term(), probe_result()}]) :: %{
          ok: integer(),
          error: integer(),
          timeout: integer()
        }
  def count_results(results) do
    Enum.reduce(results, %{ok: 0, error: 0, timeout: 0}, fn
      {_item, {:ok, _}}, acc -> %{acc | ok: acc.ok + 1}
      {_item, {:error, _}}, acc -> %{acc | error: acc.error + 1}
      {_item, {:timeout, _}}, acc -> %{acc | timeout: acc.timeout + 1}
    end)
  end

  # Executes probe function with timeout protection
  defp safe_probe(probe_fn, item, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok, probe_fn.(item)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, {:exit, reason}}
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:timeout, item}
    end
  end

  # Normalizes Task.async_stream results
  defp normalize_task_result({:ok, {item, result}}) do
    {item, result}
  end

  defp normalize_task_result({:exit, :timeout}) do
    {:unknown, {:timeout, :task_killed}}
  end

  defp normalize_task_result({:exit, reason}) do
    {:unknown, {:error, {:exit, reason}}}
  end
end
