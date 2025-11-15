defmodule LassoWeb.Dashboard.EventBuffer do
  @moduledoc """
  GenServer that manages event buffering for the Dashboard LiveView.
  Handles batching, pressure management, and periodic flushing.
  """

  use GenServer
  require Logger
  alias LassoWeb.Dashboard.Constants

  @type event_mode :: :normal | :throttled | :summary

  defmodule State do
    @moduledoc false
    defstruct buffer: [],
              buffer_count: 0,
              batch_interval: Constants.default_batch_interval(),
              event_mode: :normal,
              dropped_count: 0,
              flush_timer_ref: nil
  end

  # Client API

  @doc """
  Start the event buffer GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Push an event to the buffer.
  """
  def push(event) do
    GenServer.cast(__MODULE__, {:push_event, event})
  end

  @doc """
  Get current buffer stats.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Manually flush the buffer.
  """
  def flush do
    GenServer.cast(__MODULE__, :flush)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %State{
      buffer: [],
      buffer_count: 0,
      batch_interval: Constants.default_batch_interval(),
      event_mode: :normal,
      dropped_count: 0
    }

    # Schedule first flush
    timer_ref = schedule_flush(state.batch_interval)
    {:ok, %{state | flush_timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast({:push_event, event}, state) do
    state = check_mailbox_pressure(state)

    new_state =
      case state.event_mode do
        :summary ->
          # Drop events in summary mode
          %{state | dropped_count: state.dropped_count + 1}

        _ ->
          # Add event to buffer
          new_buffer = [event | state.buffer]
          new_count = state.buffer_count + 1

          state = %{state | buffer: new_buffer, buffer_count: new_count}

          # Early flush if buffer is full
          if new_count >= Constants.max_buffer_size() do
            flush_buffer(state)
          else
            state
          end
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:flush, state) do
    {:noreply, flush_buffer(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      buffer_count: state.buffer_count,
      event_mode: state.event_mode,
      dropped_count: state.dropped_count,
      batch_interval: state.batch_interval
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    state = flush_buffer(state)

    # Schedule next flush
    timer_ref = schedule_flush(state.batch_interval)
    {:noreply, %{state | flush_timer_ref: timer_ref}}
  end

  # Private Helpers

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_timer, interval)
  end

  defp flush_buffer(%State{buffer_count: 0} = state), do: state

  defp flush_buffer(state) do
    # Emit telemetry
    :telemetry.execute(
      [:lasso_web, :dashboard, :event_buffer_flush],
      %{buffer_size: state.buffer_count},
      %{}
    )

    # Broadcast flush to all dashboard LiveView subscribers
    events_batch = Enum.reverse(state.buffer)

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "dashboard:event_buffer",
      {:events_batch, events_batch}
    )

    # Reset buffer
    %{state | buffer: [], buffer_count: 0}
  end

  defp check_mailbox_pressure(state) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)
    current_mode = state.event_mode

    {new_mode, new_interval} =
      cond do
        queue_len > Constants.mailbox_drop_threshold() ->
          Logger.warning("EventBuffer mailbox critical: #{queue_len} messages, dropping events")
          {:summary, 500}

        queue_len > Constants.mailbox_throttle_threshold() ->
          Logger.info("EventBuffer mailbox elevated: #{queue_len} messages, throttling")
          {:throttled, 200}

        true ->
          {:normal, Constants.default_batch_interval()}
      end

    state = %{state | event_mode: new_mode, batch_interval: new_interval}

    # Broadcast mode change if state transitioned
    if current_mode != new_mode and new_mode != :normal do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "dashboard:event_buffer",
        {:mode_change, new_mode}
      )
    end

    state
  end
end
