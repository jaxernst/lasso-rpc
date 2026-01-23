defmodule LassoWeb.Dashboard.EventDedup do
  @moduledoc """
  Simple MapSet-based deduplication for cross-node PubSub events.

  Events received from multiple cluster nodes may be duplicates. This module
  tracks recently seen event IDs to prevent duplicate processing.

  Uses a 60-second deduplication window with monotonic timestamps for cleanup.
  """

  @type t :: %__MODULE__{
          seen: MapSet.t(),
          cleanup_ts: integer()
        }

  defstruct seen: MapSet.new(), cleanup_ts: 0

  @dedup_window_ms 60_000

  @doc """
  Creates a new deduplication state.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      seen: MapSet.new(),
      cleanup_ts: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Checks if an event is a duplicate and adds it to the seen set if not.

  Returns `{:ok, new_state}` if event is new, or `{:duplicate, state}` if seen before.
  """
  @spec check_and_add(t(), %{request_id: String.t()}) :: {:ok, t()} | {:duplicate, t()}
  def check_and_add(%__MODULE__{seen: seen} = state, %{request_id: request_id})
      when is_binary(request_id) do
    if MapSet.member?(seen, request_id) do
      {:duplicate, state}
    else
      {:ok, %{state | seen: MapSet.put(seen, request_id)}}
    end
  end

  def check_and_add(state, _event_without_request_id) do
    {:ok, state}
  end

  @doc """
  Expires old entries from the deduplication window.

  Call periodically (e.g., every 60 seconds) to prevent memory growth.
  """
  @spec expire_old(t()) :: t()
  def expire_old(%__MODULE__{cleanup_ts: last_cleanup} = state) do
    now = System.monotonic_time(:millisecond)

    if now - last_cleanup >= @dedup_window_ms do
      %{state | seen: MapSet.new(), cleanup_ts: now}
    else
      state
    end
  end
end
