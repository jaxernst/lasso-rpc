defmodule Lasso.Observability.RouteTotalsTest do
  use ExUnit.Case, async: false

  alias Lasso.Observability.RouteTotals

  test "series are bounded by the published catalog and a hard limit" do
    sets = Map.new(1..3_000, &{{"public", &1}, counter_set(successes: 1)})

    state = RouteTotals.advance(RouteTotals.new(), sets)
    assert map_size(RouteTotals.totals(state)) == 2_048
    assert state.dropped > 0

    state = Enum.reduce(1..3, state, fn _read, acc -> RouteTotals.advance(acc, %{}) end)
    assert RouteTotals.totals(state) == %{}
    assert state.tracked == %{}
    assert state.retired == []
  end

  test "successes and failures accumulate as separate monotonic counts" do
    set = counter_set(successes: 2, failures: 1)
    state = RouteTotals.advance(RouteTotals.new(), %{{"public", 1} => set})
    :atomics.add(set.counters, 2, 3)
    state = RouteTotals.advance(state, %{{"public", 1} => set})

    assert %{successes: 5, failures: 1} = RouteTotals.totals(state)[{"public", "1", :client}]
  end

  defp counter_set(counts) do
    counters = :atomics.new(8, signed: true)
    :atomics.put(counters, 1, Keyword.get(counts, :failures, 0))
    :atomics.put(counters, 2, Keyword.get(counts, :successes, 0))

    %{
      id: System.unique_integer([:positive, :monotonic]),
      counters: counters,
      budgets: :atomics.new(2, signed: true)
    }
  end
end
