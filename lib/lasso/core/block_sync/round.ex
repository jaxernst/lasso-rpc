defmodule Lasso.BlockSync.Round do
  @moduledoc """
  One chain's head round. Every HTTP head poll on the chain runs in the same
  tick, so the heights the upstreams report can be compared as they stand,
  without converting time into blocks.

  Each tick asks every BlockSync worker on the chain to poll. A worker polls
  when its own interval falls due and it is not rate limited, and answers with
  the height, an error, or a skip. The round closes when every worker has
  answered or the poll deadline passes. It ticks at the shortest interval its
  answers report, and soon after a worker joins with a new interval.

  A round with at least three heights is recorded in
  `Lasso.BlockSync.Registry` with the chain's few latest rounds. With fewer it
  records nothing, because two heights cannot show which one is wrong. Rounds
  sample physical instances, so one round serves every profile on the chain;
  `Lasso.RPC.Selection.HeadSuitability` compares each route only with its own
  profile's routes in the same round.

  Rounds run under their own supervisor. A round never sends a request itself,
  and a crashed round loses only the tick in flight: it restarts, asks every
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
  @min_heights 3
  # Enough rounds to span a route's head freshness at the default head interval.
  @kept_rounds 4

  defstruct [:chain_id, :interval_ms, :tick_ref, :open]

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
  # A join lets an open round collect its answers before the next one starts.
  def handle_cast({:join, interval_ms}, state) do
    state = %{state | interval_ms: min(state.interval_ms || interval_ms, interval_ms)}
    {:noreply, schedule(state, max(@join_settle_ms, answer_time_left(state)))}
  end

  @impl true
  def handle_info({:tick, ref}, %{tick_ref: ref} = state) do
    state = %{close(state) | tick_ref: nil}
    state = if state.interval_ms, do: schedule(state, state.interval_ms), else: state
    {:noreply, open(state)}
  end

  def handle_info(
        {:round_answer, ref, instance_id, interval_ms, result},
        %{open: %{ref: ref}} = state
      ) do
    open =
      state.open
      |> Map.update!(:waiting, &MapSet.delete(&1, instance_id))
      |> Map.update!(:intervals, &if(interval_ms, do: [interval_ms | &1], else: &1))
      |> Map.update!(:heights, &record_height(&1, instance_id, result))

    state = %{state | open: open}
    {:noreply, if(MapSet.size(open.waiting) == 0, do: close(state), else: state)}
  end

  def handle_info({:close, ref}, %{open: %{ref: ref}} = state), do: {:noreply, close(state)}
  def handle_info(_late_or_unknown, state), do: {:noreply, state}

  defp record_height(heights, instance_id, {:ok, height}),
    do: Map.put(heights, instance_id, height)

  defp record_height(heights, _instance_id, _error_or_skip), do: heights

  defp answer_time_left(%{open: nil}), do: 0
  defp answer_time_left(%{open: open}), do: open.started_at_ms + @answer_window_ms - now_ms()

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

    %{
      state
      | open: %{
          ref: ref,
          started_at_ms: now_ms(),
          waiting: MapSet.new(workers, &elem(&1, 0)),
          intervals: [],
          heights: %{}
        }
    }
  end

  defp close(%{open: nil} = state), do: state

  defp close(%{open: open} = state) do
    if map_size(open.heights) >= @min_heights do
      round = %{started_at_ms: open.started_at_ms, heights: open.heights}
      BlockSyncRegistry.put_round(state.chain_id, round, @kept_rounds)
    end

    state = %{
      state
      | open: nil,
        interval_ms: Enum.min(open.intervals, fn -> state.interval_ms end)
    }

    # A first round learns the interval from its answers.
    if is_nil(state.tick_ref) and state.interval_ms,
      do: schedule(state, max(open.started_at_ms + state.interval_ms - now_ms(), 0)),
      else: state
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp workers(chain_id) do
    Registry.select(Lasso.Registry, [
      {{{:block_sync_worker, chain_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
