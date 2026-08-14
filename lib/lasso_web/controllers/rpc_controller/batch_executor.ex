defmodule LassoWeb.RPCController.BatchExecutor do
  @moduledoc false

  alias Lasso.Core.Request.ExecutionScope

  @default_max_active 4
  @retained_item_keys [:index, :request_id, :respond?]

  defmodule Result do
    @moduledoc false

    @enforce_keys [:items, :counters, :max_active]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            items: [{map(), term()}],
            counters: %{atom() => non_neg_integer()},
            max_active: non_neg_integer()
          }
  end

  @type item :: %{required(:index) => non_neg_integer(), required(:deadline_us) => integer()}
  @type executor :: (item(), ExecutionScope.t() -> term())

  @spec run([item()], executor(), keyword()) :: Result.t()
  def run(items, executor, opts \\ []) when is_list(items) and is_function(executor, 2) do
    max_active = Keyword.get(opts, :max_active, @default_max_active)
    supervisor = Keyword.get(opts, :task_supervisor, Lasso.TaskSupervisor)

    if not (is_integer(max_active) and max_active > 0) do
      raise ArgumentError, "max_active must be a positive integer"
    end

    state = %{
      active_by_monitor: %{},
      active_by_ref: %{},
      counters: empty_counters(),
      executor: executor,
      max_active: max_active,
      max_active_observed: 0,
      parent: self(),
      pending: items,
      results: %{},
      supervisor: supervisor
    }

    state
    |> start_available()
    |> await_items()
    |> build_result()
  end

  defp start_available(%{pending: []} = state), do: state

  defp start_available(state) when map_size(state.active_by_ref) >= state.max_active,
    do: state

  defp start_available(%{pending: [item | rest]} = state) do
    if System.monotonic_time(:microsecond) >= item.deadline_us do
      state
      |> Map.put(:pending, rest)
      |> put_result(item, {:error, :deadline_expired})
      |> update_counter(:deadline)
      |> start_available()
    else
      start_item(state, item, rest)
    end
  end

  defp start_item(state, item, rest) do
    item_ref = make_ref()
    parent = state.parent
    executor = state.executor

    child = fn ->
      scope = ExecutionScope.monitored(self(), parent, item.deadline_us)
      result = executor.(item, scope)
      send(parent, {:batch_item_result, item_ref, self(), result})
    end

    case start_owner(state.supervisor, child) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        active = %{item: item, monitor: monitor, pid: pid}

        state
        |> Map.put(:pending, rest)
        |> put_in([:active_by_ref, item_ref], active)
        |> put_in([:active_by_monitor, monitor], item_ref)
        |> update_counter(:started)
        |> record_active_high_watermark()
        |> start_available()

      {:error, _reason} ->
        state
        |> Map.put(:pending, rest)
        |> put_result(item, {:error, :owner_spawn_failed})
        |> update_counter(:spawn_failed)
        |> start_available()
    end
  end

  defp start_owner(supervisor, child) do
    Task.Supervisor.start_child(supervisor, child)
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp await_items(%{pending: [], active_by_ref: active} = state)
       when map_size(active) == 0,
       do: state

  defp await_items(state) do
    receive do
      {:batch_item_result, item_ref, pid, result} ->
        case state.active_by_ref do
          %{^item_ref => %{pid: ^pid} = active} ->
            Process.demonitor(active.monitor, [:flush])

            state
            |> remove_active(item_ref, active.monitor)
            |> put_result(active.item, result)
            |> update_counter(:completed)
            |> start_available()
            |> await_items()

          _other ->
            state
            |> update_counter(:stale_result)
            |> await_items()
        end

      {:DOWN, monitor, :process, pid, reason} ->
        case state.active_by_monitor do
          %{^monitor => item_ref} ->
            active = Map.fetch!(state.active_by_ref, item_ref)

            if active.pid == pid do
              state
              |> remove_active(item_ref, monitor)
              |> put_result(active.item, {:error, {:owner_down, normalize_reason(reason)}})
              |> update_counter(:owner_down)
              |> start_available()
              |> await_items()
            else
              state
              |> update_counter(:stale_down)
              |> await_items()
            end

          _other ->
            state
            |> update_counter(:stale_down)
            |> await_items()
        end
    after
      remaining_wait_ms(state) ->
        expire_remaining(state)
    end
  end

  defp remaining_wait_ms(state) do
    deadline_us =
      Enum.reduce(state.pending, active_deadline(state), fn item, acc ->
        min(item.deadline_us, acc)
      end)

    max(div(deadline_us - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end

  defp active_deadline(state) do
    Enum.reduce(state.active_by_ref, :infinity, fn
      {_ref, %{item: item}}, :infinity -> item.deadline_us
      {_ref, %{item: item}}, acc -> min(item.deadline_us, acc)
    end)
  end

  defp expire_remaining(state) do
    now_us = System.monotonic_time(:microsecond)

    state =
      Enum.reduce(state.active_by_ref, state, fn {item_ref, active}, acc ->
        if active.item.deadline_us <= now_us do
          Process.exit(active.pid, :kill)
          Process.demonitor(active.monitor, [:flush])

          acc
          |> remove_active(item_ref, active.monitor)
          |> put_result(active.item, {:error, :owner_unresponsive})
          |> update_counter(:owner_unresponsive)
        else
          acc
        end
      end)

    {expired, pending} = Enum.split_with(state.pending, &(&1.deadline_us <= now_us))

    state =
      Enum.reduce(expired, %{state | pending: pending}, fn item, acc ->
        acc
        |> put_result(item, {:error, :deadline_expired})
        |> update_counter(:deadline)
      end)

    state
    |> start_available()
    |> await_items()
  end

  defp remove_active(state, item_ref, monitor) do
    %{
      state
      | active_by_ref: Map.delete(state.active_by_ref, item_ref),
        active_by_monitor: Map.delete(state.active_by_monitor, monitor)
    }
  end

  defp put_result(state, item, result),
    do: put_in(state, [:results, item.index], {Map.take(item, @retained_item_keys), result})

  defp record_active_high_watermark(state) do
    %{state | max_active_observed: max(state.max_active_observed, map_size(state.active_by_ref))}
  end

  defp empty_counters do
    %{
      completed: 0,
      deadline: 0,
      owner_down: 0,
      owner_unresponsive: 0,
      spawn_failed: 0,
      stale_down: 0,
      stale_result: 0,
      started: 0
    }
  end

  defp update_counter(state, name),
    do: update_in(state, [:counters, name], &(&1 + 1))

  defp build_result(state) do
    items =
      state.results
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_index, item_result} -> item_result end)

    %Result{
      items: items,
      counters: state.counters,
      max_active: state.max_active_observed
    }
  end

  defp normalize_reason(reason)
       when reason in [:normal, :shutdown, :killed, :noproc],
       do: reason

  defp normalize_reason(_reason), do: :unexpected_exit
end
