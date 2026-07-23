defmodule Lasso.Testing.ProbeMocks do
  @moduledoc """
  Test seams for `Lasso.Discovery.ProbeSession`.

  Each submodule has the same surface as the real probe module it stands in
  for. By default it delegates to the real implementation. Per-test, the
  caller stashes a behavior override in a shared ETS table; lookups walk
  the calling process's `$ancestors` chain so overrides propagate through
  Tasks spawned by the per-session supervisor.

  Override values:

    * `{:raise, reason}` — raise `RuntimeError.exception(reason)` on call.
    * `{:throw, term}` — `throw/1` the term.
    * `{:exit, term}` — `exit/1` the term.
    * `{:return, value}` — return `value` directly without calling the real module.
    * `{:block}` — block forever (deterministic hang; drives budget/kill tests).
    * `{:rate_limited, n}` — return an HTTP-429-like result for the first `n` calls
      to the probe, then delegate to the real module. Drives slow-mode tests.
    * `nil` (or unset) — delegate to the real module.

  Usage:

      setup do
        Lasso.Testing.ProbeMocks.setup()
        on_exit(fn -> Lasso.Testing.ProbeMocks.clear_all() end)
        :ok
      end

      test "..." do
        Lasso.Testing.ProbeMocks.set(:method_support, {:raise, "boom"})
        ...
      end
  """

  @table __MODULE__.Table
  @keys [:identify, :method_support, :limits, :websocket]

  @spec setup() :: :ok
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @spec set(atom(), term()) :: :ok
  def set(key, override) when key in @keys do
    setup()
    :ets.insert(@table, {{self(), key}, override})
    :ok
  end

  @spec clear(atom()) :: :ok
  def clear(key) when key in @keys do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, {self(), key})
    end

    :ok
  end

  @spec clear_all() :: :ok
  def clear_all do
    if :ets.whereis(@table) != :undefined do
      Enum.each(@keys, fn key -> :ets.delete(@table, {self(), key}) end)
    end

    :ok
  end

  @doc false
  def dispatch(key, real_mod, real_fun, args) do
    case lookup_override(key) do
      nil ->
        apply(real_mod, real_fun, args)

      {:return, value} ->
        value

      {:raise, reason} ->
        raise RuntimeError, reason

      {:throw, term} ->
        throw(term)

      {:exit, term} ->
        exit(term)

      {:block} ->
        Process.sleep(:infinity)

      {:rate_limited, n} when is_integer(n) and n > 0 ->
        table = @table
        call_key = {self(), key, :call_count}

        count =
          case :ets.lookup(table, call_key) do
            [{_, c}] -> c
            [] -> 0
          end

        :ets.insert(table, {call_key, count + 1})

        if count < n do
          opts = if is_list(List.last(args)), do: List.last(args), else: []

          if on_throttle = Keyword.get(opts, :on_throttle) do
            on_throttle.(%{retry_after_ms: nil, phase: :methods})
          end

          [
            %{
              method: "eth_blockNumber",
              status: :unknown,
              error: "429 Too Many Requests",
              error_code: 429,
              duration_ms: 0,
              category: :core
            }
          ]
        else
          apply(real_mod, real_fun, args)
        end
    end
  end

  defp lookup_override(key) do
    if :ets.whereis(@table) != :undefined do
      callers = Process.get(:"$callers", [])
      ancestors = Process.get(:"$ancestors", [])
      chain = [self() | callers ++ ancestors]

      Enum.find_value(chain, fn
        pid when is_pid(pid) ->
          case :ets.lookup(@table, {pid, key}) do
            [{_, override}] -> override
            [] -> nil
          end

        _ ->
          nil
      end)
    end
  end

  defmodule Discovery do
    @moduledoc false
    def identify(url, opts) do
      Lasso.Testing.ProbeMocks.dispatch(:identify, Lasso.Discovery, :identify, [url, opts])
    end
  end

  defmodule MethodSupport do
    @moduledoc false
    def probe(url, opts) do
      Lasso.Testing.ProbeMocks.dispatch(
        :method_support,
        Lasso.Discovery.Probes.MethodSupport,
        :probe,
        [url, opts]
      )
    end
  end

  defmodule Limits do
    @moduledoc false
    def probe(url, opts) do
      Lasso.Testing.ProbeMocks.dispatch(
        :limits,
        Lasso.Discovery.Probes.Limits,
        :probe,
        [url, opts]
      )
    end

    def available_tests do
      Lasso.Discovery.Probes.Limits.available_tests()
    end
  end

  defmodule WebSocket do
    @moduledoc false
    def probe(url, opts) do
      Lasso.Testing.ProbeMocks.dispatch(
        :websocket,
        Lasso.Discovery.Probes.WebSocket,
        :probe,
        [url, opts]
      )
    end
  end
end
