defmodule Lasso.RPC.ProviderKnowledge.AppliedEffects do
  @moduledoc """
  Per-node counts of learned deferrals that changed a materialized batch's order.

  A sole deferred descriptor moved behind a later lazy batch is not counted.
  Retains at most about 4,096 keys: concurrent first observations can exceed the
  limit by the number of processes passing the size check together. Retained
  counters are exact; new dimensions skipped at capacity are counted separately.
  Nothing is evicted on the request path.
  """

  alias Lasso.RPC.ProviderKnowledge.Decision

  @table :lasso_provider_knowledge_applied_effects
  @max_keys 4_096

  @spec create_table!() :: :ok
  def create_table! do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(@table, {:skipped, 0})
    :ok
  end

  @doc "Existing keys pay one inline counter write; new keys check table capacity."
  @spec record(binary(), list(), list(), [map() | nil]) :: :ok
  def record(profile, baseline, applied, deferrals) do
    if Enum.any?(deferrals, &is_map/1) do
      baseline_positions = positions(baseline)
      applied_positions = positions(applied)

      unique = deferrals |> Enum.filter(&is_map/1) |> Enum.uniq_by(& &1.route)

      for %{route: route, kind: kind, dimension: dimension} <- unique,
          baseline_position = Map.get(baseline_positions, route),
          applied_position = Map.get(applied_positions, route),
          not is_nil(baseline_position) and not is_nil(applied_position),
          applied_position > baseline_position do
        increment({profile, route, kind, dimension})
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp positions(descriptors),
    do: descriptors |> Enum.map(&Decision.route/1) |> Enum.with_index() |> Map.new()

  defp increment(key) do
    if :ets.member(@table, key) or admit(key) do
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    else
      :ets.update_counter(@table, :skipped, {2, 1}, {:skipped, 0})
    end
  end

  # Size-based admission can slightly overshoot under concurrency, but cannot
  # leak reservations when a request owner dies. The skipped row takes one slot.
  defp admit(key) do
    if :ets.info(@table, :size) < @max_keys + 1 do
      :ets.insert_new(@table, {key, 0})
      true
    else
      :ets.member(@table, key)
    end
  end

  @doc "Exact counts for retained keys since this node started."
  @spec counts(binary(), binary() | nil, :http | :ws) :: [map()]
  def counts(profile, instance_id, transport) do
    :ets.match_object(@table, {{profile, {instance_id, transport}, :_, :_}, :_})
    |> Enum.map(fn {{_, _, kind, dimension}, count} ->
      %{kind: kind, dimension: dimension, requests: count}
    end)
  rescue
    ArgumentError -> []
  end

  @doc "Bounded-kind totals for off-path metrics collection."
  @spec totals() :: [map()]
  def totals do
    rows = :ets.tab2list(@table)

    for kind <- [:method_refusal, :historical_depth, :span_limit] do
      count =
        Enum.reduce(rows, 0, fn
          {{_, _, ^kind, _}, count}, total -> total + count
          _, total -> total
        end)

      %{kind: kind, count: count}
    end
  end

  defp table_size do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  @spec stats() :: %{keys: non_neg_integer(), max_keys: pos_integer(), skipped: non_neg_integer()}
  def stats do
    %{
      keys: max(table_size() - 1, 0),
      max_keys: @max_keys,
      skipped: :ets.lookup_element(@table, :skipped, 2)
    }
  rescue
    ArgumentError -> %{keys: 0, max_keys: @max_keys, skipped: 0}
  end
end
