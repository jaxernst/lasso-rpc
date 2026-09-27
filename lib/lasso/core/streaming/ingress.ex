defmodule Lasso.Core.Streaming.Ingress do
  @moduledoc """
  Node-local admission for payload-bearing internal WebSocket messages.

  Fixed ETS shards bound bytes and message counts before a payload is sent.
  Reservations belong to the recipient and are released after processing, or
  reclaimed when that recipient dies. The application owns the production
  table so restarting the audit process cannot forget queued payloads.

  This budget is separate from retained replay history and downstream delivery
  in ContinuityBudget. Their configured node limits form the combined envelope.
  """

  use GenServer

  @table :lasso_stream_ingress
  @shards 4
  @node_bytes 128 * 1_024 * 1_024
  @owner_bytes 32 * 1_024 * 1_024
  @owner_messages 128
  @shard_messages 512
  @attempts 16

  @type token :: {:ets.tid(), non_neg_integer(), {reference(), reference()}}
  @type error ::
          {:error,
           :budget_unavailable
           | :contention
           | :recipient_down
           | :owner_messages
           | :owner_bytes
           | :node_capacity}

  @spec create_tables!(keyword()) :: atom()
  def create_tables!(opts \\ []) do
    table = Keyword.get(opts, :table, @table)

    node_bytes =
      Keyword.get(
        opts,
        :node_bytes,
        Application.get_env(:lasso, :websocket_ingress_node_byte_limit, @node_bytes)
      )

    owner_bytes =
      Keyword.get(
        opts,
        :owner_bytes,
        Application.get_env(:lasso, :websocket_ingress_owner_byte_limit, @owner_bytes)
      )

    owner_messages = Keyword.get(opts, :owner_messages, @owner_messages)
    shards = Keyword.get(opts, :shards, @shards)

    unless Enum.all?(
             [node_bytes, owner_bytes, owner_messages, shards],
             &(is_integer(&1) and &1 > 0)
           ) and
             owner_bytes <= node_bytes and div(node_bytes, shards) >= 256 do
      raise ArgumentError, "invalid WebSocket ingress limits"
    end

    table =
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    config = %{
      shards: shards,
      node_bytes: node_bytes,
      shard_bytes: div(node_bytes, shards),
      owner_bytes: owner_bytes,
      owner_messages: owner_messages
    }

    :ets.insert(table, {:config, config})
    for shard <- 0..(shards - 1), do: :ets.insert(table, {shard, 0, %{}})
    :ets.insert(table, {:stats, 0, 0, 0})
    table
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Reserves memory before sending; overload must be handled by the stream owner."
  @spec send(GenServer.server(), term(), :info | :cast, atom()) :: :ok | error()
  def send(destination, message, kind \\ :info, table \\ @table) when kind in [:info, :cast] do
    with pid when is_pid(pid) <- GenServer.whereis(destination),
         true <- Process.alive?(pid),
         {:ok, token} <- reserve(table, pid, :erlang.external_size(message)) do
      envelope = {:stream_ingress, token, message}

      case kind do
        :info -> Kernel.send(pid, envelope)
        :cast -> GenServer.cast(pid, envelope)
      end

      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :recipient_down}
    end
  end

  @doc "Releases an admitted envelope exactly once, including on handler failure."
  @spec consume(token() | nil, (-> result)) :: result when result: term()
  def consume(token, fun) when is_function(fun, 0) do
    fun.()
  after
    release(token)
  end

  @spec reserve(atom(), pid(), non_neg_integer()) :: {:ok, token()} | error()
  def reserve(table, owner, bytes) when is_pid(owner) and is_integer(bytes) and bytes >= 0 do
    table = :ets.whereis(table)
    [{:config, config}] = :ets.lookup(table, :config)
    shard = :erlang.phash2(owner, config.shards)
    reference = {make_ref(), :atomics.new(1, signed: false)}
    result = reserve_in(table, shard, owner, reference, max(bytes, 256), config, @attempts)
    if match?({:error, _}, result), do: :ets.update_counter(table, :stats, {2, 1})
    result
  rescue
    ArgumentError -> {:error, :budget_unavailable}
  end

  @spec release(token() | nil) :: :ok
  def release(nil), do: :ok

  def release({table, shard, {_ref, released} = reference}) do
    :atomics.put(released, 1, 1)
    _result = release_in(table, shard, reference, @attempts)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec stats(atom()) :: map()
  def stats(table \\ @table) do
    [{:config, config}] = :ets.lookup(table, :config)

    {bytes, count} =
      Enum.reduce(0..(config.shards - 1), {0, 0}, fn shard, {bytes, count} ->
        [{^shard, used, entries}] = :ets.lookup(table, shard)
        {bytes + used, count + map_size(entries)}
      end)

    [{:stats, rejected, released, reclaimed}] = :ets.lookup(table, :stats)

    Map.merge(config, %{
      used_bytes: bytes,
      messages: count,
      rejected: rejected,
      released: released,
      reclaimed: reclaimed
    })
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    Process.send_after(self(), :audit, 100)
    {:ok, table}
  end

  @impl true
  def handle_info(:audit, table) do
    audit(table)
    Process.send_after(self(), :audit, 100)
    {:noreply, table}
  end

  @spec audit(atom()) :: :ok
  def audit(table \\ @table) do
    [{:config, config}] = :ets.lookup(table, :config)
    for shard <- 0..(config.shards - 1), do: audit_shard(table, shard, @attempts)
    :ok
  end

  defp reserve_in(_table, _shard, _owner, _reference, _bytes, _config, 0),
    do: {:error, :contention}

  defp reserve_in(table, shard, owner, reference, bytes, config, attempts) do
    [row = {^shard, used, entries}] = :ets.lookup(table, shard)

    {owner_bytes, owner_messages} =
      Enum.reduce(entries, {0, 0}, fn
        {_ref, {^owner, charge}}, {sum, count} -> {sum + charge, count + 1}
        _, total -> total
      end)

    cond do
      not Process.alive?(owner) ->
        {:error, :recipient_down}

      owner_messages >= config.owner_messages ->
        {:error, :owner_messages}

      owner_bytes + bytes > config.owner_bytes ->
        {:error, :owner_bytes}

      used + bytes > config.shard_bytes or map_size(entries) >= @shard_messages ->
        {:error, :node_capacity}

      true ->
        next = {shard, used + bytes, Map.put(entries, reference, {owner, bytes})}

        if replace(table, row, next),
          do: {:ok, {table, shard, reference}},
          else: reserve_in(table, shard, owner, reference, bytes, config, attempts - 1)
    end
  end

  defp release_in(_table, _shard, _reference, 0), do: :contended

  defp release_in(table, shard, reference, attempts) do
    [row = {^shard, used, entries}] = :ets.lookup(table, shard)

    case Map.pop(entries, reference) do
      {nil, _} ->
        :ok

      {{_owner, bytes}, remaining} ->
        if replace(table, row, {shard, used - bytes, remaining}) do
          :ets.update_counter(table, :stats, {3, 1})
          :ok
        else
          release_in(table, shard, reference, attempts - 1)
        end
    end
  end

  defp audit_shard(_table, _shard, 0), do: :ok

  defp audit_shard(table, shard, attempts) do
    [row = {^shard, used, entries}] = :ets.lookup(table, shard)

    {remaining, bytes, removed} =
      Enum.reduce(entries, {%{}, 0, []}, fn
        {ref, {owner, charge} = entry}, {kept, reclaimed, removed} ->
          {_id, released} = ref

          if not Process.alive?(owner) or :atomics.get(released, 1) == 1 do
            {kept, reclaimed + charge, [ref | removed]}
          else
            {Map.put(kept, ref, entry), reclaimed, removed}
          end
      end)

    if removed != [] do
      if replace(table, row, {shard, used - bytes, remaining}) do
        :ets.update_counter(table, :stats, {4, length(removed)})
      else
        audit_shard(table, shard, attempts - 1)
      end
    end

    :ok
  end

  defp replace(table, old, new), do: :ets.select_replace(table, [{old, [], [{:const, new}]}]) == 1
end
