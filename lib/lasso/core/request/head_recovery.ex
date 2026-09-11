defmodule Lasso.RPC.HeadRecovery do
  @moduledoc """
  Best-effort replication of accepted local heights for provider preference.

  RPCs only read the table. A bounded background scan coalesces advancements and
  repairs missed broadcasts, including floors learned from departed peers.
  Hints neither grant serving permission nor advance the hard local floor.
  """
  use GenServer

  alias Lasso.Config.ConfigStore

  @table :lasso_recovered_heads
  @topic "local_head_recovery:v1"
  @batch_size 64
  @interval_ms 100
  @repair_ms 2_000

  @spec create_table!(atom()) :: :ok
  def create_table!(table \\ @table) do
    :ets.new(table, [:named_table, :public, :ordered_set, read_concurrency: true])
    :ok
  end

  @spec read({String.t(), pos_integer()}, atom()) :: map() | nil
  def read(key, table \\ @table) do
    case :ets.lookup(table, key) do
      [{^key, height, hash, _received_at}] -> %{height: height, hash: hash}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      table: Keyword.get(opts, :table, @table),
      floors: Keyword.get(opts, :floors, :lasso_accepted_heads),
      pubsub: Keyword.get(opts, :pubsub, Lasso.PubSub),
      local?: Keyword.get(opts, :local?, &local?/1),
      interval: Keyword.get(opts, :interval_ms, @interval_ms),
      floor_cursor: :start,
      hint_cursor: :start,
      sent: %{},
      next_repair: System.monotonic_time(:millisecond) + @repair_ms
    }

    Phoenix.PubSub.subscribe(state.pubsub, @topic)
    Phoenix.PubSub.broadcast_from(state.pubsub, self(), @topic, :repair_local_heads)
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    {floors, floor_cursor} = page(state.floors, state.floor_cursor)

    for {key, height, hash} <- floors, do: merge(state, key, height, hash, now)

    {hints, hint_cursor} = page(state.table, state.hint_cursor)

    {updates, sent} =
      Enum.reduce(hints, {[], state.sent}, fn {key, height, hash} = hint, {updates, sent} ->
        if state.local?.(key) do
          case Map.get(sent, key) do
            {^height, ^hash, at} when now - at < @repair_ms ->
              {updates, sent}

            _changed_or_due ->
              {[hint | updates], Map.put(sent, key, {height, hash, now})}
          end
        else
          :ets.delete(state.table, key)
          {updates, Map.delete(sent, key)}
        end
      end)

    if updates != [] do
      Phoenix.PubSub.broadcast_from(state.pubsub, self(), @topic, {:local_heads, updates})
    end

    Process.send_after(self(), :tick, state.interval)
    {:noreply, %{state | floor_cursor: floor_cursor, hint_cursor: hint_cursor, sent: sent}}
  end

  def handle_info({:local_heads, hints}, state)
      when is_list(hints) and length(hints) <= @batch_size do
    now = System.monotonic_time(:millisecond)

    for {key, height, hash} <- hints, do: merge(state, key, height, hash, now)

    {:noreply, state}
  end

  def handle_info(:repair_local_heads, state) do
    now = System.monotonic_time(:millisecond)

    if now >= state.next_repair do
      {:noreply, %{state | sent: %{}, next_repair: now + @repair_ms}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp page(table, :start) do
    :ets.select(table, [{:_, [], [:"$_"]}], @batch_size)
    |> page_result()
  end

  defp page(_table, cursor) do
    cursor |> :ets.select() |> page_result()
  rescue
    ArgumentError -> {[], :start}
  end

  defp page_result(:"$end_of_table"), do: {[], :start}
  defp page_result({rows, :"$end_of_table"}), do: {floor_rows(rows), :start}
  defp page_result({rows, cursor}), do: {floor_rows(rows), cursor}

  defp floor_rows(rows) do
    for {{profile, chain} = key, height, hash, _epoch} <- rows,
        is_binary(profile) and is_integer(chain) and is_integer(height),
        do: {key, height, hash}
  end

  defp merge(state, {profile, chain_id} = key, height, hash, now)
       when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and
              is_integer(height) and height >= 0 and height <= 0xFFFFFFFFFFFFFFFF do
    if state.local?.(key) and valid_hash?(hash) do
      hash = if is_binary(hash), do: String.downcase(hash)

      case :ets.lookup(state.table, key) do
        [{^key, previous, _, _}] when previous > height ->
          :ok

        [{^key, ^height, previous_hash, received_at}] ->
          if previous_hash != hash,
            do: :ets.insert(state.table, {key, height, nil, received_at})

        _older_or_missing ->
          :ets.insert(state.table, {key, height, hash, now})
      end
    end

    :ok
  end

  defp merge(_state, _key, _height, _hash, _now), do: :ok

  defp valid_hash?(nil), do: true
  defp valid_hash?(hash) when is_binary(hash), do: Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, hash)
  defp valid_hash?(_hash), do: false

  defp local?({profile, chain_id}) do
    match?({:ok, %{head_policy: "local"}}, ConfigStore.get_chain(profile, chain_id))
  end
end
