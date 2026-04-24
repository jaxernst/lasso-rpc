defmodule Lasso.Providers.ProbeCoordinator do
  @moduledoc """
  Per-chain health probe coordinator. One GenServer per unique chain.

  Cycles through all unique provider instances for a chain, probing each via
  HTTP `eth_chainId`. Results are written directly to `:lasso_instance_state` ETS.

  ## Probe Cycle

  With a 200ms tick interval and N unique instances for a chain:
  - Each instance is probed at most every 10s (minimum probe interval floor)
  - Exponential backoff per-instance on failure (2s base, 30s max, ±20% jitter)
  - Rate-limited providers back off to 30s
  - Auth-failed providers (401/402) back off to 120s

  ## ETS Write Partitioning

  Each ETS key is exclusively owned by one writer:

  - `{:health_probe, id}` — ProbeCoordinator (this module)
  - `{:health_block_sync, id}` — HttpStrategy (block sync polling)
  - `{:health_routing, id}` — Observability (real request outcomes)
  - `{:ws_status, id}` — WebSocket Connection
  - `{:rate_limit, id, transport}` — Observability + ProbeCoordinator (write-if-earlier)
  """

  use GenServer
  require Logger

  alias Lasso.Config.ChainValidator
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.Catalog

  @tick_interval_ms 200
  @default_timeout_ms 5_000
  @base_backoff_ms 2_000
  @max_backoff_ms 30_000
  @rate_limit_backoff_ms 30_000
  @auth_backoff_ms 120_000
  @min_probe_interval_ms 10_000
  @probe_rate_limit_ttl_ms 60_000
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

            {:rate_limited, _status} ->
              %{inst | current_backoff_ms: max(inst.current_backoff_ms, @rate_limit_backoff_ms)}

            {:auth_failed, _status} ->
              %{inst | current_backoff_ms: @auth_backoff_ms}

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
      last -> now - last >= max(inst.current_backoff_ms, @min_probe_interval_ms)
    end
  end

  defp probe_instance(state, instance_id, inst, now) do
    chain = state.chain

    case Catalog.get_instance(instance_id) do
      {:ok, %{url: url}} when is_binary(url) ->
        Task.Supervisor.start_child(Lasso.TaskSupervisor, fn ->
          do_http_probe(instance_id, url, chain)
        end)

      _ ->
        :skip
    end

    updated_inst = %{inst | last_probe_monotonic: now}
    %{state | instances: Map.put(state.instances, instance_id, updated_inst)}
  end

  defp do_http_probe(instance_id, url, chain) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_chainId", "params" => [], "id" => 1})

    request =
      Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(request, Lasso.Finch, receive_timeout: @default_timeout_ms) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        case classify_response_body(resp_body, chain) do
          :ok ->
            write_probe_success(instance_id)
            CircuitBreaker.signal_recovery_cast({instance_id, :http})
            {instance_id, :success}

          {:rate_limited, reason} ->
            write_probe_rate_limit(instance_id)
            {instance_id, {:rate_limited, reason}}

          {:error, reason} ->
            write_probe_failure(instance_id, {:json_rpc_error, reason})
            {instance_id, {:failure, {:json_rpc_error, reason}}}
        end

      {:ok, %{status: status}} when status in [401, 402] ->
        write_probe_auth_failure(instance_id, status)
        {instance_id, {:auth_failed, status}}

      {:ok, %{status: status}} when status in [403, 429] ->
        write_probe_rate_limit(instance_id)
        {instance_id, {:rate_limited, status}}

      {:ok, %{status: status, body: resp_body}} when status in 500..599 ->
        if rate_limit_in_body?(resp_body) do
          write_probe_rate_limit(instance_id)
          {instance_id, {:rate_limited, status}}
        else
          write_probe_failure(instance_id, {:http_status, status})
          {instance_id, {:failure, {:http_status, status}}}
        end

      {:ok, %{status: status}} ->
        write_probe_failure(instance_id, {:http_status, status})
        {instance_id, {:failure, {:http_status, status}}}

      {:error, reason} ->
        write_probe_failure(instance_id, reason)
        {instance_id, {:failure, reason}}
    end
  end

  @rate_limit_codes [-32_005, -32_097]

  defp classify_response_body(body, chain) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code, "message" => msg}}} when code in @rate_limit_codes ->
        {:rate_limited, "#{code}: #{msg}"}

      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error, "#{code}: #{msg}"}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error, msg}

      {:ok, %{"result" => hex_chain_id}} ->
        validate_chain_id(hex_chain_id, chain)

      {:ok, _} ->
        {:error, "unexpected JSON-RPC response shape"}

      {:error, _} ->
        {:error, "invalid JSON response"}
    end
  end

  defp classify_response_body(_, _chain), do: {:error, "empty response body"}

  defp validate_chain_id(hex, chain) when is_binary(hex) do
    case ChainValidator.expected_chain_id(chain) do
      nil ->
        :ok

      expected ->
        case Integer.parse(String.trim_leading(hex, "0x"), 16) do
          {actual, ""} when actual == expected -> :ok
          {actual, ""} -> {:error, "wrong chain_id: got #{actual}, expected #{expected}"}
          _ -> {:error, "invalid chain_id response: #{hex}"}
        end
    end
  end

  defp validate_chain_id(_, _chain), do: :ok

  defp rate_limit_in_body?(body) when is_binary(body) do
    lower = String.downcase(body)
    String.contains?(lower, "rate limit") or String.contains?(lower, "too many requests")
  end

  defp rate_limit_in_body?(_), do: false

  # ETS writers — write to {:health_probe, instance_id} (exclusively owned by ProbeCoordinator).
  # HttpStrategy writes to {:health_block_sync, instance_id} separately.
  # Runs inside Task.Supervisor children; if ETS is missing, the task crashes (expected).

  defp write_probe_success(instance_id) do
    existing = read_existing_probe(instance_id)

    :ets.insert(
      :lasso_instance_state,
      {{:health_probe, instance_id},
       Map.merge(existing, %{
         status: :healthy,
         http_status: :healthy,
         last_health_check: System.system_time(:millisecond),
         consecutive_failures: 0,
         last_error: nil
       })}
    )
  end

  defp write_probe_failure(instance_id, reason) do
    existing = read_existing_probe(instance_id)
    probe_failures = Map.get(existing, :consecutive_failures, 0) + 1

    :ets.insert(
      :lasso_instance_state,
      {{:health_probe, instance_id},
       Map.merge(existing, %{
         status: if(probe_failures >= 3, do: :unhealthy, else: :degraded),
         http_status: if(probe_failures >= 3, do: :unhealthy, else: :degraded),
         last_health_check: System.system_time(:millisecond),
         consecutive_failures: probe_failures,
         last_error: reason
       })}
    )

    CircuitBreaker.record_failure({instance_id, :http}, reason)
  end

  defp write_probe_auth_failure(instance_id, status) do
    existing = read_existing_probe(instance_id)
    probe_failures = Map.get(existing, :consecutive_failures, 0) + 1

    :ets.insert(
      :lasso_instance_state,
      {{:health_probe, instance_id},
       Map.merge(existing, %{
         status: :misconfigured,
         http_status: :misconfigured,
         last_health_check: System.system_time(:millisecond),
         consecutive_failures: probe_failures,
         last_error: {:auth_failed, status}
       })}
    )

    Logger.warning("Provider auth failure",
      instance_id: instance_id,
      http_status: status
    )
  end

  defp write_probe_rate_limit(instance_id) do
    existing = read_existing_probe(instance_id)

    :ets.insert(
      :lasso_instance_state,
      {{:health_probe, instance_id},
       Map.merge(existing, %{
         status: :degraded,
         http_status: :degraded,
         last_health_check: System.system_time(:millisecond)
       })}
    )

    now_ms = System.monotonic_time(:millisecond)
    probe_expiry = now_ms + @probe_rate_limit_ttl_ms

    case :ets.lookup(:lasso_instance_state, {:rate_limit, instance_id, :http}) do
      [{_, %{expiry_ms: existing_expiry}}] when existing_expiry > now_ms ->
        :ok

      _ ->
        :ets.insert(:lasso_instance_state, {
          {:rate_limit, instance_id, :http},
          %{expiry_ms: probe_expiry, retry_after_ms: @probe_rate_limit_ttl_ms}
        })
    end
  end

  defp read_existing_probe(instance_id) do
    case :ets.lookup(:lasso_instance_state, {:health_probe, instance_id}) do
      [{_, data}] -> data
      [] -> %{}
    end
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
