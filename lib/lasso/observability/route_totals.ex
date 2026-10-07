defmodule Lasso.Observability.RouteTotals do
  @moduledoc """
  Monotonic request totals built from `Lasso.RPC.RequestAggregate` counter sets.

  Every routing scope keeps its counter set while it stays published, and each read adds
  the increase since the previous one. Several scopes can share one series when
  `Lasso.Observability.MetricsScope` bounds their labels, so a scope that leaves the
  catalog cannot simply disappear: its last increases are read twice more and its count
  stays in the series. A scope's labels are fixed when it is first read, which keeps its
  history in one series even if the scope later bounds differently.

  Totals are bounded. A series is kept while any published or recently removed scope
  contributes to it, so totals track the catalog rather than everything ever published,
  and at most 2,048 series exist at once. Increments that would need a series beyond
  that limit are counted in `dropped`. A scope whose labels cannot be computed is skipped
  and counted in `errors`.
  """

  alias Lasso.Observability.MetricsScope
  alias Lasso.RPC.RequestAggregate

  @fields [:successes, :failures, :elapsed_us, :sampled_out]
  @origins [:client, :system]
  @retired_reads 2
  @max_series 2_048

  defstruct tracked: %{}, retired: [], totals: %{}, dropped: 0, errors: 0

  @type labels :: {String.t(), String.t(), :client | :system}
  @type counts :: %{
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          elapsed_us: non_neg_integer(),
          sampled_out: non_neg_integer()
        }
  @type t :: %__MODULE__{
          tracked: map(),
          retired: [map()],
          totals: %{labels() => counts()},
          dropped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds the increase since the previous call for every published and recently removed scope."
  @spec advance(t(), %{{String.t(), pos_integer()} => RequestAggregate.counter_set()}) :: t()
  def advance(%__MODULE__{} = state, sets) when is_map(sets) do
    {increments, tracked, errors} =
      Enum.reduce(sets, {[], %{}, state.errors}, fn {route, set}, {increments, tracked, errors} ->
        case track(Map.get(state.tracked, route), route, set) do
          {:ok, increment, entry} ->
            {[{entry.labels, increment} | increments], Map.put(tracked, route, entry), errors}

          :error ->
            {increments, tracked, errors + 1}
        end
      end)

    displaced =
      for {route, %{id: id} = entry} <- state.tracked,
          not match?(%{id: ^id}, Map.get(tracked, route)),
          do: Map.put(entry, :reads_left, @retired_reads)

    {retired_increments, retired} = read_retired(state.retired ++ displaced)
    live = MapSet.new(Map.values(tracked) ++ retired, & &1.labels)

    totals =
      Map.filter(state.totals, fn {{profile, chain, _origin}, _} ->
        MapSet.member?(live, {profile, chain})
      end)

    {totals, dropped} =
      Enum.reduce(increments ++ retired_increments, {totals, state.dropped}, &accumulate/2)

    %{
      state
      | tracked: tracked,
        retired: retired,
        totals: totals,
        dropped: dropped,
        errors: errors
    }
  end

  @spec totals(t()) :: %{labels() => counts()}
  def totals(%__MODULE__{totals: totals}), do: totals

  defp track(%{id: id} = previous, _route, %{id: id} = set) do
    current = read(set)
    {:ok, difference(current, previous.last), %{previous | last: current}}
  end

  defp track(_new_or_replaced, route, set) do
    with {:ok, labels} <- labels(route) do
      current = read(set)
      {:ok, current, %{id: set.id, set: set, labels: labels, last: current}}
    end
  end

  defp read_retired(retired) do
    Enum.reduce(retired, {[], []}, fn entry, {increments, kept} ->
      current = read(entry.set)
      increments = [{entry.labels, difference(current, entry.last)} | increments]

      if entry.reads_left > 1,
        do: {increments, [%{entry | last: current, reads_left: entry.reads_left - 1} | kept]},
        else: {increments, kept}
    end)
  end

  defp labels({profile, chain_id}) do
    bounded = MetricsScope.impl().bound(%{profile: profile, chain_id: chain_id})
    {:ok, {to_string(bounded.profile), to_string(bounded.chain_id)}}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp read(set) do
    counts = RequestAggregate.read_counter_set(set)
    Map.new(@origins, &{&1, Map.take(Map.fetch!(counts, &1), @fields)})
  end

  defp difference(current, previous) do
    Map.new(@origins, fn origin ->
      {origin, Map.new(@fields, &{&1, max(current[origin][&1] - previous[origin][&1], 0)})}
    end)
  end

  defp accumulate({{profile, chain}, by_origin}, acc) do
    Enum.reduce(by_origin, acc, fn {origin, counts}, {totals, dropped} ->
      key = {profile, chain, origin}

      cond do
        Map.has_key?(totals, key) ->
          {Map.update!(totals, key, &Map.merge(&1, counts, fn _field, a, b -> a + b end)),
           dropped}

        map_size(totals) < @max_series ->
          {Map.put(totals, key, counts), dropped}

        true ->
          {totals, dropped + 1}
      end
    end)
  end
end
