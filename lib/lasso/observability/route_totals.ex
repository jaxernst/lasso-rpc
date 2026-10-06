defmodule Lasso.Observability.RouteTotals do
  @moduledoc """
  Monotonic request totals built from `Lasso.RPC.RequestAggregate` counter sets.

  Every routing scope keeps its counter set while it stays published, and each read adds
  the increase since the previous one. Several scopes can share one series when
  `Lasso.Observability.MetricsScope` bounds their labels, so a scope that leaves the
  catalog cannot simply disappear: its last increases are read twice more and its count
  stays in the series. A scope's labels are fixed when it is first read, which keeps its
  history in one series even if the scope later bounds differently.
  """

  alias Lasso.Observability.MetricsScope
  alias Lasso.RPC.RequestAggregate

  @fields [:total, :successes, :elapsed_us, :sampled_out]
  @origins [:client, :system]
  @retired_reads 2

  defstruct tracked: %{}, retired: [], totals: %{}

  @type labels :: {String.t(), String.t(), :client | :system}
  @type counts :: %{
          total: non_neg_integer(),
          successes: non_neg_integer(),
          elapsed_us: non_neg_integer(),
          sampled_out: non_neg_integer()
        }
  @type t :: %__MODULE__{tracked: map(), retired: [map()], totals: %{labels() => counts()}}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds the increase since the previous call for every published and recently removed scope."
  @spec advance(t(), %{{String.t(), pos_integer()} => RequestAggregate.counter_set()}) :: t()
  def advance(%__MODULE__{} = state, sets) when is_map(sets) do
    {increments, tracked} =
      Enum.reduce(sets, {[], %{}}, fn {route, set}, {increments, tracked} ->
        current = read(set)

        {increment, entry} =
          case Map.get(state.tracked, route) do
            %{id: id} = previous when id == set.id ->
              {difference(current, previous.last), %{previous | last: current}}

            _new_or_replaced ->
              {current, %{id: set.id, set: set, labels: labels(route), last: current}}
          end

        {[{entry.labels, increment} | increments], Map.put(tracked, route, entry)}
      end)

    displaced =
      for {route, %{id: id} = entry} <- state.tracked,
          not match?(%{id: ^id}, Map.get(tracked, route)),
          do: Map.put(entry, :reads_left, @retired_reads)

    {retired_increments, retired} = read_retired(state.retired ++ displaced)
    totals = Enum.reduce(increments ++ retired_increments, state.totals, &accumulate/2)

    %{state | tracked: tracked, retired: retired, totals: totals}
  end

  @spec totals(t()) :: %{labels() => counts()}
  def totals(%__MODULE__{totals: totals}), do: totals

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
    {to_string(bounded.profile), to_string(bounded.chain_id)}
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

  defp accumulate({{profile, chain}, by_origin}, totals) do
    Enum.reduce(by_origin, totals, fn {origin, counts}, acc ->
      Map.update(acc, {profile, chain, origin}, counts, fn existing ->
        Map.merge(existing, counts, fn _field, a, b -> a + b end)
      end)
    end)
  end
end
