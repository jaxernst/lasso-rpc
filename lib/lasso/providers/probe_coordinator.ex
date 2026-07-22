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

  alias Lasso.Config.{ConfigStore, MonitoringDefaults}
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.{Catalog, RestartCounter}

  @tick_interval_ms 200
  @default_timeout_ms 5_000
  @base_backoff_ms 2_000
  @max_backoff_ms 30_000
  @rate_limit_backoff_ms 30_000
  @auth_backoff_ms 120_000
  @probe_rate_limit_ttl_ms 60_000
  @jitter_percent 0.2

  @type instance_state :: %{
          instance_id: String.t(),
          consecutive_failures: non_neg_integer(),
          last_probe_monotonic: integer() | nil,
          current_backoff_ms: non_neg_integer(),
          cached_interval_ms: pos_integer() | nil,
          cached_at: integer() | nil
        }

  defstruct [
    :chain_id,
    :tick_ref,
    instances: %{},
    probe_order: [],
    probe_index: 0,
    last_reload_at: 0,
    subscribed_instances: [],
    restart_count_cleared: false
  ]

  @spec start_link(pos_integer()) :: GenServer.on_start()
  def start_link(chain_id) when is_integer(chain_id) and chain_id > 0 do
    GenServer.start_link(__MODULE__, chain_id, name: via_name(chain_id))
  end

  @doc """
  Tells the coordinator to reload its instance list from the catalog.
  """
  @spec reload_instances(pos_integer()) :: :ok
  def reload_instances(chain_id) when is_integer(chain_id) and chain_id > 0 do
    GenServer.cast(via_name(chain_id), :reload_instances)
  end

  @impl true
  def init(chain_id) do
    state = %__MODULE__{chain_id: chain_id, last_reload_at: System.monotonic_time(:millisecond)}
    {:ok, state, {:continue, :deferred_start}}
  end

  @impl true
  def handle_continue(:deferred_start, state) do
    backoff = RestartCounter.backoff_for(RestartCounter.bump({:probe_coord, state.chain_id}))
    Process.send_after(self(), :load_instances, backoff)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reload_instances, state) do
    {:noreply, do_reload_instances(state)}
  end

  @impl true
  def handle_info(:instance_config_updated, state) do
    {:noreply, %{state | last_reload_at: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:load_instances, state) do
    state = do_reload_instances(state)
    tick_ref = schedule_tick()
    {:noreply, %{state | tick_ref: tick_ref}}
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
    handle_probe_result(instance_id, result, state)
  end

  @impl true
  def handle_info({:probe_result, instance_id, result}, state) do
    handle_probe_result(instance_id, result, state)
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp handle_probe_result(instance_id, result, state) do
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

        state =
          state
          |> Map.put(:instances, Map.put(state.instances, instance_id, updated))
          |> maybe_clear_restart_count(result)

        {:noreply, state}
    end
  end

  # First successful probe after a (re)start clears the restart
  # counter. A coordinator that crashes before any provider responds
  # keeps its count (genuine flap signal).
  defp maybe_clear_restart_count(%{restart_count_cleared: true} = state, _result), do: state

  defp maybe_clear_restart_count(state, :success) do
    RestartCounter.clear({:probe_coord, state.chain_id})
    %{state | restart_count_cleared: true}
  end

  defp maybe_clear_restart_count(state, _result), do: state

  defp do_reload_instances(state) do
    instance_ids = Catalog.list_instances_for_chain(state.chain_id)
    now = System.monotonic_time(:millisecond)

    new_instances =
      Map.new(instance_ids, fn id ->
        existing = Map.get(state.instances, id)

        inst_state =
          existing ||
            %{
              instance_id: id,
              consecutive_failures: 0,
              last_probe_monotonic: nil,
              current_backoff_ms: 0,
              cached_interval_ms: nil,
              cached_at: nil
            }

        {id, inst_state}
      end)

    state = manage_instance_subscriptions(state, instance_ids)

    %{
      state
      | instances: new_instances,
        probe_order: instance_ids,
        probe_index: 0,
        last_reload_at: now
    }
  end

  defp manage_instance_subscriptions(state, new_instance_ids) do
    old_subscribed = state.subscribed_instances
    added = new_instance_ids -- old_subscribed
    removed = old_subscribed -- new_instance_ids

    for id <- added do
      Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.instance_config_updated(id))
    end

    for id <- removed do
      Phoenix.PubSub.unsubscribe(Lasso.PubSub, Lasso.Topics.instance_config_updated(id))
    end

    %{state | subscribed_instances: new_instance_ids}
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

        {probe?, effective_ms} = should_probe?(inst, now, state)

        state =
          cond do
            probe? ->
              probe_instance(state, instance_id, inst, now)

            not is_nil(effective_ms) and not is_nil(inst) and
                (is_nil(inst.cached_interval_ms) or
                   is_nil(inst.cached_at) or
                   inst.cached_at < state.last_reload_at) ->
              updated_inst = %{inst | cached_interval_ms: effective_ms, cached_at: now}
              %{state | instances: Map.put(state.instances, instance_id, updated_inst)}

            true ->
              state
          end

        %{state | probe_index: index + 1}
    end
  end

  defp should_probe?(nil, _now, _state), do: {false, nil}

  defp should_probe?(inst, now, state) do
    effective_ms = effective_probe_interval_ms(state, inst.instance_id)

    case inst.last_probe_monotonic do
      nil -> {true, effective_ms}
      last -> {now - last >= max(inst.current_backoff_ms, effective_ms), effective_ms}
    end
  end

  defp effective_probe_interval_ms(state, instance_id) do
    inst = Map.get(state.instances, instance_id)

    cached_valid =
      not is_nil(inst) and
        not is_nil(inst.cached_interval_ms) and
        not is_nil(inst.cached_at) and
        inst.cached_at >= state.last_reload_at

    if cached_valid do
      inst.cached_interval_ms
    else
      compute_interval(state, instance_id)
    end
  end

  defp compute_interval(state, instance_id) do
    refs = Catalog.get_instance_refs(instance_id)

    intervals =
      refs
      |> Enum.map(&ConfigStore.get_chain(&1, state.chain_id))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, cc} -> cc.monitoring.probe_interval_ms end)

    case intervals do
      [] ->
        block_time_ms = instance_block_time_ms(instance_id)
        MonitoringDefaults.default_probe_interval_ms(block_time_ms)

      _ ->
        Enum.min(intervals)
    end
  end

  defp instance_block_time_ms(instance_id) do
    case Catalog.get_instance(instance_id) do
      {:ok, %{block_time_ms: bt}} when is_integer(bt) and bt > 0 -> bt
      _ -> nil
    end
  end

  defp probe_instance(state, instance_id, inst, now) do
    chain_id = state.chain_id
    coordinator = self()

    case Catalog.get_instance(instance_id) do
      {:ok, %{url: url}} when is_binary(url) ->
        Task.Supervisor.start_child(Lasso.TaskSupervisor, fn ->
          {^instance_id, result} = do_http_probe(instance_id, url, chain_id)
          send(coordinator, {:probe_result, instance_id, result})
        end)

      _ ->
        :skip
    end

    effective_ms = effective_probe_interval_ms(state, instance_id)

    updated_inst = %{
      inst
      | last_probe_monotonic: now,
        cached_interval_ms: effective_ms,
        cached_at: now
    }

    %{state | instances: Map.put(state.instances, instance_id, updated_inst)}
  end

  defp do_http_probe(instance_id, url, chain_id) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_chainId", "params" => [], "id" => 1})

    request =
      Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(request, Lasso.Finch, receive_timeout: @default_timeout_ms) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        case classify_response_body(resp_body, chain_id) do
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

  @rate_limit_codes [-32_005, -32_007, -32_029]

  defp classify_response_body(body, chain_id) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code, "message" => msg}}} when code in @rate_limit_codes ->
        {:rate_limited, "#{code}: #{msg}"}

      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error, "#{code}: #{msg}"}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error, msg}

      {:ok, %{"result" => hex_chain_id}} ->
        validate_chain_id_response(hex_chain_id, chain_id)

      {:ok, _} ->
        {:error, "unexpected JSON-RPC response shape"}

      {:error, _} ->
        {:error, "invalid JSON response"}
    end
  end

  defp classify_response_body(_, _chain_id), do: {:error, "empty response body"}

  defp validate_chain_id_response(hex, expected_chain_id)
       when is_binary(hex) and is_integer(expected_chain_id) do
    case Integer.parse(String.trim_leading(hex, "0x"), 16) do
      {actual, ""} when actual == expected_chain_id -> :ok
      {actual, ""} -> {:error, "wrong chain_id: got #{actual}, expected #{expected_chain_id}"}
      _ -> {:error, "invalid chain_id response: #{hex}"}
    end
  end

  defp validate_chain_id_response(_, _), do: :ok

  defp rate_limit_in_body?(body) when is_binary(body) do
    lower = String.downcase(body)
    String.contains?(lower, "rate limit") or String.contains?(lower, "too many requests")
  end

  defp rate_limit_in_body?(_), do: false

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

  @spec via_name(pos_integer()) :: {:via, Registry, {Lasso.Registry, term()}}
  def via_name(chain_id) when is_integer(chain_id) and chain_id > 0 do
    {:via, Registry, {Lasso.Registry, {:probe_coordinator, chain_id}}}
  end
end
