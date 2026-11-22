defmodule Lasso.BlockSync.Round do
  @moduledoc """
  One chain's head round. Every upstream on the chain reports its head in the
  same tick, so the heights can be compared as they stand, without converting
  time into blocks.

  Each tick asks every BlockSync worker on the chain for its head. A worker fed
  by a live `newHeads` subscription answers at once with its latest head. Any
  other worker polls HTTP when its own interval falls due and it is not rate
  limited, and answers with the height, an error, or a skip. Each round closes
  when every worker has answered or its poll deadline passes, so a slow answer
  still counts after the next tick has opened another round. The chain ticks at
  the shortest interval its answers report, and soon after a worker joins with
  a new interval.

  When a round closes, it judges each profile scope on the chain, from the
  catalog's current routing plans, that has at least two of its head-observing
  upstreams in the round. Each of those upstreams gets that scope's lag: the
  highest of the scope's heights less its own. With three or more heights, a
  height more than the scope's agreement band above their lower median is an
  outlier and ignored. Two heights cannot show which one is wrong, so the higher
  one is the mark. The lags go to `Lasso.BlockSync.Registry` for
  `Lasso.RPC.Selection.HeadSuitability`. A scope with fewer answers keeps the
  lags it has, so neither another profile's rounds nor an upstream that errors
  or skips replaces a verdict, and an answer from an upstream the catalog no
  longer routes judges nothing.

  `start_now/1` starts a round at once, so an upstream that switches between
  `newHeads` and HTTP polling, or whose `newHeads` head moves backward, is
  measured without waiting for the next tick.

  Rounds run under their own supervisor. A round never sends a request itself,
  and a crashed round loses only the rounds in flight: it restarts, asks every
  worker again and relearns its interval from their answers. Workers monitor
  their round and join again when it stops, so polling resumes even after the
  supervisor itself restarts.
  """

  use GenServer

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Core.Support.DynamicSupervisorCall
  alias Lasso.Observations.HeadComparison
  alias Lasso.Providers.Catalog

  @supervisor Lasso.BlockSync.RoundSupervisor
  @join_settle_ms 250
  # The HTTP poll deadline, plus time for the answer to arrive.
  @answer_window_ms 3_500
  @min_heights 2

  defstruct [:chain_id, :interval_ms, :tick_ref, open: %{}]

  @doc """
  Starts the chain's round if needed and schedules a round for the joining
  interval. Members monitor the returned round and join again when it stops.
  """
  @spec join(pos_integer(), pos_integer()) :: {:ok, pid()} | {:error, term()}
  def join(chain_id, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    with {:ok, pid} <- ensure_started(chain_id) do
      GenServer.cast(pid, {:join, interval_ms})
      {:ok, pid}
    end
  end

  @doc "Starts a round on the chain now, without moving its tick."
  @spec start_now(pos_integer()) :: :ok | {:error, term()}
  def start_now(chain_id) do
    with {:ok, pid} <- ensure_started(chain_id), do: GenServer.cast(pid, :start_now)
  end

  @spec start_link(pos_integer()) :: GenServer.on_start()
  def start_link(chain_id), do: GenServer.start_link(__MODULE__, chain_id, name: via(chain_id))

  defp via(chain_id), do: {:via, Registry, {Lasso.Registry, {:block_sync_round, chain_id}}}

  defp ensure_started(chain_id) do
    case GenServer.whereis(via(chain_id)) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisorCall.start_child(@supervisor, {__MODULE__, chain_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> error
        end
    end
  end

  @impl true
  def init(chain_id) do
    {:ok, schedule(%__MODULE__{chain_id: chain_id}, @join_settle_ms)}
  end

  @impl true
  def handle_cast({:join, interval_ms}, state) do
    state = %{state | interval_ms: min(state.interval_ms || interval_ms, interval_ms)}
    {:noreply, schedule(state, @join_settle_ms)}
  end

  def handle_cast(:start_now, state), do: {:noreply, open(state)}

  @impl true
  def handle_info({:tick, ref}, %{tick_ref: ref} = state) do
    state =
      if state.interval_ms,
        do: schedule(state, state.interval_ms),
        else: %{state | tick_ref: nil}

    {:noreply, open(state)}
  end

  def handle_info({:round_answer, ref, instance_id, interval_ms, result}, state)
      when is_map_key(state.open, ref) do
    round = Map.fetch!(state.open, ref)

    if MapSet.member?(round.waiting, instance_id) do
      round = %{
        round
        | waiting: MapSet.delete(round.waiting, instance_id),
          intervals: if(interval_ms, do: [interval_ms | round.intervals], else: round.intervals),
          heights: record_height(round.heights, instance_id, result)
      }

      state = put_in(state.open[ref], round)
      {:noreply, if(MapSet.size(round.waiting) == 0, do: close(state, ref), else: state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:close, ref}, state) when is_map_key(state.open, ref),
    do: {:noreply, close(state, ref)}

  def handle_info(_late_or_unknown, state), do: {:noreply, state}

  defp record_height(heights, instance_id, {:ok, height}),
    do: Map.put(heights, instance_id, height)

  defp record_height(heights, _instance_id, _error_or_skip), do: heights

  defp schedule(state, delay_ms) do
    ref = make_ref()
    Process.send_after(self(), {:tick, ref}, delay_ms)
    %{state | tick_ref: ref}
  end

  # A round takes its place in the sequence before it asks any worker, so no
  # answer it collects predates a lag row publication that the round follows.
  defp open(state) do
    sequence = BlockSyncRegistry.next_sequence()
    started_at_ms = now_ms()
    ref = make_ref()
    workers = workers(state.chain_id)

    for {_instance_id, pid} <- workers,
        do: send(pid, {:block_sync_round, self(), ref, state.interval_ms || 0})

    Process.send_after(self(), {:close, ref}, @answer_window_ms)

    round = %{
      sequence: sequence,
      started_at_ms: started_at_ms,
      waiting: MapSet.new(workers, &elem(&1, 0)),
      intervals: [],
      heights: %{}
    }

    put_in(state.open[ref], round)
  end

  defp close(state, ref) do
    {round, open} = Map.pop!(state.open, ref)
    judge(state.chain_id, round)

    state = %{
      state
      | open: open,
        interval_ms: Enum.min(round.intervals, fn -> state.interval_ms end)
    }

    # A first round learns the interval from its answers.
    if is_nil(state.tick_ref) and state.interval_ms,
      do: schedule(state, max(round.started_at_ms + state.interval_ms - now_ms(), 0)),
      else: state
  end

  defp judge(chain_id, %{heights: heights} = round) when map_size(heights) >= @min_heights do
    for scope <- head_scopes(chain_id),
        scope_heights <- [Map.take(heights, scope.observer_ids)],
        map_size(scope_heights) >= @min_heights do
      band = HeadComparison.agreement_blocks(scope.policy)
      BlockSyncRegistry.put_head_lags(scope, lags(scope_heights, band, round))
    end

    :ok
  end

  defp judge(_chain_id, _round), do: :ok

  defp head_scopes(chain_id) do
    case Catalog.snapshot() do
      %{routing_plans: plans} -> for {{_profile, ^chain_id}, plan} <- plans, do: plan.head_scope
      _unpublished -> []
    end
  end

  defp lags(heights, band, round) do
    sorted = heights |> Map.values() |> Enum.sort()
    ceiling = ceiling(sorted, band)
    top = sorted |> Enum.take_while(&(&1 <= ceiling)) |> List.last()

    Map.new(heights, fn {instance_id, height} ->
      {instance_id,
       %{
         lag: top - height,
         outlier?: height > ceiling,
         round: round.sequence,
         measured_at_ms: round.started_at_ms
       }}
    end)
  end

  defp ceiling([_low, high], _band), do: high
  defp ceiling(sorted, band), do: Enum.at(sorted, div(length(sorted) - 1, 2)) + band

  defp now_ms, do: System.system_time(:millisecond)

  defp workers(chain_id) do
    Registry.select(Lasso.Registry, [
      {{{:block_sync_worker, chain_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
