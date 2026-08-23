defmodule LassoWeb.Dashboard.TrafficCounters do
  @moduledoc false

  use GenServer

  alias Lasso.RPC.{RequestProjection, RequestTerminal}

  @table :lasso_dashboard_traffic_counters
  @runtime_key {__MODULE__, :runtime}
  @default_max_rows 65_536
  @retention_seconds 65
  @cleanup_interval_ms 5_000

  @type scope :: :profile
  @type stats :: %{
          count: non_neg_integer(),
          successes: non_neg_integer(),
          errors: non_neg_integer(),
          elapsed_us: non_neg_integer(),
          failovers: non_neg_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(RequestProjection.t()) :: :ok | :ignored | :dropped
  def record(%RequestProjection{request_origin: :system}), do: :ignored

  def record(%RequestProjection{} = event) do
    record_request(event.fact, event.request_origin, event.failover_count, event.emitted_at_ms)
  end

  @spec record_request(RequestTerminal.t(), :client | :system, non_neg_integer()) ::
          :ok | :ignored | :dropped
  def record_request(fact, request_origin, failovers) do
    record_request(fact, request_origin, failovers, System.system_time(:millisecond))
  end

  defp record_request(_fact, :system, _failovers, _emitted_at_ms), do: :ignored

  defp record_request(fact, :client, failovers, emitted_at_ms) do
    %{table: table, rows: rows, max_rows: max_rows} = :persistent_term.get(@runtime_key)
    second = div(emitted_at_ms, 1_000)
    profile = Map.fetch!(fact, :profile)
    delta = counter_delta(fact, failovers)

    record_scope(table, rows, max_rows, {profile, :profile, second}, delta)
  rescue
    ArgumentError ->
      mark_drop()
      :dropped
  end

  defp record_scope(table, rows, max_rows, key, delta) do
    case :ets.lookup(table, key) do
      [_row] -> update_existing(table, key, delta)
      [] -> insert_or_update(table, rows, max_rows, key, delta)
    end
  end

  @spec windows(binary(), [scope()], pos_integer(), integer()) :: %{scope() => stats()}
  def windows(profile, scopes, window_seconds, now_second)
      when is_binary(profile) and is_list(scopes) and is_integer(window_seconds) and
             window_seconds > 0 and is_integer(now_second) do
    start_second = now_second - window_seconds + 1

    scopes
    |> Enum.uniq()
    |> Map.new(fn scope ->
      {scope, window(profile, scope, start_second, now_second)}
    end)
  rescue
    ArgumentError -> %{}
  end

  @spec cluster_windows(binary(), [scope()], pos_integer()) :: map()
  def cluster_windows(profile, scopes, window_seconds \\ 60) do
    now_second = System.system_time(:second)
    nodes = [node() | connected_nodes()] |> Enum.uniq()

    {results, bad_nodes} =
      :rpc.multicall(
        nodes,
        __MODULE__,
        :node_windows,
        [profile, scopes, window_seconds, now_second],
        750
      )

    valid = Enum.filter(results, &match?(%{scopes: %{}, last_drop_second: _}, &1))
    start_second = now_second - window_seconds + 1

    %{
      scopes: merge_node_windows(Enum.map(valid, & &1.scopes), scopes),
      coverage: %{
        responding: length(valid),
        total: length(nodes),
        bad_nodes: bad_nodes,
        lossless: Enum.all?(valid, &(&1.last_drop_second < start_second))
      },
      window_seconds: window_seconds,
      as_of_second: now_second
    }
  end

  @doc false
  def node_windows(profile, scopes, window_seconds, now_second) do
    %{dropped_at_second: dropped_at_second} = :persistent_term.get(@runtime_key)

    %{
      scopes: windows(profile, scopes, window_seconds, now_second),
      last_drop_second: :atomics.get(dropped_at_second, 1)
    }
  end

  @spec stats() :: map()
  def stats do
    %{
      table: table,
      rows: rows,
      max_rows: max_rows,
      dropped: dropped,
      dropped_at_second: dropped_at_second
    } =
      :persistent_term.get(@runtime_key)

    %{
      rows: :atomics.get(rows, 1),
      actual_rows: :ets.info(table, :size),
      max_rows: max_rows,
      dropped: :atomics.get(dropped, 1),
      last_drop_second: :atomics.get(dropped_at_second, 1)
    }
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    rows = :atomics.new(1, signed: false)
    dropped = :atomics.new(1, signed: false)
    dropped_at_second = :atomics.new(1, signed: false)
    max_rows = Keyword.get(opts, :max_rows, @default_max_rows)

    runtime = %{
      table: table,
      rows: rows,
      dropped: dropped,
      dropped_at_second: dropped_at_second,
      max_rows: max_rows
    }

    :persistent_term.put(@runtime_key, runtime)
    schedule_cleanup()
    {:ok, runtime}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = System.system_time(:second) - @retention_seconds

    removed =
      :ets.foldl(
        fn
          {{_profile, _scope, second} = key, _total, _successes, _errors, _elapsed_us, _failovers},
          count
          when second < cutoff ->
            :ets.delete(state.table, key)
            count + 1

          _row, count ->
            count
        end,
        0,
        state.table
      )

    if removed > 0, do: :atomics.sub(state.rows, 1, removed)
    schedule_cleanup()
    {:noreply, state}
  end

  defp insert_or_update(table, rows, max_rows, key, delta) do
    case reserve_row(rows, max_rows) do
      :ok ->
        row = row(key, delta)

        if :ets.insert_new(table, row) do
          :ok
        else
          :atomics.sub(rows, 1, 1)
          update_existing(table, key, delta)
        end

      :full ->
        mark_drop()
        :dropped
    end
  end

  defp reserve_row(rows, max_rows) do
    if :atomics.add_get(rows, 1, 1) <= max_rows do
      :ok
    else
      :atomics.sub(rows, 1, 1)
      :full
    end
  end

  defp update_existing(table, key, {success, error, elapsed_us, failovers}) do
    :ets.update_counter(table, key, [
      {2, 1},
      {3, success},
      {4, error},
      {5, elapsed_us},
      {6, failovers}
    ])

    :ok
  rescue
    ArgumentError ->
      mark_drop()
      :dropped
  end

  defp row(key, {success, error, elapsed_us, failovers}),
    do: {key, 1, success, error, elapsed_us, failovers}

  defp counter_delta(
         %RequestTerminal.UpstreamResponse{attempt: %{kind: :success}} = fact,
         failovers
       ),
       do: {1, 0, Map.fetch!(fact, :elapsed_us), failovers}

  defp counter_delta(fact, failovers),
    do: {0, 1, Map.fetch!(fact, :elapsed_us), failovers}

  defp window(profile, :profile, start_second, now_second) do
    Enum.reduce(start_second..now_second, empty_stats(), fn second, acc ->
      merge_key({profile, :profile, second}, acc)
    end)
  end

  defp window(_profile, _scope, _start_second, _now_second), do: empty_stats()

  defp merge_key(key, acc) do
    case :ets.lookup(@table, key) do
      [row] -> merge_row(row, acc)
      [] -> acc
    end
  end

  defp merge_row({_key, total, successes, errors, elapsed_us, failovers}, acc) do
    %{
      count: acc.count + total,
      successes: acc.successes + successes,
      errors: acc.errors + errors,
      elapsed_us: acc.elapsed_us + elapsed_us,
      failovers: acc.failovers + failovers
    }
  end

  defp merge_node_windows(results, scopes) do
    Map.new(scopes, fn scope ->
      stats =
        Enum.reduce(results, empty_stats(), fn result, acc ->
          Map.get(result, scope, empty_stats()) |> merge_stats(acc)
        end)

      {scope, stats}
    end)
  end

  defp merge_stats(stats, acc) do
    %{
      count: acc.count + stats.count,
      successes: acc.successes + stats.successes,
      errors: acc.errors + stats.errors,
      elapsed_us: acc.elapsed_us + stats.elapsed_us,
      failovers: acc.failovers + stats.failovers
    }
  end

  defp empty_stats,
    do: %{count: 0, successes: 0, errors: 0, elapsed_us: 0, failovers: 0}

  defp mark_drop do
    case :persistent_term.get(@runtime_key, nil) do
      %{dropped: dropped, dropped_at_second: dropped_at_second} ->
        :atomics.add(dropped, 1, 1)
        :atomics.put(dropped_at_second, 1, System.system_time(:second))

      _unavailable ->
        :ok
    end
  end

  defp connected_nodes do
    Lasso.Cluster.Topology.get_connected_nodes()
  catch
    :exit, _reason -> Node.list()
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
