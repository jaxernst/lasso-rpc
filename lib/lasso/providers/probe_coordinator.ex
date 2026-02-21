defmodule Lasso.Providers.ProbeCoordinator do
  @moduledoc """
  Per-chain health probe coordinator. One GenServer per unique chain.

  Cycles through all unique provider instances for a chain, probing each via
  HTTP `eth_chainId`. Results are written directly to `:lasso_instance_state` ETS.

  ## Probe Cycle

  With a 200ms tick interval and N unique instances for a chain:
  - Each instance is probed every `200ms × N` on average
  - Exponential backoff per-instance on failure (2s base, 30s max, ±20% jitter)

  ## ETS Write Partitioning

  ProbeCoordinator owns writes to `{:health, instance_id}` for probe-sourced fields:
  `status`, `http_status`, `last_health_check`.

  WebSocket status is stored separately under `{:ws_status, instance_id}` by `Connection`.

  Observability owns `update_counter` for `consecutive_failures`/`consecutive_successes`.
  """

  use GenServer
  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.Catalog

  @tick_interval_ms 200
  @default_timeout_ms 5_000
  @base_backoff_ms 2_000
  @max_backoff_ms 30_000
  @jitter_percent 0.2

  @type instance_state :: %{
          instance_id: String.t(),
          consecutive_failures: non_neg_integer(),
          last_probe_monotonic: integer() | nil,
          current_backoff_ms: non_neg_integer()
        }

  defstruct [
    :chain,
    :tick_ref,
    instances: %{},
    probe_order: [],
    probe_index: 0
  ]

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: via_name(chain))
  end

  @doc """
  Tells the coordinator to reload its instance list from the catalog.
  """
  @spec reload_instances(String.t()) :: :ok
  def reload_instances(chain) do
    GenServer.cast(via_name(chain), :reload_instances)
  end

  @impl true
  def init(chain) do
    state = %__MODULE__{chain: chain}
    state = do_reload_instances(state)
    tick_ref = schedule_tick()

    {:ok, %{state | tick_ref: tick_ref}}
  end

  @impl true
  def handle_cast(:reload_instances, state) do
    {:noreply, do_reload_instances(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    tick_ref = schedule_tick()
    {:noreply, %{state | tick_ref: tick_ref}}
  end

  @impl true
  def handle_info({ref, {instance_id, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.get(state.instances, instance_id) do
      nil ->
        {:noreply, state}

      inst ->
        updated =
          case result do
            :success ->
              %{inst | consecutive_failures: 0, current_backoff_ms: 0}

            {:failure, _reason} ->
              new_failures = inst.consecutive_failures + 1
              backoff = compute_backoff(new_failures)
              %{inst | consecutive_failures: new_failures, current_backoff_ms: backoff}
          end

        {:noreply, %{state | instances: Map.put(state.instances, instance_id, updated)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp do_reload_instances(state) do
    instance_ids = Catalog.list_instances_for_chain(state.chain)

    new_instances =
      Map.new(instance_ids, fn id ->
        existing = Map.get(state.instances, id)

        inst_state =
          existing ||
            %{
              instance_id: id,
              consecutive_failures: 0,
              last_probe_monotonic: nil,
              current_backoff_ms: 0
            }

        {id, inst_state}
      end)

    %{state | instances: new_instances, probe_order: instance_ids, probe_index: 0}
  end

  defp do_tick(state) do
    case state.probe_order do
      [] ->
        state

      order ->
        index = rem(state.probe_index, length(order))
        instance_id = Enum.at(order, index)
        now = System.monotonic_time(:millisecond)

        inst = Map.get(state.instances, instance_id)

        state =
          if should_probe?(inst, now) do
            probe_instance(state, instance_id, inst, now)
          else
            state
          end

        %{state | probe_index: index + 1}
    end
  end

  defp should_probe?(nil, _now), do: false

  defp should_probe?(inst, now) do
    case inst.last_probe_monotonic do
      nil -> true
      last -> now - last >= inst.current_backoff_ms
    end
  end

  defp probe_instance(state, instance_id, inst, now) do
    chain = state.chain

    case Catalog.get_instance(instance_id) do
      {:ok, %{url: url}} when is_binary(url) ->
        Task.async(fn -> do_http_probe(instance_id, url, chain) end)

      _ ->
        :skip
    end

    updated_inst = %{inst | last_probe_monotonic: now}
    %{state | instances: Map.put(state.instances, instance_id, updated_inst)}
  end

  defp do_http_probe(instance_id, url, _chain) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_chainId", "params" => [], "id" => 1})

    request =
      Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(request, Lasso.Finch, receive_timeout: @default_timeout_ms) do
      {:ok, %{status: status}} when status in 200..299 ->
        write_probe_success(instance_id)
        CircuitBreaker.signal_recovery_cast({instance_id, :http})
        {instance_id, :success}

      {:ok, %{status: status}} ->
        write_probe_failure(instance_id, {:http_status, status})
        {instance_id, {:failure, {:http_status, status}}}

      {:error, reason} ->
        write_probe_failure(instance_id, reason)
        {instance_id, {:failure, reason}}
    end
  end

  defp write_probe_success(instance_id) do
    merged =
      Map.merge(read_existing_health(instance_id), %{
        status: :healthy,
        http_status: :healthy,
        last_health_check: System.system_time(:millisecond),
        last_error: nil
      })

    :ets.insert(:lasso_instance_state, {{:health, instance_id}, merged})
  rescue
    ArgumentError -> :ok
  end

  defp write_probe_failure(instance_id, reason) do
    existing = read_existing_health(instance_id)
    probe_failures = Map.get(existing, :consecutive_failures, 0) + 1
    new_status = if probe_failures >= 3, do: :unhealthy, else: :degraded

    merged =
      Map.merge(existing, %{
        status: new_status,
        http_status: new_status,
        last_health_check: System.system_time(:millisecond),
        last_error: reason
      })

    :ets.insert(:lasso_instance_state, {{:health, instance_id}, merged})
  rescue
    ArgumentError -> :ok
  end

  defp read_existing_health(instance_id) do
    case :ets.lookup(:lasso_instance_state, {:health, instance_id}) do
      [{_, data}] -> data
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp compute_backoff(failure_count) do
    base = @base_backoff_ms * trunc(:math.pow(2, min(failure_count - 1, 4)))
    capped = min(base, @max_backoff_ms)
    jitter = trunc(capped * @jitter_percent * (:rand.uniform() * 2 - 1))
    max(0, capped + jitter)
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  @spec via_name(String.t()) :: {:via, Registry, {Lasso.Registry, term()}}
  def via_name(chain) do
    {:via, Registry, {Lasso.Registry, {:probe_coordinator, chain}}}
  end
end
