defmodule Lasso.Diagnostic.Profiler do
  @moduledoc """
  Profiling tools for identifying CPU-bound bottlenecks in ProviderPool operations.

  Usage:
    # Profile list_candidates calls
    Lasso.Diagnostic.Profiler.profile_list_candidates("ethereum", iterations: 100)

    # Profile with fprof (more detailed but slower)
    Lasso.Diagnostic.Profiler.fprof_list_candidates("ethereum", iterations: 10)
  """

  alias Lasso.RPC.ProviderPool

  @doc """
  Profiles list_candidates using :eprof (faster, less overhead).

  Good for identifying hot code paths.
  """
  def eprof_list_candidates(chain_name, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 100)
    filters = Keyword.get(opts, :filters, %{})

    # Get the ProviderPool process
    pool_pid = GenServer.whereis(ProviderPool.via_name(chain_name))

    if is_nil(pool_pid) do
      {:error, :pool_not_found}
    else
      :eprof.start()
      :eprof.start_profiling([pool_pid, self()])

      for _ <- 1..iterations do
        ProviderPool.list_candidates(chain_name, filters)
      end

      :eprof.stop_profiling()
      :eprof.analyze(:total)
      :eprof.stop()
    end
  end

  @doc """
  Profiles list_candidates using :fprof (more detailed, higher overhead).

  Better for understanding exact call chains and time distribution.
  """
  def fprof_list_candidates(chain_name, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 10)
    filters = Keyword.get(opts, :filters, %{})

    # Get the ProviderPool process
    pool_pid = GenServer.whereis(ProviderPool.via_name(chain_name))

    if is_nil(pool_pid) do
      {:error, :pool_not_found}
    else
      # Create a wrapper function to profile
      profiled_fun = fn ->
        for _ <- 1..iterations do
          ProviderPool.list_candidates(chain_name, filters)
        end
      end

      :fprof.trace([:start, {:procs, [pool_pid, self()]}])
      profiled_fun.()
      :fprof.trace([:stop])

      :fprof.profile()
      :fprof.analyse([:totals, {:sort, :own}, {:dest, ~c"fprof_analysis.txt"}])

      IO.puts("Profile written to fprof_analysis.txt")
      {:ok, "fprof_analysis.txt"}
    end
  end

  @doc """
  Profiles using the simpler :cprof (call count profiling).

  Good for understanding how many times functions are called.
  """
  def cprof_list_candidates(chain_name, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 100)
    filters = Keyword.get(opts, :filters, %{})

    :cprof.start()

    for _ <- 1..iterations do
      ProviderPool.list_candidates(chain_name, filters)
    end

    :cprof.pause()
    result = :cprof.analyse(Lasso.RPC.ProviderPool)
    :cprof.stop()

    result
  end

  @doc """
  Profiles the handle_call implementation directly (without GenServer overhead).

  This helps isolate whether the bottleneck is in GenServer.call itself or the handler.
  """
  def profile_handle_call_directly(chain_name, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 1000)
    filters = Keyword.get(opts, :filters, %{})

    # Get the current state
    pool_pid = GenServer.whereis(ProviderPool.via_name(chain_name))

    if is_nil(pool_pid) do
      {:error, :pool_not_found}
    else
      # This is hacky but useful for diagnosis: get state via sys
      state = :sys.get_state(pool_pid)

      # Now benchmark the pure handle_call logic
      measurements =
        for _ <- 1..iterations do
          start = System.monotonic_time(:microsecond)

          # Simulate what handle_call does
          _candidates = simulate_list_candidates(state, filters)

          System.monotonic_time(:microsecond) - start
        end

      %{
        iterations: iterations,
        min_us: Enum.min(measurements),
        max_us: Enum.max(measurements),
        avg_us: avg(measurements),
        median_us: percentile(measurements, 0.5),
        p95_us: percentile(measurements, 0.95),
        p99_us: percentile(measurements, 0.99)
      }
    end
  end

  # Simulate the handle_call logic for {:list_candidates, filters}
  # This is copied from the actual implementation to test pure processing speed
  defp simulate_list_candidates(state, filters) do
    current_time = System.monotonic_time(:millisecond)

    state.active_providers
    |> Enum.map(&Map.get(state.providers, &1))
    |> Enum.filter(fn p ->
      case Map.get(filters, :protocol) do
        :http ->
          transport_available?(p, :http, current_time)

        :ws ->
          transport_available?(p, :ws, current_time) and is_pid(ws_connection_pid(p.id))

        :both ->
          transport_available?(p, :http, current_time) and
            transport_available?(p, :ws, current_time)

        _ ->
          transport_available?(p, :http, current_time) or
            transport_available?(p, :ws, current_time)
      end
    end)
    |> Enum.filter(fn provider ->
      case Map.get(filters, :protocol) do
        :http ->
          get_cb_state(state.circuit_states, provider.id, :http) != :open

        :ws ->
          get_cb_state(state.circuit_states, provider.id, :ws) != :open

        _ ->
          not (get_cb_state(state.circuit_states, provider.id, :http) == :open and
                 get_cb_state(state.circuit_states, provider.id, :ws) == :open)
      end
    end)
    |> Enum.filter(fn provider ->
      case Map.get(filters, :exclude) do
        nil -> true
        exclude_list when is_list(exclude_list) -> provider.id not in exclude_list
        _ -> true
      end
    end)
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
  end

  defp ws_connection_pid(provider_id) when is_binary(provider_id) do
    GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, provider_id}}})
  end

  defp get_cb_state(circuit_states, provider_id, transport) do
    case Map.get(circuit_states, provider_id) do
      %{} = m -> Map.get(m, transport, :closed)
      other when other in [:open, :closed, :half_open] -> other
      _ -> :closed
    end
  end

  defp transport_available?(provider, :http, now_ms) do
    has_http = is_binary(Map.get(provider.config, :url))

    if not has_http,
      do: false,
      else: not in_cooldown?(Map.get(provider, :http_policy), provider, now_ms)
  end

  defp transport_available?(provider, :ws, now_ms) do
    has_ws = is_binary(Map.get(provider.config, :ws_url))

    if not has_ws,
      do: false,
      else: not in_cooldown?(Map.get(provider, :ws_policy), provider, now_ms)
  end

  defp in_cooldown?(%Lasso.RPC.HealthPolicy{} = pol, _provider, now_ms),
    do: Lasso.RPC.HealthPolicy.cooldown?(pol, now_ms)

  defp in_cooldown?(_other, provider, now_ms),
    do: not (is_nil(provider.cooldown_until) or provider.cooldown_until <= now_ms)

  # Helpers
  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp percentile(list, p) when p >= 0 and p <= 1 do
    sorted = Enum.sort(list)
    index = round(length(sorted) * p) - 1
    index = max(0, min(index, length(sorted) - 1))
    Enum.at(sorted, index)
  end
end
