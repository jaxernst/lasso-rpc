defmodule Lasso.BlockPublication.Handoff do
  @moduledoc """
  Bounded local waiting during publication handoff. Notifications only wake a
  reader; the serving gate remains the authority. No journal work is requested.
  """
  alias Lasso.BlockPublication.Gate

  @table :lasso_block_publications
  @max_wait_us 1_000_000

  @spec await(Gate.key(), integer(), reference() | nil, atom()) ::
          {:ok, Gate.grant()} | {:error, atom()} | :unmanaged
  def await(key, request_deadline_us, caller_monitor, table \\ @table) do
    cutoff = min(request_deadline_us, System.monotonic_time(:microsecond) + @max_wait_us)
    reply_alias = :erlang.alias()
    topic = topic(key, table)

    try do
      :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, topic, metadata: reply_alias)
      read_or_wait(key, table, cutoff, request_deadline_us, caller_monitor, reply_alias)
    rescue
      ArgumentError -> {:error, :publication_changing}
    after
      :erlang.unalias(reply_alias)
      unsubscribe(topic)
      flush(reply_alias)
    end
  end

  @doc "Wakes local readers after a serving gate revision changes."
  @spec notify(Gate.key(), atom()) :: :ok | {:error, term()}
  def notify(key, table) do
    Phoenix.PubSub.local_broadcast(Lasso.PubSub, topic(key, table), :changed, __MODULE__)
  rescue
    ArgumentError -> :ok
  end

  @doc "PubSub dispatcher delivering notifications through revocable reply aliases."
  @spec dispatch([{pid(), term()}], term(), :changed) :: :ok
  def dispatch(entries, _from, :changed) do
    for {_pid, reply_alias} <- entries,
        is_reference(reply_alias),
        do: send(reply_alias, {:publication_changed, reply_alias})

    :ok
  end

  @doc "Local notification topic for an isolated gate table and publication scope."
  @spec topic(Gate.key(), atom()) :: String.t()
  def topic(key, table \\ @table),
    do: "block_publication_handoff:" <> Base.url_encode64(:erlang.term_to_binary({table, key}))

  defp read_or_wait(key, table, cutoff, deadline, caller_monitor, reply_alias) do
    now = System.monotonic_time(:microsecond)

    if now >= deadline do
      {:error, :deadline_exhausted}
    else
      case Gate.read(key, System.system_time(:millisecond), table) do
        {:error, :publication_changing} when now < cutoff ->
          receive do
            {:publication_changed, ^reply_alias} ->
              read_or_wait(key, table, cutoff, deadline, caller_monitor, reply_alias)

            {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
              {:error, :caller_abandoned}
          after
            div(cutoff - now + 999, 1_000) ->
              read_or_wait(key, table, cutoff, deadline, caller_monitor, reply_alias)
          end

        result ->
          result
      end
    end
  end

  defp unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, topic)
  rescue
    ArgumentError -> :ok
  end

  defp flush(reply_alias) do
    receive do
      {:publication_changed, ^reply_alias} -> flush(reply_alias)
    after
      0 -> :ok
    end
  end
end
