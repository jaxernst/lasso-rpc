defmodule Lasso.RPC.ProviderProbe do
  @moduledoc """
  Executes periodic provider health probes.

  This GenServer is responsible ONLY for probe execution:
  - Scheduling probe cycles
  - Making HTTP requests (eth_blockNumber)
  - Handling timeouts and errors
  - Collecting results

  It reports results to ProviderPool via cast (fire-and-forget).
  It does NOT maintain any health state or make routing decisions.

  ## Separation of Concerns

  - ProviderProbe: Execution (what probes to run, when)
  - ProviderPool: State (health status, selection, ETS)

  This separation allows:
  - Easy testing (mock HTTP without health state logic)
  - Easy extension (add newHeads without changing health logic)
  - Clear ownership (probe strategy vs health policy)
  """

  use GenServer
  require Logger

  alias Lasso.RPC.{CircuitBreaker, ProviderPool, TransportRegistry, Channel}
  alias Lasso.Config.ConfigStore

  # Minimal state - only probing concerns
  defstruct [
    :chain,
    :probe_interval_ms,
    :probe_sequence,
    :table
  ]

  ## Client API

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:provider_probe, chain}}}

  @doc """
  Manually trigger a probe cycle (useful for testing).
  """
  def trigger_probe(chain) do
    GenServer.cast(via(chain), :probe_now)
  end

  ## GenServer Callbacks

  @impl true
  def init(chain) do
    # Create ETS table for storing probe results (owned by this process)
    # Table is unnamed and referenced by table ID stored in state
    table =
      :ets.new(:"provider_probe_#{chain}", [
        :set,
        :public,
        read_concurrency: true
      ])

    state = %__MODULE__{
      chain: chain,
      probe_interval_ms: probe_interval_for_chain(chain),
      probe_sequence: 0,
      table: table
    }

    # Schedule first probe after brief delay
    schedule_probe(2_000)

    Logger.info("ProviderProbe started",
      chain: chain,
      probe_interval_ms: state.probe_interval_ms
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:probe, state) do
    start_time = System.monotonic_time(:millisecond)
    sequence = state.probe_sequence + 1

    # Execute probe cycle
    results = execute_probe_cycle(state.chain, sequence)

    # Report all results to ProviderPool (fire-and-forget)
    ProviderPool.report_probe_results(state.chain, results)

    # Emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    emit_telemetry(state.chain, results, duration)

    # Schedule next probe
    schedule_probe(state.probe_interval_ms)

    {:noreply, %{state | probe_sequence: sequence}}
  end

  @impl true
  def handle_cast(:probe_now, state) do
    start_time = System.monotonic_time(:millisecond)
    sequence = state.probe_sequence + 1

    # Execute probe cycle immediately
    results = execute_probe_cycle(state.chain, sequence)

    # Report all results to ProviderPool
    ProviderPool.report_probe_results(state.chain, results)

    # Emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    emit_telemetry(state.chain, results, duration)

    {:noreply, %{state | probe_sequence: sequence}}
  end

  ## Private: Probe Execution

  defp execute_probe_cycle(chain, sequence) do
    providers = get_providers_to_probe(chain)

    if providers == [] do
      Logger.debug("No providers to probe", chain: chain)
      []
    else
      # Probe all providers concurrently
      Task.Supervisor.async_stream(
        Lasso.TaskSupervisor,
        providers,
        fn provider -> probe_provider(chain, provider, sequence) end,
        timeout: 3_000,
        on_timeout: :kill_task,
        shutdown: 1_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> nil
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end
  end

  defp probe_provider(chain, provider, sequence) do
    start_time = System.monotonic_time(:millisecond)

    case TransportRegistry.get_channel(chain, provider.id, :http) do
      {:ok, channel} ->
        rpc_request = %{
          "jsonrpc" => "2.0",
          "method" => "eth_blockNumber",
          "params" => [],
          "id" => :rand.uniform(1_000_000)
        }

        case Channel.request(channel, rpc_request, 3_000) do
          {:ok, "0x" <> hex, _io_ms} ->
            latency_ms = System.monotonic_time(:millisecond) - start_time
            height = String.to_integer(hex, 16)

            # Report success to circuit breaker for recovery (best-effort)
            # This triggers: open → half_open → closed transitions
            # Wrapped in try/rescue so CB errors don't mark successful probe as failed
            try do
              CircuitBreaker.record_success({chain, provider.id, :http})
            rescue
              e ->
                Logger.warning("Circuit breaker reporting failed",
                  error: Exception.message(e),
                  provider_id: provider.id,
                  chain: chain
                )
            end

            %{
              provider_id: provider.id,
              timestamp: System.system_time(:millisecond),
              sequence: sequence,
              success?: true,
              block_height: height,
              latency_ms: latency_ms,
              error: nil
            }

          {:error, reason, _io_ms} ->
            latency_ms = System.monotonic_time(:millisecond) - start_time
            # Don't report failures to circuit breaker - probes only help recovery
            # Failed probes shouldn't extend open circuit duration

            %{
              provider_id: provider.id,
              timestamp: System.system_time(:millisecond),
              sequence: sequence,
              success?: false,
              latency_ms: latency_ms,
              error: reason
            }
        end

      {:error, reason} ->
        %{
          provider_id: provider.id,
          timestamp: System.system_time(:millisecond),
          sequence: sequence,
          success?: false,
          error: {:channel_unavailable, reason}
        }
    end
  rescue
    e ->
      %{
        provider_id: provider.id,
        timestamp: System.system_time(:millisecond),
        sequence: sequence,
        success?: false,
        error: {:probe_crashed, Exception.message(e)}
      }
  end

  defp get_providers_to_probe(chain) do
    case ConfigStore.get_chain(chain) do
      {:ok, chain_config} -> chain_config.providers
      _ -> []
    end
  end

  defp schedule_probe(delay_ms) do
    Process.send_after(self(), :probe, delay_ms)
  end

  defp probe_interval_for_chain(chain) do
    # Get probe interval from chain configuration (chains.yml)
    # Falls back to application config if chain not found
    case ConfigStore.get_chain(chain) do
      {:ok, chain_config} ->
        chain_config.monitoring.probe_interval_ms

      {:error, _} ->
        # Fallback to application config for backwards compatibility
        intervals =
          Application.get_env(:lasso, :provider_probe, [])
          |> Keyword.get(:probe_interval_by_chain, %{})

        Map.get(intervals, chain) ||
          Application.get_env(:lasso, :provider_probe, [])
          |> Keyword.get(:default_probe_interval_ms, 12_000)
    end
  end

  defp emit_telemetry(chain, results, duration_ms) do
    successful = Enum.count(results, & &1.success?)
    failed = Enum.count(results, &(not &1.success?))

    :telemetry.execute(
      [:lasso, :provider_probe, :cycle_completed],
      %{successful: successful, failed: failed, duration_ms: duration_ms},
      %{chain: chain}
    )
  end
end
