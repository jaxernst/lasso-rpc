defmodule Lasso.RPC.RequestAggregate do
  @moduledoc """
  Fixed-cardinality request outcome counters for active routing scopes.

  Counter references are published inside the same immutable catalog snapshot as
  its routing plans. A routing scope keeps its counters across catalog
  generations, so its counts accumulate for as long as the scope stays published
  on this node. Request processes update atomics directly; optional detailed
  diagnostics are admitted through a per-origin, per-scope rate budget.
  """

  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{AttemptTerminal, RequestTerminal}

  @details_per_second 256
  @budget_base 512
  @budget_retries 8

  @client_failure 1
  @client_success 2
  @client_elapsed_us 3
  @client_sampled_out 4
  @system_failure 5
  @system_success 6
  @system_elapsed_us 7
  @system_sampled_out 8

  @type origin :: :client | :system
  @type counter_set :: %{
          required(:id) => pos_integer(),
          required(:counters) => term(),
          required(:budgets) => term()
        }

  @doc false
  @spec prepare(non_neg_integer(), map(), Catalog.snapshot() | nil) ::
          %{{binary(), pos_integer()} => counter_set()}
  def prepare(generation, routing_plans, previous_snapshot)
      when is_integer(generation) and generation >= 0 and is_map(routing_plans) do
    reusable = published_aggregates(previous_snapshot)

    Map.new(routing_plans, fn {{profile, chain_id}, _plan} ->
      key = {profile, chain_id}

      {key,
       Map.get_lazy(reusable, key, fn ->
         %{
           id: System.unique_integer([:positive, :monotonic]),
           counters: :atomics.new(8, signed: true),
           budgets: :atomics.new(2, signed: true)
         }
       end)}
    end)
  end

  @doc false
  @spec record_and_reserve_detail(RequestTerminal.t(), origin(), integer()) ::
          :detail | :aggregate_only | :untracked
  def record_and_reserve_detail(fact, origin, now_ms \\ System.system_time(:millisecond))
      when origin in [:client, :system] and is_integer(now_ms) and now_ms >= 0 do
    with %{request_aggregates: aggregates} <- Catalog.snapshot(),
         %{profile: profile, chain_id: chain_id} <- fact,
         %{counters: counters, budgets: budgets} <- Map.get(aggregates, {profile, chain_id}) do
      record(counters, fact, origin)

      if not success?(fact) or
           reserve_detail(budgets, origin, div(now_ms, 1_000), @budget_retries) do
        :detail
      else
        :atomics.add(counters, sampled_out_index(origin), 1)
        :aggregate_only
      end
    else
      _unavailable -> :untracked
    end
  rescue
    ArgumentError -> :untracked
  end

  @spec snapshot(binary(), pos_integer()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    with %{generation: generation, request_aggregates: aggregates} <- Catalog.snapshot(),
         %{counters: counters} <- Map.get(aggregates, {profile, chain_id}) do
      {:ok,
       %{
         generation: generation,
         client: read_origin(counters, :client),
         system: read_origin(counters, :system)
       }}
    else
      _unavailable -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc "Reads a counter set's cumulative client and system counts."
  @spec read_counter_set(counter_set()) :: %{client: map(), system: map()}
  def read_counter_set(%{counters: counters}),
    do: %{client: read_origin(counters, :client), system: read_origin(counters, :system)}

  defp record(counters, fact, origin) do
    :atomics.add(counters, elapsed_index(origin), Map.fetch!(fact, :elapsed_us))

    # Successes and failures are separate monotonic counters, so a reader never derives one
    # from two reads that a concurrent completion can interleave.
    if success?(fact),
      do: :atomics.add(counters, success_index(origin), 1),
      else: :atomics.add(counters, failure_index(origin), 1)

    :ok
  end

  defp reserve_detail(_budgets, _origin, _second, 0), do: false

  defp reserve_detail(budgets, origin, second, retries) do
    index = budget_index(origin)
    current = :atomics.get(budgets, index)
    current_second = div(current, @budget_base)
    current_count = rem(current, @budget_base)

    cond do
      current_second == second and current_count >= @details_per_second ->
        false

      current_second == second ->
        reserve_detail_cas(
          budgets,
          origin,
          second,
          current,
          current + 1,
          retries
        )

      true ->
        reserve_detail_cas(
          budgets,
          origin,
          second,
          current,
          second * @budget_base + 1,
          retries
        )
    end
  end

  defp reserve_detail_cas(budgets, origin, second, current, desired, retries) do
    case :atomics.compare_exchange(budgets, budget_index(origin), current, desired) do
      :ok -> true
      _changed -> reserve_detail(budgets, origin, second, retries - 1)
    end
  end

  defp read_origin(counters, origin) do
    successes = :atomics.get(counters, success_index(origin))
    failures = :atomics.get(counters, failure_index(origin))

    %{
      total: successes + failures,
      successes: successes,
      failures: failures,
      elapsed_us: :atomics.get(counters, elapsed_index(origin)),
      sampled_out: :atomics.get(counters, sampled_out_index(origin))
    }
  end

  defp success?(%RequestTerminal.UpstreamResponse{
         attempt: %AttemptTerminal.Response{kind: :success}
       }),
       do: true

  defp success?(%RequestTerminal.LocalSuccess{}), do: true
  defp success?(_fact), do: false

  defp published_aggregates(%{request_aggregates: aggregates}) when is_map(aggregates),
    do: aggregates

  defp published_aggregates(_snapshot), do: %{}

  defp failure_index(:client), do: @client_failure
  defp failure_index(:system), do: @system_failure
  defp success_index(:client), do: @client_success
  defp success_index(:system), do: @system_success
  defp elapsed_index(:client), do: @client_elapsed_us
  defp elapsed_index(:system), do: @system_elapsed_us
  defp sampled_out_index(:client), do: @client_sampled_out
  defp sampled_out_index(:system), do: @system_sampled_out
  defp budget_index(:client), do: 1
  defp budget_index(:system), do: 2
end
