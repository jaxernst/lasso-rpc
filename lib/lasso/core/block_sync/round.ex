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

  A round with at least two heights becomes the latest recorded round of every
  upstream that answered it, in `Lasso.BlockSync.Registry`. A lone height has
  nothing to be compared with, so a round with fewer records nothing and the
  upstream keeps its earlier round. Rounds sample physical instances, so one
  round serves every profile on the chain;
  `Lasso.RPC.Selection.HeadSuitability` compares each route only with its own
  profile's routes in the same round.

  When an upstream switches between `newHeads` and HTTP polling, `reset/2`
  removes its answers from recorded and open rounds and starts a round at once,
  so its next verdict comes from the feed it now uses.

  Rounds run under their own supervisor. A round never sends a request itself,
  and a crashed round loses only the rounds in flight: it restarts, asks every
  worker again and relearns its interval from their answers. Workers monitor
  their round and join again when it stops, so polling resumes even after the
  supervisor itself restarts.
  """

  use GenServer

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Core.Support.DynamicSupervisorCall

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

  @doc """
  Forgets an upstream's round answers after it switches head feeds and starts a
  round now.
  """
  @spec reset(pos_integer(), String.t()) :: :ok | {:error, term()}
  def reset(chain_id, instance_id) do
    with {:ok, pid} <- ensure_started(chain_id) do
      GenServer.cast(pid, {:reset, instance_id})
    end
  end

  @doc "The fewest heights a round, or a profile's share of one, can judge."
  @spec min_heights() :: pos_integer()
  def min_heights, do: @min_heights

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

  def handle_cast({:reset, instance_id}, state) do
    BlockSyncRegistry.forget_round_answers(state.chain_id, instance_id)

    open =
      Map.new(state.open, fn {ref, round} ->
        {ref,
         %{
           round
           | waiting: MapSet.delete(round.waiting, instance_id),
             heights: Map.delete(round.heights, instance_id)
         }}
      end)

    {:noreply, open(%{state | open: open})}
  end

  @impl true
  def handle_info({:tick, ref}, %{tick_ref: ref} = state) do
    state =
      if state.interval_ms,
        do: schedule(state, state.interval_ms),
        else: %{state | tick_ref: nil}

    {:noreply, open(state)}
  end

  # Only an upstream the round is still waiting on can answer it, so an answer
  # from before a reset is ignored.
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

  defp open(state) do
    ref = make_ref()
    workers = workers(state.chain_id)

    for {_instance_id, pid} <- workers,
        do: send(pid, {:block_sync_round, self(), ref, state.interval_ms || 0})

    Process.send_after(self(), {:close, ref}, @answer_window_ms)

    round = %{
      started_at_ms: now_ms(),
      waiting: MapSet.new(workers, &elem(&1, 0)),
      intervals: [],
      heights: %{}
    }

    put_in(state.open[ref], round)
  end

  defp close(state, ref) do
    {round, open} = Map.pop!(state.open, ref)

    if map_size(round.heights) >= @min_heights do
      BlockSyncRegistry.put_round(state.chain_id, %{
        started_at_ms: round.started_at_ms,
        heights: round.heights
      })
    end

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

  defp now_ms, do: System.system_time(:millisecond)

  defp workers(chain_id) do
    Registry.select(Lasso.Registry, [
      {{{:block_sync_worker, chain_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
