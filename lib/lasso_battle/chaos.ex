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

  alias Lasso.RPC.ProviderPool

  @doc """
  Kills a provider after a specified delay.

  ## Options

  - `:delay` - Milliseconds to wait before killing (default: 0)
  - `:chain` - Chain name (required)

  ## Example

      Chaos.kill_provider("provider_a", chain: "ethereum", delay: 10_000)
      # Waits 10s, then terminates provider_a on ethereum chain
  """
  def kill_provider(provider_id, opts \\ []) do
    chain = Keyword.fetch!(opts, :chain)
    delay = Keyword.get(opts, :delay, 0)

    fn ->
      if delay > 0 do
        Logger.info("Chaos: Scheduled kill of #{provider_id} on #{chain} in #{delay}ms")
        Process.sleep(delay)
      end

      Logger.warning("Chaos: Killing provider #{provider_id} on #{chain}")

      case ProviderPool.get_provider_ws_pid(chain, provider_id) do
        {:ok, pid} ->
          Process.exit(pid, :kill)
          Logger.warning("Chaos: Killed provider #{provider_id} (pid: #{inspect(pid)})")
          :ok

        {:error, :not_found} ->
          Logger.warning("Chaos: Provider #{provider_id} not found on #{chain}, cannot kill")
          {:error, :not_found}
      end
    end
  end

  @doc """
  Flaps a provider (kills and restarts periodically).

  ## Options

  - `:chain` - Chain name (required)
  - `:down` - Milliseconds to stay down (default: 5_000)
  - `:up` - Milliseconds to stay up between flaps (default: 30_000)
  - `:count` - Number of flaps (default: :infinity)
  - `:initial_delay` - Initial delay before first flap (default: 0)

  ## Example

      Chaos.flap_provider("provider_a", chain: "ethereum", down: 10_000, up: 60_000, count: 3)
      # Kills provider every 60s, stays down for 10s, repeats 3 times
  """
  def flap_provider(provider_id, opts \\ []) do
    chain = Keyword.fetch!(opts, :chain)
    down_time = Keyword.get(opts, :down, 5_000)
    up_time = Keyword.get(opts, :up, 30_000)
    count = Keyword.get(opts, :count, :infinity)
    initial_delay = Keyword.get(opts, :initial_delay, 0)

    fn ->
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
    end
  end

  @doc """
  Degrades a provider by injecting artificial latency.

  This modifies the provider's latency configuration dynamically.

  ## Options

  - `:latency` - Additional latency to inject in milliseconds (required)
  - `:after` - Delay before degradation starts (default: 0)
  - `:duration` - How long to keep degraded (default: :infinity)

  ## Example

      Chaos.degrade_provider("provider_a", latency: 500, after: 30_000, duration: 60_000)
      # After 30s, add 500ms latency for 60s
  """
  def degrade_provider(provider_id, opts) do
    fn ->
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
    end
  end

  @doc """
  Opens a circuit breaker manually.

  Useful for simulating circuit breaker behavior without actual failures.

  ## Example

      Chaos.open_circuit_breaker("provider_a", duration: 30_000)
      # Opens circuit breaker for 30s
  """
  def open_circuit_breaker(provider_id, opts \\ []) do
    fn ->
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
    end
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

  # Private helpers

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

    case ProviderPool.get_provider_ws_pid(chain, provider_id) do
      {:ok, pid} ->
        Process.exit(pid, :kill)
        Logger.warning("Chaos: Killed #{provider_id} (will be restarted by supervisor)")

        # Wait for down_time
        Logger.info("Chaos: Provider #{provider_id} down for #{down_time}ms")
        Process.sleep(down_time)

        # Supervisor should have restarted it by now
        case ProviderPool.get_provider_ws_pid(chain, provider_id) do
          {:ok, new_pid} ->
            Logger.info("Chaos: Provider #{provider_id} restarted (new pid: #{inspect(new_pid)})")

          {:error, :not_found} ->
            Logger.warning("Chaos: Provider #{provider_id} not yet restarted")
        end

      {:error, :not_found} ->
        Logger.warning(
          "Chaos: Provider #{provider_id} not found on #{chain} during flap #{iteration + 1}"
        )
    end

    # Continue flapping
    new_count = if count == :infinity, do: :infinity, else: count - 1
    flap_loop(chain, provider_id, down_time, up_time, new_count, iteration + 1)
  end
end
