defmodule Lasso.Core.Streaming.ContinuityBudget do
  @moduledoc false

  use GenServer

  @default_node_limit 128 * 1_024 * 1_024
  @default_stream_limit 16 * 1_024 * 1_024
  @default_client_limit 16 * 1_024 * 1_024
  @default_delivery_message_limit 32

  @type rejection ::
          :budget_unavailable
          | :client_limit
          | :client_message_limit
          | :node_limit
          | :stream_limit

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec set_stream_bytes(GenServer.name(), pid(), non_neg_integer()) ::
          :ok | {:error, rejection()}
  def set_stream_bytes(budget \\ __MODULE__, owner \\ self(), bytes)
      when is_pid(owner) and is_integer(bytes) and bytes >= 0 do
    safe_call(budget, {:set_stream_bytes, owner, bytes})
  end

  @spec reserve_delivery(GenServer.name(), pid(), non_neg_integer()) ::
          :ok | {:error, rejection()}
  def reserve_delivery(budget \\ __MODULE__, owner, bytes)
      when is_pid(owner) and is_integer(bytes) and bytes >= 0 do
    safe_call(budget, {:reserve_delivery, owner, bytes})
  end

  @doc "Admits one bounded fanout chunk with a single owner-ledger call."
  @spec reserve_deliveries(GenServer.name(), [{pid(), non_neg_integer()}]) :: [
          :ok | {:error, rejection()}
        ]
  def reserve_deliveries(budget \\ __MODULE__, deliveries)
      when is_list(deliveries) and length(deliveries) <= 64 do
    case safe_call(budget, {:reserve_deliveries, deliveries}) do
      results when is_list(results) -> results
      {:error, reason} -> Enum.map(deliveries, fn _ -> {:error, reason} end)
    end
  end

  @spec release_delivery(GenServer.name(), pid(), non_neg_integer()) :: :ok
  def release_delivery(budget \\ __MODULE__, owner, bytes)
      when is_pid(owner) and is_integer(bytes) and bytes >= 0 do
    GenServer.cast(budget, {:release_delivery, owner, bytes})
  catch
    :exit, _reason -> :ok
  end

  @spec release_owner(GenServer.name(), pid()) :: :ok
  def release_owner(budget \\ __MODULE__, owner \\ self()) when is_pid(owner) do
    GenServer.cast(budget, {:release_owner, owner})
  catch
    :exit, _reason -> :ok
  end

  @spec stats(GenServer.name()) :: map()
  def stats(budget \\ __MODULE__) do
    case safe_call(budget, :stats) do
      {:error, :budget_unavailable} -> %{available?: false}
      stats -> stats
    end
  end

  @impl true
  def init(opts) do
    node_limit =
      positive_limit(
        opts,
        :node_limit,
        Application.get_env(:lasso, :websocket_continuity_node_byte_limit, @default_node_limit)
      )

    stream_limit =
      positive_limit(
        opts,
        :stream_limit,
        Application.get_env(
          :lasso,
          :websocket_continuity_stream_byte_limit,
          @default_stream_limit
        )
      )

    client_limit =
      positive_limit(
        opts,
        :client_limit,
        Application.get_env(
          :lasso,
          :websocket_continuity_client_byte_limit,
          @default_client_limit
        )
      )

    delivery_message_limit =
      positive_limit(
        opts,
        :delivery_message_limit,
        Application.get_env(
          :lasso,
          :websocket_downstream_mailbox_limit,
          @default_delivery_message_limit
        )
      )

    if stream_limit > node_limit or client_limit > node_limit do
      raise ArgumentError, "continuity owner limits cannot exceed the node limit"
    end

    {:ok,
     %{
       node_limit: node_limit,
       stream_limit: stream_limit,
       client_limit: client_limit,
       delivery_message_limit: delivery_message_limit,
       used_bytes: 0,
       peak_bytes: 0,
       owners: %{},
       monitors: %{},
       accepted: 0,
       rejected: 0,
       released: 0,
       reclaimed: 0
     }}
  end

  @impl true
  def handle_call({:set_stream_bytes, owner, bytes}, _from, state) do
    current = owner_bytes(state, owner, :stream_bytes)
    change_owner_bytes(state, owner, :stream_bytes, current, bytes, state.stream_limit)
  end

  def handle_call({:reserve_delivery, owner, bytes}, _from, state) do
    reserve_delivery_in(state, owner, bytes)
  end

  def handle_call({:reserve_deliveries, deliveries}, _from, state) do
    {results, state} =
      Enum.map_reduce(deliveries, state, fn {owner, bytes}, state ->
        {:reply, result, state} = reserve_delivery_in(state, owner, bytes)
        {result, state}
      end)

    {:reply, results, state}
  end

  def handle_call(:stats, _from, state) do
    stream_bytes = state.owners |> Map.values() |> Enum.sum_by(& &1.stream_bytes)
    delivery_bytes = state.owners |> Map.values() |> Enum.sum_by(& &1.delivery_bytes)
    delivery_messages = state.owners |> Map.values() |> Enum.sum_by(& &1.delivery_messages)

    {:reply,
     %{
       available?: true,
       node_limit: state.node_limit,
       stream_limit: state.stream_limit,
       client_limit: state.client_limit,
       delivery_message_limit: state.delivery_message_limit,
       used_bytes: state.used_bytes,
       stream_bytes: stream_bytes,
       delivery_bytes: delivery_bytes,
       delivery_messages: delivery_messages,
       peak_bytes: state.peak_bytes,
       owners: map_size(state.owners),
       accepted: state.accepted,
       rejected: state.rejected,
       released: state.released,
       reclaimed: state.reclaimed
     }, state}
  end

  @impl true
  def handle_cast({:release_delivery, owner, bytes}, state) do
    current = owner_bytes(state, owner, :delivery_bytes)
    next = max(current - bytes, 0)

    message_delta =
      if owner_bytes(state, owner, :delivery_messages) > 0,
        do: -1,
        else: 0

    {:noreply,
     apply_owner_bytes(
       state,
       owner,
       :delivery_bytes,
       current,
       next,
       :released,
       message_delta
     )}
  end

  def handle_cast({:release_owner, owner}, state) do
    {:noreply, remove_owner(state, owner, :released)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case state.monitors do
      %{^monitor => ^owner} -> {:noreply, remove_owner(state, owner, :reclaimed)}
      _stale -> {:noreply, state}
    end
  end

  defp reserve_delivery_in(state, owner, bytes) do
    current = owner_bytes(state, owner, :delivery_bytes)
    messages = owner_bytes(state, owner, :delivery_messages)

    cond do
      not Process.alive?(owner) ->
        reject(state, :budget_unavailable, :delivery_bytes)

      current + bytes > state.client_limit ->
        reject(state, :client_limit, :delivery_bytes)

      messages >= state.delivery_message_limit ->
        reject(state, :client_message_limit, :delivery_messages)

      state.used_bytes + bytes > state.node_limit ->
        reject(state, :node_limit, :delivery_bytes)

      true ->
        state =
          apply_owner_bytes(
            state,
            owner,
            :delivery_bytes,
            current,
            current + bytes,
            :accepted,
            1
          )

        {:reply, :ok, state}
    end
  end

  defp change_owner_bytes(state, owner, field, current, next, owner_limit) do
    cond do
      not Process.alive?(owner) ->
        reject(state, :budget_unavailable, field)

      next > owner_limit ->
        reject(state, :stream_limit, field)

      state.used_bytes - current + next > state.node_limit ->
        reject(state, :node_limit, field)

      true ->
        state = apply_owner_bytes(state, owner, field, current, next, :accepted)
        {:reply, :ok, state}
    end
  end

  defp apply_owner_bytes(state, owner, field, current, next, stat, message_delta \\ 0) do
    delta = next - current
    state = ensure_owner(state, owner)
    entry = Map.fetch!(state.owners, owner)

    entry =
      entry
      |> Map.put(field, next)
      |> Map.update!(:delivery_messages, &max(&1 + message_delta, 0))

    used_bytes = max(state.used_bytes + delta, 0)

    state = %{
      state
      | owners: Map.put(state.owners, owner, entry),
        used_bytes: used_bytes,
        peak_bytes: max(state.peak_bytes, used_bytes),
        accepted: state.accepted + if(stat == :accepted, do: 1, else: 0),
        released: state.released + if(stat == :released and delta < 0, do: 1, else: 0)
    }

    maybe_remove_empty_owner(state, owner)
  end

  defp ensure_owner(state, owner) do
    if Map.has_key?(state.owners, owner) do
      state
    else
      monitor = Process.monitor(owner)

      %{
        state
        | owners:
            Map.put(state.owners, owner, %{
              monitor: monitor,
              stream_bytes: 0,
              delivery_bytes: 0,
              delivery_messages: 0
            }),
          monitors: Map.put(state.monitors, monitor, owner)
      }
    end
  end

  defp maybe_remove_empty_owner(state, owner) do
    case Map.get(state.owners, owner) do
      %{stream_bytes: 0, delivery_bytes: 0, delivery_messages: 0} ->
        remove_owner(state, owner, :empty)

      _active_or_missing ->
        state
    end
  end

  defp remove_owner(state, owner, reason) do
    case Map.pop(state.owners, owner) do
      {nil, _owners} ->
        state

      {entry, owners} ->
        Process.demonitor(entry.monitor, [:flush])
        released_bytes = entry.stream_bytes + entry.delivery_bytes

        %{
          state
          | owners: owners,
            monitors: Map.delete(state.monitors, entry.monitor),
            used_bytes: max(state.used_bytes - released_bytes, 0),
            released: state.released + if(reason == :released, do: 1, else: 0),
            reclaimed: state.reclaimed + if(reason == :reclaimed, do: 1, else: 0)
        }
    end
  end

  defp reject(state, reason, field) do
    :telemetry.execute(
      [:lasso, :stream, :continuity_budget, :rejected],
      %{count: 1, retained_bytes: state.used_bytes, limit_bytes: state.node_limit},
      %{reason: reason, kind: field}
    )

    {:reply, {:error, reason}, %{state | rejected: state.rejected + 1}}
  end

  defp owner_bytes(state, owner, field) do
    state.owners |> Map.get(owner, %{}) |> Map.get(field, 0)
  end

  defp safe_call(budget, message) do
    GenServer.call(budget, message)
  catch
    :exit, _reason -> {:error, :budget_unavailable}
  end

  defp positive_limit(opts, key, fallback) do
    case Keyword.get(opts, key, fallback) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end
end
