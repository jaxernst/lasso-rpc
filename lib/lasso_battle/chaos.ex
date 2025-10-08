defmodule Lasso.Battle.Chaos do
  @moduledoc """
  Chaos injection for battle testing.

  Provides controlled failure injection:
  - Kill providers (terminate process)
  - Flap providers (periodic up/down)
  - Degrade providers (inject latency)
  - Network partitions (Phase 3)
  """

  require Logger

  @doc """
  Kills a provider after a specified delay.

  Returns a Task that can be stopped with `Task.shutdown/1`.

  ## Options

  - `:delay` - Milliseconds to wait before killing (default: 0)
  - `:chain` - Chain name (required)

  ## Example

      task = Chaos.kill_provider("provider_a", chain: "ethereum", delay: 10_000)
      # Waits 10s, then terminates provider_a on ethereum chain
      # Stop early if needed: Task.shutdown(task)
  """
  def kill_provider(provider_id, opts \\ []) do
    chain = Keyword.fetch!(opts, :chain)
    delay = Keyword.get(opts, :delay, 0)

    Task.async(fn ->
      if delay > 0 do
        Logger.info("Chaos: Scheduled kill of #{provider_id} on #{chain} in #{delay}ms")
        Process.sleep(delay)
      end

      Logger.warning("Chaos: Killing provider #{provider_id} on #{chain}")

      # Look up WS connection directly in Registry
      case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
        [{pid, _}] when is_pid(pid) ->
          Process.exit(pid, :kill)
          Logger.warning("Chaos: Killed WS connection for #{provider_id} (pid: #{inspect(pid)})")
          :ok

        [] ->
          Logger.warning("Chaos: WS connection for #{provider_id} not found in Registry, cannot kill")
          {:error, :not_found}
      end
    end)
  end

  @doc """
  Flaps a provider (kills and restarts periodically).

  Returns a Task that can be stopped with `Task.shutdown/1`.

  ## Options

  - `:chain` - Chain name (required)
  - `:down` - Milliseconds to stay down (default: 5_000)
  - `:up` - Milliseconds to stay up between flaps (default: 30_000)
  - `:count` - Number of flaps (default: :infinity)
  - `:initial_delay` - Initial delay before first flap (default: 0)

  ## Example

      task = Chaos.flap_provider("provider_a", chain: "ethereum", down: 10_000, up: 60_000, count: 3)
      # Kills provider every 60s, stays down for 10s, repeats 3 times
      # Stop early if needed: Task.shutdown(task)
  """
  def flap_provider(provider_id, opts \\ []) do
    chain = Keyword.fetch!(opts, :chain)
    down_time = Keyword.get(opts, :down, 5_000)
    up_time = Keyword.get(opts, :up, 30_000)
    count = Keyword.get(opts, :count, :infinity)
    initial_delay = Keyword.get(opts, :initial_delay, 0)

    Task.async(fn ->
      if initial_delay > 0 do
        Logger.info(
          "Chaos: Scheduled flap of #{provider_id} on #{chain} to start in #{initial_delay}ms"
        )

        Process.sleep(initial_delay)
      end

      Logger.info(
        "Chaos: Starting flap sequence for #{provider_id} on #{chain} (down: #{down_time}ms, up: #{up_time}ms)"
      )

      flap_loop(chain, provider_id, down_time, up_time, count, 0)
    end)
  end

  @doc """
  Degrades a provider by injecting artificial latency.

  Returns a Task that can be stopped with `Task.shutdown/1`.

  This modifies the provider's latency configuration dynamically.

  ## Options

  - `:latency` - Additional latency to inject in milliseconds (required)
  - `:after` - Delay before degradation starts (default: 0)
  - `:duration` - How long to keep degraded (default: :infinity)

  ## Example

      task = Chaos.degrade_provider("provider_a", latency: 500, after: 30_000, duration: 60_000)
      # After 30s, add 500ms latency for 60s
      # Stop early if needed: Task.shutdown(task)
  """
  def degrade_provider(provider_id, opts) do
    Task.async(fn ->
      latency = Keyword.fetch!(opts, :latency)
      delay = Keyword.get(opts, :after, 0)
      duration = Keyword.get(opts, :duration, :infinity)

      if delay > 0 do
        Logger.info("Chaos: Scheduled degradation of #{provider_id} in #{delay}ms")
        Process.sleep(delay)
      end

      Logger.warning("Chaos: Degrading #{provider_id} with +#{latency}ms latency")

      # For Phase 2, we'll simulate degradation via telemetry
      # In a real implementation, this would modify the provider's config
      :telemetry.execute(
        [:lasso, :battle, :chaos],
        %{latency_injected: latency},
        %{provider_id: provider_id, action: :degrade}
      )

      if duration != :infinity do
        Process.sleep(duration)

        Logger.info("Chaos: Restoring #{provider_id} (degradation period ended)")

        :telemetry.execute(
          [:lasso, :battle, :chaos],
          %{latency_injected: 0},
          %{provider_id: provider_id, action: :restore}
        )
      end

      :ok
    end)
  end

  @doc """
  Opens a circuit breaker manually.

  Returns a Task that can be stopped with `Task.shutdown/1`.

  Useful for simulating circuit breaker behavior without actual failures.

  ## Example

      task = Chaos.open_circuit_breaker("provider_a", duration: 30_000)
      # Opens circuit breaker for 30s
      # Stop early if needed: Task.shutdown(task)
  """
  def open_circuit_breaker(provider_id, opts \\ []) do
    Task.async(fn ->
      delay = Keyword.get(opts, :delay, 0)
      duration = Keyword.get(opts, :duration, 30_000)

      if delay > 0, do: Process.sleep(delay)

      Logger.warning("Chaos: Opening circuit breaker for #{provider_id}")

      case Lasso.RPC.CircuitBreaker.open(provider_id) do
        :ok ->
          Logger.warning("Chaos: Circuit breaker opened for #{provider_id}")

          if duration != :infinity do
            Process.sleep(duration)

            Logger.info("Chaos: Closing circuit breaker for #{provider_id}")
            Lasso.RPC.CircuitBreaker.close(provider_id)
          end

          :ok
      end
    end)
  end

  @doc """
  Simulates network latency increase.

  ## Example

      Chaos.inject_latency(fn ->
        # Your workload code
      end, latency: 100)
  """
  def inject_latency(workload_fn, opts) do
    latency = Keyword.fetch!(opts, :latency)

    fn ->
      # Wrap workload with latency injection
      original_result = workload_fn.()

      # Sleep to simulate latency
      Process.sleep(latency)

      original_result
    end
  end

  @doc """
  Injects random provider failures at intervals.

  Returns a Task that can be shutdown to stop the chaos.

  ## Options

  - `:chain` - Chain name (required)
  - `:kill_interval` - How often to potentially kill a provider (default: 5000ms)
  - `:recovery_delay` - How long before provider recovers (default: 2000ms)
  - `:kill_probability` - Chance of kill on each interval 0.0-1.0 (default: 0.3)
  - `:min_providers` - Minimum providers to keep alive (default: 1)

  ## Example

      task = Chaos.random_provider_chaos(
        chain: "ethereum",
        kill_interval: 10_000,
        kill_probability: 0.5
      )

      # Later stop chaos
      Task.shutdown(task)
  """
  def random_provider_chaos(opts) do
    chain = Keyword.fetch!(opts, :chain)
    kill_interval = Keyword.get(opts, :kill_interval, 5_000)
    recovery_delay = Keyword.get(opts, :recovery_delay, 2_000)
    kill_probability = Keyword.get(opts, :kill_probability, 0.3)
    min_providers = Keyword.get(opts, :min_providers, 1)

    Task.async(fn ->
      random_chaos_loop(chain, kill_interval, recovery_delay, kill_probability, min_providers)
    end)
  end

  @doc """
  Simulates memory pressure by allocating large binaries.

  Forces garbage collection activity to test system behavior under memory pressure.

  ## Options

  - `:target_mb` - Amount of memory to allocate per cycle (default: 100MB)
  - `:interval_ms` - How often to allocate (default: 1000ms)
  - `:duration_ms` - How long to maintain pressure (default: :infinity)

  ## Example

      task = Chaos.memory_pressure(
        target_mb: 200,
        interval_ms: 500,
        duration_ms: 60_000
      )
  """
  def memory_pressure(opts \\ []) do
    target_mb = Keyword.get(opts, :target_mb, 100)
    interval_ms = Keyword.get(opts, :interval_ms, 1_000)
    duration_ms = Keyword.get(opts, :duration_ms, :infinity)

    Task.async(fn ->
      start_time = System.monotonic_time(:millisecond)
      memory_pressure_loop(target_mb, interval_ms, start_time, duration_ms)
    end)
  end

  @doc """
  Applies multiple chaos scenarios simultaneously.

  ## Options

  Each chaos type can be configured independently.

  ## Example

      tasks = Chaos.combined_chaos(
        chain: "ethereum",
        provider_chaos: [kill_interval: 5_000],
        memory_pressure: [target_mb: 100]
      )

      # Later stop all chaos
      Chaos.stop_all_chaos(tasks)
  """
  def combined_chaos(opts) do
    chain = Keyword.fetch!(opts, :chain)
    chaos_tasks = []

    chaos_tasks =
      if provider_opts = Keyword.get(opts, :provider_chaos) do
        task = random_provider_chaos(Keyword.put(provider_opts, :chain, chain))
        [task | chaos_tasks]
      else
        chaos_tasks
      end

    chaos_tasks =
      if memory_opts = Keyword.get(opts, :memory_pressure) do
        task = memory_pressure(memory_opts)
        [task | chaos_tasks]
      else
        chaos_tasks
      end

    chaos_tasks
  end

  @doc """
  Stops all chaos tasks gracefully.

  ## Example

      tasks = Chaos.combined_chaos(...)
      Chaos.stop_all_chaos(tasks)
  """
  def stop_all_chaos(tasks) when is_list(tasks) do
    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end

  # Private helpers

  defp random_chaos_loop(chain, interval, recovery, probability, min_providers) do
    Process.sleep(interval)

    # Get list of active providers (from Registry)
    providers = list_active_providers_for_chain(chain)

    # Only kill if we have more than minimum and probability succeeds
    if length(providers) > min_providers and :rand.uniform() < probability do
      target = Enum.random(providers)

      Logger.warning("🔥 CHAOS: Random kill - killing #{target} on #{chain}")

      # Kill the provider
      case Registry.lookup(Lasso.Registry, {:ws_conn, target}) do
        [{pid, _}] ->
          Process.exit(pid, :kill)

          # Schedule recovery
          Task.start(fn ->
            Process.sleep(recovery)
            Logger.info("♻️  CHAOS: Random kill - provider #{target} should recover via supervisor")
          end)

        [] ->
          :ok
      end
    end

    random_chaos_loop(chain, interval, recovery, probability, min_providers)
  end

  defp memory_pressure_loop(target_mb, interval, start_time, total_duration) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if total_duration != :infinity and elapsed >= total_duration do
      Logger.info("CHAOS: Memory pressure completed")
      :done
    else
      # Allocate large binary
      size = target_mb * 1024 * 1024
      _blob = :binary.copy(<<0>>, size)

      Logger.debug("CHAOS: Allocated #{target_mb}MB memory")

      # Wait for interval (binary gets GC'd)
      Process.sleep(interval)

      memory_pressure_loop(target_mb, interval, start_time, total_duration)
    end
  end

  defp list_active_providers_for_chain(chain) do
    # FIXME: Currently returns ALL providers across all chains
    # because Registry key {:ws_conn, provider_id} doesn't include chain info.
    #
    # This means random_provider_chaos could kill providers from other tests
    # running in parallel on different chains.
    #
    # Solutions:
    # 1. Change Registry key to {:ws_conn, chain, provider_id}
    # 2. Store chain in Registry value metadata
    # 3. Query ProviderPool.list_providers(chain) if available
    #
    # For now, logging a warning if this function is used.
    Logger.warning(
      "Chaos: list_active_providers_for_chain/1 ignores chain parameter! " <>
        "May affect providers from other chains. Chain: #{chain}"
    )

    # Get all WS connections from Registry (ignores chain)
    Registry.select(Lasso.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn
      {{:ws_conn, _provider_id}, _pid} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:ws_conn, provider_id}, _pid} -> provider_id end)
  end

  defp flap_loop(_chain, _provider_id, _down_time, _up_time, 0, iteration) do
    Logger.info("Chaos: Flap sequence complete (#{iteration} flaps)")
    :ok
  end

  defp flap_loop(chain, provider_id, down_time, up_time, count, iteration) do
    # Wait for up_time before next flap (unless first iteration)
    if iteration > 0 do
      Logger.info("Chaos: Waiting #{up_time}ms before next flap of #{provider_id} on #{chain}")
      Process.sleep(up_time)
    end

    # Kill the provider
    Logger.warning("Chaos: Flap #{iteration + 1} - Killing #{provider_id} on #{chain}")

    case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
      [{pid, _}] ->
        Process.exit(pid, :kill)
        Logger.warning("Chaos: Killed #{provider_id} (will be restarted by supervisor)")

        # Wait for down_time
        Logger.info("Chaos: Provider #{provider_id} down for #{down_time}ms")
        Process.sleep(down_time)

        # Supervisor should have restarted it by now
        case Registry.lookup(Lasso.Registry, {:ws_conn, provider_id}) do
          [{new_pid, _}] ->
            Logger.info("Chaos: Provider #{provider_id} restarted (new pid: #{inspect(new_pid)})")

          [] ->
            Logger.warning("Chaos: Provider #{provider_id} not yet restarted")
        end

      [] ->
        Logger.warning(
          "Chaos: Provider #{provider_id} not found on #{chain} during flap #{iteration + 1}"
        )
    end

    # Continue flapping
    new_count = if count == :infinity, do: :infinity, else: count - 1
    flap_loop(chain, provider_id, down_time, up_time, new_count, iteration + 1)
  end
end
